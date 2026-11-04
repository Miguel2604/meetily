import AppKit
import Summary

/// Push-to-talk dictation: the switch, Accessibility access, and which model tidies the text.
final class DictationPane: SettingsPane {
    private let model: AppModel
    private lazy var enabled = Self.checkbox("Hold Right Option (⌥) to dictate into any app", false, target: self, action: #selector(enabledChosen(_:)))
    private let cleanup = NSPopUpButton()
    private let access = NSTextField.meety("", font: Typography.body)
    private lazy var grant = NSButton(title: "Allow…", target: self, action: #selector(grantAccess))
    private static let modes: [(CleanupMode, String)] = [
        (.onDevice, "Apple Intelligence, on this Mac"), (.summaryModel, "The summary model"), (.off, "Nothing, paste as heard"),
    ]

    init(model: AppModel) {
        self.model = model
        super.init(title: "Dictation")
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    override func viewDidLoad() {
        super.viewDidLoad()
        cleanup.autoenablesItems = false
        cleanup.addItems(withTitles: Self.modes.map(\.1))
        cleanup.item(at: 0)?.isEnabled = DictationCleanup.onDeviceAvailable
        cleanup.target = self
        cleanup.action = #selector(cleanupChosen)
        let accessRow = NSStackView(views: [access, grant])
        accessRow.spacing = 8
        section("Push to talk", [form([("Dictation", enabled), ("Accessibility", accessRow)])],
                note: "Hold the key, speak, and let go: the text is pasted where you are typing. Meety needs Accessibility access to notice the key in other apps and to paste. Dictation uses the language set in General and the model set in Transcription, and pauses while a meeting records.")
        section("Cleanup", [form([("Tidy the text with", cleanup)])],
                note: "Fixes punctuation and capitalization, and drops filler words and false starts. If cleanup fails or takes more than 5 seconds, the text is pasted as heard. Apple Intelligence needs to be on in System Settings.")
        track { [weak self] in
            guard let self else { return }
            let settings = model.settings
            enabled.state = settings.dictationEnabled ? .on : .off
            cleanup.selectItem(at: Self.modes.firstIndex { $0.0.rawValue == settings.dictationCleanup } ?? 0)
            let granted = model.dictation.accessibilityGranted
            access.stringValue = granted ? "Allowed" : "Not allowed yet"
            access.textColor = granted ? .labelColor : .secondaryLabelColor
            grant.isHidden = granted
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        model.dictation.refresh()
    }

    @objc private func enabledChosen(_ sender: NSButton) {
        model.settings.dictationEnabled = sender.state == .on
        if sender.state == .on, !model.dictation.accessibilityGranted { model.dictation.requestAccessibility() }
    }

    @objc private func cleanupChosen() { model.settings.dictationCleanup = Self.modes[cleanup.indexOfSelectedItem].0.rawValue }

    @objc private func grantAccess() { model.dictation.requestAccessibility() }
}
