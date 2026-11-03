import Audio
import Core
import Foundation
import Testing
@testable import Transcription

@MainActor @Suite struct RecorderTests {
    let store: Store
    let mic = SampleSource(samples: silence(1, rate: 48_000) + tone(2, rate: 48_000) + silence(2, rate: 48_000), chunk: 24_000)
    init() throws { store = try tempStore() }

    func inputs(_ title: String) -> Recorder.Inputs {
        Recorder.Inputs(title: title, folder: tempDir().appending(path: title), engine: FakeEngine(), detector: EnergyDetector(),
                        microphone: mic, system: nil)
    }

    @Test func `starts through progress, collects live segments, and saves under the edited title`() async throws {
        let recorder = Recorder(store: store)
        var progress: [Recorder.Phase] = []
        await recorder.start { report in
            report("Loading transcription model…")
            progress.append(recorder.phase)
            return inputs("Meeting 04_11_26_09_00_00")
        }
        #expect(progress == [.starting("Loading transcription model…")])
        #expect(recorder.phase == .recording)
        while !mic.isFinished { try await Task.sleep(for: .milliseconds(10)) }
        recorder.title = "Design review"
        let id = try #require(await recorder.stop())
        #expect(recorder.phase == .idle)
        #expect(recorder.segments.map(\.text) == ["words 2.7"])
        #expect(try await store.meeting(id: id)?.title == "Design review")
        #expect(try await store.transcripts(meetingID: id).count == 1)
    }

    @Test func `a failed start reports the error and can be retried`() async throws {
        let recorder = Recorder(store: store)
        struct NotReady: Error, CustomStringConvertible { var description: String { "Transcription model not ready" } }
        await recorder.start { _ in throw NotReady() }
        #expect(recorder.phase == .failed("Transcription model not ready"))
        await recorder.start { _ in inputs("Retry") }
        #expect(recorder.phase == .recording)
        _ = await recorder.stop()
    }

    @Test func `pause and resume, and elapsed time leaves the pause out`() async throws {
        let recorder = Recorder(store: store)
        await recorder.start { _ in inputs("Paused") }
        let started = try #require(recorder.startedAt)
        await recorder.pause()
        #expect(recorder.phase == .paused)
        #expect(recorder.elapsed(at: started.addingTimeInterval(70)) < 1) // paused right away
        await recorder.resume()
        #expect(recorder.elapsed(at: Date().addingTimeInterval(5)) > 4.9)
        #expect(recorder.phase == .recording)
        _ = await recorder.stop()
    }

    @Test func `capture notices surface as warnings`() async throws {
        let recorder = Recorder(store: store)
        let (notices, sink) = AsyncStream.makeStream(of: String.self)
        await recorder.start { _ in
            var i = inputs("Notices")
            i.notices = notices
            return i
        }
        sink.yield("Microphone disconnected. Recording with “MacBook Pro Microphone”.")
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.notice == "Microphone disconnected. Recording with “MacBook Pro Microphone”.")
        _ = await recorder.stop()
    }
}

@Suite struct MicrophoneNoticeTests {
    let builtIn = AudioDevice(id: 1, uid: "BuiltIn", name: "MacBook Pro Microphone", inputChannels: 1, outputChannels: 0)
    let usb = AudioDevice(id: 2, uid: "USB", name: "USB Mic", inputChannels: 1, outputChannels: 0)

    @Test func `describes what changed, and nothing when it didn't`() {
        #expect(LiveMicrophone.notice(from: usb, to: .requested(usb)) == nil)
        #expect(LiveMicrophone.notice(from: usb, to: .fellBack(builtIn)) == "Microphone disconnected. Recording with “MacBook Pro Microphone”.")
        #expect(LiveMicrophone.notice(from: builtIn, to: .requested(usb)) == "Recording with “USB Mic”.")
        #expect(LiveMicrophone.notice(from: usb, to: .unavailable) == "No microphone available. Recording system audio only.")
        #expect(LiveMicrophone.notice(from: nil, to: .requested(usb)) == "Microphone reconnected: “USB Mic”.")
    }
}
