import AppKit
import Core
import Summary
import Transcription

/// Push-to-talk dictation: the switch, Accessibility access, and which model tidies the text.
final class DictationPane: SettingsPane, NSTextViewDelegate, NSTextFieldDelegate {
    private let model: AppModel
    private lazy var enabled = Self.checkbox("Dictate into any app", false, target: self, action: #selector(enabledChosen(_:)))
    private let holdKey = NSPopUpButton()
    private lazy var soundsBox = Self.checkbox("Play a sound when it starts and stops", true, target: self, action: #selector(soundsChosen(_:)))
    private lazy var keepHistory = Self.checkbox("Keep my dictations for seven days", false, target: self, action: #selector(historyChosen(_:)))
    private var historyWindow: DictationHistoryWindowController?
    private let cleanup = NSPopUpButton()
    private let access = NSTextField.meety("", font: Typography.body)
    private lazy var grant = NSButton(title: "Allow…", target: self, action: #selector(grantAccess))
    private let provider = NSPopUpButton()
    private let modelBox = NSComboBox()
    private let key = NSSecureTextField()
    private var modelForm = NSView()
    private let vocabularyScroll = NSTextView.scrollableTextView()
    private var vocabulary: NSTextView { vocabularyScroll.documentView as! NSTextView }
    private let appRows = NSStackView()
    private lazy var addApp = NSButton.meety("Add App…", symbol: "plus", target: self, action: #selector(showAppMenu))
    /// The provider whose stored key the key field shows; nil while it loads, so nothing is saved under the wrong one.
    private var keyProvider: Provider?
    private static let modes: [(CleanupMode, String)] = [
        (.onDevice, "Apple Intelligence, on this Mac"), (.dictationModel, "A model for dictation"),
        (.summaryModel, "The summary model"), (.off, "Nothing, paste as heard"),
    ]
    /// Fast hosted APIs and local Ollama. The ChatGPT subscription is left out: Codex takes 6 s or more, past the timeout.
    private static let providers: [(Provider, String)] = [
        (.claude, "Claude"), (.openai, "OpenAI"), (.groq, "Groq"), (.openrouter, "OpenRouter"), (.ollama, "Ollama, on this Mac"),
    ]

    init(model: AppModel) {
        self.model = model
        super.init(title: "Dictation")
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    override func viewDidLoad() {
        super.viewDidLoad()
        holdKey.addItems(withTitles: DictationKey.allCases.map(\.title))
        holdKey.target = self
        holdKey.action = #selector(keyPicked)
        cleanup.autoenablesItems = false
        cleanup.addItems(withTitles: Self.modes.map(\.1))
        cleanup.item(at: 0)?.isEnabled = DictationCleanup.onDeviceAvailable
        cleanup.target = self
        cleanup.action = #selector(cleanupChosen)
        provider.addItems(withTitles: Self.providers.map(\.1))
        provider.target = self
        provider.action = #selector(providerChosen)
        modelBox.completes = true
        modelBox.numberOfVisibleItems = 12
        modelBox.placeholderString = "For example claude-haiku-5-5"
        key.placeholderString = "Shared with Summary, kept in the Keychain"
        for field in [modelBox, key] {
            field.cell?.sendsActionOnEndEditing = true
            field.target = self
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        }
        modelBox.action = #selector(modelChosen)
        key.action = #selector(keyChosen)
        modelForm = form([("Provider", provider), ("Model", modelBox), ("API key", key)])
        let accessRow = NSStackView(views: [access, grant])
        accessRow.spacing = 8
        section("Push to talk", [form([("Dictation", enabled), ("Hold to talk", holdKey), ("Sounds", soundsBox), ("Accessibility", accessRow)])],
                note: "Hold the key, speak, and let go: the text is pasted where you are typing. Double-tap it to keep listening hands-free, then press it once to finish. ⌥⇧V pastes the last dictation again. Meety needs Accessibility access to notice the key in other apps and to paste. Dictation uses the language set in General and the model set in Transcription, and pauses while a meeting records. If you pick Fn, set “Press 🌐 key to” to Do Nothing in System Settings › Keyboard.")
        section("Cleanup", [form([("Tidy the text with", cleanup)]), modelForm],
                note: "Fixes punctuation and capitalization, drops filler words and false starts, and keeps the language you spoke. If cleanup fails or takes more than 5 seconds, the text is pasted as heard. Apple Intelligence needs to be on in System Settings and doesn't support every language; a fast hosted model such as Claude Haiku or Mercury on OpenRouter does.")
        appRows.orientation = .vertical
        appRows.alignment = .leading
        appRows.spacing = 8
        let addRow = NSStackView(views: [addApp, NSView()])
        section("Per-app instructions", [appRows, addRow],
                note: "When you dictate into one of these apps, cleanup also follows what you wrote here: “casual, no period at the end” for Slack, or “keep commands and file names exactly as spoken” for Terminal. Cleanup has to be on, and a hosted model receives the app's name and your instructions. A browser counts as one app, whatever site it's on.")
        renderAppRows()
        vocabularyScroll.borderType = .bezelBorder
        vocabularyScroll.heightAnchor.constraint(equalToConstant: 96).isActive = true
        vocabulary.font = Typography.body
        vocabulary.isRichText = false
        vocabulary.isAutomaticQuoteSubstitutionEnabled = false
        vocabulary.isAutomaticDashSubstitutionEnabled = false
        vocabulary.isAutomaticTextReplacementEnabled = false
        vocabulary.isAutomaticSpellingCorrectionEnabled = false
        vocabulary.textContainerInset = NSSize(width: 4, height: 6)
        vocabulary.string = model.settings.dictationVocabulary
        vocabulary.delegate = self
        section("Vocabulary", [vocabularyScroll],
                note: "Names and terms, one per line, with what the transcript writes instead after a colon: Kubernetes: cuber netties, koobernetes. Those spellings are fixed on this Mac, even with cleanup off. Cleanup also learns the first 64 terms, so a hosted model receives them.")
        let showHistory = NSButton.meety("Show History…", symbol: "clock", target: self, action: #selector(openHistory))
        let historyRow = NSStackView(views: [keepHistory, NSView(), showHistory])
        section("History", [form([("", historyRow)])],
                note: "Off by default. While it's on, the text you dictate and the app it went into are saved in Meety's database on this Mac for seven days, then deleted. Audio is never kept. Turning it off stops saving; Delete All in the history window removes what's there.")
        historyRow.widthAnchor.constraint(equalToConstant: Self.width - 56 - 28).isActive = true
        loadKeyAndModels()
        track { [weak self] in
            guard let self else { return }
            let settings = model.settings
            enabled.state = settings.dictationEnabled ? .on : .off
            keepHistory.state = settings.dictationHistory ? .on : .off
            soundsBox.state = settings.dictationSounds ? .on : .off
            holdKey.selectItem(at: DictationKey.allCases.firstIndex(of: DictationKey(saved: settings.dictationKey)) ?? 0)
            cleanup.selectItem(at: Self.modes.firstIndex { $0.0.rawValue == settings.dictationCleanup } ?? 0)
            provider.selectItem(at: Self.providers.firstIndex { $0.0.rawValue == settings.dictationProvider } ?? 0)
            modelBox.stringValue = settings.dictationModel
            let hidden = settings.dictationCleanup != CleanupMode.dictationModel.rawValue
            if modelForm.isHidden != hidden {
                modelForm.isHidden = hidden
                fit()
            }
            let granted = model.dictation.accessibilityGranted
            access.stringValue = granted ? "Allowed" : "Not allowed yet"
            access.textColor = granted ? .labelColor : .secondaryLabelColor
            grant.isHidden = granted
        }
    }

    // MARK: Per-app instructions

    /// Rows are rebuilt only when one is added or removed, so typing never loses focus.
    private func renderAppRows() {
        appRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, app) in model.settings.dictationAppPrompts.enumerated() {
            let row = appRow(app, index: index)
            appRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: Self.width - 56).isActive = true
        }
        appRows.isHidden = model.settings.dictationAppPrompts.isEmpty
    }

    private func appRow(_ app: DictationAppPrompt, index: Int) -> NSView {
        let icon = NSImageView(image: Self.icon(app.bundleID))
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let name = NSTextField(labelWithString: app.name)
        name.font = Typography.bodyMedium
        let remove = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove \(app.name)")!,
                              target: self, action: #selector(removeApp(_:)))
        remove.isBordered = false
        remove.contentTintColor = .tertiaryLabelColor
        remove.tag = index
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [icon, name, spacer, remove])
        header.spacing = 8
        let field = NSTextField(string: app.instructions)
        field.placeholderString = "How to write for \(app.name)"
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.tag = index
        field.delegate = self
        field.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let stack = NSStackView(views: [header, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return FormSection(rows: [("", stack)])
    }

    private static func icon(_ bundleID: String) -> NSImage {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field !== modelBox, field !== key,
              model.settings.dictationAppPrompts.indices.contains(field.tag) else { return }
        model.settings.dictationAppPrompts[field.tag].instructions = field.stringValue
    }

    /// The apps open now, then a way to pick any other.
    @objc private func showAppMenu() {
        let listed = Set(model.settings.dictationAppPrompts.map(\.bundleID))
        let menu = NSMenu()
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                && !listed.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for app in running {
            let item = NSMenuItem(title: app.localizedName ?? app.bundleIdentifier!, action: #selector(appPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app.bundleIdentifier
            item.image = app.icon
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        if !running.isEmpty { menu.addItem(.separator()) }
        let other = NSMenuItem(title: "Choose from Applications…", action: #selector(chooseApp), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: addApp.bounds.height + 4), in: addApp)
    }

    @objc private func appPicked(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        add(bundleID: bundleID, name: sender.title)
    }

    @objc private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        add(bundleID: bundleID, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
    }

    private func add(bundleID: String, name: String) {
        guard !model.settings.dictationAppPrompts.contains(where: { $0.bundleID == bundleID }) else { return }
        model.settings.dictationAppPrompts.append(DictationAppPrompt(bundleID: bundleID, name: name, instructions: ""))
        renderAppRows()
        fit()
        (appRows.arrangedSubviews.last.flatMap { Self.firstField(in: $0) }).map { view.window?.makeFirstResponder($0) }
    }

    private static func firstField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap(firstField).first
    }

    @objc private func removeApp(_ sender: NSButton) {
        view.window?.makeFirstResponder(nil)
        guard model.settings.dictationAppPrompts.indices.contains(sender.tag) else { return }
        model.settings.dictationAppPrompts.remove(at: sender.tag)
        renderAppRows()
        fit()
    }

    func textDidChange(_ notification: Notification) { model.settings.dictationVocabulary = vocabulary.string }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nil) // the first text field would otherwise take focus and scroll the pane to it
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        model.dictation.refresh()
    }

    @objc private func enabledChosen(_ sender: NSButton) {
        model.settings.dictationEnabled = sender.state == .on
        if sender.state == .on, !model.dictation.accessibilityGranted { model.dictation.requestAccessibility() }
    }

    @objc private func soundsChosen(_ sender: NSButton) { model.settings.dictationSounds = sender.state == .on }

    @objc private func historyChosen(_ sender: NSButton) { model.settings.dictationHistory = sender.state == .on }

    @objc private func openHistory() {
        let window = historyWindow ?? DictationHistoryWindowController(store: model.store)
        historyWindow = window
        window.show()
    }

    @objc private func keyPicked() { model.settings.dictationKey = DictationKey.allCases[holdKey.indexOfSelectedItem].rawValue }

    @objc private func cleanupChosen() { model.settings.dictationCleanup = Self.modes[cleanup.indexOfSelectedItem].0.rawValue }

    private var chosenProvider: Provider { Self.providers[provider.indexOfSelectedItem].0 }

    @objc private func providerChosen() {
        guard chosenProvider.rawValue != model.settings.dictationProvider else { return }
        view.window?.makeFirstResponder(nil) // a key being typed saves under the provider it was typed for
        keyProvider = nil
        model.settings.dictationProvider = chosenProvider.rawValue
        model.settings.dictationModel = "" // model names differ between providers
        loadKeyAndModels()
    }

    @objc private func modelChosen() { model.settings.dictationModel = modelBox.stringValue.trimmingCharacters(in: .whitespaces) }

    /// The key is the provider's Keychain entry, the same one the Summary pane saves.
    @objc private func keyChosen() {
        guard let chosen = keyProvider else { return }
        let value = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do { try await Self.saveKey(value, for: chosen) } catch { presentError(error) }
            fetchModels()
        }
    }

    private func loadKeyAndModels() {
        let chosen = Provider(id: model.settings.dictationProvider) ?? .claude
        Task {
            let stored = await Self.storedKey(chosen)
            guard chosenProvider == chosen else { return } // the provider changed while loading
            key.stringValue = stored ?? ""
            keyProvider = chosen
            fetchModels()
        }
    }

    private func fetchModels() {
        let (chosen, apiKey) = (chosenProvider, key.stringValue)
        Task {
            let names = (try? await LLMClient().models(chosen, apiKey: apiKey).map(\.id)) ?? []
            guard chosenProvider == chosen else { return }
            modelBox.removeAllItems()
            modelBox.addItems(withObjectValues: names)
        }
    }

    // Off the main actor: a Keychain call can block on an access prompt.
    @concurrent private static func storedKey(_ provider: Provider) async -> String? { Keychain().get(provider.rawValue) }
    @concurrent private static func saveKey(_ value: String, for provider: Provider) async throws {
        try Keychain().set(value.isEmpty ? nil : value, for: provider.rawValue)
    }

    @objc private func grantAccess() { model.dictation.requestAccessibility() }
}
