import Foundation
import Testing
@testable import Audio

@Suite struct DictationSoundTests {
    func peak(_ samples: [Float]) -> Float { samples.map(abs).max() ?? 0 }

    @Test(arguments: DictationCue.allCases)
    func `every cue is short, quiet, and starts and ends without a click`(cue: DictationCue) {
        let samples = DictationSounds.samples(cue)
        #expect(!samples.isEmpty)
        #expect(Double(samples.count) / DictationSounds.sampleRate <= 0.3)
        #expect(peak(samples) <= 0.3)
        #expect(peak(samples) > 0.02)
        #expect(abs(samples.first ?? 1) < 0.01)
        #expect(peak(Array(samples.suffix(16))) < 0.01)
    }

    @Test func `the cues differ, and start and stop move in opposite directions`() {
        let all = DictationCue.allCases.map(DictationSounds.samples)
        #expect(Set(all).count == DictationCue.allCases.count)
        func zeroCrossings(_ samples: ArraySlice<Float>) -> Int { zip(samples, samples.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count }
        func pitchRises(_ samples: [Float]) -> Bool {
            let half = samples.count / 2
            return zeroCrossings(samples[half...]) > zeroCrossings(samples[..<half])
        }
        #expect(DictationSounds.samples(.start).count < DictationSounds.samples(.lock).count)
        #expect(DictationSounds.samples(.done).count < DictationSounds.samples(.start).count)
        #expect(pitchRises(DictationSounds.samples(.start)))
        #expect(!pitchRises(DictationSounds.samples(.stop)))
    }

    @Test func `the WAV header describes the samples`() throws {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1, 2]
        let wav = DictationSounds.wav(samples)
        #expect(wav.count == 44 + samples.count * 2)
        func text(_ range: Range<Int>) -> String { String(decoding: wav[range], as: UTF8.self) }
        func uint32(_ at: Int) -> UInt32 { wav[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
        #expect(text(0..<4) == "RIFF")
        #expect(text(8..<12) == "WAVE")
        #expect(text(36..<40) == "data")
        #expect(uint32(4) == UInt32(wav.count - 8))
        #expect(uint32(24) == UInt32(DictationSounds.sampleRate))
        #expect(uint32(40) == UInt32(samples.count * 2))
        let last = wav[(wav.count - 2)...].enumerated().reduce(UInt16(0)) { $0 | UInt16($1.element) << (8 * $1.offset) }
        #expect(Int16(bitPattern: last) == Int16.max) // 2 clamps instead of wrapping
    }
}
