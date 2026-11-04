import Foundation
import Testing
@testable import Audio

/// How long a dictation's microphone takes to deliver audio after the key goes down
/// (MEETY_REAL_DEVICES=1 swift test --filter MicStart).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MEETY_REAL_DEVICES"] == "1"))
struct MicStartTests {
    @Test func `the microphone delivers audio soon after starting`() throws {
        for _ in 0..<3 {
            let begin = ContinuousClock.now
            let mic = MicrophoneCapture()
            try mic.start(device: nil, voiceProcessing: false)
            let started = ContinuousClock.now - begin
            var first: Duration?
            while first == nil, ContinuousClock.now - begin < .seconds(2) {
                if !mic.drain().isEmpty { first = ContinuousClock.now - begin }
                Thread.sleep(forTimeInterval: 0.005)
            }
            mic.stop()
            print("start() \(started.formatted(.units(allowed: [.milliseconds]))), first audio \(first.map { $0.formatted(.units(allowed: [.milliseconds])) } ?? "never")")
            #expect(first != nil)
        }
    }
}
