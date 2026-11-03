import Core
import Foundation
import llama
import Synchronization

/// llama.cpp sampling settings per model family (port of `SamplingParams`).
public struct Sampling: Sendable, Hashable {
    public var temperature: Float
    public var topK: Int32
    public var topP: Float
    public var presencePenalty: Float
    public var frequencyPenalty: Float
    public var repeatPenalty: Float
    public var penaltyLastN: Int32
    public var stopTokens: [String]

    public static func qwen35Summary(stop: [String]) -> Sampling {
        Sampling(temperature: 0.5, topK: 20, topP: 0.8, presencePenalty: 0.3, frequencyPenalty: 0, repeatPenalty: 1.05, penaltyLastN: 256, stopTokens: stop)
    }

    public static func gemma3Instruct(stop: [String]) -> Sampling {
        Sampling(temperature: 1, topK: 64, topP: 0.95, presencePenalty: 0, frequencyPenalty: 0, repeatPenalty: 1, penaltyLastN: 0, stopTokens: stop)
    }

    /// Non-finite or out-of-range values fall back to neutral ones; a zero top-k stays (it disables top-k).
    var sanitized: Sampling {
        func finite(_ value: Float, _ fallback: Float) -> Float { value.isFinite ? value : fallback }
        return Sampling(temperature: max(0, finite(temperature, 0)), topK: max(0, topK),
                        topP: topP.isFinite && topP > 0 && topP <= 1 ? topP : 1,
                        presencePenalty: max(0, finite(presencePenalty, 0)), frequencyPenalty: max(0, finite(frequencyPenalty, 0)),
                        repeatPenalty: repeatPenalty.isFinite && repeatPenalty > 0 ? repeatPenalty : 1,
                        penaltyLastN: max(0, penaltyLastN), stopTokens: stopTokens)
    }

    var usesPenalties: Bool {
        penaltyLastN > 0 && (presencePenalty > 0 || frequencyPenalty > 0 || abs(repeatPenalty - 1) > .ulpOfOne)
    }
}

/// A GGUF model in `models/summary` (port of `summary_engine/models.rs`).
public struct BuiltInModel: Sendable, Hashable, Identifiable {
    public var name: String
    public var displayName: String
    public var file: String
    public var template: String
    public var url: URL
    public var sizeMB: Int
    public var contextSize: Int
    public var sampling: Sampling
    public var description: String

    public var id: String { name }

    public static let catalog = [
        BuiltInModel(name: "qwen3.5:2b", displayName: "Qwen 3.5 2B (Balanced)", file: "Qwen3.5-2B-Q4_K_M.gguf", template: "qwen3.5_nonthinking",
                     url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf")!,
                     sizeMB: 1221, contextSize: 32768, sampling: .qwen35Summary(stop: ["<|im_end|>"]),
                     description: "Balanced Qwen 3.5 model for built-in summaries. Higher quality with modest local requirements."),
        BuiltInModel(name: "qwen3.5:4b", displayName: "Qwen 3.5 4B (High Quality)", file: "Qwen3.5-4B-Q4_K_M.gguf", template: "qwen3.5_nonthinking",
                     url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf")!,
                     sizeMB: 2614, contextSize: 32768, sampling: .qwen35Summary(stop: ["<|im_end|>"]),
                     description: "High-quality Qwen 3.5 model for built-in summaries. Best local Qwen option in the current lineup."),
        BuiltInModel(name: "gemma3:4b", displayName: "Gemma 3 4B (Balanced)", file: "gemma-3-4b-it-Q4_K_M.gguf", template: "gemma3",
                     url: URL(string: "https://huggingface.co/bartowski/google_gemma-3-4b-it-GGUF/resolve/main/google_gemma-3-4b-it-Q4_K_M.gguf")!,
                     sizeMB: 2374, contextSize: 32768, sampling: .gemma3Instruct(stop: ["<end_of_turn>"]),
                     description: "Balanced model. Great quality/speed trade-off. Requires ~3.5GB RAM."),
        BuiltInModel(name: "gemma3:1b", displayName: "Gemma 3 1B (Fast)", file: "gemma-3-1b-it-Q8_0.gguf", template: "gemma3",
                     url: URL(string: "https://huggingface.co/bartowski/google_gemma-3-1b-it-GGUF/resolve/main/google_gemma-3-1b-it-Q8_0.gguf")!,
                     sizeMB: 1019, contextSize: 32768, sampling: .gemma3Instruct(stop: ["<end_of_turn>"]),
                     description: "Fastest model. Runs on any hardware with ~1GB RAM. Good for quick summaries."),
    ]

