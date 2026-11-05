import AppKit
import Audio
import Core

/// Settings: toolbar tabs for General, Recording, Transcription, Summary, Dictation and About (app/settings/page.tsx).
final class SettingsWindowController: NSWindowController {
    enum Tab: Int { case general, recording, transcription, summary, dictation, about }

    private let tabs = NSTabViewController()

    init(model: AppModel) {
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        let panes: [(SettingsPane, String)] = [
            (GeneralPane(model: model), "gearshape"), (RecordingPane(model: model), "mic"),
            (TranscriptionPane(model: model), "waveform"), (SummaryPane(model: model), "sparkles"),
            (DictationPane(model: model), "waveform.badge.mic"), (AboutPane(), "info.circle"),
        ]
        for (pane, symbol) in panes {
            let item = NSTabViewItem(viewController: pane)
            item.label = pane.title ?? ""
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.setFrameAutosaveName("SettingsWindow")
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    func show(_ tab: Tab? = nil) {
        if let tab { tabs.selectedTabViewItemIndex = tab.rawValue }
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Measures from the top, so a pane taller than the window opens at its first section and stays there as the window resizes.
private final class TopClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// A settings tab: a fixed-width column of titled sections that scrolls when it is taller than the screen. The window
/// takes the pane's fitting size on a tab switch.
class SettingsPane: NSViewController {
    let column = NSStackView()
    static let width: CGFloat = 620

    init(title: String) {
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    override func loadView() {
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.edgeInsets = NSEdgeInsets(top: 20, left: 28, bottom: 24, right: 28)
        column.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let clip = TopClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = column
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            column.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
        view = scroll
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        fit()
    }

    /// Call after showing or hiding content so the window follows.
    func fit() {
        column.layoutSubtreeIfNeeded()
        let screen = (view.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        preferredContentSize = NSSize(width: Self.width, height: min(column.fittingSize.height, screen - 100)) // 100: title bar and tabs
        guard let window = view.window, window.isVisible else { return }
        let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: preferredContentSize)).size
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height), display: true, animate: true)
    }

    /// A section header, its content, and an optional footnote.
    func section(_ title: String?, _ views: [NSView], note: String? = nil) {
        if let title {
            let header = NSTextField.meety(title, font: Typography.headline)
            column.addArrangedSubview(header)
            if column.arrangedSubviews.count > 1, let previous = column.arrangedSubviews.dropLast().last { column.setCustomSpacing(24, after: previous) }
        }
        for view in views { full(view) }
        if let note { full(NSTextField.meety(note, font: Typography.caption, color: .secondaryLabelColor)) }
    }

    /// Adds a view that spans the column's content width.
    func full(_ view: NSView) {
        column.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: Self.width - 56).isActive = true
    }

    /// A grouped form: each row's label leading, its control trailing.
    func form(_ rows: [(String, NSView)]) -> NSView { FormSection(rows: rows) }

    static func checkbox(_ title: String, _ on: Bool, target: AnyObject, action: Selector) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: target, action: action)
        box.state = on ? .on : .off
        return box
    }
}

// MARK: General

/// Transcription language, recordings folder and notifications (PreferenceSettings.tsx, LanguageSelection.tsx).
final class GeneralPane: SettingsPane {
    private let model: AppModel
    private let language = NSPopUpButton()
    private let folder = NSTextField(labelWithString: "")

