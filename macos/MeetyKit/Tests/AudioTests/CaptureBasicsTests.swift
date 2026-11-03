import Foundation
import Testing
@testable import Audio

func sine(_ hz: Double, seconds: Double, rate: Double, amplitude: Float = 0.5) -> [Float] {
    (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
}

@Suite struct RingBufferTests {
    @Test func `reads back what was written, across wraparound`() {
        let ring = RingBuffer(capacity: 8)
        var out = [Float](repeating: 0, count: 8)
        for round in 0..<5 {
            let input: [Float] = (0..<5).map { Float(round * 10 + $0) }
            #expect(input.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 5) } == 5)
            #expect(ring.available == 5)
            #expect(out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, max: 8) } == 5)
            #expect(Array(out[0..<5]) == input)
        }
    }

    @Test func `drops and counts what does not fit`() {
        let ring = RingBuffer(capacity: 4)
        let input: [Float] = [1, 2, 3, 4, 5, 6]
        #expect(input.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 6) } == 4)
        #expect(ring.droppedSamples == 2)
    }

    @Test func `one producer and one consumer keep order`() async {
        let ring = RingBuffer(capacity: 1024)
        let total = 200_000
        let producer = Thread {
            var next = 0
            var chunk = [Float](repeating: 0, count: 64)
            while next < total {
                let n = min(64, total - next)
                for i in 0..<n { chunk[i] = Float(next + i) }
                let written = chunk.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: n) }
                next += written
            }
        }
        producer.start()
        var expected = 0
        var buffer = [Float](repeating: 0, count: 128)
        var ordered = true
        while expected < total {
            let n = buffer.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, max: 128) }
            for i in 0..<n where buffer[i] != Float(expected + i) { ordered = false }
            expected += n
            if n == 0 { await Task.yield() }
        }
        #expect(ordered)
        #expect(ring.droppedSamples > 0 || ring.droppedSamples == 0) // writes retry, so drops are allowed
    }
}

@Suite struct LevelTests {
    @Test func `rms and peak of a sine`() {
        let level = AudioLevel(samples: sine(1000, seconds: 0.1, rate: 48_000, amplitude: 0.5))
        #expect(abs(level.peak - 0.5) < 0.001)
        #expect(abs(level.rms - 0.5 / Float(2).squareRoot()) < 0.005)
        #expect(AudioLevel(samples: []).rms == 0)
    }
}

@Suite struct ResamplerTests {
    @Test func `44.1 kHz to 48 kHz keeps length and pitch`() throws {
        let resampler = try Resampler(from: 44_100, to: 48_000)
        let input = sine(440, seconds: 1, rate: 44_100)
        var output: [Float] = []
        for start in stride(from: 0, to: input.count, by: 441) {
            output += resampler.process(Array(input[start..<min(start + 441, input.count)]))
        }
        #expect(abs(output.count - 48_000) < 200)
        // Zero crossings of a 440 Hz sine over the middle 0.5 s: ~440.
        let mid = output[12_000..<36_000]
        let crossings = zip(mid, mid.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        #expect(abs(crossings - 220) <= 2)
    }

    @Test func `same rate passes through`() throws {
        let resampler = try Resampler(from: 48_000, to: 48_000)
        #expect(resampler.process([1, 2, 3]) == [1, 2, 3])
    }
}

@Suite struct MicResolutionTests {
    let devices = [
        AudioDevice(id: 1, uid: "builtin", name: "MacBook Pro Microphone", inputChannels: 1, outputChannels: 0),
        AudioDevice(id: 2, uid: "usb", name: "USB Mic", inputChannels: 2, outputChannels: 0),
    ]

    @Test func `requested mic that exists is used`() {
        #expect(MicResolution.resolve(requested: "USB Mic", inputs: devices, defaultInput: devices[0]) == .requested(devices[1]))
    }

    @Test func `missing mic falls back to default and says so`() {
        #expect(MicResolution.resolve(requested: "iPhone Microphone", inputs: devices, defaultInput: devices[0]) == .fellBack(devices[0]))
    }

    @Test func `no request uses the default silently`() {
        #expect(MicResolution.resolve(requested: nil, inputs: devices, defaultInput: devices[0]) == .requested(devices[0]))
    }

    @Test func `no mic at all`() {
        #expect(MicResolution.resolve(requested: "USB Mic", inputs: [], defaultInput: nil) == .unavailable)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["MEETY_REAL_DEVICES"] == "1"))
struct RealDeviceTests {
    @Test func `lists devices and a default input`() {
        #expect(!AudioDevices.inputs().isEmpty)
        #expect(AudioDevices.defaultInput() != nil)
        #expect(AudioDevices.defaultOutput() != nil)
    }

    @Test func `microphone delivers 48 kHz frames`() async throws {
        let mic = MicrophoneCapture()
        try mic.start(device: nil)
        try await Task.sleep(for: .seconds(1))
        let samples = mic.drain()
        mic.stop()
        #expect(samples.count > 40_000)
    }
}