    public static func named(_ name: String) -> BuiltInModel? { catalog.first { $0.name == name } }

    /// The onboarding pick for this Mac (`recommend_summary_model`): Qwen 3.5 4B from 14 GB of RAM, else 2B.
    public static func recommended(ramGB: UInt64 = ProcessInfo.processInfo.physicalMemory >> 30) -> BuiltInModel {
        named(ramGB >= 14 ? "qwen3.5:4b" : "qwen3.5:2b")!
    }

    /// The best of the downloaded models (`summary_model_priority`): Qwen before Gemma, larger first.
    public static func best(of names: [String]) -> BuiltInModel? {
        let priority = ["gemma3:1b", "gemma3:4b", "qwen3.5:2b", "qwen3.5:4b"]
        return names.filter(priority.contains).max { priority.firstIndex(of: $0)! < priority.firstIndex(of: $1)! }.flatMap(named)
    }
}

public enum BuiltInError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case unknownModel(String)
    case unknownTemplate(String)
    case notDownloaded(String)
    case busy(String)
    case invalidFile(String)
    case llama(String)

    public var description: String {
        switch self {
        case .unknownModel(let name): "Unknown model: \(name)"
        case .unknownTemplate(let name): "Unknown template: \(name)"
        case .notDownloaded(let name): "Built-in model \(name) is not downloaded"
        case .busy(let name): "Built-in model \(name) is downloading"
        case .invalidFile(let message): message
        case .llama(let message): message
        }
    }

    public var errorDescription: String? { description }
}

/// Fills the model's chat template; control markers in the user text are defused so it cannot close its own turn.
func formatPrompt(template: String, system: String, user: String) throws(BuiltInError) -> String {
    let markers = ["<|im_start|>": "< |im_start| >", "<|im_end|>": "< |im_end| >", "<start_of_turn>": "< start_of_turn >",
                   "<end_of_turn>": "< end_of_turn >", "<think>": "< think >", "</think>": "< /think >"]
    let escaped = markers.reduce(user) { $0.replacing($1.key, with: $1.value) }
    switch template {
    case "gemma3":
        return "<start_of_turn>user\n\(system)<end_of_turn>\n<start_of_turn>user\n\(escaped)<end_of_turn>\n<start_of_turn>model\n"
    case "qwen3.5_nonthinking":
        // An empty think block starts the answer in direct-response mode.
        return "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(escaped)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    default:
        throw .unknownTemplate(template)
    }
}

/// One loaded GGUF model.
protocol LlamaRunner: Sendable {
    func generate(prompt: String, maxTokens: Int, sampling: Sampling) async throws -> String
}

