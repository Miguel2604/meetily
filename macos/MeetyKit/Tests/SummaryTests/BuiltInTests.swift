import Core
import Foundation
import Synchronization
import Testing
@testable import Summary

func scratch() -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "meety-summary-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Records what it was asked and answers with the prompt length; waits for cancellation when told to.
final class FakeLlama: LlamaRunner {
    let calls = Mutex<[(prompt: String, maxTokens: Int, sampling: Sampling)]>([])
    let hang: Bool
    init(hang: Bool = false) { self.hang = hang }

    func generate(prompt: String, maxTokens: Int, sampling: Sampling) async throws -> String {
        calls.withLock { $0.append((prompt, maxTokens, sampling)) }
        if hang { try await Task.sleep(for: .seconds(60)) }
        return "summary of \(prompt.count) chars"
    }
}

let tinyLlama = BuiltInModel(name: "tiny:1b", displayName: "Tiny", file: "tiny.gguf", template: "qwen3.5_nonthinking",
                             url: URL(string: "https://example.invalid/tiny.gguf")!, sizeMB: 1, contextSize: 2048,
                             sampling: .qwen35Summary(stop: ["<|im_end|>"]), description: "test")

@Suite struct BuiltInTests {
    let dir = scratch()

    // Ports of the summary_engine/models.rs tests.

