import Accelerate

/// Port of `AudioMixerRingBuffer` + `ProfessionalAudioMixer`: accumulate 48 kHz mic and system
/// samples, emit fixed windows once either stream has a full one (the other is zero-padded), and mix by
/// summing. The Rust "soft scaling" divides an over-range sample by its own magnitude, which is a clip
/// to ±1, so that is what this does. No ducking, matching what the Rust mixer actually ran.
public struct AudioMixer {
    public static let windowSamples = 28_800          // 600 ms at 48 kHz, the Rust window
    public static let maxBufferSamples = windowSamples * 8

    private var mic: [Float] = []
    private var system: [Float] = []
    public private(set) var droppedMic = 0
    public private(set) var droppedSystem = 0

    public init() {}

    public var bufferedMic: Int { mic.count }
    public var bufferedSystem: Int { system.count }

    public mutating func add(mic samples: [Float]) { Self.append(samples, to: &mic, dropped: &droppedMic) }
    public mutating func add(system samples: [Float]) { Self.append(samples, to: &system, dropped: &droppedSystem) }

    private static func append(_ samples: [Float], to buffer: inout [Float], dropped: inout Int) {
        buffer += samples
        let overflow = buffer.count - maxBufferSamples
        if overflow > 0 {
            buffer.removeFirst(overflow)
            dropped += overflow
        }
    }

    /// The next mixed window, or nil until a stream has a full window.
    public mutating func nextWindow() -> [Float]? {
        guard mic.count >= Self.windowSamples || system.count >= Self.windowSamples else { return nil }
        return mix(Self.take(&mic, Self.windowSamples), Self.take(&system, Self.windowSamples))
    }

    /// Whatever is left, mixed (used on stop).
    public mutating func flush() -> [Float] {
        let n = max(mic.count, system.count)
        guard n > 0 else { return [] }
        return mix(Self.take(&mic, n), Self.take(&system, n))
    }

    private static func take(_ buffer: inout [Float], _ n: Int) -> [Float] {
        let count = min(n, buffer.count)
        var window = Array(buffer[..<count])
        buffer.removeFirst(count)
        if count < n { window += [Float](repeating: 0, count: n - count) }
        return window
    }

    private func mix(_ a: [Float], _ b: [Float]) -> [Float] {
        vDSP.clip(vDSP.add(a, b), to: -1...1)
    }
}
