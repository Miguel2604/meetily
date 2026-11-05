import AppKit
import Transcription

/// The menu bar item (tray.rs): recording state, start / pause / stop, open Meety, Settings, Quit.
final class StatusItem: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let openMain: () -> Void
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let state = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var record = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "")
    private lazy var pause = NSMenuItem(title: "Pause Recording", action: #selector(togglePause), keyEquivalent: "")
    private lazy var pasteLast = NSMenuItem(title: "Paste Last Dictation", action: #selector(pasteLastDictation), keyEquivalent: "v")

    init(model: AppModel, openMain: @escaping () -> Void) {
        self.model = model
        self.openMain = openMain
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        state.isEnabled = false
        for entry in [record, pause, pasteLast] { entry.target = self }
        pasteLast.keyEquivalentModifierMask = [.option, .shift]
        pasteLast.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        let open = NSMenuItem(title: "Open Meety", action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        let settings = NSMenuItem(title: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: "")
        let quit = NSMenuItem(title: "Quit Meety", action: #selector(AppDelegate.quit(_:)), keyEquivalent: "")
        for (entry, symbol) in [(open, "macwindow"), (settings, "gearshape"), (quit, "power")] { entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.items = [state, .separator(), record, pause, .separator(), pasteLast, open, settings, .separator(), quit]
        item.menu = menu
        track { [weak self] in self?.render() }
    }

    private func render() {
        let phase = model.recorder.phase
        let (symbol, label): (String, String) = switch phase {
        case .recording: ("record.circle.fill", "Meety, recording")
        case .paused: ("pause.circle", "Meety, paused")
        case .starting, .stopping: ("ellipsis.circle", "Meety, busy")
        case .idle, .failed: ("waveform", "Meety")
        }
        // Red while recording, like the system's own recording indicators; a template image otherwise.
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.button?.image = phase == .recording ? image?.withSymbolConfiguration(.init(paletteColors: [.systemRed])) : image
        item.button?.image?.isTemplate = phase != .recording
        item.button?.toolTip = label
        updateMenu()
    }

    /// Also runs as the menu opens, so the elapsed time is current.
    func menuNeedsUpdate(_ menu: NSMenu) { updateMenu() }

    private func updateMenu() {
        let recorder = model.recorder
        let elapsed = Clock.duration(recorder.elapsed())
        switch recorder.phase {
        case .recording: state.title = "Recording · \(elapsed)"
        case .paused: state.title = "Paused · \(elapsed)"
        case .starting(let step): state.title = step
        case .stopping: state.title = "Saving…"
        case .idle, .failed: state.title = "Not recording"
        }
        let live = recorder.phase == .recording || recorder.phase == .paused
        record.title = live ? "Stop Recording" : "Start Recording"
        record.image = NSImage(systemSymbolName: live ? "stop.circle" : "record.circle", accessibilityDescription: nil)
        pause.image = NSImage(systemSymbolName: recorder.phase == .paused ? "play.circle" : "pause.circle", accessibilityDescription: nil)
        record.isEnabled = live || recorder.phase == .idle || { if case .failed = recorder.phase { true } else { false } }()
        pause.title = recorder.phase == .paused ? "Resume Recording" : "Pause Recording"
        pause.isHidden = !live
        pasteLast.isHidden = !model.settings.dictationEnabled
        pasteLast.isEnabled = Paste.last != nil
    }

    @objc private func toggleRecording() {
        let phase = model.recorder.phase
        openMain()
        Task {
            if phase == .recording || phase == .paused { await model.stopRecording() } else { await model.startRecording() }
        }
    }

    @objc private func togglePause() {
        let recorder = model.recorder
        Task { recorder.phase == .paused ? await recorder.resume() : await recorder.pause() }
    }

    @objc private func pasteLastDictation() { model.dictation.pasteLast() }

    @objc private func openWindow() { openMain() }
}
