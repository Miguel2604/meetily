import AppKit

#if DEBUG
/// `MEETY_SNAPSHOT=/path.png` renders the main window's content to a PNG after launch and quits,
/// so UI changes can be checked without screen-recording permission.
enum DebugSnapshot {
    static func scheduleIfRequested(_ window: NSWindow) {
        guard let path = ProcessInfo.processInfo.environment["MEETY_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["MEETY_SNAPSHOT_DELAY"] ?? "") ?? 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let view = window.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
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
