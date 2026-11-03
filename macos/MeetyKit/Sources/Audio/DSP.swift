import Accelerate
import Foundation

/// 80 Hz 2nd-order Butterworth high-pass at 48 kHz (vDSP biquad). The Rust chain used a 1st-order IIR
/// at the same cutoff; the biquad removes hum and rumble more firmly without touching speech.
public struct HighPassFilter {
    private var biquad: vDSP.Biquad<Float>

    public init(cutoff: Double = 80, sampleRate: Double = 48_000) {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * 0.5.squareRoot())
        let a0 = 1 + alpha
        let coefficients = [(1 + cos(w0)) / 2 / a0, -(1 + cos(w0)) / a0, (1 + cos(w0)) / 2 / a0, -2 * cos(w0) / a0, (1 - alpha) / a0]
        biquad = vDSP.Biquad(coefficients: coefficients, channelCount: 1, sectionCount: 1, ofType: Float.self)!
    }

    public mutating func process(_ samples: [Float]) -> [Float] { biquad.apply(input: samples) }
}

/// ITU-R BS.1770 / EBU R128 integrated loudness at 48 kHz: K-weighting, 400 ms blocks every 100 ms,
/// absolute gate at -70 LUFS, relative gate 10 LU below.
public struct LoudnessMeter {
    private var kWeighting = vDSP.Biquad(coefficients: [
        1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585,
        1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621,
    ], channelCount: 1, sectionCount: 2, ofType: Float.self)!
    private var hopEnergies: [Double] = []   // mean square of each 100 ms hop
    private var hopSum = 0.0
    private var hopCount = 0
    private var blockPowers: [Double] = []   // mean square of each 400 ms block
    private static let hop = 4_800

    public init() {}

    /// Adds samples; returns true when at least one new 400 ms block completed.
    @discardableResult
    public mutating func add(_ samples: [Float]) -> Bool {
        let weighted = kWeighting.apply(input: samples)
        var completed = false
        var index = 0
        while index < weighted.count {
            let n = min(Self.hop - hopCount, weighted.count - index)
            hopSum += Double(vDSP.sumOfSquares(weighted[index..<index + n]))
            hopCount += n
            index += n
            if hopCount == Self.hop {
                hopEnergies.append(hopSum / Double(Self.hop))
                hopSum = 0
                hopCount = 0
                if hopEnergies.count >= 4 {
                    blockPowers.append(hopEnergies.suffix(4).reduce(0, +) / 4)
                    hopEnergies.removeFirst(hopEnergies.count - 3)
                    completed = true
                }
            }
        }
        return completed
    }

    public var integratedLUFS: Double {
        let absolute = blockPowers.filter { Self.lufs($0) > -70 }
        guard !absolute.isEmpty else { return -.infinity }
        let threshold = Self.lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let relative = absolute.filter { Self.lufs($0) > threshold }
        return Self.lufs(relative.reduce(0, +) / Double(relative.count))
    }

    private static func lufs(_ meanSquare: Double) -> Double { -0.691 + 10 * log10(meanSquare) }
}

/// Port of `LoudnessNormalizer`: cumulative EBU R128 gain toward -23 LUFS, then `TruePeakLimiter`
/// (10 ms delay line, per-sample reduction to -1 dBFS).
public struct LoudnessNormalizer {
    public static let targetLUFS = -23.0
    private var meter = LoudnessMeter()
    private var gain: Float = 1
    private let peakLimit: Float = pow(10, -1 / 20)
    private var delay = [Float](repeating: 0, count: 480)
    private var reduction = [Float](repeating: 1, count: 480)
    private var position = 0

    public init() {}

    public mutating func process(_ samples: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: samples.count)
        // Update the gain every 100 ms hop, as blocks complete.
        var start = 0
        while start < samples.count {
            let end = min(start + 4_800, samples.count)
            let slice = Array(samples[start..<end])
            if meter.add(slice) {
                let loudness = meter.integratedLUFS
                if loudness.isFinite && loudness < 0 { gain = Float(pow(10, (Self.targetLUFS - loudness) / 20)) }
            }
            for i in start..<end { output[i] = limit(samples[i] * gain) }
            start = end
        }
        return output
    }

    private mutating func limit(_ sample: Float) -> Float {
        delay[position] = sample
        reduction[position] = abs(sample) > peakLimit ? peakLimit / abs(sample) : 1
        position = (position + 1) % delay.count
        return delay[position] * reduction[position]
    }
}

/// The per-microphone chain from `pipeline.rs`: high-pass, then loudness normalization.
/// Noise suppression is Apple voice processing on the capture node (see `MicrophoneCapture`).
public struct MicrophoneDSP {
    private var highPass = HighPassFilter()
    private var normalizer = LoudnessNormalizer()

    public init() {}

    public mutating func process(_ samples: [Float]) -> [Float] {
        normalizer.process(highPass.process(samples))
    }
}