/// The built-in model catalog, files in `models/summary`, and in-process generation (replaces `llama-helper`).
public actor BuiltInModels {
    static let maxTokens = 4096
    /// Free the model's memory after five idle minutes, like the sidecar did.
    static let idleTimeout = Duration.seconds(300)

    public let directory: URL
    public let catalog: [BuiltInModel]
    let load: @Sendable (URL, Int) throws -> any LlamaRunner
    private var downloads: [String: (task: Task<Void, any Error>, progress: Double)] = [:]
    private var current: (model: BuiltInModel, runner: any LlamaRunner)?
    private var idle: Task<Void, Never>?

    public init(directory: URL = Paths.summaryModels) {
        self.init(directory: directory, catalog: BuiltInModel.catalog, load: { try LlamaContext(model: $0, contextSize: $1) })
    }

    init(directory: URL, catalog: [BuiltInModel], load: @escaping @Sendable (URL, Int) throws -> any LlamaRunner) {
        self.directory = directory
        self.catalog = catalog
        self.load = load
    }

    private func file(_ model: BuiltInModel) -> URL { directory.appending(path: model.file) }

    /// Available when the file is within 10% of the catalog size, as the Tauri scan checked.
    public func status(_ model: BuiltInModel) -> ModelStatus {
        if let download = downloads[model.name] { return .downloading(download.progress) }
        let bytes = Double((try? file(model).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let megabytes = bytes / 1_048_576
        return megabytes >= Double(model.sizeMB) * 0.9 && megabytes <= Double(model.sizeMB) * 1.1 ? .available : .missing
    }

    public func models() -> [(model: BuiltInModel, status: ModelStatus)] { catalog.map { ($0, status($0)) } }

    public func isReady(_ name: String) -> Bool {
        catalog.first { $0.name == name }.map { status($0) == .available } ?? false
    }

    // shortcut: no resume of partial downloads (the Tauri manager resumed with Range); a failed download restarts.
    public func download(_ model: BuiltInModel, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard downloads[model.name] == nil else { throw BuiltInError.busy(model.name) }
        let (file, directory) = (file(model), directory)
        let report: @Sendable (Double) -> Void = { value in
            Task { await self.setProgress(model, value) }
            progress(value)
        }
        let task = Task {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await fetch(model.url, to: file) { report($0 * 0.99) }
            try validateGGUF(file)
        }
        downloads[model.name] = (task, 0)
        let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        downloads[model.name] = nil
        if case .failure = result { try? FileManager.default.removeItem(at: file) }
        if task.isCancelled { throw CancellationError() }
        try result.get()
        progress(1)
    }

    private func setProgress(_ model: BuiltInModel, _ value: Double) {
        downloads[model.name]?.progress = value
    }

    public func cancelDownload(_ model: BuiltInModel) async {
        guard let task = downloads[model.name]?.task else { return }
        task.cancel()
        _ = await task.result
        while downloads[model.name] != nil { await Task.yield() }
    }

    public func delete(_ model: BuiltInModel) throws {
        guard downloads[model.name] == nil else { throw BuiltInError.busy(model.name) }
        if current?.model == model { unload() }
        if FileManager.default.fileExists(atPath: file(model).path) { try FileManager.default.removeItem(at: file(model)) }
    }

    /// Runs one prompt through the model's chat template. Cancelling the task stops generation.
    public func generate(model name: String, system: String, user: String) async throws -> String {
        guard let model = catalog.first(where: { $0.name == name }) else { throw BuiltInError.unknownModel(name) }
        let prompt = try formatPrompt(template: model.template, system: system, user: user)
        let runner = try runner(for: model)
        idle?.cancel()
        defer {
            idle = Task { [weak self] in
                try? await Task.sleep(for: Self.idleTimeout)
                guard !Task.isCancelled else { return }
                await self?.unload()
            }
        }
        return try await runner.generate(prompt: prompt, maxTokens: Self.maxTokens, sampling: model.sampling.sanitized)
    }

    private func runner(for model: BuiltInModel) throws -> any LlamaRunner {
        if let current, current.model == model { return current.runner }
        guard downloads[model.name] == nil else { throw BuiltInError.busy(model.name) }
        guard status(model) == .available else { throw BuiltInError.notDownloaded(model.name) }
        current = nil
        let runner = try load(file(model), model.contextSize)
        current = (model, runner)
        return runner
    }

    public func unload() {
        idle?.cancel()
        current = nil
    }
}

func validateGGUF(_ url: URL) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let magic = String(decoding: try handle.read(upToCount: 4) ?? Data(), as: UTF8.self)
    guard ["GGUF", "ggjt", "ggla", "ggml"].contains(magic) else {
        throw BuiltInError.invalidFile("Invalid model file: \(url.lastPathComponent) is not a GGUF model")
    }
}

/// A llama.cpp model on Metal. Generation blocks for seconds to minutes, so it runs on a private queue off the
/// Swift concurrency pool, one call at a time; cancellation sets a flag checked per token and by llama.cpp's abort hook.
final class LlamaContext: LlamaRunner, @unchecked Sendable { // `model` is only used on `queue`
    private let model: OpaquePointer
    private let contextSize: Int
    private let queue = DispatchQueue(label: "meety.llama", qos: .userInitiated)

    init(model url: URL, contextSize: Int) throws {
        llama_log_set({ _, _, _ in }, nil) // llama.cpp logs every load step to stderr
        llama_backend_init()
        var params = llama_model_default_params()
        params.n_gpu_layers = -1 // Apple Silicon has unified memory: every layer on Metal
        guard let model = llama_model_load_from_file(url.path, params) else {
            throw BuiltInError.llama("llama.cpp could not load \(url.lastPathComponent)")
        }
        self.model = model
        self.contextSize = contextSize
    }

    deinit { llama_model_free(model) }

    func generate(prompt: String, maxTokens: Int, sampling: Sampling) async throws -> String {
        let cancelled = Cancelled()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    continuation.resume(with: Result { try run(prompt, maxTokens: maxTokens, sampling: sampling, cancelled: cancelled) })
                }
            }
        } onCancel: {
            cancelled.flag.store(true, ordering: .relaxed)
        }
    }

    final class Cancelled: Sendable {
        let flag = Atomic(false)
    }

    private func run(_ prompt: String, maxTokens: Int, sampling: Sampling, cancelled: Cancelled) throws -> String {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        var params = llama_context_default_params()
        params.n_ctx = UInt32(contextSize)
        params.n_batch = UInt32(contextSize)
        params.n_threads = Int32(max(1, cores / 2 + 2))
        params.n_threads_batch = params.n_threads
        params.abort_callback = { data in Unmanaged<Cancelled>.fromOpaque(data!).takeUnretainedValue().flag.load(ordering: .relaxed) }
        params.abort_callback_data = Unmanaged.passUnretained(cancelled).toOpaque()
        guard let context = llama_init_from_model(model, params) else { throw BuiltInError.llama("llama.cpp could not create a context") }
        defer { llama_free(context) }
        let vocab = llama_model_get_vocab(model)

        var tokens = tokenize(prompt, vocab)
        guard tokens.count < contextSize else {
            throw BuiltInError.llama("The prompt is \(tokens.count) tokens, more than the \(contextSize)-token context allows")
        }
        let sampler = makeSampler(sampling, vocab)
        defer { llama_sampler_free(sampler) }

        guard llama_decode(context, llama_batch_get_one(&tokens, Int32(tokens.count))) == 0 else {
            if cancelled.flag.load(ordering: .relaxed) { throw CancellationError() }
            throw BuiltInError.llama("llama_decode failed on the prompt")
        }
        var output = "", pending: [UInt8] = []
        let lookback = (sampling.stopTokens.map(\.count).max() ?? 0) + 16
        for _ in 0..<min(maxTokens, contextSize - tokens.count) {
            if cancelled.flag.load(ordering: .relaxed) { throw CancellationError() }
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            pending += piece(token, vocab)
            if let text = String(validating: pending, as: UTF8.self) { // a character can span tokens
                output += text
                pending.removeAll()
                let tail = String(output.suffix(lookback))
                if let stop = sampling.stopTokens.first(where: { tail.contains($0) }) {
                    output = String(output.replacing(stop, with: "").reversed().drop(while: \.isWhitespace).reversed())
                    break
                }
            }
            guard llama_decode(context, llama_batch_get_one(&token, 1)) == 0 else {
                if cancelled.flag.load(ordering: .relaxed) { throw CancellationError() }
                throw BuiltInError.llama("llama_decode failed while generating")
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeSampler(_ s: Sampling, _ vocab: OpaquePointer?) -> UnsafeMutablePointer<llama_sampler> {
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        if s.usesPenalties {
            llama_sampler_chain_add(chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), s.penaltyLastN, s.repeatPenalty, s.frequencyPenalty, s.presencePenalty))
        }
        if s.temperature <= 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(s.topK))
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(s.topP, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_temp(s.temperature))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32(truncatingIfNeeded: UInt64(Date().timeIntervalSince1970 * 1000))))
        }
        return chain
    }

    private func tokenize(_ text: String, _ vocab: OpaquePointer?) -> [llama_token] {
        let count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(count) + 2)
        // Special tokens parse, so the template's turn markers become control tokens.
        let n = llama_tokenize(vocab, text, count, &tokens, Int32(tokens.count), true, true)
        return Array(tokens.prefix(Int(max(0, n))))
    }

    private func piece(_ token: llama_token, _ vocab: OpaquePointer?) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        if n < 0 {
            buffer = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        }
        return buffer.prefix(Int(max(0, n))).map { UInt8(bitPattern: $0) }
    }
}
