import Accelerate

/// RMS and peak of a block, linear 0...1.
public struct AudioLevel: Sendable, Equatable {
    public var rms: Float
    public var peak: Float

    public init(rms: Float, peak: Float) { self.rms = rms; self.peak = peak }

    public init(samples: [Float]) {
        guard !samples.isEmpty else { self.init(rms: 0, peak: 0); return }
        self.init(rms: vDSP.rootMeanSquare(samples), peak: vDSP.maximumMagnitude(samples))
    }

    public static let silent = AudioLevel(rms: 0, peak: 0)
}