    init(model: AppModel) {
        self.model = model
        super.init(title: "General")
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let settings = model.settings
        language.addItems(withTitles: TranscribeSheet.languages.map(\.name))
        language.target = self
        language.action = #selector(languageChosen)
        folder.lineBreakMode = .byTruncatingMiddle
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [NSButton(title: "Choose…", target: self, action: #selector(chooseFolder)),
                                          NSButton(title: "Show in Finder", target: self, action: #selector(openFolder))])
        buttons.spacing = 8
        let folderRow = NSStackView(views: [folder, buttons])
        folderRow.orientation = .vertical
        folderRow.alignment = .leading
        folderRow.spacing = 6
        folder.widthAnchor.constraint(lessThanOrEqualToConstant: Self.width - 56 - 158).isActive = true

        section("Transcription", [form([("Language", language)])],
                note: "English uses Parakeet. Tagalog and other languages use Whisper. Auto-detect uses the model chosen under Transcription.")
        section("Recordings", [form([("Save recordings in", folderRow)])])
        section("Notifications", [
            form([("", Self.checkbox("When recording starts and stops", settings.recordingNotifications, target: self, action: #selector(recordingNotices(_:)))),
                  ("", Self.checkbox("When a summary is ready", settings.summaryNotifications, target: self, action: #selector(summaryNotices(_:))))]),
        ])
        track { [weak self] in
            guard let self else { return }
            language.selectItem(at: TranscribeSheet.languages.firstIndex { $0.code == self.model.settings.language } ?? 0)
            folder.stringValue = (model.settings.saveFolder.path as NSString).abbreviatingWithTildeInPath
            folder.toolTip = model.settings.saveFolder.path
        }
    }

    @objc private func languageChosen() { model.settings.language = TranscribeSheet.languages[language.indexOfSelectedItem].code }
    @objc private func recordingNotices(_ sender: NSButton) { model.settings.recordingNotifications = sender.state == .on }
    @objc private func summaryNotices(_ sender: NSButton) { model.settings.summaryNotifications = sender.state == .on }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.settings.saveFolder
        panel.prompt = "Choose"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [model] response in
            if response == .OK, let url = panel.url { model.settings.saveFolder = url }
        }
    }

    @objc private func openFolder() {
        let url = model.settings.saveFolder
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}

// MARK: Recording

/// Default microphone, system audio, and the recording notice (RecordingSettings.tsx, DeviceSelection.tsx).
/// The "Save audio recordings" switch isn't offered: the recording file is what playback, retranscribe and crash safety use.
final class RecordingPane: SettingsPane {
    private let model: AppModel
    private let microphone = NSPopUpButton()
    private lazy var system = Self.checkbox("Record the other side of the call", true, target: self, action: #selector(systemChosen(_:)))
    private lazy var consent = Self.checkbox("Remind me to tell participants they are being recorded", true, target: self, action: #selector(consentChosen(_:)))

    init(model: AppModel) {
        self.model = model
        super.init(title: "Recording")
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    override func viewDidLoad() {
        super.viewDidLoad()
        microphone.target = self
        microphone.action = #selector(microphoneChosen)
        section("Devices", [form([("Microphone", microphone), ("System audio", system)])],
                note: "Meety follows the system default microphone when you pick Default, and switches back if a chosen device disconnects.")
        section("When recording starts", [form([("Notice", consent)])])
        track { [weak self] in
            guard let self else { return }
            let settings = model.settings
            microphone.fillMicrophones(preferred: settings.preferredMicDevice)
            system.state = settings.recordSystemAudio ? .on : .off
            consent.state = settings.showRecordingConsent ? .on : .off
        }
        Task { [weak self] in
            for await _ in AudioDevices.events() { self?.microphone.fillMicrophones(preferred: self?.model.settings.preferredMicDevice) }
        }
    }

    @objc private func microphoneChosen() { model.settings.preferredMicDevice = microphone.selectedItem?.representedObject as? String }
    @objc private func systemChosen(_ sender: NSButton) { model.settings.recordSystemAudio = sender.state == .on }
    @objc private func consentChosen(_ sender: NSButton) { model.settings.showRecordingConsent = sender.state == .on }
}

// MARK: About

/// The mark, version and what Meety is (About.tsx). The updater is dropped.
final class AboutPane: SettingsPane {
    init() { super.init(title: "About") }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let mark = MeetyMarkView()
        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([mark.widthAnchor.constraint(equalToConstant: 56), mark.heightAnchor.constraint(equalToConstant: 56)])
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "Version \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        let name = NSStackView(views: [NSTextField.meety("Meety", font: Typography.title),
                                       NSTextField.meety(version, font: Typography.callout, color: .secondaryLabelColor)])
        name.orientation = .vertical
        name.alignment = .leading
        name.spacing = 2
        let header = NSStackView(views: [mark, name])
        header.spacing = 14
        column.addArrangedSubview(header)
        column.setCustomSpacing(20, after: header)
        for (title, body) in [
            ("Stays on this computer", "Audio, transcripts and summaries are stored and processed locally. Nothing is uploaded unless you pick a cloud model."),
            ("Works with every call app", "Zoom, Google Meet, Teams or a room with no call at all."),
            ("Any model you like", "Run the built-in or an Ollama model, or connect your own API key. No lock-in."),
            ("No per-minute bill", "Local transcription and summaries cost nothing to run."),
        ] {
            let text = NSStackView(views: [NSTextField.meety(title, font: Typography.bodyMedium),
                                           NSTextField.meety(body, font: Typography.callout, color: .secondaryLabelColor)])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 2
            full(text)
        }
    }
}
