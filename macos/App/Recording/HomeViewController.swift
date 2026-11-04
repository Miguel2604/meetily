import AppKit
import Audio
import Core
import Transcription

/// Home: a large Record button with the input pickers, and the live recording screen once a recording starts
/// (page.tsx, HomeIdle.tsx, TranscriptPanel.tsx, RecordingControls.tsx).
final class HomeViewController: NSViewController, NSTextFieldDelegate {
    private let model: AppModel
    private var recorder: Recorder { model.recorder }

    // Idle
    private let idle = NSStackView()

    // Active
    private let active = NSStackView()
    private let titleField = NSTextField(string: "")
    private let status = NSTextField.meety("", font: Typography.callout, color: .secondaryLabelColor)
    private let statusDot = CardView()
    private var noticeBanner: NSGlassEffectView!
    private let noticeLabel = NSTextField.meety("", font: Typography.callout)
    private let transcript = TranscriptListView()
    private let listening = NSTextField.meety("", font: Typography.callout, color: .secondaryLabelColor)

    // Floating glass control bar
    private let bar = NSGlassEffectContainerView()
    private let micPopup = NSPopUpButton()
    private let systemPopup = NSPopUpButton()
    private let spinner = NSProgressIndicator()
    private let progressLabel = NSTextField.meety("", font: Typography.callout, color: .secondaryLabelColor)
    private lazy var pauseButton = NSButton.meetyCircle("pause.fill", label: "Pause recording", target: self, action: #selector(togglePause))
    private lazy var stopButton = NSButton.meetyCircle("stop.fill", label: "Stop recording", role: .destructive, target: self, action: #selector(stop))
    private let waveform = WaveformView()
    private let elapsed = NSTextField(labelWithString: "0:00")
    private var startingControls: [NSView] = []
    private var recordingControls: [NSView] = []

    private var consent: NSGlassEffectView!
    private var displayLink: CADisplayLink?
    private var shownFailure: String?
    private var lastPhase = Recorder.Phase.idle

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    override func loadView() {
        let root = NSView()
        buildIdle()
        buildActive()
        buildBar()
        buildConsent()
        for v in [idle, active, bar, consent] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        let column = root.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        column.isActive = true
        NSLayoutConstraint.activate([
            idle.centerYAnchor.constraint(equalTo: root.safeAreaLayoutGuide.centerYAnchor, constant: -20),
            idle.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            idle.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 32),

            active.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 16),
            active.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            active.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            active.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),
            // Below the window-resize priority, so the capped column never pins the window width.
            active.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).withPriority(.dragThatCannotResizeWindow),
            active.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            bar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),

