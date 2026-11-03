import FluidAudio
import Foundation

/// Speech probability per fixed-size frame of 16 kHz audio. Stateful (one per stream).
public protocol VoiceDetector: Sendable {
    var frameSize: Int { get }
    func speechProbability(_ frame: [Float]) async throws -> Float
}

/// A speech burst cut from a 16 kHz stream, times in seconds from the stream's start.
public struct SpeechChunk: Sendable, Equatable {
    public var samples: [Float]
    public var start: Double
    public var end: Double
}

/// Streaming VAD segmenter, the `ContinuousVadProcessor` policy: Silero hysteresis (0.50 / 0.35),
/// a speech burst closes after `redemption` of silence, 300 ms pre-pad, 400 ms post-pad,
/// bursts under 250 ms dropped. Bursts are also cut at `maxSpeech` so continuous audio still
/// reaches the transcript (the Rust live path could hold one segment open indefinitely, #756).
public struct SpeechSegmenter {
    public struct Config: Sendable {
        public var threshold: Float = 0.5
        public var negativeThreshold: Float = 0.35
        public var redemption: Double
        public var prePad = 0.3
        public var postPad = 0.4
        public var minSpeech = 0.25
        public var maxSpeech = 30.0

        /// Live recording: short redemption keeps transcript latency low.
        public static let live = Config(redemption: 0.5)
        /// Import and retranscription: longer clips bridge natural pauses (better ASR context).
        public static let batch = Config(redemption: 2)
    }

    let detector: any VoiceDetector
    let config: Config
    private let rate = transcriptionSampleRate
    private var audio: [Float] = []   // kept from `audioStart` on: the pre-pad window or the open burst
    private var audioStart = 0        // absolute sample index of audio[0]
    private var evaluated = 0         // absolute index of the first sample not yet classified
    private var speechStart: Int?
    private var silenceStart: Int?

    public init(detector: any VoiceDetector, config: Config) {
        self.detector = detector
        self.config = config
    }

    private func samples(_ seconds: Double) -> Int { Int(seconds * rate) }
    private var end: Int { audioStart + audio.count }

    public mutating func process(_ input: [Float]) async throws -> [SpeechChunk] {
        audio += input
        var chunks: [SpeechChunk] = []
        let n = detector.frameSize
        while end - evaluated >= n {
            let from = evaluated - audioStart
            let p = try await detector.speechProbability(Array(audio[from..<from + n]))
            evaluated += n
            if let chunk = step(p, frameStart: evaluated - n, frameEnd: evaluated) { chunks.append(chunk) }
        }
        return chunks
    }

    /// Classifies the trailing partial frame and closes any open burst at the end of the audio.
    public mutating func flush() async throws -> [SpeechChunk] {
        var chunks: [SpeechChunk] = []
        let remainder = end - evaluated
        if remainder > 0 {
            let frame = Array(audio[(evaluated - audioStart)...]) + [Float](repeating: 0, count: detector.frameSize - remainder)
            let p = try await detector.speechProbability(frame)
            evaluated += remainder
            if let chunk = step(p, frameStart: evaluated - remainder, frameEnd: evaluated) { chunks.append(chunk) }
        }
        if let start = speechStart, end - start >= samples(config.minSpeech) { chunks.append(cut(start, end)) }
        speechStart = nil
        silenceStart = nil
        trim(to: end)
        return chunks
    }

    private mutating func step(_ p: Float, frameStart: Int, frameEnd: Int) -> SpeechChunk? {
        guard let start = speechStart else {
            if p >= config.threshold {
                speechStart = max(audioStart, frameStart - samples(config.prePad))
            } else {
                trim(to: frameEnd - samples(config.prePad))
            }
            return nil
        }
        if p >= config.threshold {
            silenceStart = nil
        } else if p < config.negativeThreshold, silenceStart == nil {
            silenceStart = frameStart
        }
        if let silence = silenceStart, frameEnd - silence >= samples(config.redemption) {
            let stop = min(silence + samples(config.postPad), frameEnd)
            speechStart = nil
            silenceStart = nil
            let chunk = silence - start >= samples(config.minSpeech + config.prePad) ? cut(start, stop) : nil
            trim(to: stop)
            return chunk
        }
        if frameEnd - start >= samples(config.maxSpeech) {
            speechStart = frameEnd
            let chunk = cut(start, frameEnd)
            trim(to: frameEnd)
            return chunk
        }
        return nil
    }

    private func cut(_ from: Int, _ to: Int) -> SpeechChunk {
        SpeechChunk(samples: Array(audio[(from - audioStart)..<(to - audioStart)]), start: Double(from) / rate, end: Double(to) / rate)
    }

    private mutating func trim(to index: Int) {
        let count = index - audioStart
        guard count > 0 else { return }
        audio.removeFirst(count)
        audioStart = index
    }
}

/// FluidAudio's Silero VAD (Core ML), loaded once; hand each stream its own `detector()`.
public final class VoiceModel: Sendable {
    let vad: VadManager

    init(vad: VadManager) { self.vad = vad }

    /// Downloads the model into `directory` the first time (~2 MB).
    public static func load(directory: URL) async throws -> VoiceModel {
        VoiceModel(vad: try await VadManager(modelDirectory: directory))
    }

    public func detector() -> any VoiceDetector { SileroDetector(vad: vad) }
}

actor SileroDetector: VoiceDetector {
    let vad: VadManager
    private var state = VadStreamState.initial()

    init(vad: VadManager) { self.vad = vad }

    nonisolated var frameSize: Int { VadManager.chunkSize } // 256 ms

    func speechProbability(_ frame: [Float]) async throws -> Float {
        let result = try await vad.processStreamingChunk(frame, state: state)
        state = result.state
        return result.probability
    }
}
