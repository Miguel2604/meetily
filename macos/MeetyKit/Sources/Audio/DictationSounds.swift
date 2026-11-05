import Foundation

/// The moments of a dictation that make a sound.
public enum DictationCue: CaseIterable, Sendable {
    case start, lock, stop, done, failed
}

/// Dictation's sounds, synthesized so they ship as code: soft mallet notes, quiet and short so the microphone, open at
/// the same time, barely hears them.
public enum DictationSounds {
    public static let sampleRate = 44_100.0

    private struct Note {
        var hertz: Double
        var at: Double
        var gain: Float = 0.2
    }

    private static func notes(_ cue: DictationCue) -> [Note] {
        switch cue {
        case .start: [Note(hertz: 587.33, at: 0), Note(hertz: 880, at: 0.05)] // D5 up to A5
        case .lock: [Note(hertz: 587.33, at: 0), Note(hertz: 880, at: 0.05), Note(hertz: 1174.66, at: 0.1)] // and D6: it stays on
        case .stop: [Note(hertz: 880, at: 0, gain: 0.16), Note(hertz: 587.33, at: 0.05, gain: 0.16)] // the way back down
        case .done: [Note(hertz: 1174.66, at: 0, gain: 0.09)]
        case .failed: [Note(hertz: 392, at: 0, gain: 0.2), Note(hertz: 311.13, at: 0.07, gain: 0.2)] // G4 to E♭4
        }
    }

    public static func samples(_ cue: DictationCue) -> [Float] {
        let notes = notes(cue)
        let decay = 0.022 // seconds per 1/e: a struck bar, not a beep
        let length = (notes.map(\.at).max() ?? 0) + 8 * decay
        var output = [Float](repeating: 0, count: Int(length * sampleRate))
        for note in notes {
            let first = Int(note.at * sampleRate)
            for index in first..<output.count {
                let t = Double(index - first) / sampleRate
                let attack = min(1, t / 0.002)
                let body = sin(2 * .pi * note.hertz * t) + 0.22 * sin(2 * .pi * 2 * note.hertz * t) * exp(-t / 0.012)
                    + 0.06 * sin(2 * .pi * 3.93 * note.hertz * t) * exp(-t / 0.004) // the mallet's tick
                output[index] += note.gain * Float(attack * exp(-t / decay) * body)
            }
        }
        // The decay ends near silence; this takes the rest away, so the end can't click.
        let fade = Int(0.01 * sampleRate)
        for offset in 0..<min(fade, output.count) { output[output.count - 1 - offset] *= Float(offset) / Float(fade) }
        return output
    }

    /// 16-bit mono PCM in a WAV container, which `NSSound` plays from memory.
    public static func wav(_ samples: [Float]) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func uint32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func uint16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        text("RIFF"); uint32(UInt32(36 + samples.count * 2)); text("WAVE")
        text("fmt "); uint32(16); uint16(1); uint16(1)
        uint32(UInt32(sampleRate)); uint32(UInt32(sampleRate) * 2); uint16(2); uint16(16)
        text("data"); uint32(UInt32(samples.count * 2))
        for sample in samples { uint16(UInt16(bitPattern: Int16(max(-1, min(1, sample)) * Float(Int16.max)))) }
        return data
    }
}