            consent.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            consent.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 16),
            consent.widthAnchor.constraint(equalToConstant: 300),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        track { [weak self] in self?.renderPhase() }
        track { [weak self] in
            guard let self else { return }
            transcript.set(recorder.segments.map { .init(start: $0.start, text: $0.text) })
            renderListening()
        }
        track { [weak self] in
            guard let self else { return }
            _ = (model.settings.preferredMicDevice, model.settings.recordSystemAudio)
            fillDevicePopups()
        }
        Task { [weak self] in
            for await _ in AudioDevices.events() { self?.fillDevicePopups() }
        }
    }

    // MARK: Build

    private func buildIdle() {
        let hero = NSButton.meetyCircle("mic.fill", label: "Start recording (⌘N)", role: .primary, target: self, action: #selector(record))
        hero.controlSize = .extraLarge
        hero.bezelColor = .systemRed
        // A prominent glass button picks its own content color, so the white is baked into the symbol.
        hero.image = hero.image?.withSymbolConfiguration(.init(pointSize: 30, weight: .semibold).applying(.init(paletteColors: [.white])))
        hero.widthAnchor.constraint(equalToConstant: 88).isActive = true
        hero.heightAnchor.constraint(equalToConstant: 88).isActive = true
        let title = NSTextField.meety("Start Recording", font: Typography.title)
        let hint = NSTextField.meety("Press ⌘N from anywhere in Meety. Audio and transcripts stay on this Mac.", font: Typography.callout, color: .secondaryLabelColor)
        hint.alignment = .center
        hint.preferredMaxLayoutWidth = 320
        let pickers = NSStackView(views: [micPopup, systemPopup])
        pickers.spacing = 8
        idle.orientation = .vertical
        idle.alignment = .centerX
        idle.spacing = 6
        for v in [hero, title, hint, pickers] as [NSView] { idle.addArrangedSubview(v) }
        idle.setCustomSpacing(20, after: hero)
        idle.setCustomSpacing(24, after: hint)
    }

    private func buildActive() {
        titleField.font = Typography.title
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.lineBreakMode = .byTruncatingTail
        titleField.placeholderString = "Meeting title"
        titleField.setAccessibilityLabel("Meeting title")
        titleField.delegate = self
        statusDot.stroke = nil
        statusDot.layer?.cornerRadius = 4
        statusDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let statusRow = NSStackView(views: [statusDot, status])
        statusRow.spacing = 6

        let warning = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Warning")!)
        warning.contentTintColor = .systemOrange
        let dismiss = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")!, target: self, action: #selector(dismissNotice))
        dismiss.isBordered = false
        let noticeRow = NSStackView(views: [warning, noticeLabel, dismiss])
        noticeRow.spacing = 8
        noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noticeBanner = NSGlassEffectView(wrapping: noticeRow, inset: NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 8), cornerRadius: 16)
        noticeBanner.tintColor = NSColor.systemOrange.withAlphaComponent(0.25)

        listening.alignment = .center
        active.orientation = .vertical
        active.alignment = .leading
        active.spacing = 6
        for v in [titleField, statusRow, noticeBanner, listening, transcript] as [NSView] { active.addArrangedSubview(v) }
        active.setCustomSpacing(12, after: statusRow)
        for v in [titleField, noticeBanner, listening, transcript] as [NSView] { v.widthAnchor.constraint(equalTo: active.widthAnchor).isActive = true }
        transcript.setContentHuggingPriority(.defaultLow, for: .vertical)
        // The live transcript scrolls under the floating bar.
        transcript.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 96, right: 0)
        transcript.scrollerInsets = transcript.contentInsets
    }

    private func buildBar() {
        micPopup.target = self
        micPopup.action = #selector(micChosen)
        micPopup.setAccessibilityLabel("Microphone")
        systemPopup.target = self
        systemPopup.action = #selector(systemChosen)
        systemPopup.setAccessibilityLabel("System audio")
        spinner.style = .spinning
        spinner.controlSize = .small
        elapsed.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!)
        dot.symbolConfiguration = .init(pointSize: 9, weight: .regular)
        dot.contentTintColor = .systemRed

        startingControls = [spinner, progressLabel]
        recordingControls = [dot, elapsed, waveform, pauseButton, stopButton]
        let status = NSStackView(views: startingControls + [dot, elapsed, waveform])
        status.spacing = 10
        let capsule = NSGlassEffectView(wrapping: status, inset: NSEdgeInsets(top: 10, left: 18, bottom: 10, right: 18), cornerRadius: 22)
        for button in [pauseButton, stopButton] {
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        let row = NSStackView(views: [capsule, pauseButton, stopButton])
        row.spacing = 10
        bar.spacing = 10
        bar.contentView = row
        capsule.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    private func buildConsent() {
        let icon = NSImageView(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)!)
        icon.contentTintColor = .controlAccentColor
        let title = NSTextField.meety("Recording Started", font: Typography.bodyMedium)
        let header = NSStackView(views: [icon, title])
        header.spacing = 6
        let body = NSTextField.meety("Inform all participants this meeting is being recorded.", font: Typography.callout)
        let again = NSButton(checkboxWithTitle: "Don't show this again", target: nil, action: nil)
        again.font = Typography.caption
        let done = NSButton.meety("I've Notified Participants", role: .primary, target: self, action: #selector(acknowledgeConsent(_:)))
        done.controlSize = .regular
        let stack = NSStackView(views: [header, body, again, done])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        consent = NSGlassEffectView(wrapping: stack, inset: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14), cornerRadius: 22)
        done.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: 0).isActive = true
        body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        consent.isHidden = true
        consent.setAccessibilityElement(true)
        consent.setAccessibilityRole(.group)
        consent.setAccessibilityLabel("Recording notice")
        consentCheckbox = again
    }

    private var consentCheckbox: NSButton?

    // MARK: Render

    private func renderPhase() {
        let phase = recorder.phase
        let isLive = phase == .recording || phase == .paused
        let isBusy: Bool
        switch phase {
        case .starting(let message): isBusy = true; progressLabel.stringValue = message
        case .stopping: isBusy = true; progressLabel.stringValue = "Finalizing transcription..."
        default: isBusy = false
        }
        let showActive = isLive || isBusy || !recorder.segments.isEmpty && phase != .idle
        idle.isHidden = showActive
        active.isHidden = !showActive
        bar.isHidden = !(isLive || isBusy)
        startingControls.forEach { $0.isHidden = !isBusy }
        recordingControls.forEach { $0.isHidden = !isLive }
        if isBusy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        pauseButton.toolTip = phase == .paused ? "Resume recording" : "Pause recording"
        pauseButton.image = NSImage(systemSymbolName: phase == .paused ? "play.fill" : "pause.fill", accessibilityDescription: pauseButton.toolTip)
        status.stringValue = phase == .paused ? "Paused" : isLive ? "Recording" : progressLabel.stringValue
        statusDot.fill = phase == .paused ? .tertiaryLabelColor : .systemRed
        if titleField.currentEditor() == nil { titleField.stringValue = recorder.title }
        noticeLabel.stringValue = recorder.notice ?? ""
        noticeBanner.isHidden = recorder.notice == nil
        renderListening()

        if isLive { startDisplayLink() } else { stopDisplayLink() }
        if lastPhase.isStarting, phase == .recording, model.settings.showRecordingConsent { showConsent() }
        if !isLive { consent.isHidden = true }
        if case .failed(let message) = phase, message != shownFailure {
            shownFailure = message
            let alert = NSAlert()
            alert.messageText = "Recording failed"
            alert.informativeText = message
            if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
        if !phase.isFailed { shownFailure = nil }
        lastPhase = phase
    }

    private func renderListening() {
        let phase = recorder.phase
        listening.isHidden = !recorder.segments.isEmpty || !(phase == .recording || phase == .paused)
        listening.stringValue = phase == .paused ? "Recording paused. Click Resume to continue recording." : "Listening for speech... Speak to see live transcription."
    }

    private func fillDevicePopups() {
        let settings = model.settings
        micPopup.fillMicrophones(preferred: settings.preferredMicDevice)
        systemPopup.removeAllItems()
        systemPopup.addItems(withTitles: ["System audio on", "Microphone only"])
        systemPopup.selectItem(at: settings.recordSystemAudio ? 0 : 1)
    }

    // MARK: Display link: meters and the clock, only while recording

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = view.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        waveform.reset()
    }

    @objc private func tick() {
        let levels = recorder.levels
        waveform.push(max(levels.microphone.rms, levels.system.rms), at: CACurrentMediaTime())
        let clock = Clock.duration(recorder.elapsed())
        if elapsed.stringValue != clock { elapsed.stringValue = clock }
    }

    // MARK: Actions

    @objc private func record() { Task { await model.startRecording() } }

    @objc private func togglePause() {
        Task { recorder.phase == .paused ? await recorder.resume() : await recorder.pause() }
    }

    @objc private func stop() { Task { await model.stopRecording() } }

    @objc private func micChosen() { model.settings.preferredMicDevice = micPopup.selectedItem?.representedObject as? String }

    @objc private func systemChosen() { model.settings.recordSystemAudio = systemPopup.indexOfSelectedItem == 0 }

    @objc private func dismissNotice() { noticeBanner.isHidden = true }

    func controlTextDidChange(_ obj: Notification) { recorder.title = titleField.stringValue }

    private func showConsent() {
        consentCheckbox?.state = .off
        consent.isHidden = false
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.consent.isHidden = true
        }
    }

    @objc private func acknowledgeConsent(_ sender: Any?) {
        if consentCheckbox?.state == .on { model.settings.showRecordingConsent = false }
        consent.isHidden = true
    }
}

extension Recorder.Phase {
    var isStarting: Bool { if case .starting = self { true } else { false } }
    var isFailed: Bool { if case .failed = self { true } else { false } }
}

extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

extension NSPopUpButton {
    /// "Default microphone (name)", each input by name, and a missing preferred device marked disconnected.
    /// Items carry the device name; the default item carries nil.
    func fillMicrophones(preferred: String?) {
        removeAllItems()
        addItem(withTitle: "Default microphone" + (AudioDevices.defaultInput().map { " (\($0.name))" } ?? ""))
        for device in AudioDevices.inputs() {
            addItem(withTitle: device.name)
            lastItem?.representedObject = device.name
        }
        guard let preferred else { return }
        if indexOfItem(withRepresentedObject: preferred) < 0 {
            addItem(withTitle: "\(preferred) (disconnected)")
            lastItem?.representedObject = preferred
        }
        selectItem(at: indexOfItem(withRepresentedObject: preferred))
    }
}
