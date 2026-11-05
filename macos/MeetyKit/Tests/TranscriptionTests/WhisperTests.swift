import Audio
import Core
import Foundation
import Testing
@testable import Transcription

final class FakeRunner: WhisperRunner {
    func run(_ samples: [Float], language: String?) async throws -> String { "\(language ?? "auto"):\(samples.count)" }
}

let tinyModel = WhisperModel(name: "tiny-q5_1", file: "ggml-tiny-q5_1.bin", sizeMB: 1, description: "test")

/// A stand-in "Hugging Face": a 1 MB model file and a zipped encoder folder, served from file://.
func fakeRemote() throws -> URL {
    let remote = tempDir()
    FileManager.default.createFile(atPath: remote.appending(path: tinyModel.file).path, contents: Data(count: 1_100_000))
    let staging = tempDir()
    let encoder = staging.appending(path: tinyModel.encoderFolder)
    try FileManager.default.createDirectory(at: encoder, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: encoder.appending(path: "model.mil").path, contents: Data("x".utf8))
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-c", "-k", "--keepParent", encoder.path, remote.appending(path: tinyModel.encoderFolder + ".zip").path]
    try ditto.run()
    ditto.waitUntilExit()
    return remote
}

@Suite struct WhisperTests {
    let dir = tempDir()

    @Test func `the catalog is large-v3-turbo with its Core ML encoder name`() {
        #expect(WhisperModel.catalog.map(\.name) == ["large-v3-turbo-q8_0"])
        #expect(WhisperModel.turbo.file == "ggml-large-v3-turbo-q8_0.bin")
        #expect(WhisperModel.turbo.encoderFolder == "ggml-large-v3-turbo-encoder.mlmodelc")
        #expect(tinyModel.encoderFolder == "ggml-tiny-encoder.mlmodelc")
        #expect(WhisperModel(name: "base", file: "ggml-base.bin", sizeMB: 1, description: "").encoderFolder == "ggml-base-encoder.mlmodelc")
    }

    @Test func `a model is available only with a full-size file and its encoder`() async throws {
        let models = WhisperModels(directory: dir, catalog: [tinyModel], load: { _ in FakeRunner() })
        #expect(await models.status(tinyModel) == .missing)
        FileManager.default.createFile(atPath: dir.appending(path: tinyModel.file).path, contents: Data(count: 500_000))
        try FileManager.default.createDirectory(at: dir.appending(path: tinyModel.encoderFolder), withIntermediateDirectories: true)
        #expect(await models.status(tinyModel) == .missing) // truncated download
        FileManager.default.createFile(atPath: dir.appending(path: tinyModel.file).path, contents: Data(count: 1_000_000))
        #expect(await models.status(tinyModel) == .available)
    }

    @Test func `download fetches the model and encoder, then prepares it`() async throws {
        let models = WhisperModels(directory: dir, catalog: [tinyModel], baseURL: try fakeRemote(), load: { _ in FakeRunner() })
        let seen = Progress()
        try await models.download(tinyModel) { seen.add($0) }
        #expect(seen.values.last == 1)
        #expect(seen.values.dropLast().allSatisfy { $0 < 1 })
        #expect(zip(seen.values, seen.values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(await models.status(tinyModel) == .available)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: tinyModel.encoderFolder).appending(path: "model.mil").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: tinyModel.encoderFolder + ".zip").path))

        try await models.delete(tinyModel)
        #expect(await models.status(tinyModel) == .missing)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: tinyModel.encoderFolder).path))
    }

    @Test func `a failed download leaves nothing behind`() async throws {
        let models = WhisperModels(directory: dir, catalog: [tinyModel], baseURL: tempDir(), load: { _ in FakeRunner() })
        await #expect(throws: (any Error).self) { try await models.download(tinyModel) }
        #expect(await models.status(tinyModel) == .missing)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func `engines pad short chunks to a second and pass the language`() async throws {
        let models = WhisperModels(directory: dir, catalog: [tinyModel], baseURL: try fakeRemote(), load: { _ in FakeRunner() })
        try await models.download(tinyModel)
        let tagalog = try await models.engine(tinyModel, language: "tl")
        #expect(try await tagalog.transcribe(samples: [Float](repeating: 0.1, count: 8_000)) == [Segment(text: "tl:16160", start: 0, end: 0.5)])
        #expect(try await tagalog.transcribe(samples: []).isEmpty)
        let auto = try await models.engine(tinyModel, language: nil)
        #expect(try await auto.transcribe(samples: [Float](repeating: 0.1, count: 32_000)).map(\.text) == ["auto:32000"])
    }

