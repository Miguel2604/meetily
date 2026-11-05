import AppKit
import Transcription

/// The dictation pill at the bottom of the screen. The same bars carry the whole dictation: they follow the voice while
/// listening, ripple while it's being worked on, then give way to a check drawn once. White on a flat dark capsule, with no
/// other color, glass or gradient: it has to read the same over any window, and colors here looked cheap. It never takes
/// focus, so the text lands in the app the user is typing in. It fires on a key pressed many times a day, so nothing here
/// takes longer than 240 ms and any state can interrupt any other.
final class DictationOverlay {
    /// The microphone level, read every frame while the bars are live.
    var level: () -> Float = { 0 }

    private static let height: CGFloat = 40, sideInset: CGFloat = 15
    // The curves from the taste skill's motion tokens.
    private static let easeOut = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    private static let easeInOut = CAMediaTimingFunction(controlPoints: 0.76, 0, 0.24, 1)

    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 104), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
    private let root = NSView()
    private let capsule = NSView()
    private let bars = LevelBars()
    private let check = CheckMark()
    private let icon = NSImageView()
    private let label: NSTextField = { // one line: a wrapping label has no fitting width, so the pill collapses
        let label = NSTextField(labelWithString: "")
        label.font = Typography.bodyMedium
        label.lineBreakMode = .byTruncatingTail
        label.wantsLayer = true
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true
        return label
    }()
    private lazy var row = NSStackView(views: [bars, check, icon, label])
    /// Only the capsule's width moves; what's inside crossfades, so nothing slides under anything else.
    private lazy var capsuleWidth = capsule.widthAnchor.constraint(equalToConstant: Self.height)
    private var holding: Task<Void, Never>?
    /// False while hidden or on the way out; a late exit completion checks it before ordering the panel away.
    private var shown = false
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init() {
        row.spacing = 9
        row.alignment = .centerY
        row.wantsLayer = true
        row.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        icon.contentTintColor = .white
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        bars.level = { [weak self] in self?.level() ?? 0 }
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        root.wantsLayer = true
        capsule.wantsLayer = true
        capsule.translatesAutoresizingMaskIntoConstraints = false
        if let layer = capsule.layer {
            layer.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
            layer.cornerRadius = Self.height / 2
            layer.cornerCurve = .continuous
            // It does float above everything, so it earns a shadow, and that's what lifts it off a dark window.
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.32
            layer.shadowRadius = 14
            layer.shadowOffset = CGSize(width: 0, height: -5)
        }
        capsule.addSubview(row)
        root.addSubview(capsule)
        NSLayoutConstraint.activate([
            capsule.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            capsule.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            capsule.heightAnchor.constraint(equalToConstant: Self.height),
            capsuleWidth,
            row.centerXAnchor.constraint(equalTo: capsule.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
        ])
        panel.contentView = root
    }

    func show(_ phase: Dictation.Phase, finishKey: String?) {
        switch phase {
        case .idle: if holding == nil { hide() }
        case .listening:
            let hint = finishKey.map { "Press \($0) again to finish" }
            settle(bars: .live, text: hint, muted: true)
            announce(hint ?? "Listening")
        case .transcribing: settle(bars: .ripple, text: "Transcribing", working: true)
        case .cleaning: settle(bars: .calm, text: "Tidying up", working: true)
        }
    }

    /// A check drawn once, then gone: the text landed.
    func confirm() {
        settle(check: true)
        hold(for: .milliseconds(700))
    }

    func flash(_ message: String) {
        settle(warning: true, text: message)
        announce(message)
        hold(for: .seconds(3))
    }

    private func hold(for duration: Duration) {
        holding = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            holding = nil
            hide()
        }
    }

    /// Puts the pill in one state, morphing from whatever it was showing.
    private func settle(bars mode: LevelBars.Mode? = nil, check showsCheck: Bool = false, warning: Bool = false, text: String? = nil,
                        muted: Bool = false, working: Bool = false) {
        holding?.cancel()
        holding = nil
        let morphing = shown && !reduceMotion
        if morphing {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.14
            row.layer?.add(fade, forKey: "content")
        }
        bars.isHidden = mode == nil
        if let mode { bars.run(mode) } else { bars.stop() }
        check.isHidden = !showsCheck
        icon.isHidden = !warning
        label.stringValue = text ?? ""
        label.isHidden = text == nil
        label.textColor = muted ? NSColor(white: 1, alpha: 0.62) : .white
        setBreathing(working)
        row.layoutSubtreeIfNeeded()
        let width = showsCheck ? Self.height : row.fittingSize.width + 2 * Self.sideInset
        if morphing {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = Self.easeInOut
                context.allowsImplicitAnimation = true
                capsuleWidth.animator().constant = width
                root.layoutSubtreeIfNeeded()
            }
        } else {
            capsuleWidth.constant = width
            root.layoutSubtreeIfNeeded()
        }
        if !shown { enter() }
        if showsCheck { check.draw(animated: !reduceMotion) }
    }

    /// The working words breathe, so a slow cleanup still looks alive. A move of opacity alone, once per state run.
    private func setBreathing(_ on: Bool) {
        guard on, !reduceMotion else { return label.layer?.removeAnimation(forKey: "breath") ?? () }
        guard label.layer?.animation(forKey: "breath") == nil else { return }
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 1
        breath.toValue = 0.5
        breath.duration = 0.9
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        label.layer?.add(breath, forKey: "breath")
    }

    private func enter() {
        shown = true
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.minY + 12))
        }
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = Self.easeOut
            panel.animator().alphaValue = 1
        }
        if !reduceMotion { spring(from: squeezed(0.92, drop: 8)) }
    }

    private func hide() {
        guard shown else { return }
        shown = false
        bars.stop()
        setBreathing(false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = Self.easeOut
            panel.animator().alphaValue = 0
            if !reduceMotion {
                let shrink = CABasicAnimation(keyPath: "sublayerTransform")
                shrink.toValue = NSValue(caTransform3D: squeezed(0.96, drop: 4))
                shrink.duration = context.duration
                shrink.timingFunction = context.timingFunction
                shrink.fillMode = .forwards
                shrink.isRemovedOnCompletion = false
                root.layer?.add(shrink, forKey: "pill")
            }
        } completionHandler: { [weak self] in
            guard let self, !shown else { return }
            root.layer?.removeAnimation(forKey: "pill")
            panel.orderOut(nil)
        }
    }

    /// Scales the pill around its own middle and moves it down.
    private func squeezed(_ scale: CGFloat, drop: CGFloat) -> CATransform3D {
        let middle = CGPoint(x: capsule.frame.midX, y: capsule.frame.midY)
        var transform = CATransform3DMakeTranslation(middle.x, middle.y - drop, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -middle.x, -middle.y, 0)
    }

    private func spring(from: CATransform3D) {
        guard let layer = root.layer else { return }
        let current = layer.presentation()?.sublayerTransform
        layer.removeAnimation(forKey: "pill")
        let spring = CASpringAnimation(keyPath: "sublayerTransform")
        spring.fromValue = NSValue(caTransform3D: current.flatMap { CATransform3DIsIdentity($0) ? nil : $0 } ?? from)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 1
        spring.stiffness = 420
        spring.damping = 34 // settles fast with no visible overshoot
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "pill")
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    #if DEBUG
    var debugWindowNumber: Int { panel.windowNumber }
    #endif
}

