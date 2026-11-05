import AppKit
import ApplicationServices
import Audio
import Observation
import os
import Summary
import Transcription

/// Hold Right Option in any app to dictate: the key monitors, the overlay, and pasting into the focused app.
/// Watching keys outside Meety and posting ⌘V both need Accessibility access.
@Observable
final class DictationController {
    private(set) var accessibilityGranted = AXIsProcessTrusted()

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let overlay = DictationOverlay()
    @ObservationIgnored private var ptt = PushToTalk()
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var monitorsTrusted = false
    @ObservationIgnored private var polling = false
    @ObservationIgnored private var asked = false
    @ObservationIgnored private lazy var dictation = Dictation(
        capture: { [settings = model.settings] in
            let device = MicResolution.resolve(requested: settings.preferredMicDevice, inputs: AudioDevices.inputs(),
                                               defaultInput: AudioDevices.defaultInput()).device
            let capture = MicrophoneCapture()
            try capture.start(device: device, voiceProcessing: false) // voice processing starts slower and ducks other audio
            return capture
        },
        engine: { [model] in try await model.transcriptionEngine() },
        clean: { [weak self] raw in await self?.clean(raw) ?? raw },
        deliver: { [weak self] text in
            if !Paste.insert(text) { self?.overlay.flash("Copied. Press ⌘V, or allow Accessibility in Settings › Dictation to paste") }
        })

    init(model: AppModel) {
        self.model = model
        track { [weak self] in self?.refresh() }
        track { [weak self] in
            guard let self else { return }
            overlay.show(dictation.phase)
        }
    }

    /// Asks for Accessibility with the system prompt (which links to System Settings).
    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Installs the key monitors while dictation is on. Monitors added before the Accessibility grant never see keys,
    /// so this polls for the grant and reinstalls them once it lands.
    func refresh() {
        let enabled = model.settings.dictationEnabled
        let trusted = AXIsProcessTrusted()
        if accessibilityGranted != trusted { accessibilityGranted = trusted }
        if enabled, !trusted, !asked {
            asked = true
            requestAccessibility() // once per launch: lists this build in System Settings, ready to switch on
        }
        if enabled, !trusted, !polling {
            polling = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.polling = false
                self?.refresh()
            }
        }
        guard enabled != !monitors.isEmpty || (enabled && trusted != monitorsTrusted) else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        ptt = PushToTalk() // a hold that began before the change would cancel the next real one
        guard enabled else {
            dictation.cancel()
            return
        }
        monitorsTrusted = trusted
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0); return $0 }) { monitors.append(local) }
        Task { [model] in // warm both models now, never at the first dictation (D9)
            _ = try? await model.transcriptionEngine()
            DictationCleanup.prewarmOnDevice()
        }
    }

    private func handle(_ event: NSEvent) {
        // Our own ⌘V paste would otherwise read as typing and cancel a dictation already under way.
        guard event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else { return }
        let action: PushToTalk.Action?
        if event.type == .keyDown {
            action = ptt.keyDown()
        } else {
            let flags = event.modifierFlags
            let device = flags.rawValue // NX_DEVICELALTKEYMASK 0x20, NX_DEVICERALTKEYMASK 0x40
            action = ptt.flagsChanged(keyCode: event.keyCode, held: device & 0x40 != 0,
                                      others: !flags.intersection([.command, .control, .shift, .function]).isEmpty || device & 0x20 != 0,
                                      at: .now)
        }
        if let action { Logger(subsystem: "com.meetily.ai", category: "dictation").info("Push to talk: \(String(describing: action), privacy: .public)") }
        switch action {
        case .start: start()
        case .finish:
            Task {
                do { try await dictation.finish() } catch { overlay.flash("Dictation failed: \(error)") }
            }
        case .cancel: dictation.discard()
        case nil: break
        }
    }

    private func start() {
        guard !model.recorder.isActive else { return overlay.flash("Dictation is off while a meeting records") }
        guard MicrophonePermission.isGranted else {
            if MicrophonePermission.isUndetermined { Task { _ = await MicrophonePermission.request() } }
            else { overlay.flash("Allow Meety in System Settings › Privacy & Security › Microphone") }
            return
        }
        do { try dictation.start() } catch { overlay.flash("Microphone failed to start: \(error)") }
    }

    private func clean(_ raw: String) async -> String {
        switch CleanupMode(rawValue: model.settings.dictationCleanup) ?? .onDevice {
        case .off:
            return raw
        case .onDevice:
            guard DictationCleanup.onDeviceAvailable else { return raw }
            return await DictationCleanup.clean(raw, generate: DictationCleanup.onDevice)
        case .summaryModel:
            guard let config = try? await SummaryConfig.load(store: model.store) else { return raw }
            return await DictationCleanup.clean(raw, generate: DictationCleanup.summaryModel(config, client: LLMClient(), builtIn: model.builtIn))
        case .dictationModel:
            let name = model.settings.dictationModel
            guard let provider = Provider(id: model.settings.dictationProvider), !name.isEmpty else { return raw }
            let config = await SummaryConfig.dictation(provider: provider, model: name)
            return await DictationCleanup.clean(raw, generate: DictationCleanup.summaryModel(config, client: LLMClient(), builtIn: model.builtIn))
        }
    }
}

