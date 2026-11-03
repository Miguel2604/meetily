import Audio
import Foundation
import Synchronization

/// The recording microphone: follows the preferred device (or the default) across unplugs, default-device
/// changes and engine configuration changes, restarting the capture and posting a notice each time.
public final class LiveMicrophone: AudioSource {
    private let preferred: String?
    private let state = Mutex<(capture: MicrophoneCapture?, retiredDrops: Int, started: Date)>((nil, 0, .distantPast))
    /// Set by an engine configuration change (device unplugged, format change): restart even on the same device.
    private let configurationChanged = Mutex(false)
    private let (recheck, recheckSink) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    private let (noticeStream, noticeSink) = AsyncStream.makeStream(of: String.self)
    private let watchers = Mutex<[Task<Void, Never>]>([])

    /// Messages for the UI when the microphone changes.
    public var notices: AsyncStream<String> { noticeStream }
    /// The device being recorded, nil when no microphone is available.
    public var device: AudioDevice? { state.withLock { $0.capture?.device } }

    /// Starts on the preferred microphone, else the default. Throws only if the chosen device fails to start.
    public init(preferred: String?) throws {
        self.preferred = preferred
        try restart(force: true, initial: true)
        let recheckSink = recheckSink
        watchers.withLock {
            $0 = [
                Task { for await _ in AudioDevices.events() { recheckSink.yield() } },
                Task { [weak self] in
                    guard let stream = self?.recheck else { return }
                    for await _ in stream {
                        guard let self else { return }
                        let force = self.configurationChanged.withLock { flag in defer { flag = false }; return flag }
                        do { try self.restart(force: force) } catch { self.noticeSink.yield("Microphone failed to restart: \(error)") }
                    }
                },
            ]
        }
    }

    public func drain() -> [Float] { state.withLock { $0.capture?.drain() ?? [] } }

    public var droppedSamples: Int { state.withLock { $0.retiredDrops + ($0.capture?.droppedSamples ?? 0) } }

    public func stop() {
        watchers.withLock { $0.forEach { $0.cancel() }; $0 = [] }
        recheckSink.finish()
        noticeSink.finish()
        state.withLock { $0.capture?.stop(); $0.capture = nil }
    }

    /// Re-resolves the device; restarts the capture when it changed (or `force`, after a configuration change).
    private func restart(force: Bool, initial: Bool = false) throws {
        let resolution = MicResolution.resolve(requested: preferred, inputs: AudioDevices.inputs(), defaultInput: AudioDevices.defaultInput())
        let (current, started) = state.withLock { ($0.capture?.device, $0.started) }
        // Starting a voice-processing unit can itself post a configuration change; don't restart in a loop.
        let freshlyStarted = Date().timeIntervalSince(started) < 2
        guard resolution.device?.uid != current?.uid || (force && !freshlyStarted) || initial else { return }
        state.withLock { s in
            s.retiredDrops += s.capture?.droppedSamples ?? 0
            s.capture?.stop()
            s.capture = nil
        }
        var quiet = false
        if initial, case .requested = resolution { quiet = true }
        if !quiet, let message = Self.notice(from: current, to: resolution) { noticeSink.yield(message) }
        guard let device = resolution.device else { return }
        let capture = MicrophoneCapture()
        let sink = recheckSink
        capture.onConfigurationChange = { [weak self] in
            self?.configurationChanged.withLock { $0 = true }
            sink.yield()
        }
        try capture.start(device: device)
        state.withLock { $0.capture = capture; $0.started = Date() }
    }

    /// What to tell the user when the recorded microphone changes; nil when it didn't.
    static func notice(from previous: AudioDevice?, to resolution: MicResolution) -> String? {
        switch resolution {
        case .requested(let device) where device.uid == previous?.uid: nil
        case .fellBack(let device) where device.uid == previous?.uid: nil
        case .requested(let device): previous == nil ? "Microphone reconnected: “\(device.name)”." : "Recording with “\(device.name)”."
        case .fellBack(let device): "Microphone disconnected. Recording with “\(device.name)”."
        case .unavailable: "No microphone available. Recording system audio only."
        }
    }
}
