import AppKit
import Summary
import Transcription

/// First-launch setup: welcome, permissions with live status, then the transcription and summary models
/// downloading and preparing (onboarding/OnboardingFlow.tsx). Shown until `Settings.onboardingCompleted`,
/// which the first launch imports from the Tauri app's onboarding-status.json.
final class OnboardingWindowController: NSWindowController {
    init(model: AppModel, onFinish: @escaping () -> Void) {
        let window = NSWindow(contentViewController: OnboardingViewController(model: model, onFinish: onFinish))
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to Meety"
        window.isMovableByWindowBackground = true
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }
}

final class OnboardingViewController: NSViewController {
    private enum Step: Int, CaseIterable { case welcome, permissions, models }

    private let model: AppModel
    private let onFinish: () -> Void
    private var step = Step.welcome
    private let content = NSStackView()
    private let stepLabel = NSTextField.meety("", font: Typography.caption, color: .secondaryLabelColor)
    private lazy var back = NSButton.meety("Back", target: self, action: #selector(goBack))
    private lazy var next = NSButton.meety("Get Started", role: .primary, target: self, action: #selector(goNext))
    private var permissionRows: [(Permission, NSTextField, NSButton)] = []
    private var timer: Timer?
    private let footnote = NSTextField.meety("", font: Typography.callout, color: .secondaryLabelColor)

    /// The transcription model onboarding sets up (the Tauri default), and the summary model for this Mac.
    private let transcription = ModelLibrary.Item.parakeet(.default)
    private lazy var summary = ModelLibrary.Item.builtIn(BuiltInModel.recommended())

    init(model: AppModel, onFinish: @escaping () -> Void) {
        self.model = model
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    override func loadView() {
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        let footer = NSStackView()
        footer.setViews([stepLabel], in: .leading)
        footer.setViews([back, next], in: .trailing)
        let root = NSStackView(views: [content, NSView(), footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.edgeInsets = NSEdgeInsets(top: 48, left: 40, bottom: 24, right: 40)
        root.setHuggingPriority(.defaultLow, for: .vertical)
        for view in [content, footer] { view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -80).isActive = true }
        root.widthAnchor.constraint(equalToConstant: 620).isActive = true
        root.heightAnchor.constraint(equalToConstant: 560).isActive = true
        next.keyEquivalent = "\r"
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        show(.welcome)
        #if DEBUG
        if let index = ProcessInfo.processInfo.environment["MEETY_ONBOARDING"].flatMap(Int.init), let step = Step(rawValue: index) { show(step) }
        #endif
        track { [weak self] in self?.renderModels() }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        timer?.invalidate()
    }

    // MARK: Steps

    private func show(_ step: Step) {
        self.step = step
        timer?.invalidate()
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        permissionRows = []
        stepLabel.stringValue = "Step \(step.rawValue + 1) of \(Step.allCases.count)"
        back.isHidden = step == .welcome
        switch step {
        case .welcome: showWelcome()
        case .permissions: showPermissions()
        case .models: showModels()
        }
        view.window?.recalculateKeyViewLoop()
    }

    private func heading(_ title: String, _ subtitle: String) {
        add(NSTextField.meety(title, font: NSFont.systemFont(ofSize: 24, weight: .semibold)))
        let sub = NSTextField.meety(subtitle, font: Typography.body, color: .secondaryLabelColor)
        add(sub)
        content.setCustomSpacing(24, after: sub)
    }

    private func add(_ view: NSView) {
        content.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    private func showWelcome() {
        let mark = MeetyMarkView()
        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([mark.widthAnchor.constraint(equalToConstant: 64), mark.heightAnchor.constraint(equalToConstant: 64)])
        content.addArrangedSubview(mark)
        content.setCustomSpacing(20, after: mark)
        heading("Welcome to Meety", "Record. Transcribe. Summarize. All on your device.")
        for (symbol, text) in [("lock", "Your data never leaves your device"), ("text.badge.checkmark", "Notes and action items written for you"),
                               ("wifi.slash", "Works offline, no cloud required")] {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
            icon.contentTintColor = .secondaryLabelColor
            icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
            let row = NSStackView(views: [icon, NSTextField.meety(text, font: Typography.body)])
            row.spacing = 10
            content.addArrangedSubview(row)
        }
        let time = NSTextField.meety("Takes less than 3 minutes", font: Typography.callout, color: .secondaryLabelColor)
        content.addArrangedSubview(time)
        content.setCustomSpacing(24, after: content.arrangedSubviews[content.arrangedSubviews.count - 2])
        next.title = "Get Started"
        next.isEnabled = true
    }

    private func showPermissions() {
        heading("Grant permissions", "Meety needs your microphone and system audio to record meetings. You can change these later in System Settings.")
        for permission in Permission.allCases {
            let card = CardView()
            let icon = NSImageView(image: NSImage(systemSymbolName: permission.symbol, accessibilityDescription: nil)!)
            icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
            icon.contentTintColor = .labelColor
            icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
            let detail = NSTextField.meety(permission.detail, font: Typography.callout, color: .secondaryLabelColor)
            detail.preferredMaxLayoutWidth = 320
            detail.widthAnchor.constraint(equalToConstant: 320).isActive = true
            let text = NSStackView(views: [NSTextField.meety(permission.title, font: Typography.bodyMedium), detail])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 2
            let status = NSTextField.meety("Checking…", font: Typography.callout, color: .secondaryLabelColor)
            let button = NSButton.meety("Enable", target: self, action: #selector(requestPermission(_:)))
            button.controlSize = .regular
            button.tag = Permission.allCases.firstIndex(of: permission)!
            let leading = NSStackView(views: [icon, text])
            leading.spacing = 12
            let trailing = NSStackView(views: [status, button])
            trailing.spacing = 10
            for view in [leading, trailing] {
                view.translatesAutoresizingMaskIntoConstraints = false
                card.addSubview(view)
            }
            // Explicit edges: a wrapping label in a gravity stack loses the stack's vertical insets.
            NSLayoutConstraint.activate([
                leading.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
                leading.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
                leading.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
                trailing.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
                trailing.centerYAnchor.constraint(equalTo: card.centerYAnchor),
                leading.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -12),
            ])
            add(card)
            permissionRows.append((permission, status, button))
        }
        next.title = "Continue"
        next.isEnabled = true
        refreshPermissions()
        // Live status: a grant in System Settings shows up without a relaunch.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
    }

    private func refreshPermissions() {
        for (permission, label, button) in permissionRows {
            Task {
                let status = await permission.status()
                label.stringValue = switch status {
                case .granted: "Allowed"
                case .denied: "Not allowed"
                case .notDetermined: "Not set"
                }
                label.textColor = status == .granted ? .labelColor : .secondaryLabelColor
                button.isHidden = status == .granted
                button.title = status == .denied ? "Open Settings" : "Enable"
            }
        }
    }

    private func showModels() {
        heading("Getting things ready", "Meety transcribes and summarizes on this Mac. The models download once and are prepared for the Neural Engine.")
        let library = model.library
        let label = { (text: String) in NSTextField.meety(text, font: Typography.bodyMedium) }
        add(label("Transcription engine"))
        add(ModelRowView(item: transcription, library: library))
        add(label("Summary engine"))
        add(ModelRowView(item: summary, library: library))
        add(footnote)
        next.title = "Finish"
        Task {
            await library.refresh()
            // A built-in model already on disk beats downloading the recommendation.
            let downloaded = await model.builtIn.models().filter { $0.status == .available }.map(\.model.name)
            if let best = BuiltInModel.best(of: downloaded), ModelLibrary.Item.builtIn(best) != summary {
                summary = .builtIn(best)
                if step == .models { show(.models) }
                return
            }
            for item in [transcription, summary] { Task { await prepare(item) } }
        }
    }

    /// Downloads `item` if needed, then selects it unless the user already has a model of that kind.
    private func prepare(_ item: ModelLibrary.Item) async {
        let library = model.library
        if library.state(item) == .missing { await library.download(item) }
        guard library.state(item) == .ready else { return }
        switch item {
        case .builtIn: if library.summary?.model.isEmpty ?? true { await library.use(item) }
        default: if library.transcription == nil { await library.use(item) }
        }
    }

    private func renderModels() {
        let library = model.library
        let ready = library.state(transcription) == .ready
        guard step == .models else { return }
        next.isEnabled = ready
        footnote.stringValue = ready
            ? (library.state(summary) == .ready ? "All set." : "You can continue while the summary engine finishes. Downloads continue in the background.")
            : "You can start using Meety after the transcription engine is downloaded."
    }

    // MARK: Actions

    @objc private func requestPermission(_ sender: NSButton) {
        let permission = Permission.allCases[sender.tag]
        Task {
            await permission.request()
            refreshPermissions()
        }
    }

    @objc private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        show(previous)
    }

    @objc private func goNext() {
        guard let following = Step(rawValue: step.rawValue + 1) else {
            model.settings.onboardingCompleted = true
            onFinish()
            return
        }
        show(following)
        renderModels()
    }
}