/// Puts text into the focused app: the clipboard plus a synthetic ⌘V, then the previous clipboard comes back.
enum Paste {
    /// The clipboard from before a paste whose restore is still pending, and the change count right after that paste.
    private static var pending: (saved: [NSPasteboardItem], ours: Int, restore: Task<Void, Never>)?

    /// False when Accessibility is off: the text is left on the clipboard to paste by hand.
    @discardableResult static func insert(_ text: String) -> Bool {
        let board = NSPasteboard.general
        pending?.restore.cancel()
        // A paste inside the previous one's restore window keeps the original clipboard, unless the user copied since.
        let saved = pending.flatMap { $0.ours == board.changeCount ? $0.saved : nil } ?? snapshot(board)
        pending = nil
        board.clearContents()
        board.setString(text, forType: .string)
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) // clipboard managers skip it
        guard AXIsProcessTrusted() else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down) // 9: V
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        let ours = board.changeCount
        // The target app reads the clipboard as it handles ⌘V; restore after that, unless something else copied since.
        let restore = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            pending = nil
            guard board.changeCount == ours else { return }
            board.clearContents()
            board.writeObjects(saved)
        }
        pending = (saved, ours, restore)
        return true
    }

    private static func snapshot(_ board: NSPasteboard) -> [NSPasteboardItem] {
        (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
    }
}

/// A small glass pill at the bottom of the screen: listening, transcribing, cleaning, or a short error.
/// It never takes focus, so the text lands in the app the user is typing in.
final class DictationOverlay {
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let icon = NSImageView()
    private let label: NSTextField = { // one line: a wrapping label has no fitting width, so the pill collapses
        let label = NSTextField(labelWithString: "")
        label.font = Typography.bodyMedium
        label.lineBreakMode = .byTruncatingTail
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 480).isActive = true
        return label
    }()
    private lazy var glass = NSGlassEffectView(wrapping: row, inset: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 18), cornerRadius: 21)
    private lazy var row = NSStackView(views: [icon, label])
    private var flashing: Task<Void, Never>?

    init() {
        row.spacing = 8
        icon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = glass
    }

    func show(_ phase: Dictation.Phase) {
        switch phase {
        case .idle: if flashing == nil { panel.orderOut(nil) }
        case .listening: present("mic.fill", .systemRed, "Listening…")
        case .transcribing: present("waveform", .secondaryLabelColor, "Transcribing…")
        case .cleaning: present("sparkles", .secondaryLabelColor, "Tidying up…")
        }
    }

    func flash(_ message: String) {
        Logger(subsystem: "com.meetily.ai", category: "dictation").notice("Dictation pill: \(message, privacy: .public)")
        present("exclamationmark.triangle.fill", .systemOrange, message)
        flashing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            flashing = nil
            panel.orderOut(nil)
        }
    }

    private func present(_ symbol: String, _ color: NSColor, _ text: String) {
        flashing?.cancel()
        flashing = nil
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = color
        label.stringValue = text
        panel.setContentSize(glass.fittingSize)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.minY + 40))
        }
        panel.orderFrontRegardless()
    }
}