/// A check that draws itself once, stroke first.
final class CheckMark: NSView {
    private let stroke = CAShapeLayer()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        wantsLayer = true
        let path = CGMutablePath()
        path.addLines(between: [CGPoint(x: 2, y: 8), CGPoint(x: 6.2, y: 3.6), CGPoint(x: 14, y: 12.4)])
        stroke.path = path
        stroke.fillColor = nil
        stroke.strokeColor = NSColor.white.cgColor
        stroke.lineWidth = 2.2
        stroke.lineCap = .round
        stroke.lineJoin = .round
        layer?.addSublayer(stroke)
        widthAnchor.constraint(equalToConstant: 16).isActive = true
        heightAnchor.constraint(equalToConstant: 16).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    func draw(animated: Bool) {
        stroke.removeAnimation(forKey: "draw")
        guard animated else { return }
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.24
        draw.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        stroke.add(draw, forKey: "draw")
    }
}

/// Capsule bars that carry the dictation: live from the microphone, a travelling ripple while transcribing, a slow calm
/// swell while tidying up.
final class LevelBars: NSView {
    enum Mode { case live, ripple, calm }

    var level: () -> Float = { 0 }

    private static let count = 7, barWidth: CGFloat = 3, gap: CGFloat = 3, tallest: CGFloat = 20, lowest: CGFloat = 3
    /// The middle bars travel furthest, which reads as a voice rather than an equalizer.
    private static let weights: [Float] = [0.45, 0.7, 0.9, 1, 0.9, 0.7, 0.45]
    private var layers: [CALayer] = []
    private var heights = [Float](repeating: 0, count: count)
    private var mode = Mode.live
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0..<Self.count {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = Self.barWidth / 2
            layer?.addSublayer(bar)
            layers.append(bar)
        }
        widthAnchor.constraint(equalToConstant: CGFloat(Self.count) * Self.barWidth + CGFloat(Self.count - 1) * Self.gap).isActive = true
        heightAnchor.constraint(equalToConstant: Self.tallest).isActive = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    func run(_ mode: Mode) {
        self.mode = mode
        guard link == nil else { return }
        lastTick = 0
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        heights = heights.map { _ in 0 }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let step = lastTick == 0 ? 1 / 60 : Float(now - lastTick)
        lastTick = now
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // On a −52…−16 dBFS scale, where speech actually sits.
        let loudness = max(0, min(1, (20 * log10(max(level(), 1e-6)) + 52) / 36))
        for index in layers.indices {
            let position = Float(index)
            let target: Float = switch mode {
            case .live: loudness * Self.weights[index] * (0.8 + 0.2 * sin(Float(now) * 11 + position * 1.7))
            case .ripple: still ? 0.25 : 0.12 + 0.34 * (0.5 + 0.5 * sin(Float(now) * 6 - position * 0.9))
            case .calm: still ? 0.2 : (0.1 + 0.22 * (0.5 + 0.5 * sin(Float(now) * 2.6))) * Self.weights[index]
            }
            // Fast up, slow down: how a level meter reads as alive rather than jittery.
            let rate = target > heights[index] ? step / 0.03 : step / 0.12
            heights[index] += (target - heights[index]) * min(1, rate)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in layers.enumerated() {
            let height = Self.lowest + CGFloat(heights[index]) * (Self.tallest - Self.lowest)
            bar.frame = CGRect(x: CGFloat(index) * (Self.barWidth + Self.gap), y: (bounds.height - height) / 2, width: Self.barWidth, height: height)
        }
        CATransaction.commit()
    }
}
