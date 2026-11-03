import AppKit
import Audio
import Core
import Transcription

/// Home: "Ready to record" with recent meetings, and the live recording screen once a recording starts
/// (page.tsx, HomeIdle.tsx, TranscriptPanel.tsx, RecordingControls.tsx).
final class HomeViewController: NSViewController, NSTextFieldDelegate {
    private let model: AppModel
    private var recorder: Recorder { model.recorder }

    // Idle
    private let idle = NSStackView()
    private let recentCount = NSTextField.meety("", font: Typography.callout, color: .meetyMutedForeground)
    private let recentList = NSStackView()

    // Active
    private let active = NSStackView()
    private let titleField = NSTextField(string: "")
    private let status = NSTextField.meety("", font: Typography.callout, color: .meetyMutedForeground)
    private let statusDot = CardView()
    private let noticeBanner = CardView()
    private let noticeLabel = NSTextField.meety("", font: Typography.callout)
    private let transcript = TranscriptListView()
    private let listening = NSTextField.meety("", font: Typography.callout, color: .meetyMutedForeground)

    // Control bar
    private let bar = CardView()
    private lazy var recordButton = NSButton.meety("Start recording", symbol: "record.circle", role: .primary, target: self, action: #selector(record))
    private let micPopup = NSPopUpButton()
    private let systemPopup = NSPopUpButton()
    private let spinner = NSProgressIndicator()
    private let progressLabel = NSTextField.meety("", font: Typography.callout, color: .meetyMutedForeground)
    private lazy var pauseButton = NSButton.meety("Pause", symbol: "pause.fill", target: self, action: #selector(togglePause))
    private lazy var stopButton = NSButton.meety("Stop", symbol: "stop.fill", role: .destructive, target: self, action: #selector(stop))
    private let micMeter = LevelMeterView(label: "Microphone level")
    private let systemMeter = LevelMeterView(label: "System audio level")
    private let elapsed = NSTextField(labelWithString: "0:00")
    private var idleControls: [NSView] = []
    private var startingControls: [NSView] = []
    private var recordingControls: [NSView] = []

    private let consent = CardView()
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
            idle.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 40),
            idle.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            idle.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            idle.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 32),
            idle.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -64).withPriority(.defaultHigh),

