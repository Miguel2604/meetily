import AppKit

/// A scrolling bar waveform of recent input levels on one shape layer; the owner pushes levels from a display link.
final class WaveformView: NSView {
    private let bars = CAShapeLayer()
    private var history = [CGFloat](repeating: 0, count: 36)
    private var lastPush: CFTimeInterval = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(bars)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel("Input level")
        widthAnchor.constraint(equalToConstant: 132).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    /// Adds a bar about 20 times a second, whatever the display rate.
    func push(_ rms: Float, at time: CFTimeInterval) {
        guard time - lastPush >= 0.05 else { return }
        lastPush = time
        history.removeFirst()
        history.append(Self.fraction(rms))
        setAccessibilityValue(history.last)
        redraw()
    }

    func reset() {
        history = history.map { _ in 0 }
        redraw()
    }

    override func layout() {
        super.layout()
        redraw()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { bars.fillColor = NSColor.secondaryLabelColor.cgColor }
    }

    private func redraw() {
        let step = bounds.width / CGFloat(history.count)
        let width = max(1, step * 0.55)
        let path = CGMutablePath()
        for (i, level) in history.enumerated() {
            let height = max(2, level * bounds.height)
            let radius = min(width, height) / 2
            path.addRoundedRect(in: CGRect(x: CGFloat(i) * step, y: (bounds.height - height) / 2, width: width, height: height),
                                cornerWidth: radius, cornerHeight: radius)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.frame = bounds
        bars.path = path
        CATransaction.commit()
    }

    /// RMS on a −60…0 dBFS scale.
    static func fraction(_ rms: Float) -> CGFloat {
        let db = 20 * log10(max(rms, 1e-6))
        return CGFloat(min(1, max(0, (db + 60) / 60)))
    }
}
