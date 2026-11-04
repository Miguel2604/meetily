import AVFoundation
import AudioToolbox
import CoreAudio

/// Microphone permission (`NSMicrophoneUsageDescription`).
public enum MicrophonePermission {
    public static var isGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    public static var isUndetermined: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined }
    public static func request() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }
}

/// Microphone capture through AVAudioEngine. The sink node's real-time block only downmixes into
/// a ring buffer (D7); `drain()` resamples to 48 kHz mono on the consumer side.
public final class MicrophoneCapture: @unchecked Sendable { // start/stop/drain are called from one consumer
    public static let sampleRate = 48_000.0

    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var ring = RingBuffer(capacity: 1 << 18)
    private var resampler: Resampler?
    public private(set) var device: AudioDevice?
    /// Called on an engine thread when the device's configuration changes (unplugged, format change).
    public var onConfigurationChange: (@Sendable () -> Void)?

    public init() {}

    public var droppedSamples: Int { ring.droppedSamples }

    /// Starts on `device`, or the system default input when nil.
    /// `voiceProcessing` turns on Apple's echo cancellation and noise suppression, with other-audio
    /// ducking at its minimum; when it cannot be enabled the mic records unprocessed.
    /// shortcut: chosen without an A/B on real meetings (the fixtures are files, voice processing acts on live
    /// input only, and the Tauri app ran with RNNoise off); vendor RNNoise if it degrades the mic.
    public func start(device: AudioDevice?, voiceProcessing: Bool = true) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if voiceProcessing, (try? input.setVoiceProcessingEnabled(true)) != nil {
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        if let device, let unit = input.audioUnit {
            var id = device.id
            try HAL.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                               &id, UInt32(MemoryLayout<AudioObjectID>.size)), "set mic device")
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError.noDevice }
        let ring = RingBuffer(capacity: 1 << 18) // ~5 s at 48 kHz
        let channels = Int(format.channelCount)
        let sink = AVAudioSinkNode { _, frames, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let n = Int(frames)
            if channels == 1 {
                ring.write(first, count: n)
            } else if buffers.count == 1 {
                // Interleaved: average the channels.
                ring.write(count: n) { i in
                    var sum: Float = 0
                    for c in 0..<channels { sum += first[i * channels + c] }
                    return sum / Float(channels)
                }
            } else {
                // Deinterleaved: microphones put the voice on channel 0; average the planes.
                let planes = buffers.count
                ring.write(count: n) { i in
                    var sum: Float = 0
                    for c in 0..<planes { sum += buffers[c].mData!.assumingMemoryBound(to: Float.self)[i] }
                    return sum / Float(planes)
                }
            }
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.onConfigurationChange?()
        }
        engine.prepare()
        do {
            // A just-stopped voice-processing unit releases the device asynchronously ('!dev'); retry briefly.
            for attempt in 1...4 {
                do { try engine.start(); break } catch where attempt < 4 { Thread.sleep(forTimeInterval: 0.25) }
            }
        } catch where input.isVoiceProcessingEnabled {
            // The voice-processing unit intermittently fails to initialize (-10875); record unprocessed rather than not at all.
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            try? input.setVoiceProcessingEnabled(false)
            return try start(device: device, voiceProcessing: false)
        }
        self.ring = ring
        self.resampler = try Resampler(from: format.sampleRate, to: Self.sampleRate)
        self.engine = engine
        self.device = device ?? AudioDevices.defaultInput()
    }

    /// Everything captured since the last call, as 48 kHz mono.
    public func drain() -> [Float] {
        let raw = ring.drain()
        return resampler?.process(raw) ?? raw
    }

    public func stop() {
        guard let engine else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.stop()
        // Leaving voice processing on keeps the VPIO unit holding the device, and the next engine gets no input.
        if engine.inputNode.isVoiceProcessingEnabled { try? engine.inputNode.setVoiceProcessingEnabled(false) }
        self.engine = nil
    }

    deinit { engine?.stop() }
}
