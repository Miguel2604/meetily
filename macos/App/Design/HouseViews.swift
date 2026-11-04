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

    /// A round, icon-only glass button; `label` is its accessibility label and tooltip.
    static func meetyCircle(_ symbol: String, label: String, role: Role = .secondary, target: AnyObject?, action: Selector?) -> NSButton {
        let button = meety("", role: role, target: target, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.borderShape = .circle
        button.toolTip = label
        return button
    }
}

extension NSGlassEffectView {
    /// Liquid Glass around `content` with padding. Glass is for controls and chrome, never behind long text.
    convenience init(wrapping content: NSView, inset: NSEdgeInsets, cornerRadius: CGFloat) {
        self.init(frame: .zero)
        let box = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset.left),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -inset.right),
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: inset.top),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -inset.bottom),
        ])
        contentView = box
        self.cornerRadius = cornerRadius
    }
}

/// A rounded, grouped surface, as System Settings draws its groups. Colors re-resolve on appearance changes in `updateLayer`.
class CardView: NSView {
    var fill: NSColor = .quaternarySystemFill { didSet { needsDisplay = true } }
    var stroke: NSColor? { didSet { needsDisplay = true } }

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

/// A System Settings–style form group: rows of label and control in one rounded box, hairlines between rows.
/// A row with an empty label is its control alone, leading-aligned (hints, button rows).
final class FormSection: CardView {
    init(rows: [(String, NSView)]) {
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for (index, (label, control)) in rows.enumerated() {
            if index > 0 {
                let rule = NSBox()
                rule.boxType = .separator
                stack.addArrangedSubview(rule)
                rule.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14).isActive = true
                rule.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14).isActive = true
            }
            let content = NSStackView(views: label.isEmpty ? [control] : [NSTextField(labelWithString: label), NSView(), control])
            content.alignment = .centerY
            // Required padding: stack view edge insets give way when a sheet or window sizes to fit.
            let row = NSView()
            content.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
                content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
                content.topAnchor.constraint(equalTo: row.topAnchor, constant: 9),
                content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -9),
            ])
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }
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
