import AppKit
import Core
import Summary
import Transcription
import UniformTypeIdentifiers

/// Meeting details: the summary or notes document, with the recording playing from a floating glass capsule, and the
/// transcript in a trailing inspector. The window toolbar drives it: Summary/Notes, Generate (template, model,
/// language and context in a popover), Share, More and the transcript toggle (MainWindowController).
final class MeetingViewController: NSSplitViewController, NSMenuItemValidation {
    enum Mode { case summary, notes }

    private let model: AppModel
    private let meetingID: String
    let summary: SummaryController
    private var meeting: Meeting?
    private var transcripts: [Transcript] = []
    var mode = Mode.summary { didSet { renderSummary() } }

    // Transcript inspector
    private let transcriptList = TranscriptListView()

    // Document
    private let titleLabel = NSTextField.meety("", font: Typography.largeTitle)
    private let dateLabel = NSTextField.meety("", font: Typography.callout, color: .secondaryLabelColor)
    private let player = NSView()
    private var audioBar: AudioBarView?
    private let summaryEditor = MarkdownEditor()
    private let notesEditor = MarkdownEditor()
    private let writing = NSStackView()
    private let errorLabel = NSTextField.meety("", font: Typography.callout, color: .systemRed)
    private lazy var empty = EmptyStateView(
        symbol: "doc.questionmark", title: "No Summary Generated Yet",
        message: "Generate an AI-powered summary of your meeting transcript to get key points, action items, and decisions.",
        action: ("Generate Summary", "sparkles", self, #selector(generate)))

    // Generate options (popover)
    private let options = NSPopover()
    private let templatePopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let languagePopup = NSPopUpButton()
    private let customPrompt = NSTextField()

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
        let document = NSSplitViewItem(viewController: Placeholder(documentPane()))
        document.minimumThickness = 360
        let inspector = NSSplitViewItem(inspectorWithViewController: Placeholder(transcriptPane()))
        inspector.minimumThickness = 280
        inspector.maximumThickness = 520
        addSplitViewItem(document)
        addSplitViewItem(inspector)
        splitView.autosaveName = "MeetingSplit"
        buildOptions()
        track { [weak self] in self?.renderSummary() }
        Task { await load() }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        audioBar?.stop()
        Task { await flushEdits() }
    }

    // MARK: Build

    private func transcriptPane() -> NSView {
        let heading = NSTextField.meety("Transcript", font: Typography.headline)
        transcriptList.onSelect = { [weak self] row in self?.audioBar?.seek(to: row.start) }
        let stack = NSStackView(views: [heading, transcriptList])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 0, right: 8)
        for v in [heading, transcriptList] as [NSView] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true }
        transcriptList.setContentHuggingPriority(.defaultLow, for: .vertical)
        return SafeAreaContainer(stack)
    }

    private func documentPane() -> NSView {
        titleLabel.maximumNumberOfLines = 2
        let header = NSStackView(views: [titleLabel, dateLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        header.edgeInsets = NSEdgeInsets(top: 0, left: 29, bottom: 0, right: 29) // the editor's text inset plus line padding

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
        // Text clears the floating player.
        for editor in [summaryEditor, notesEditor] {
            editor.automaticallyAdjustsContentInsets = false
            editor.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 72, right: 0)
        }
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
        let stack = NSStackView(views: [header, errorLabel, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
        let root = SafeAreaContainer(stack)

        player.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(player)
        NSLayoutConstraint.activate([
            player.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            player.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            player.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            player.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).withPriority(.defaultHigh),
        ])
        return root
    }

    private func buildOptions() {
        templatePopup.target = self
        templatePopup.action = #selector(templateChosen)
        modelPopup.target = self
        modelPopup.action = #selector(modelChosen)
        languagePopup.target = self
        languagePopup.action = #selector(languageChosen)
        templatePopup.setAccessibilityLabel("Template")
        modelPopup.setAccessibilityLabel("Model")
        languagePopup.setAccessibilityLabel("Summary language")
        customPrompt.placeholderString = "People involved, meeting overview, objective…"
        customPrompt.setAccessibilityLabel("Context for the summary")
        customPrompt.lineBreakMode = .byWordWrapping
        customPrompt.usesSingleLineMode = false
        customPrompt.heightAnchor.constraint(equalToConstant: 56).isActive = true
        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            return label
        }
        let grid = NSGridView(views: [
            [label("Template:"), templatePopup],
            [label("Model:"), modelPopup],
            [label("Language:"), languagePopup],
            [label("Context:"), customPrompt],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.column(at: 1).width = 260
        let go = NSButton.meety("Generate Summary", symbol: "sparkles", role: .primary, target: self, action: #selector(generateFromOptions))
        go.keyEquivalent = "\r"
        let stack = NSStackView(views: [grid, go])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        options.contentViewController = Placeholder(stack)
        options.behavior = .transient
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
        audioBar?.stop()
        player.subviews.forEach { $0.removeFromSuperview() }
        audioBar = audioURL.map(AudioBarView.init(url:))
        if let audioBar {
            let glass = NSGlassEffectView(wrapping: audioBar, inset: NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 8), cornerRadius: 22)
            glass.translatesAutoresizingMaskIntoConstraints = false
            player.addSubview(glass)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: player.leadingAnchor), glass.trailingAnchor.constraint(equalTo: player.trailingAnchor),
                glass.topAnchor.constraint(equalTo: player.topAnchor), glass.bottomAnchor.constraint(equalTo: player.bottomAnchor),
            ])
        }
        languagePopup.isEnabled = folderURL != nil
    }

    private var audioURL: URL? { folderURL.flatMap(OfflineTranscription.findAudio(in:)) }

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
        let notes = mode == .notes
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
        for control in [templatePopup, modelPopup, languagePopup, customPrompt] as [NSControl] { control.isEnabled = !generating }
        if generating { options.performClose(nil) }
        if let title = summary.title, title != titleLabel.stringValue, meeting != nil {
            titleLabel.stringValue = title
            Task { await model.reloadMeetings() }
        }
    }

    // MARK: Actions

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

    /// The Generate toolbar item: options and a Generate button, anchored to the item.
    func showOptions(relativeTo item: NSToolbarItem) {
        options.isShown ? options.performClose(nil) : options.show(relativeTo: item)
    }

    @objc private func generateFromOptions() {
        options.performClose(nil)
        generate()
    }

    func stopGeneration() { Task { await summary.cancel() } }

    func toggleTranscript() { toggleInspector(nil) }

    /// File › Save: stores pending summary and notes edits now, showing a failure instead of swallowing it.
    func saveNow() {
        Task {
            do { if summary.isDirty { try await summary.save() } } catch { model.present(error) }
            await saveNotes()
        }
    }

    /// What Share sends: the summary, or the transcript when there is no summary yet.
    var shareText: String? { summaryCopyText ?? transcriptCopyText }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copyTranscript): !transcripts.isEmpty
        case #selector(copySummary), #selector(exportSummary): summaryCopyText != nil && !summary.isGenerating
        case #selector(openFolder): folderURL != nil
        case #selector(retranscribe): audioURL != nil
        default: true
        }
    }

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

    private var transcriptCopyText: String? {
        guard let meeting, !transcripts.isEmpty else { return nil }
        return SummaryText.transcriptCopy(meetingID: meeting.id, title: titleLabel.stringValue, date: meeting.createdDate ?? Date(), transcripts: transcripts)
    }

    @objc func copyTranscript() { transcriptCopyText.map(copy) }

    private var summaryCopyText: String? {
        guard let meeting, summary.hasSummary else { return nil }
        return SummaryText.summaryCopy(meetingID: meeting.id, title: titleLabel.stringValue, date: meeting.createdDate ?? Date(), markdown: summary.markdown)
    }

    @objc func copySummary() { summaryCopyText.map(copy) }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func exportSummary() {
        guard let text = summaryCopyText, let window = view.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = Paths.sanitizeFilename(titleLabel.stringValue) + " summary.md"
        panel.beginSheetModal(for: window) { [model] response in
            guard response == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { model.present(error) }
        }
    }

    @objc func openFolder() {
        guard let folder = folderURL else { return }
        NSWorkspace.shared.open(folder)
    }

    @objc func retranscribe() {
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
