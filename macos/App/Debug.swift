import AppKit

#if DEBUG
/// `MEETY_SNAPSHOT=/path.png` captures the front window to a PNG after launch and quits.
/// `MEETY_APPEARANCE=light|dark` forces the appearance.
enum DebugSnapshot {
    /// `window` is asked at snapshot time, so a window opened after launch (Settings) can be captured.
    static func scheduleIfRequested(_ window: @escaping () -> NSWindow?) {
        let env = ProcessInfo.processInfo.environment
        if let name = env["MEETY_APPEARANCE"] { NSApp.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua) }
        guard let path = env["MEETY_SNAPSHOT"] else { return }
        let delay = Double(env["MEETY_SNAPSHOT_DELAY"] ?? "") ?? 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            defer { exit(0) } // terminate(_:) waits while a sheet is attached
            guard let window = window() else { return }
            // The window server draws Liquid Glass, so cacheDisplay would show it as flat fills.
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", path]
            try? capture.run()
            capture.waitUntilExit()
            if capture.terminationStatus == 0, FileManager.default.fileExists(atPath: path) { return }
            guard let view = window.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif

#if DEBUG
import Core
import Transcription

/// `MEETY_DEMO_RECORDING=1` records a synthetic tone through the real session with a canned engine,
/// so the recording screen can be checked without microphone permission or a model.
enum DemoRecording {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["MEETY_DEMO_RECORDING"] != nil }

    final class Engine: TranscriptionEngine {
        let lines = ["Okay, let's get started with the weekly design review.", "First item is the new sidebar, which groups meetings by date and searches transcripts. It also shows a snippet of the matching transcript under each title, and rename and delete work from the keyboard as well as the context menu.",
                     "We also need to decide on the recording screen layout before Friday."]
        let counter = Mutex(0)
        func transcribe(samples: [Float]) async throws -> [Segment] {
            let i = counter.withLock { defer { $0 += 1 }; return $0 }
            return [Segment(text: lines[i % lines.count], start: 0, end: Double(samples.count) / 16_000)]
        }
    }

    final class Detector: VoiceDetector {
        var frameSize: Int { 480 }
        func speechProbability(_ frame: [Float]) async throws -> Float { (frame.map { $0 * $0 }.reduce(0, +) / Float(frame.count)) > 1e-4 ? 1 : 0 }
    }

    static func inputs(title: String, folder: URL) -> Recorder.Inputs {
        var samples: [Float] = []
        for _ in 0..<20 { // bursts of tone and silence, 48 kHz
            samples += (0..<96_000).map { 0.2 * sin(2 * .pi * 220 * Float($0) / 48_000) } + [Float](repeating: 0, count: 48_000)
        }
        return Recorder.Inputs(title: title, folder: folder, engine: Engine(), detector: Detector(),
                               microphone: PacedSource(samples: samples), system: nil, microphoneName: "Demo tone")
    }

    /// Releases samples in real time, like a capture.
    final class PacedSource: AudioSource {
        let samples: [Float]
        let state = Mutex((position: 0, started: Date()))
        init(samples: [Float]) { self.samples = samples }
        var droppedSamples: Int { 0 }
        func stop() {}
        func drain() -> [Float] {
            state.withLock { s in
                let end = min(samples.count, Int(Date().timeIntervalSince(s.started) * 48_000))
                defer { s.position = max(s.position, end) }
                return end > s.position ? Array(samples[s.position..<end]) : []
            }
        }
    }
}
import Synchronization
#endif