    @Test func `the model stays loaded between uses, then unloads once idle`() async throws {
        let loads = Progress()
        let models = WhisperModels(directory: dir, catalog: [tinyModel], baseURL: try fakeRemote(), idleTimeout: .milliseconds(100),
                                   load: { _ in loads.add(1); return FakeRunner() })
        try await models.download(tinyModel)
        weak var first = try await models.engine(tinyModel, language: nil).runner as? FakeRunner
        _ = try await models.engine(tinyModel, language: nil)
        #expect(loads.values.count == 2) // the download's warm-up, then one load for both engines
        #expect(first != nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(first == nil)
        _ = try await models.engine(tinyModel, language: nil)
        #expect(loads.values.count == 3)
    }

    @Test func `an engine in use past the idle timeout is shared, not loaded twice`() async throws {
        let loads = Progress()
        let models = WhisperModels(directory: dir, catalog: [tinyModel], baseURL: try fakeRemote(), idleTimeout: .milliseconds(50),
                                   load: { _ in loads.add(1); return FakeRunner() })
        try await models.download(tinyModel)
        let recording = try await models.engine(tinyModel, language: "tl")
        try await Task.sleep(for: .milliseconds(200))
        let dictation = try await models.engine(tinyModel, language: nil)
        #expect(dictation.runner === recording.runner)
        #expect(loads.values.count == 2)
    }

    @Test func `loading a missing model fails`() async {
        let models = WhisperModels(directory: dir, catalog: [tinyModel], load: { _ in FakeRunner() })
        await #expect(throws: WhisperError.self) { try await models.engine(tinyModel, language: nil) }
    }
}

@Suite struct LanguageRoutingTests {
    let parakeet = TranscriptConfig(id: "1", provider: "parakeet", model: "phonon-2")
    let whisper = TranscriptConfig(id: "1", provider: "localWhisper", model: "large-v3-turbo-q8_0")

    @Test func `English goes to Parakeet, keeping the chosen Parakeet model`() {
        #expect(EngineChoice.route(language: "en", config: parakeet) == .parakeet(.phonon2))
        #expect(EngineChoice.route(language: "en", config: whisper) == .parakeet(.ultra))
        #expect(EngineChoice.route(language: "en", config: nil) == .parakeet(.ultra))
    }

    @Test func `Tagalog and other codes go to Whisper in that language`() {
        #expect(EngineChoice.route(language: "tl", config: parakeet) == .whisper(.turbo, language: "tl"))
        #expect(EngineChoice.route(language: "es", config: nil) == .whisper(.turbo, language: "es"))
    }

    @Test func `auto follows the configured provider`() {
        #expect(EngineChoice.route(language: "auto", config: parakeet) == .parakeet(.phonon2))
        #expect(EngineChoice.route(language: "auto", config: whisper) == .whisper(.turbo, language: nil))
        #expect(EngineChoice.route(language: "auto", config: nil) == .parakeet(.ultra))
        #expect(EngineChoice.route(language: "auto", config: TranscriptConfig(id: "1", provider: "parakeet", model: "gone")) == .parakeet(.ultra))
    }
}

/// Real large-v3-turbo + Core ML encoder (MEETY_REAL_WHISPER=1; downloads ~2 GB into the live models dir
/// the first time, then compiles the encoder for the Neural Engine).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MEETY_REAL_WHISPER"] == "1"))
struct RealWhisperTests {
    @Test func `transcribes synthesized speech`() async throws {
        let models = WhisperModels(directory: Paths.whisperModels)
        if await models.status(.turbo) != .available { try await models.download(.turbo) { print(String(format: "whisper %.0f%%", $0 * 100)) } }
        let engine = try await models.engine(.turbo, language: "en")
        let text = try await engine.transcribe(samples: spokenSamples("The quarterly budget review is on Friday.")).map(\.text).joined()
        print("whisper: \(text)")
        #expect(text.lowercased().contains("budget"))
    }

    @Test func `the dictation sounds leave the transcript alone`() async throws {
        let models = WhisperModels(directory: Paths.whisperModels)
        try #require(await models.status(.turbo) == .available)
        let engine = try await models.engine(.turbo, language: "en")
        func cue(_ cue: DictationCue) throws -> [Float] {
            try Resampler(from: DictationSounds.sampleRate, to: transcriptionSampleRate).process(DictationSounds.samples(cue))
        }
        func words(_ text: String) -> [String] { text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
        let clean = silence(0.3) + (try spokenSamples("The quarterly budget review is on Friday.")) + silence(0.2)
        var heard = clean
        for (index, sample) in try cue(.start).enumerated() { heard[index] += sample }
        let stopAt = clean.count - Int(0.2 * transcriptionSampleRate)
        for (index, sample) in try cue(.stop).enumerated() where stopAt + index < heard.count { heard[stopAt + index] += sample }
        let plain = try await engine.transcribe(samples: clean).map(\.text).joined(separator: " ")
        let mixed = try await engine.transcribe(samples: heard).map(\.text).joined(separator: " ")
        print("whisper without sounds: \(plain)\nwhisper with sounds:    \(mixed)")
        #expect(words(plain) == words(mixed))
    }
}
