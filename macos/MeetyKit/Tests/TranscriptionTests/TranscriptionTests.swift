import AVFoundation
import Core
import Foundation
import Testing
@testable import Transcription

/// Stand-in for FluidAudio, same contract as the Rust tests' fake helper. A model counts as downloaded
/// once `<dir>/ready` exists. A `<dir>.slow` marker makes download hang until cancelled; a `<dir>.fail`
/// marker makes load fail.
struct FakeChunks: ChunkTranscriber {
    let model: ParakeetModel
    func transcribe(_ samples: [Float]) async throws -> String { "\(model.rawValue):\(samples.count)" }
}

extension ParakeetBackend {
    static let fake = ParakeetBackend(
        isDownloaded: { dir, _ in FileManager.default.fileExists(atPath: dir.appending(path: "ready").path) },
        download: { dir, _, progress in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            progress(0.5)
            if FileManager.default.fileExists(atPath: dir.path + ".slow") { try await Task.sleep(for: .seconds(30)) }
            FileManager.default.createFile(atPath: dir.appending(path: "ready").path, contents: nil)
        },
        load: { dir, model in
            if FileManager.default.fileExists(atPath: dir.path + ".fail") { throw ParakeetError.engine("no Neural Engine plan") }
            return FakeChunks(model: model)
        })
}

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "meety-\(UUID().uuidString)", directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Double] = []
    var values: [Double] { lock.withLock { _values } }
    func add(_ value: Double) { lock.withLock { _values.append(value) } }
}

@Suite struct ParakeetTests {
    let dir = tempDir()
    var models: ParakeetModels { ParakeetModels(directory: dir, backend: .fake) }

    @Test func `catalog lists both models with Ultra as the default`() async {
        let list = await models.models()
        #expect(list.map(\.model) == [.ultra, .phonon2])
        #expect(list.map(\.model.rawValue) == ["parakeet-ultra", "phonon-2"])
        #expect(list.allSatisfy { $0.status == .missing })
        #expect(ParakeetModel.default == .ultra)
    }

    @Test func `download reports progress, then prepares and transcribes`() async throws {
        let models = self.models
        let seen = Progress()
        try await models.download(.phonon2) { seen.add($0) }
        #expect(seen.values == [0.5, 0.99, 1.0])
        #expect(await models.status(.phonon2) == .available)

        let engine = try await models.engine(.phonon2)
        #expect(try await engine.transcribe(samples: [Float](repeating: 0, count: 16_000)).map(\.text) == ["phonon-2:16000"])
        #expect(await models.loaded == .phonon2)
        await models.unload()
        #expect(await models.loaded == nil)
    }

    @Test func `short chunks are padded to 0.3 s and empty ones skip the model`() async throws {
        let models = self.models
        try await models.download(.ultra)
        let engine = try await models.engine(.ultra)
        let segments = try await engine.transcribe(samples: [Float](repeating: 0.1, count: 1_600))
        #expect(segments == [Segment(text: "parakeet-ultra:4800", start: 0, end: 0.1)])
        #expect(try await engine.transcribe(samples: []).isEmpty)
    }

    @Test func `cancelling a download stops it and cleans up`() async throws {
        let models = self.models
        let modelDir = dir.appending(path: "parakeet-ultra")
        FileManager.default.createFile(atPath: modelDir.path + ".slow", contents: nil)
        let download = Task { try await models.download(.ultra) }
        while !FileManager.default.fileExists(atPath: modelDir.path) { try await Task.sleep(for: .milliseconds(20)) }
        if case .downloading = await models.status(.ultra) {} else { Issue.record("not downloading") }
        await models.cancelDownload(.ultra)
        await #expect(throws: CancellationError.self) { try await download.value }
        #expect(!FileManager.default.fileExists(atPath: modelDir.path))
        #expect(await models.status(.ultra) == .missing)
    }

    @Test func `a second download of the same model is refused`() async throws {
        let models = self.models
        FileManager.default.createFile(atPath: dir.appending(path: "phonon-2").path + ".slow", contents: nil)
        let first = Task { try await models.download(.phonon2) }
        while await models.status(.phonon2) == .missing { try await Task.sleep(for: .milliseconds(10)) }
        await #expect(throws: ParakeetError.self) { try await models.download(.phonon2) }
        await models.cancelDownload(.phonon2)
        _ = await first.result
    }

    @Test func `load errors reach the caller`() async throws {
        let models = self.models
        try await models.download(.ultra)
        FileManager.default.createFile(atPath: dir.appending(path: "parakeet-ultra").path + ".fail", contents: nil)
        await #expect { try await models.engine(.ultra) } throws: { "\($0)".contains("no Neural Engine plan") }
        #expect(await models.loaded == nil)
        await #expect(throws: ParakeetError.self) { try await models.engine(.phonon2) } // not downloaded
    }

    @Test func `delete unloads and removes the model`() async throws {
        let models = self.models
        try await models.download(.ultra)
        _ = try await models.engine(.ultra)
        try await models.delete(.ultra)
        #expect(await models.loaded == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "parakeet-ultra").path))
        #expect(await models.status(.ultra) == .missing)
    }

    @Test func `only one model stays loaded`() async throws {
        let models = self.models
        try await models.download(.ultra)
        try await models.download(.phonon2)
        let first = try await models.engine(.ultra)
        #expect(try await models.engine(.ultra) === first)
        _ = try await models.engine(.phonon2)
        #expect(await models.loaded == .phonon2)
    }
}

/// Synthesized English speech, so real-model tests can check words without shipping recordings.
func spokenSamples(_ text: String, rate: Double = 16_000) throws -> [Float] {
    let url = tempDir().appending(path: "say.wav")
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-o", url.path, "--data-format=LEF32@\(Int(rate))", text]
    try say.run()
    say.waitUntilExit()
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

/// Real models from the live models dir, read-only use (needs the models already on disk).
/// MEETY_REAL_MODELS=1 swift test --filter RealParakeet
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MEETY_REAL_MODELS"] == "1"))
struct RealParakeetTests {
    @Test(arguments: [ParakeetModel.ultra, .phonon2])
    func `transcribes synthesized speech`(model: ParakeetModel) async throws {
        let models = ParakeetModels(directory: Paths.parakeetModels)
        try #require(await models.status(model) == .available)
        let engine = try await models.engine(model)
        let text = try await engine.transcribe(samples: spokenSamples("Hello world, this is a meeting about the budget.")).map(\.text).joined()
        print("\(model.rawValue): \(text)")
        #expect(text.lowercased().contains("budget"))
    }
}
