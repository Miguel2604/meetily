import Foundation
import Testing
@testable import Audio

@Suite struct DSPTests {
    func gainDB(_ hz: Double) -> Float {
        var filter = HighPassFilter()
        let input = sine(hz, seconds: 1, rate: 48_000)
        let output = filter.process(input)
        // Skip the first 0.5 s of settling.
        return 20 * log10(AudioLevel(samples: Array(output[24_000...])).rms / AudioLevel(samples: Array(input[24_000...])).rms)
    }

    @Test func `high-pass cuts 50 Hz hum and keeps speech`() {
        #expect(gainDB(50) < -6)
        #expect(gainDB(20) < -20)
        #expect(abs(gainDB(1000)) < 0.1)
    }

    @Test func `a -20 dBFS 1 kHz sine reads -23 LUFS`() {
        var meter = LoudnessMeter()
        meter.add(sine(1000, seconds: 5, rate: 48_000, amplitude: 0.1))
        #expect(abs(meter.integratedLUFS - -23.0) < 0.5)
    }

    @Test func `silence is gated out`() {
        var meter = LoudnessMeter()
        meter.add([Float](repeating: 0, count: 48_000 * 2))
        #expect(meter.integratedLUFS == -.infinity)
        meter.add(sine(1000, seconds: 3, rate: 48_000, amplitude: 0.1))
        #expect(abs(meter.integratedLUFS - -23.0) < 0.5)
    }

    @Test func `normalizer brings a quiet voice to -23 LUFS`() {
        var normalizer = LoudnessNormalizer()
        let quiet = sine(440, seconds: 12, rate: 48_000, amplitude: 0.01) // about -43 LUFS
        var output: [Float] = []
        for start in stride(from: 0, to: quiet.count, by: 480) { output += normalizer.process(Array(quiet[start..<start + 480])) }
        #expect(output.count == quiet.count)
        var meter = LoudnessMeter()
        meter.add(Array(output[(48_000 * 6)...]))
        #expect(abs(meter.integratedLUFS - -23.0) < 0.5)
    }

    @Test func `limiter keeps peaks under -1 dBFS`() {
        var normalizer = LoudnessNormalizer()
        // Quiet passages push the gain up; a sudden loud burst must not clip.
        var input = sine(440, seconds: 6, rate: 48_000, amplitude: 0.005)
        input += sine(440, seconds: 1, rate: 48_000, amplitude: 0.9)
        let output = normalizer.process(input)
        #expect(AudioLevel(samples: output).peak <= 0.892)
    }

    @Test func `mic chain runs high-pass then normalize`() {
        var chain = MicrophoneDSP()
        let output = chain.process(sine(1000, seconds: 0.1, rate: 48_000))
        #expect(output.count == 4800)
    }
}
