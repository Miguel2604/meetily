import AppKit
import ApplicationServices
import Audio
import Carbon.HIToolbox
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
    @ObservationIgnored private let sounds = DictationSoundPlayer()
    @ObservationIgnored private var lastPhase = Dictation.Phase.idle
    @ObservationIgnored private var reveal: Task<Void, Never>?
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
        deliver: { [weak self] text in self?.deliver(text) })
    /// The transcript behind the dictation being cleaned. Dictations clean and deliver one at a time, so it's the right one.
    @ObservationIgnored private var heard = ""
    @ObservationIgnored private var pasteLastKey: EventHotKeyRef?
    private static weak var active: DictationController?
    private static let pasteLastHandler: Void = {
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { DictationController.active?.pasteLast() }
            return noErr
        }, 1, &pressed, nil, nil)
    }()

    init(model: AppModel) {
        self.model = model
        track { [weak self] in self?.refresh() }
        Task { [store = model.store] in // hourly, so entries expire on time in an app that stays open for weeks
            while !Task.isCancelled {
                try? await store.pruneDictations()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
        overlay.level = { [weak self] in self?.dictation.level ?? 0 }
        track { [weak self] in
            guard let self else { return }
            phaseChanged(dictation.phase)
        }
    }

    private func phaseChanged(_ phase: Dictation.Phase) {
        defer { lastPhase = phase }
        guard phase != .listening else {
            guard lastPhase != .listening else { return }
            // Starting the microphone blocks this actor, so the key of a shortcut (⌥E) is queued behind it. A moment's
            // grace lets that cancel first, and neither the pill nor the sound shows for a keyboard shortcut.
            reveal?.cancel()
            reveal = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled, let self else { return }
                overlay.show(.listening, finishKey: ptt.isLocked ? key.symbol : nil)
                play(ptt.isLocked ? .lock : .start)
            }
            return
        }
        reveal?.cancel()
        overlay.show(phase, finishKey: nil)
    }

    private func play(_ cue: DictationCue) {
        if model.settings.dictationSounds { sounds.play(cue) }
    }

    private func fail(_ message: String) {
        overlay.flash(message)
        play(.failed)
    }

    private func deliver(_ text: String) {
        paste(text)
        guard model.settings.dictationHistory else { return }
        let (heard, app) = (heard, NSWorkspace.shared.frontmostApplication?.localizedName)
        Task { [store = model.store] in
            do { try await store.saveDictation(heard: heard, text: text, app: app) } catch {
                Logger(subsystem: "com.meetily.ai", category: "dictation").warning("History save failed: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    /// Pastes the last dictation again; the way back to one that landed nowhere, since the clipboard is restored.
    func pasteLast() {
        if let text = Paste.last { paste(text) }
    }

    private func paste(_ text: String) {
        guard Paste.insert(text) else { return fail("Copied. Press ⌘V, or allow Accessibility") }
        guard dictation.phase != .listening else { return } // the next dictation has the pill and the quiet
        overlay.confirm()
        play(.done)
    }

    /// ⌥⇧V, as a Carbon hot key: it needs no permission and the V never reaches the app in front.
    private func setPasteLastKey(_ on: Bool) {
        if let pasteLastKey { UnregisterEventHotKey(pasteLastKey) }
        pasteLastKey = nil
        guard on else { return }
        Self.active = self
        _ = Self.pasteLastHandler
        RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(optionKey | shiftKey), EventHotKeyID(signature: 0x4D54_4C59, id: 1),
                            GetApplicationEventTarget(), 0, &pasteLastKey)
    }

    /// Asks for Accessibility with the system prompt (which links to System Settings).
    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    #if DEBUG
    /// `MEETY_DICTATION_PILL=<dir>`: every pill state once, with a fake voice and no microphone, writing frames of the pill's
    /// own window (never the rest of the screen) to the directory, then quits.
    func runPillDemo(frames: String) {
        overlay.level = { Float(0.002 + 0.09 * pow(0.5 + 0.5 * sin(CACurrentMediaTime() * 5.3), 2) * (0.5 + 0.5 * sin(CACurrentMediaTime() * 1.7))) }
        Task {
            let pause = { (seconds: Double) in try? await Task.sleep(for: .seconds(seconds)) }
            await pause(0.5)
            overlay.show(.listening, finishKey: nil)
            let number = overlay.debugWindowNumber
            Task.detached {
                for index in 0..<400 {
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l\(number)", String(format: "\(frames)/f-%04d.png", index)]
                    try? capture.run()
                    capture.waitUntilExit()
                }
            }
            await pause(1.5)
            overlay.show(.transcribing, finishKey: nil); await pause(0.8)
            overlay.show(.cleaning, finishKey: nil); await pause(1.2)
            overlay.confirm(); await pause(1.2)
            overlay.show(.listening, finishKey: key.symbol); await pause(1.2)
            overlay.show(.cleaning, finishKey: nil); await pause(0.8)
            overlay.flash("Copied. Press ⌘V, or allow Accessibility"); await pause(3.4)
            exit(0)
        }
    }
    #endif

    private var key: DictationKey { DictationKey(saved: model.settings.dictationKey) }

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
        // A new key waits for the capture to end, so a hands-free dictation can still finish on the key it started with.
        let keyChanged = ptt.keyCode != key.keyCode && dictation.phase != .listening
        guard enabled != !monitors.isEmpty || (enabled && trusted != monitorsTrusted) || keyChanged else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        ptt = PushToTalk(key: key) // a hold that began before the change would cancel the next real one
        setPasteLastKey(enabled)
        guard enabled else {
            dictation.cancel()
            return
        }
        monitorsTrusted = trusted
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
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
        if event.type != .flagsChanged { Paste.inputHappened() }
        guard event.type == .keyDown || event.type == .flagsChanged else { return }
        let action: PushToTalk.Action?
        if event.type == .keyDown {
            action = ptt.keyDown()
        } else {
            let flags = event.modifierFlags.rawValue
            action = ptt.flagsChanged(keyCode: event.keyCode, held: key.isHeld(flags: flags), others: key.othersDown(flags: flags), at: .now)
        }
        if let action { Logger(subsystem: "com.meetily.ai", category: "dictation").info("Push to talk: \(String(describing: action), privacy: .public)") }
        switch action {
        case .start:
            start()
            if dictation.phase != .listening { ptt = PushToTalk(key: key) } // it didn't start, so don't wait for a finishing press
        case .finish:
            play(.stop)
            Task {
                do { try await dictation.finish() } catch { fail("Dictation failed: \(error)") }
            }
        case .cancel: dictation.discard()
        case nil: break
        }
    }

    private func start() {
        guard !model.recorder.isActive else { return fail("Dictation is off while a meeting records") }
        guard MicrophonePermission.isGranted else {
            if MicrophonePermission.isUndetermined { Task { _ = await MicrophonePermission.request() } }
            else { fail("Allow Meety in System Settings › Privacy & Security › Microphone") }
            return
        }
        dictation.hearsCues = model.settings.dictationSounds
        do { try dictation.start() } catch { fail("Microphone failed to start: \(error)") }
    }

    private func clean(_ heard: String) async -> String {
        self.heard = heard
        let vocabulary = DictationVocabulary(model.settings.dictationVocabulary)
        let raw = vocabulary.correct(heard)
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let app = model.settings.dictationAppPrompts.first { $0.bundleID == front }
        switch CleanupMode(rawValue: model.settings.dictationCleanup) ?? .onDevice {
        case .off:
            return raw
        case .onDevice:
            guard DictationCleanup.onDeviceAvailable else { return raw }
            return await DictationCleanup.clean(raw, terms: vocabulary.terms, app: app, generate: DictationCleanup.onDevice)
        case .summaryModel:
            guard let config = try? await SummaryConfig.load(store: model.store) else { return raw }
            return await DictationCleanup.clean(raw, terms: vocabulary.terms, app: app, generate: DictationCleanup.summaryModel(config, client: LLMClient(), builtIn: model.builtIn))
        case .dictationModel:
            let name = model.settings.dictationModel
            guard let provider = Provider(id: model.settings.dictationProvider), !name.isEmpty else { return raw }
            let config = await SummaryConfig.dictation(provider: provider, model: name)
            return await DictationCleanup.clean(raw, terms: vocabulary.terms, app: app, generate: DictationCleanup.summaryModel(config, client: LLMClient(), builtIn: model.builtIn))
        }
    }
}

/// Puts text into the focused app: the clipboard plus a synthetic ⌘V, then the previous clipboard comes back.
enum Paste {
    /// The clipboard from before a paste whose restore is still pending, and the change count right after that paste.
    private static var pending: (saved: [NSPasteboardItem], ours: Int, restore: Task<Void, Never>)?
    /// The last dictation, for Paste Last. In memory only: dictated text never goes to disk.
    private(set) static var last: String?
    /// The app and the text of the last insert, while nothing has been typed or clicked since.
    private static var continuation: (app: pid_t?, text: String)?

    static func inputHappened() { continuation = nil }

    /// False when Accessibility is off: the text is left on the clipboard to paste by hand.
    @discardableResult static func insert(_ dictated: String) -> Bool {
        last = dictated
        let front = NSWorkspace.shared.frontmostApplication
        let text = continuation.flatMap { $0.app == front?.processIdentifier ? DictationText.joined(after: $0.text, dictated) : nil } ?? dictated
        let trusted = AXIsProcessTrusted()
        if trusted { continuation = (front?.processIdentifier, text) }
        if trusted, losesPaste(front) {
            type(text)
            return true
        }
        let board = NSPasteboard.general
        pending?.restore.cancel()
        // A paste inside the previous one's restore window keeps the original clipboard, unless the user copied since.
        let saved = pending.flatMap { $0.ours == board.changeCount ? $0.saved : nil } ?? snapshot(board)
        pending = nil
        board.clearContents()
        board.setString(text, forType: .string)
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) // clipboard managers skip it
        guard trusted else { return false }
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

    private static func losesPaste(_ app: NSRunningApplication?) -> Bool {
        guard let frameworks = app?.bundleURL?.appending(path: "Contents/Frameworks") else { return false }
        let manager = FileManager.default
        let versions = ((try? manager.contentsOfDirectory(atPath: frameworks.path)) ?? [])
            .filter { $0.hasSuffix(" Framework.framework") }
            .flatMap { (try? manager.contentsOfDirectory(atPath: frameworks.appending(path: "\($0)/Versions").path)) ?? [] }
        return DictationText.losesPaste(frameworkVersions: versions)
    }

    /// Types `text` as synthetic key events; the clipboard stays as it is.
    private static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for stroke in DictationText.strokes(text) {
            for down in [true, false] {
                let event: CGEvent?
                switch stroke {
                case .text(let units):
                    event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    event?.flags = [] // a held dictation key mustn't change what the text means
                    event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                case .lineBreak:
                    event = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down) // 36: Return
                    event?.flags = .maskShift // a plain Return would send a chat message
                }
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    private static func snapshot(_ board: NSPasteboard) -> [NSPasteboardItem] {
        (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
    }
}

/// Dictation's sounds, loaded ahead of time so they play on the event.
final class DictationSoundPlayer {
    private let sounds: [DictationCue: NSSound] = Dictionary(uniqueKeysWithValues: DictationCue.allCases.compactMap { cue in
        NSSound(data: DictationSounds.wav(DictationSounds.samples(cue))).map { (cue, $0) }
    })

    func play(_ cue: DictationCue) {
        sounds[cue]?.stop()
        sounds[cue]?.play()
    }
}
