import AppKit

/// One downloadable model: name, description, size, status with progress, and Download / Cancel / Use / Delete
/// (ParakeetModelManager.tsx, WhisperModelManager.tsx, BuiltInModelManager.tsx).
final class ModelRowView: CardView {
    let item: ModelLibrary.Item
    private let library: ModelLibrary
    private let status = NSTextField.meety("", font: Typography.caption, color: .secondaryLabelColor)
    private let progress = NSProgressIndicator()
    private lazy var primary = NSButton.meety("Download", target: self, action: #selector(primaryAction))
    private lazy var delete = NSButton.meety("", symbol: "trash", target: self, action: #selector(deleteAction))

    init(item: ModelLibrary.Item, library: ModelLibrary) {
        self.item = item
        self.library = library
        super.init(frame: .zero)
        let title = NSTextField.meety(item.title, font: Typography.bodyMedium)
        let size = NSTextField.meety(Self.size(item.sizeMB), font: Typography.caption, color: .secondaryLabelColor)
        let detail = NSTextField.meety(item.detail, font: Typography.callout, color: .secondaryLabelColor)
        detail.preferredMaxLayoutWidth = 340
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        primary.controlSize = .regular
        delete.controlSize = .regular
        delete.toolTip = "Delete the model to free up space"
        delete.setAccessibilityLabel("Delete \(item.title)")

        let heading = NSStackView(views: [title, size])
        heading.spacing = 6
        let text = NSStackView(views: [heading, detail, progress, status])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        let buttons = NSStackView(views: [primary, delete])
        buttons.spacing = 6
        buttons.setContentHuggingPriority(.required, for: .horizontal)
        for view in [text, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            text.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -12),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 240),
            detail.widthAnchor.constraint(equalToConstant: 340),
        ])
        track { [weak self] in self?.render() }
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    static func size(_ megabytes: Int) -> String {
        megabytes >= 1000 ? String(format: "%.1f GB", Double(megabytes) / 1000) : "\(megabytes) MB"
    }

    private func render() {
        let state = library.state(item)
        let selected = library.isSelected(item)
        progress.isHidden = true
        delete.isHidden = false
        primary.isEnabled = true
        status.textColor = .secondaryLabelColor
        switch state {
        case .missing:
            (primary.title, status.stringValue) = ("Download", "Not downloaded")
            delete.isHidden = true
        case .downloading(let value):
            progress.isHidden = false
            progress.doubleValue = value
            primary.title = "Cancel"
            delete.isHidden = true
            status.stringValue = value >= 0.99
                ? "Preparing for the Neural Engine… The first time, this can take a few minutes."
                : "Downloading… \(Int(value * 100))%"
        case .preparing:
            (primary.title, primary.isEnabled) = ("Preparing…", false)
            status.stringValue = "Preparing \(item.title)… This may take a few minutes."
        case .ready:
            primary.title = selected ? "In Use" : "Use"
            primary.isEnabled = !selected
            status.stringValue = selected ? "Ready · in use" : "Ready"
        case .failed(let message):
            primary.title = "Retry"
            status.stringValue = message
            status.textColor = .systemRed
        }
        setAccessibilityLabel("\(item.title), \(status.stringValue)")
    }

    @objc private func primaryAction() {
        switch library.state(item) {
        case .downloading: Task { await library.cancel(item) }
        case .ready: Task { await library.use(item) }
        case .preparing: break
        case .missing: Task { await library.download(item) }
        case .failed: Task { await library.retry(item) }
        }
    }

    @objc private func deleteAction() {
        let alert = NSAlert()
        alert.messageText = "Delete \(item.title)?"
        alert.informativeText = "You can download it again later."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [library, item] response in
            if response == .alertFirstButtonReturn { Task { await library.delete(item) } }
        }
    }
}
