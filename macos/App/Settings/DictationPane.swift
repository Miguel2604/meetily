import AppKit
import Core
import Summary
import Transcription

/// Push-to-talk dictation: the switch, Accessibility access, and which model tidies the text.
final class DictationPane: SettingsPane, NSTextViewDelegate {
    private let model: AppModel
    private lazy var enabled = Self.checkbox("Dictate into any app", false, target: self, action: #selector(enabledChosen(_:)))
    private let holdKey = NSPopUpButton()
    private let cleanup = NSPopUpButton()
    private let access = NSTextField.meety("", font: Typography.body)
    private lazy var grant = NSButton(title: "Allow…", target: self, action: #selector(grantAccess))
    private let provider = NSPopUpButton()
    private let modelBox = NSComboBox()
    private let key = NSSecureTextField()
    private var modelForm = NSView()
    private let vocabularyScroll = NSTextView.scrollableTextView()
    private var vocabulary: NSTextView { vocabularyScroll.documentView as! NSTextView }
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
        section("Push to talk", [form([("Dictation", enabled), ("Hold to talk", holdKey), ("Accessibility", accessRow)])],
                note: "Hold the key, speak, and let go: the text is pasted where you are typing. Double-tap it to keep listening hands-free, then press it once to finish. ⌥⇧V pastes the last dictation again. Meety needs Accessibility access to notice the key in other apps and to paste. Dictation uses the language set in General and the model set in Transcription, and pauses while a meeting records. If you pick Fn, set “Press 🌐 key to” to Do Nothing in System Settings › Keyboard.")
        section("Cleanup", [form([("Tidy the text with", cleanup)]), modelForm],
                note: "Fixes punctuation and capitalization, drops filler words and false starts, and keeps the language you spoke. If cleanup fails or takes more than 5 seconds, the text is pasted as heard. Apple Intelligence needs to be on in System Settings and doesn't support every language; a fast hosted model such as Claude Haiku or Mercury on OpenRouter does.")
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
        loadKeyAndModels()
        track { [weak self] in
            guard let self else { return }
            let settings = model.settings
            enabled.state = settings.dictationEnabled ? .on : .off
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

    func textDidChange(_ notification: Notification) { model.settings.dictationVocabulary = vocabulary.string }

    override func viewWillAppear() {
        super.viewWillAppear()
        model.dictation.refresh()
    }

    @objc private func enabledChosen(_ sender: NSButton) {
        model.settings.dictationEnabled = sender.state == .on
        if sender.state == .on, !model.dictation.accessibilityGranted { model.dictation.requestAccessibility() }
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
