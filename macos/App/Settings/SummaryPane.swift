import AppKit
import Core
import Summary

/// Summary provider, model, API key (Keychain), endpoints, Ollama pulls and built-in models
/// (SummaryModelSettings.tsx, ModelSettingsModal.tsx, BuiltInModelManager.tsx, SummaryLanguageSettings.tsx).
final class SummaryPane: SettingsPane {
    private static let providers: [(Provider, String)] = [
        (.builtin, "Built-in AI (offline, no API key)"), (.ollama, "Ollama"), (.claude, "Claude"), (.openai, "OpenAI"),
        (.groq, "Groq"), (.openrouter, "OpenRouter"), (.customOpenAI, "Custom server (OpenAI-compatible)"),
        (.chatgpt, "ChatGPT subscription (Codex CLI)"),
    ]

    private let model: AppModel
    private var config = SummaryConfig(provider: .builtin, model: "")
    private let client = LLMClient()
    private var pulling = false

    private let provider = NSPopUpButton()
    private let modelBox = NSComboBox()
    private let key = NSSecureTextField()
    private let endpoint = NSTextField()
    private let maxTokens = NSTextField()
    private let temperature = NSTextField()
    private let topP = NSTextField()
    private let pullName = NSTextField()
    private let pullProgress = NSProgressIndicator()
    private let hint = NSTextField.meety("", font: Typography.caption, color: .secondaryLabelColor)
    private let status = NSTextField.meety("", font: Typography.callout, color: .secondaryLabelColor)
    private let language = NSPopUpButton()
    private lazy var pullButton = NSButton(title: "Pull", target: self, action: #selector(pull))
    private lazy var deleteOllama = NSButton(title: "Delete…", target: self, action: #selector(deleteOllamaModel))
    private lazy var testButton = NSButton(title: "Test Connection", target: self, action: #selector(testConnection))
    private lazy var saveButton = NSButton.meety("Save", role: .primary, target: self, action: #selector(save))
    private var formRows: [(String, NSView)] = []
    private var grid = NSView()

    init(model: AppModel) {
        self.model = model
        super.init(title: "Summary")
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    override func viewDidLoad() {
        super.viewDidLoad()
        provider.addItems(withTitles: Self.providers.map(\.1))
        provider.target = self
        provider.action = #selector(providerChosen)
        modelBox.completes = true
        modelBox.numberOfVisibleItems = 12
        modelBox.placeholderString = "Model name"
        let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Fetch models")!, target: self, action: #selector(fetchModels))
        refresh.bezelStyle = .push
        refresh.toolTip = "Fetch models"
        let modelRow = NSStackView(views: [modelBox, refresh, deleteOllama])
        modelRow.spacing = 6
        key.placeholderString = "Enter your API key"
        maxTokens.placeholderString = "Optional"
        temperature.placeholderString = "0.0 – 2.0"
        topP.placeholderString = "0.0 – 1.0"
        pullName.placeholderString = "e.g. gemma3:1b"
        pullProgress.style = .bar
        pullProgress.controlSize = .small
        pullProgress.isHidden = true
        let pullRow = NSStackView(views: [pullName, pullButton, pullProgress])
        pullRow.spacing = 6
        pullProgress.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let buttons = NSStackView(views: [saveButton, testButton, status])
        buttons.spacing = 8
        for field in [modelBox, key, endpoint, pullName] as [NSView] { field.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true }
        for field in [maxTokens, temperature, topP] { field.widthAnchor.constraint(equalToConstant: 100).isActive = true }

        formRows = [("Provider", provider), ("Model", modelRow), ("API key", key), ("Endpoint", endpoint), ("Max tokens", maxTokens),
                    ("Temperature", temperature), ("Top P", topP), ("Pull a model", pullRow), ("", hint), ("", buttons)]
        section("Summary model", [grid])

        let rows = ModelLibrary.Item.summary.map { ModelRowView(item: $0, library: model.library) }
        section("Built-in models", rows, note: "Built-in models run on this Mac with llama.cpp. Pick one with Use, or choose it above.")

        language.addItem(withTitle: "Same as the transcript")
        language.addItems(withTitles: TranscribeSheet.languages.dropFirst().map(\.name))
        language.target = self
        language.action = #selector(languageChosen)
        let auto = Self.checkbox("Generate a summary when a recording stops", model.settings.autoSummary, target: self, action: #selector(autoChosen(_:)))
        section("Summaries", [form([("Automatic", auto), ("Language", language)])])
        let languages = TranscribeSheet.languages.dropFirst().map(\.code)
        language.selectItem(at: model.settings.summaryLanguage.flatMap { languages.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)

        // A saved change elsewhere (a built-in row's Use) resets the form to what is stored.
        track { [weak self] in
            guard let self, let saved = model.library.summary else { return }
            config = saved
            render()
            fetchModels()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        Task { await model.library.refresh() }
    }

    // MARK: Form

    private func render() {
        provider.selectItem(at: Self.providers.firstIndex { $0.0 == config.provider } ?? 0)
        modelBox.stringValue = config.model
        key.stringValue = config.apiKey
        endpoint.stringValue = config.provider == .customOpenAI ? config.customEndpoint : config.ollamaEndpoint
        endpoint.placeholderString = config.provider == .customOpenAI ? "http://localhost:8000/v1" : LLMClient.defaultOllama
        maxTokens.stringValue = config.maxTokens.map(String.init) ?? ""
        temperature.stringValue = config.temperature.map { "\($0)" } ?? ""
        topP.stringValue = config.topP.map { "\($0)" } ?? ""
        let custom = config.provider == .customOpenAI, ollama = config.provider == .ollama
        let visible = [true, true, config.takesKey, custom || ollama, custom, custom, custom, ollama, true, true]
        // A fresh form with only this provider's rows.
        var rows = zip(formRows, visible).filter(\.1).map(\.0)
        if !SummaryConfig.keyed.contains(config.provider), let index = rows.firstIndex(where: { $0.1 === key }) { rows[index].0 = "API key (optional)" }
        let fresh = form(rows)
        if let index = column.arrangedSubviews.firstIndex(of: grid) {
            grid.removeFromSuperview()
            column.insertArrangedSubview(fresh, at: index)
            fresh.widthAnchor.constraint(equalToConstant: Self.width - 56).isActive = true
        }
        grid = fresh
        deleteOllama.isHidden = !ollama
        testButton.isHidden = !custom
        hint.stringValue = switch config.provider {
        case .builtin: "Download a built-in model below, then pick it here."
        case .chatgpt: "Uses your ChatGPT subscription through the Codex CLI. Run “codex login” in Terminal first."
        case .ollama: "Ollama must be running on this Mac or at the endpoint. Leave the endpoint empty for localhost."
        case .customOpenAI: "Any server with an OpenAI-compatible /chat/completions API, such as LM Studio or vLLM."
        default: "Your key is stored in the macOS Keychain."
        }
        status.stringValue = ""
        fit()
    }

    private func readFields() {
        config.model = modelBox.stringValue.trimmingCharacters(in: .whitespaces)
        config.apiKey = key.stringValue
        switch config.provider {
        case .customOpenAI: config.customEndpoint = endpoint.stringValue.trimmingCharacters(in: .whitespaces)
        case .ollama: config.ollamaEndpoint = endpoint.stringValue.trimmingCharacters(in: .whitespaces)
        default: break
        }
        config.maxTokens = Int(maxTokens.stringValue)
        config.temperature = Double(temperature.stringValue)
        config.topP = Double(topP.stringValue)
    }

    private func show(_ message: String, error: Bool = false) {
        status.stringValue = message
        status.textColor = error ? .systemRed : .secondaryLabelColor
    }

    private var ollamaEndpoint: String? { config.ollamaEndpoint.isEmpty ? nil : config.ollamaEndpoint }

    // MARK: Actions

    @objc private func providerChosen() {
        readFields()
        let chosen = Self.providers[provider.indexOfSelectedItem].0
        guard chosen != config.provider else { return }
        config.provider = chosen
        config.apiKey = ""
        config.model = model.library.summary?.provider == chosen ? model.library.summary?.model ?? "" : ""
        render()
        Task {
            let key = config.takesKey ? await Self.storedKey(chosen) : nil
            guard config.provider == chosen else { return }
            config.apiKey = key ?? ""
            self.key.stringValue = config.apiKey
            fetchModels()
        }
    }

    @concurrent private static func storedKey(_ provider: Provider) async -> String? { Keychain().get(provider.rawValue) }

    @objc private func fetchModels() {
        readFields()
        let (chosen, key, endpoint) = (config.provider, config.apiKey, ollamaEndpoint)
        Task {
            var names: [String] = []
            switch chosen {
            case .builtin: names = await model.builtIn.models().filter { $0.status == .available }.map(\.model.name)
            case .customOpenAI: break
            default:
                do { names = try await client.models(chosen, apiKey: key, endpoint: endpoint).map(\.id) } catch {
                    if config.provider == chosen { show("\(error)", error: true) }
                }
            }
            guard config.provider == chosen else { return } // the provider changed while loading
            modelBox.removeAllItems()
            modelBox.addItems(withObjectValues: names)
        }
    }

    @objc private func save() {
        readFields()
        let config = config
        Task {
            do {
                try await config.save(store: model.store)
                if config.provider == .builtin { model.settings.builtInSummaryModel = config.model }
                show("Saved")
                await model.library.refresh()
            } catch {
                show((error as? LLMError)?.description ?? error.localizedDescription, error: true)
            }
        }
    }

    @objc private func testConnection() {
        readFields()
        let config = config
        show("Testing…")
        Task {
            do {
                try await client.testCustomEndpoint(config.customEndpoint, apiKey: config.apiKey.isEmpty ? nil : config.apiKey, model: config.model)
                show("Connection successful!")
            } catch {
                show("\(error)", error: true)
            }
        }
    }

    /// One pull at a time: the button stays disabled until it finishes.
    @objc private func pull() {
        readFields()
        let name = pullName.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !pulling else { return }
        pulling = true
        pullButton.isEnabled = false
        pullProgress.isHidden = false
        pullProgress.doubleValue = 0
        show("Downloading \(name)…")
        let endpoint = ollamaEndpoint
        Task {
            do {
                try await client.pullOllama(name, endpoint: endpoint) { percent in
                    Task { @MainActor in self.pullProgress.doubleValue = Double(percent) }
                }
                show("Downloaded \(name)")
                config.model = name
                modelBox.stringValue = name
                fetchModels()
            } catch {
                show("\(error)", error: true)
            }
            pulling = false
            pullButton.isEnabled = true
            pullProgress.isHidden = true
        }
    }

    @objc private func deleteOllamaModel() {
        let name = modelBox.stringValue
        guard !name.isEmpty, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(name) from Ollama?"
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                do {
                    try await self.client.deleteOllama(name, endpoint: self.ollamaEndpoint)
                    self.show("Model \(name) deleted")
                    self.modelBox.stringValue = ""
                    self.fetchModels()
                } catch {
                    self.show("\(error)", error: true)
                }
            }
        }
    }

    @objc private func autoChosen(_ sender: NSButton) { model.settings.autoSummary = sender.state == .on }

    @objc private func languageChosen() {
        let index = language.indexOfSelectedItem
        model.settings.summaryLanguage = index == 0 ? nil : TranscribeSheet.languages[index].code
    }
}