            active.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 16),
            active.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            active.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            active.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),
            active.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).withPriority(.defaultHigh),
            active.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -12),

            bar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),

            consent.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            consent.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -12),
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
        track { [weak self] in self?.renderRecent() }
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
        let heading = NSTextField.meety("Ready to record", font: NSFont.systemFont(ofSize: 24, weight: .semibold))
        let intro = NSTextField.meety(
            "Start recording when the call begins. Meety writes the transcript as people talk and turns it into notes afterwards. Audio and text stay on this computer.",
            font: NSFont.systemFont(ofSize: 15), color: .meetyMutedForeground)
        let recentTitle = NSTextField.meety("Recent meetings", font: Typography.bodyMedium)
        let header = NSStackView(views: [recentTitle, NSView(), recentCount])
        let rule = NSBox()
        rule.boxType = .separator
        recentList.orientation = .vertical
        recentList.alignment = .leading
        recentList.spacing = 0
        idle.orientation = .vertical
        idle.alignment = .leading
        idle.spacing = 8
        for v in [heading, intro, header, rule, recentList] as [NSView] { idle.addArrangedSubview(v) }
        idle.setCustomSpacing(40, after: intro)
        idle.setCustomSpacing(4, after: header)
        for v in [intro, header, rule, recentList] as [NSView] { v.widthAnchor.constraint(equalTo: idle.widthAnchor).isActive = true }
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
        noticeRow.translatesAutoresizingMaskIntoConstraints = false
        noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noticeBanner.fill = .meetyMuted
        noticeBanner.stroke = nil
        noticeBanner.addSubview(noticeRow)
        pin(noticeRow, in: noticeBanner, inset: 8)

        listening.alignment = .center
        active.orientation = .vertical
        active.alignment = .leading
        active.spacing = 6
        for v in [titleField, statusRow, noticeBanner, listening, transcript] as [NSView] { active.addArrangedSubview(v) }
        active.setCustomSpacing(12, after: statusRow)
        for v in [titleField, noticeBanner, listening, transcript] as [NSView] { v.widthAnchor.constraint(equalTo: active.widthAnchor).isActive = true }
        transcript.setContentHuggingPriority(.defaultLow, for: .vertical)
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
        elapsed.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let micIcon = NSImageView(image: NSImage(systemSymbolName: "mic", accessibilityDescription: nil)!)
        let systemIcon = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil)!)
        for icon in [micIcon, systemIcon] { icon.contentTintColor = .meetyMutedForeground }
        let meters = NSStackView(views: [micIcon, micMeter, systemIcon, systemMeter])
        meters.spacing = 6

        idleControls = [recordButton, micPopup, systemPopup]
        startingControls = [spinner, progressLabel]
        recordingControls = [elapsed, meters, pauseButton, stopButton]
        let row = NSStackView(views: idleControls + startingControls + recordingControls)
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.fill = .meetyBackground
        bar.shadow = NSShadow()
        bar.layer?.shadowOpacity = 0.12
        bar.layer?.shadowRadius = 12
        bar.layer?.shadowOffset = CGSize(width: 0, height: -2)
        bar.addSubview(row)
        pin(row, in: bar, inset: 0)
    }

    private func buildConsent() {
        let icon = NSImageView(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)!)
        icon.contentTintColor = .meetySignal
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
        stack.translatesAutoresizingMaskIntoConstraints = false
        consent.addSubview(stack)
        pin(stack, in: consent, inset: 12)
        done.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: 0).isActive = true
        body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        consent.isHidden = true
        consent.setAccessibilityElement(true)
        consent.setAccessibilityRole(.group)
        consent.setAccessibilityLabel("Recording notice")
        consentCheckbox = again
    }

    private var consentCheckbox: NSButton?

    private func pin(_ child: NSView, in parent: NSView, inset: CGFloat) {
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
        ])
    }

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
        idleControls.forEach { $0.isHidden = isLive || isBusy }
        startingControls.forEach { $0.isHidden = !isBusy }
        recordingControls.forEach { $0.isHidden = !isLive }
        if isBusy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        pauseButton.title = phase == .paused ? "Resume" : "Pause"
        pauseButton.image = NSImage(systemSymbolName: phase == .paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
        status.stringValue = phase == .paused ? "Paused" : isLive ? "Recording" : progressLabel.stringValue
        statusDot.fill = phase == .paused ? .meetyInput : .meetySignal
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

    private func renderRecent() {
        let meetings = model.meetings
        recentCount.stringValue = "\(meetings.count) saved"
        recentList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if meetings.isEmpty {
            let empty = CardView()
            empty.fill = .clear
            let label = NSTextField.meety("Your first recording will appear here once it is saved.", font: Typography.callout, color: .meetyMutedForeground)
            label.translatesAutoresizingMaskIntoConstraints = false
            empty.addSubview(label)
            pin(label, in: empty, inset: 12)
            recentList.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: recentList.widthAnchor).isActive = true
            return
        }
        for meeting in meetings.prefix(6) {
            let row = NSButton(title: meeting.title, image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!, target: self, action: #selector(openRecent(_:)))
            row.isBordered = false
            row.alignment = .left
            row.imagePosition = .imageTrailing
            row.imageHugsTitle = false
            row.font = Typography.body
            row.contentTintColor = .meetyMutedForeground
            row.lineBreakMode = .byTruncatingTail
            row.identifier = .init(meeting.id)
            row.heightAnchor.constraint(equalToConstant: 40).isActive = true
            recentList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: recentList.widthAnchor).isActive = true
        }
    }

    private func fillDevicePopups() {
        let settings = model.settings
        micPopup.removeAllItems()
        micPopup.addItem(withTitle: "Default microphone" + (AudioDevices.defaultInput().map { " (\($0.name))" } ?? ""))
        for device in AudioDevices.inputs() {
            micPopup.addItem(withTitle: device.name)
            micPopup.lastItem?.representedObject = device.name
        }
        if let preferred = settings.preferredMicDevice {
            if micPopup.indexOfItem(withTitle: preferred) < 0 {
                micPopup.addItem(withTitle: "\(preferred) (disconnected)")
                micPopup.lastItem?.representedObject = preferred
            }
            micPopup.selectItem(at: micPopup.indexOfItem(withRepresentedObject: preferred))
        }
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
        micMeter.level = .silent
        systemMeter.level = .silent
    }

    @objc private func tick() {
        let levels = recorder.levels
        micMeter.level = levels.microphone
        systemMeter.level = levels.system
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

    @objc private func openRecent(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        model.route = .meeting(id)
    }

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

private extension Recorder.Phase {
    var isStarting: Bool { if case .starting = self { true } else { false } }
    var isFailed: Bool { if case .failed = self { true } else { false } }
}

extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
