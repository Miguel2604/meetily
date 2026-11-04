import AppKit
import Core
import Summary
import Transcription
import UniformTypeIdentifiers

/// Meeting details (MeetingDetailsSplitView.tsx): transcript with audio playback on the left; summary and
/// notes editors with generate, template, model and language pickers on the right.
final class MeetingViewController: NSSplitViewController {
    private let model: AppModel
    private let meetingID: String
    private let summary: SummaryController
    private var meeting: Meeting?
    private var transcripts: [Transcript] = []

    // Transcript pane
    private let transcriptList = TranscriptListView()
    private let titleLabel = NSTextField.meety("", font: Typography.title)
    private let dateLabel = NSTextField.meety("", font: Typography.callout, color: .secondaryLabelColor)
    private let audioSlot = NSStackView()
    private var audioBar: AudioBarView?
    private lazy var copyTranscriptButton = small("Copy", "doc.on.doc", #selector(copyTranscript), tip: "Copy Transcript")
    private lazy var folderButton = small("Recording", "folder", #selector(openFolder), tip: "Open Recording Folder")
    private lazy var enhanceButton = small("Enhance", "wand.and.stars", #selector(retranscribe), tip: "Retranscribe to enhance your recorded audio")

    // Summary pane
    private let tabs = NSSegmentedControl(labels: ["Summary", "Notes"], trackingMode: .selectOne, target: nil, action: nil)
    private lazy var generateButton = small("Generate Summary", "sparkles", #selector(generate), tip: "Generate AI Summary")
    private lazy var stopButton = small("Stop", "stop.fill", #selector(stopGeneration), tip: "Stop summary generation")
    private let templatePopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let languagePopup = NSPopUpButton()
    private lazy var saveButton = small("Save", "square.and.arrow.down", #selector(saveSummary), tip: "Save edits")
    private lazy var copySummaryButton = small("Copy", "doc.on.doc", #selector(copySummary), tip: "Copy Summary")
    private lazy var exportButton = small("Export…", "square.and.arrow.up", #selector(exportSummary), tip: "Export the summary as Markdown")
    private let customPrompt = NSTextField()
    private let summaryEditor = MarkdownEditor()
    private let notesEditor = MarkdownEditor()
    private let writing = NSStackView()
    private let errorLabel = NSTextField.meety("", font: Typography.callout, color: .systemRed)
    private lazy var empty = EmptyStateView(
        symbol: "doc.questionmark", title: "No Summary Generated Yet",
        message: "Generate an AI-powered summary of your meeting transcript to get key points, action items, and decisions.",
        action: ("Generate Summary", "sparkles", self, #selector(generate)))
    private var notesSave: Task<Void, Never>?
    /// Set by typing only, so leaving before the notes load never writes the empty editor over them.
    private var notesEdited = false
    private var templates: [(id: String, name: String, description: String)] = []
    private var modelChoices: [(provider: String, model: String)] = []

    init(model: AppModel, meetingID: String) {
        self.model = model
        self.meetingID = meetingID
        summary = SummaryController(meetingID: meetingID, store: model.store, service: model.summaries)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let left = NSSplitViewItem(viewController: Placeholder(transcriptPane()))
        left.minimumThickness = 300
        let right = NSSplitViewItem(viewController: Placeholder(summaryPane()))
        right.minimumThickness = 360
        addSplitViewItem(left)
        addSplitViewItem(right)
        splitView.autosaveName = "MeetingSplit"
        track { [weak self] in self?.renderSummary() }
        Task { await load() }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        audioBar?.stop()
        Task { await flushEdits() }
    }

    // MARK: Build

    private func small(_ title: String, _ symbol: String, _ action: Selector, tip: String) -> NSButton {
        let button = NSButton.meety(title, symbol: symbol, target: self, action: action)
        button.controlSize = .regular
        button.toolTip = tip
        return button
    }

    private func transcriptPane() -> NSView {
        titleLabel.maximumNumberOfLines = 2
        let actions = NSStackView(views: [copyTranscriptButton, folderButton, enhanceButton])
        let header = NSStackView(views: [titleLabel, dateLabel, actions])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        header.setCustomSpacing(12, after: dateLabel)
        transcriptList.onSelect = { [weak self] row in self?.audioBar?.seek(to: row.start) }
        audioSlot.orientation = .vertical
        let stack = NSStackView(views: [header, transcriptList, audioSlot])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 12, right: 12)
        for v in [header, transcriptList, audioSlot] as [NSView] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        transcriptList.setContentHuggingPriority(.defaultLow, for: .vertical)
        let root = SafeAreaContainer(stack)
        return root
    }

    private func summaryPane() -> NSView {
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(switchTab)
        templatePopup.target = self
        templatePopup.action = #selector(templateChosen)
        templatePopup.toolTip = "Select summary template"
        modelPopup.target = self
        modelPopup.action = #selector(modelChosen)
        modelPopup.toolTip = "Summary model"
        languagePopup.target = self
        languagePopup.action = #selector(languageChosen)
        languagePopup.setAccessibilityLabel("Set summary language")
        for popup in [templatePopup, modelPopup, languagePopup] { popup.controlSize = .regular }
        customPrompt.placeholderString = "Add context for AI summary. For example people involved, meeting overview, objective etc..."
        customPrompt.lineBreakMode = .byTruncatingTail

        let row1 = NSStackView(views: [tabs, NSView(), saveButton, copySummaryButton, exportButton])
        let row2 = NSStackView(views: [generateButton, stopButton, templatePopup])
        let row3 = NSStackView(views: [modelPopup, languagePopup])
        row3.distribution = .fillEqually
        // A narrow pane truncates the pickers and drops Export, then Copy, instead of widening the window past the screen.
        for v in [templatePopup, modelPopup, languagePopup, customPrompt] as [NSView] { v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        row1.setVisibilityPriority(.detachOnlyIfNecessary, for: exportButton)
        row1.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 900), for: copySummaryButton)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.startAnimation(nil)
        writing.setViews([spinner, NSTextField.meety("Writing the summary…", font: Typography.callout, color: .secondaryLabelColor)], in: .center)
        writing.orientation = .vertical

        summaryEditor.onChange = { [weak self] text in self?.summary.markdown = text }
        notesEditor.onChange = { [weak self] _ in
            self?.notesEdited = true
            self?.scheduleNotesSave()
        }
        notesEditor.isHidden = true
        errorLabel.isHidden = true

        let body = NSView()
        for v in [summaryEditor, notesEditor, writing, empty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: body.leadingAnchor), v.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                v.topAnchor.constraint(equalTo: body.topAnchor), v.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            ])
        }
        let stack = NSStackView(views: [row1, row2, row3, customPrompt, errorLabel, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 0, right: 16)
        for v in [row1, row2, row3, customPrompt, errorLabel, body] as [NSView] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
        let root = SafeAreaContainer(stack)
        root.wantsLayer = true
        return root
    }

    // MARK: Load

    private func load() async {
        do {
            meeting = try await model.store.meeting(id: meetingID)
            transcripts = try await model.store.transcripts(meetingID: meetingID)
            notesEditor.markdown = try await model.store.notes(meetingID: meetingID) ?? ""
        } catch {
            model.present(error)
        }
        renderMeeting()
        await fillPickers()
        renderSummary()
        await summary.load()
    }

    private func renderMeeting() {
        titleLabel.stringValue = summary.title ?? meeting?.title ?? ""
        dateLabel.stringValue = meeting?.createdDate?.formatted(date: .long, time: .shortened) ?? ""
        transcriptList.set(transcripts.map { .init(start: $0.audioStartTime ?? 0, text: $0.transcript, source: Self.source($0.speaker)) })
        copyTranscriptButton.isEnabled = !transcripts.isEmpty
        let folder = meeting?.folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        folderButton.isEnabled = folder != nil
        enhanceButton.isEnabled = folder.flatMap(OfflineTranscription.findAudio(in:)) != nil
        audioBar?.stop()
        audioSlot.arrangedSubviews.forEach { $0.removeFromSuperview() }
        audioBar = folder.flatMap(OfflineTranscription.findAudio(in:)).map(AudioBarView.init(url:))
        if let audioBar { audioSlot.addArrangedSubview(audioBar) }
        languagePopup.isEnabled = folder != nil
    }

    private static func source(_ speaker: String?) -> String? {
        switch speaker {
        case "mic", "microphone", "user": "Microphone"
        case "system", "speaker": "System"
        default: nil
        }
    }

    private func fillPickers() async {
        templates = Templates.list()
        templatePopup.removeAllItems()
        for template in templates {
            templatePopup.addItem(withTitle: template.name)
            templatePopup.lastItem?.toolTip = template.description
        }
        templatePopup.selectItem(at: templates.firstIndex { $0.id == model.summaryTemplate } ?? 0)

        let config = try? await model.store.modelConfig()
        let builtIn = await model.builtIn.models().filter { $0.status == .available }.map { (provider: "builtin-ai", model: $0.model.name) }
        modelChoices = (config.map { [(provider: $0.provider, model: $0.model)] } ?? []) + builtIn.filter { $0.model != config?.model }
        modelPopup.removeAllItems()
        for choice in modelChoices { modelPopup.addItem(withTitle: "\(choice.provider) · \(choice.model)") }
        if modelChoices.isEmpty { modelPopup.addItem(withTitle: "No model — set one in Settings") }
        modelPopup.selectItem(at: 0)

        languagePopup.removeAllItems()
        let languages = [("", "Auto (match transcript)")] + TranscribeSheet.languages.dropFirst().map { ($0.code, $0.name) }
        for (code, name) in languages {
            languagePopup.addItem(withTitle: name)
            languagePopup.lastItem?.representedObject = code
        }
        let current = folderURL.flatMap(MeetingMetadata.summaryLanguage(in:)) ?? ""
        languagePopup.selectItem(at: max(0, languagePopup.indexOfItem(withRepresentedObject: current)))
    }

    private var folderURL: URL? { meeting?.folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    // MARK: Render

    private func renderSummary() {
        let generating = summary.isGenerating
        let notes = tabs.selectedSegment == 1
        summaryEditor.markdown = summary.markdown
        summaryEditor.isHidden = notes || generating || !summary.hasSummary
        notesEditor.isHidden = !notes
        writing.isHidden = notes || !generating
        empty.isHidden = notes || generating || summary.hasSummary
        empty.button?.title = summary.error == nil ? "Generate Summary" : "Retry summary"
        empty.button?.isEnabled = !modelChoices.isEmpty || meeting == nil
        empty.message = modelChoices.isEmpty && meeting != nil
            ? "Please select a model in Settings first."
            : "Generate an AI-powered summary of your meeting transcript to get key points, action items, and decisions."
        errorLabel.stringValue = summary.error ?? ""
        errorLabel.isHidden = notes || summary.error == nil
        generateButton.title = summary.hasSummary ? "Regenerate Summary" : "Generate Summary"
        generateButton.isHidden = generating
        stopButton.isHidden = !generating
        for control in [templatePopup, modelPopup, languagePopup, customPrompt] as [NSControl] { control.isEnabled = !generating }
        saveButton.isEnabled = summary.isDirty && !generating
        copySummaryButton.isEnabled = summary.hasSummary && !generating
        exportButton.isEnabled = summary.hasSummary && !generating
        for v in [generateButton, stopButton, templatePopup, modelPopup, languagePopup, customPrompt] as [NSView] { v.superview?.isHidden = notes && v !== customPrompt }
        customPrompt.isHidden = notes
        for v in [saveButton, copySummaryButton, exportButton] { v.isHidden = notes }
        if let title = summary.title, title != titleLabel.stringValue, meeting != nil {
            titleLabel.stringValue = title
            Task { await model.reloadMeetings() }
        }
    }

    // MARK: Actions

    @objc private func switchTab() { renderSummary() }

    @objc private func generate() {
        guard let choice = modelChoices.first.map({ _ in modelChoices[max(0, modelPopup.indexOfSelectedItem)] }) else {
            (NSApp.delegate as? AppDelegate)?.showSettings(tab: .summary)
            return
        }
        let language = folderURL.flatMap(MeetingMetadata.summaryLanguage(in:)) ?? model.settings.summaryLanguage
        let template = templates.indices.contains(templatePopup.indexOfSelectedItem) ? templates[templatePopup.indexOfSelectedItem].id : "standard_meeting"
        Task {
            await summary.generate(provider: choice.provider, model: choice.model, templateID: template,
                                   customPrompt: customPrompt.stringValue, language: language)
            if !NSApp.isActive { await model.summaryFinished(meetingID: meetingID) } // only when Meety is in the background
        }
    }

    @objc private func stopGeneration() { Task { await summary.cancel() } }

    @objc private func templateChosen() {
        if templates.indices.contains(templatePopup.indexOfSelectedItem) { model.summaryTemplate = templates[templatePopup.indexOfSelectedItem].id }
    }

    @objc private func modelChosen() {
        guard modelChoices.indices.contains(modelPopup.indexOfSelectedItem) else { return }
        let choice = modelChoices[modelPopup.indexOfSelectedItem]
        Task {
            let config = try? await model.store.modelConfig()
            try? await model.store.saveModelConfig(provider: choice.provider, model: choice.model,
                                                   whisperModel: config?.whisperModel ?? "large-v3-turbo", ollamaEndpoint: config?.ollamaEndpoint)
            if choice.provider == "builtin-ai" { model.settings.builtInSummaryModel = choice.model }
        }
    }

    @objc private func languageChosen() {
        guard let folder = folderURL else { return }
        let code = languagePopup.selectedItem?.representedObject as? String
        do { try MeetingMetadata.setSummaryLanguage(code?.isEmpty == false ? code : nil, in: folder) } catch {
            model.present(error)
        }
    }

    @objc func saveSummary() {
        Task {
            do { try await summary.save() } catch { model.present(error) }
        }
    }

    @objc private func copyTranscript() {
        guard let meeting else { return }
        copy(SummaryText.transcriptCopy(meetingID: meeting.id, title: titleLabel.stringValue, date: meeting.createdDate ?? Date(), transcripts: transcripts))
    }

    private var summaryCopyText: String? {
        guard let meeting, summary.hasSummary else { return nil }
        return SummaryText.summaryCopy(meetingID: meeting.id, title: titleLabel.stringValue, date: meeting.createdDate ?? Date(), markdown: summary.markdown)
    }

    @objc private func copySummary() { summaryCopyText.map(copy) }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func exportSummary() {
        guard let text = summaryCopyText, let window = view.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = Paths.sanitizeFilename(titleLabel.stringValue) + " summary.md"
        panel.beginSheetModal(for: window) { [model] response in
            guard response == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { model.present(error) }
        }
    }

    @objc private func openFolder() {
        guard let folder = folderURL else { return }
        NSWorkspace.shared.open(folder)
    }

    @objc private func retranscribe() {
        presentAsSheet(TranscribeSheet(model: model, job: .retranscribe(meetingID: meetingID)) { [weak self] _ in
            Task { [weak self] in
                guard let self else { return }
                transcripts = (try? await model.store.transcripts(meetingID: meetingID)) ?? transcripts
                renderMeeting()
            }
        })
    }

    private func scheduleNotesSave() {
        notesSave?.cancel()
        notesSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.saveNotes()
        }
    }

    private func saveNotes() async {
        notesSave?.cancel()
        notesSave = nil
        guard notesEdited else { return }
        notesEdited = false
        do { try await model.store.saveNotes(meetingID: meetingID, markdown: notesEditor.markdown) } catch { model.present(error) }
    }

    /// Saves pending summary and notes edits (leaving the meeting, quitting).
    func flushEdits() async {
        if summary.isDirty { try? await summary.save() }
        await saveNotes()
    }
}

/// Lays a view out inside its parent's safe area (below the title bar).
final class SafeAreaContainer: NSView {
    init(_ content: NSView) {
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }
}
