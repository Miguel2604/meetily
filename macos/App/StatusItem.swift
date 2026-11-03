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

    init(model: AppModel, openMain: @escaping () -> Void) {
        self.model = model
        self.openMain = openMain
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        state.isEnabled = false
        for entry in [record, pause] { entry.target = self }
        let open = NSMenuItem(title: "Open Meety", action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.items = [state, .separator(), record, pause, .separator(), open,
                      NSMenuItem(title: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ""),
                      .separator(), NSMenuItem(title: "Quit Meety", action: #selector(AppDelegate.quit(_:)), keyEquivalent: "")]
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
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.button?.image?.isTemplate = true
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
        record.isEnabled = live || recorder.phase == .idle || { if case .failed = recorder.phase { true } else { false } }()
        pause.title = recorder.phase == .paused ? "Resume Recording" : "Pause Recording"
        pause.isHidden = !live
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

    @objc private func openWindow() { openMain() }
}
