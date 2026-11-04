import AppKit

extension NSButton {
    enum Role { case primary, secondary, destructive }

    /// House buttons are native glass buttons, so focus rings, hover, disabled state and accessibility come from AppKit.
    static func meety(_ title: String, symbol: String? = nil, role: Role = .secondary, target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .glass
        button.controlSize = .large
        if let symbol { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); button.imagePosition = .imageLeading }
        switch role {
        case .primary: button.tintProminence = .primary
        case .secondary: break
        case .destructive: button.tintProminence = .primary; button.bezelColor = .systemRed
        }
        return button
    }
}

/// A rounded, bordered surface (the web app's `Card`). Colors re-resolve on appearance changes in `updateLayer`.
class CardView: NSView {
    var fill: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
    var stroke: NSColor? = .separatorColor { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Metrics.radius
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = stroke?.cgColor
        layer?.borderWidth = stroke == nil ? 0 : 1
    }
}

/// Centered icon, title, message and an optional action (EmptyStateSummary.tsx and friends).
final class EmptyStateView: NSView {
    let button: NSButton?
    private let messageLabel: NSTextField

    init(symbol: String, title: String, message: String, action: (title: String, symbol: String?, target: AnyObject?, selector: Selector)? = nil) {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 40, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        let titleLabel = NSTextField.meety(title, font: Typography.headline)
        titleLabel.alignment = .center
        messageLabel = NSTextField.meety(message, font: Typography.callout, color: .secondaryLabelColor)
        messageLabel.alignment = .center
        messageLabel.preferredMaxLayoutWidth = 360
        button = action.map { NSButton.meety($0.title, symbol: $0.symbol, role: .primary, target: $0.target, action: $0.selector) }

        super.init(frame: .zero)
        let stack = NSStackView(views: [icon, titleLabel, messageLabel] + (button.map { [$0] } ?? []))
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(16, after: icon)
        stack.setCustomSpacing(20, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 32),
        ])
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    var message: String {
        get { messageLabel.stringValue }
        set { messageLabel.stringValue = newValue }
    }
}

/// The Meety mark: a three-bar voice level in an ink square (MeetyMark.tsx, icons/meety.svg), on shape layers.
final class MeetyMarkView: NSView {
    private let square = CAShapeLayer()
    private let bars = (0..<3).map { _ in CAShapeLayer() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        square.fillColor = NSColor(srgbRed: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255, alpha: 1).cgColor
        layer?.addSublayer(square)
        for (bar, color) in zip(bars, [NSColor.white, NSColor(srgbRed: 0x5b / 255, green: 0x93 / 255, blue: 0xe8 / 255, alpha: 1), .white]) {
            bar.fillColor = color.cgColor
            square.addSublayer(bar)
        }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    override func layout() {
        super.layout()
        // SVG viewBox 100…924 (824 units). The bars are vertically centered, so y-flip doesn't matter.
        let scale = min(bounds.width, bounds.height) / 824
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: (x - 100) * scale, y: (y - 100) * scale, width: w * scale, height: h * scale)
        }
        square.frame = bounds
        square.path = CGPath(roundedRect: rect(100, 100, 824, 824), cornerWidth: 185 * scale, cornerHeight: 185 * scale, transform: nil)
        for (bar, spec) in zip(bars, [(284.0, 362.0, 300.0), (460, 252, 520), (636, 322, 380)]) {
            bar.path = CGPath(roundedRect: rect(spec.0, spec.1, 104, spec.2), cornerWidth: 52 * scale, cornerHeight: 52 * scale, transform: nil)
        }
    }
}