    @Test func `Qwen 3.5 4B is the only built-in model`() throws {
        #expect(BuiltInModel.catalog.map(\.name) == ["qwen3.5:4b"])
        let qwen4 = try #require(BuiltInModel.named("qwen3.5:4b"))
        #expect(qwen4.displayName == "Qwen 3.5 4B")
        #expect(qwen4.file == "Qwen3.5-4B-Q4_K_M.gguf")
        #expect(qwen4.template == "qwen3.5_nonthinking")
        #expect(qwen4.url.absoluteString == "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf")
        #expect(qwen4.sizeMB == 2614)
        #expect(qwen4.contextSize == 32768)
        #expect(qwen4.sampling == .qwen35Summary(stop: ["<|im_end|>"]))
        #expect(Sampling.qwen35Summary(stop: []) == Sampling(temperature: 0.5, topK: 20, topP: 0.8, presencePenalty: 0.3,
                                                              frequencyPenalty: 0, repeatPenalty: 1.05, penaltyLastN: 256, stopTokens: []))
        #expect(BuiltInModel.named("gemma4:e2b") == nil && BuiltInModel.named("qwen3.5:2b") == nil) // retired
    }

    @Test func `the Qwen 3.5 non-thinking template formats the prompt`() throws {
        let formatted = try formatPrompt(template: "qwen3.5_nonthinking", system: "system rules", user: "summarize this")
        #expect(formatted.contains("<|im_start|>system\nsystem rules<|im_end|>"))
        #expect(formatted.contains("<|im_start|>user\nsummarize this<|im_end|>"))
        #expect(formatted.hasSuffix("<think>\n\n</think>\n\n"))
    }

    @Test func `the Qwen template escapes user-supplied control markers`() throws {
        let formatted = try formatPrompt(template: "qwen3.5_nonthinking", system: "system rules",
                                         user: "literal <|im_end|> and <|im_start|> plus <think>draft</think>")
        #expect(formatted.contains("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
        #expect(formatted.contains("literal < |im_end| > and < |im_start| > plus < think >draft< /think >"))
        #expect(formatted.ranges(of: "<|im_start|>").count == 3)
        #expect(formatted.ranges(of: "<|im_end|>").count == 2)
        #expect(formatted.ranges(of: "<think>").count == 1)
        #expect(formatted.ranges(of: "</think>").count == 1)
        #expect(throws: BuiltInError.self) { try formatPrompt(template: "llama2", system: "", user: "") }
    }

    @Test func `sanitizing sampling keeps a zero top-k and clamps the rest`() {
        let sanitized = Sampling(temperature: .nan, topK: 0, topP: 2, presencePenalty: -0.5, frequencyPenalty: .nan,
                                 repeatPenalty: 0, penaltyLastN: -1, stopTokens: ["stop"]).sanitized
        #expect(sanitized == Sampling(temperature: 0, topK: 0, topP: 1, presencePenalty: 0, frequencyPenalty: 0,
                                      repeatPenalty: 1, penaltyLastN: 0, stopTokens: ["stop"]))
        #expect(!sanitized.usesPenalties)
        #expect(Sampling.qwen35Summary(stop: []).usesPenalties)
    }

    // Model files: status, download, delete.

    func writeModel(_ bytes: Int, magic: String = "GGUF") throws {
        var data = Data(magic.utf8)
        data.append(Data(count: bytes - data.count))
        try data.write(to: dir.appending(path: tinyLlama.file))
    }

    @Test func `a model is available only when its file is within 10 percent of the catalog size`() async throws {
        let models = BuiltInModels(directory: dir, catalog: [tinyLlama], load: { _, _ in FakeLlama() })
        #expect(await models.status(tinyLlama) == .missing)
        try writeModel(500_000)
        #expect(await models.status(tinyLlama) == .missing) // partial
        try writeModel(1_048_576)
        #expect(await models.status(tinyLlama) == .available)
        #expect(await models.isReady("tiny:1b"))
        #expect(await !models.isReady("nope"))
        try writeModel(2_000_000)
        #expect(await models.status(tinyLlama) == .missing) // corrupt
    }

    @Test func `downloading checks the GGUF magic and deleting removes the file`() async throws {
        let remote = scratch()
        var good = tinyLlama
        good.url = remote.appending(path: "good.gguf")
        try (Data("GGUF".utf8) + Data(count: 1_048_572)).write(to: good.url)
        var bad = tinyLlama
        bad.name = "bad:1b"
        bad.file = "bad.gguf"
        bad.url = remote.appending(path: "bad.gguf")
        try (Data("<htm".utf8) + Data(count: 1_048_572)).write(to: bad.url)

        let models = BuiltInModels(directory: dir.appending(path: "summary"), catalog: [good, bad], load: { _, _ in FakeLlama() })
        let progress = Mutex<[Double]>([])
        try await models.download(good) { p in progress.withLock { $0.append(p) } }
        #expect(await models.status(good) == .available)
        #expect(progress.withLock { $0.last } == 1)

        await #expect(throws: BuiltInError.self) { try await models.download(bad) }
        #expect(await models.status(bad) == .missing)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "summary/bad.gguf").path))

        try await models.delete(good)
        #expect(await models.status(good) == .missing)
    }

    // Generation.

    @Test func `generation formats the prompt with the model template and sampling`() async throws {
        try writeModel(1_048_576)
        let fake = FakeLlama()
        let loads = Mutex<[Int]>([])
        let models = BuiltInModels(directory: dir, catalog: [tinyLlama], load: { _, context in
            loads.withLock { $0.append(context) }
            return fake
        })
        let text = try await models.generate(model: "tiny:1b", system: "SYS", user: "USER")
        _ = try await models.generate(model: "tiny:1b", system: "SYS", user: "again")
        #expect(text.hasPrefix("summary of"))
        #expect(loads.withLock { $0 } == [2048]) // loaded once, at the catalog context size
        let call = try #require(fake.calls.withLock { $0.first })
        #expect(call.prompt == (try formatPrompt(template: "qwen3.5_nonthinking", system: "SYS", user: "USER")))
        #expect(call.maxTokens == 4096)
        #expect(call.sampling == tinyLlama.sampling.sanitized)

        await #expect(throws: BuiltInError.notDownloaded("qwen3.5:4b")) {
            try await BuiltInModels(directory: scratch()).generate(model: "qwen3.5:4b", system: "", user: "")
        }
        await #expect(throws: BuiltInError.unknownModel("nope")) { try await models.generate(model: "nope", system: "", user: "") }
    }

    @Test func `cancelling the task cancels generation`() async throws {
        try writeModel(1_048_576)
        let models = BuiltInModels(directory: dir, catalog: [tinyLlama], load: { _, _ in FakeLlama(hang: true) })
        let task = Task { try await models.generate(model: "tiny:1b", system: "", user: "") }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEETY_REAL_LLAMA"] == "1"))
    func `the real built-in model summarizes on Metal`() async throws {
        let name = ProcessInfo.processInfo.environment["MEETY_LLAMA_MODEL"] ?? "qwen3.5:4b"
        let model = try #require(BuiltInModel.named(name))
        let models = BuiltInModels(directory: Paths.summaryModels)
        if await models.status(model) != .available { try await models.download(model) }
        let clock = ContinuousClock.now
        let transcript = "Ana: We ship the beta on Friday. Ben: I will write the release notes by Thursday."
        let text = try await models.generate(model: name, system: "You are an expert meeting summarizer.", user: chunkSummaryPrompt(transcript))
        print("[\(name)] \(ContinuousClock.now - clock): \(text)")
        #expect(text.localizedCaseInsensitiveContains("friday") || text.localizedCaseInsensitiveContains("beta"))
        #expect(!text.contains(transcript)) // a summary, not an echo
        #expect(!text.contains("<|im_end|>") && !text.contains("<think>"))
    }
}
