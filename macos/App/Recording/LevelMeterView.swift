import AppKit
import Audio

/// A horizontal level bar on a CALayer; the owner sets `level` from a display link.
final class LevelMeterView: NSView {
    private let fill = CALayer()

    var level = AudioLevel.silent {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fill.frame = CGRect(x: 0, y: 0, width: bounds.width * Self.fraction(level.rms), height: bounds.height)
            CATransaction.commit()
        }
    }

    init(label: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 2
        layer?.masksToBounds = true
        layer?.addSublayer(fill)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel(label)
        widthAnchor.constraint(equalToConstant: 72).isActive = true
        heightAnchor.constraint(equalToConstant: 4).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        fill.backgroundColor = NSColor.controlAccentColor.cgColor
    }

    /// RMS on a −60…0 dBFS scale.
    static func fraction(_ rms: Float) -> CGFloat {
        let db = 20 * log10(max(rms, 1e-6))
        return CGFloat(min(1, max(0, (db + 60) / 60)))
    }
}
