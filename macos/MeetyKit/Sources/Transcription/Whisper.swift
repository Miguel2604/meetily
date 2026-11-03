import Core
import Foundation
import Synchronization
import whisper

/// A whisper.cpp ggml model plus its Core ML encoder, both in `models/` as the Tauri app keeps them.
public struct WhisperModel: Sendable, Hashable {
    public let name: String
    public let file: String
    public let sizeMB: Int
    public let description: String

    public static let turbo = WhisperModel(
        name: "large-v3-turbo-q8_0", file: "ggml-large-v3-turbo-q8_0.bin", sizeMB: 834,
        description: "Best for Tagalog and Taglish. Near full-precision large-v3-turbo, encoder on the Neural Engine")
    public static let catalog = [turbo]

    /// whisper.cpp looks for `<model without .bin and quantization>-encoder.mlmodelc` next to the model.
    public var encoderFolder: String {
        var stem = file.hasSuffix(".bin") ? String(file.dropLast(4)) : file
        if let dash = stem.lastIndex(of: "-"), stem[stem.index(after: dash)...].wholeMatch(of: /q\d_\d/) != nil {
            stem = String(stem[..<dash])
        }
        return stem + "-encoder.mlmodelc"
    }
}

public enum WhisperError: Error, Equatable, CustomStringConvertible {
    case notDownloaded(String)
    case busy(String)
    case load(String)
    case transcribe(String)

    public var description: String {
        switch self {
        case .notDownloaded(let name): "Whisper model \(name) is not downloaded"
        case .busy(let name): "Whisper model \(name) is downloading"
        case .load(let path): "whisper.cpp could not load \(path)"
        case .transcribe(let message): message
        }
    }
}

/// One loaded whisper.cpp model; runs are serialized.
protocol WhisperRunner: Sendable {
    func run(_ samples: [Float], language: String?) async throws -> String
}

/// whisper.cpp blocks for seconds per call and its context is single-threaded, so calls run one at a
/// time on a private queue, off the Swift concurrency pool.
final class WhisperContext: WhisperRunner, @unchecked Sendable { // `context` is only touched on `queue`
    private let context: OpaquePointer
    private let queue = DispatchQueue(label: "meety.whisper", qos: .userInitiated)

    init(model: URL) throws {
        whisper_log_set({ _, _, _ in }, nil) // whisper.cpp and ggml log every load step to stderr
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let context = whisper_init_from_file_with_params(model.path, params) else { throw WhisperError.load(model.path) }
        self.context = context
    }

    deinit { whisper_free(context) }

    func run(_ samples: [Float], language: String?) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [context] in
                // The `transcribe_audio` parameters from the Tauri engine.
                var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
                params.beam_search.beam_size = 5
                params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
                params.translate = false
                params.no_timestamps = true // timestamp heuristics drop whole valid chunks
                params.print_special = false
                params.print_progress = false
                params.print_realtime = false
                params.print_timestamps = false
                params.suppress_blank = true
                params.suppress_nst = true
                params.temperature = 0.3
                params.max_initial_ts = 1
                params.entropy_thold = 2.4
                params.logprob_thold = -1
                params.no_speech_thold = 0.55
                params.single_segment = false
                let status = (language ?? "auto").withCString { code in
                    params.language = code
                    return samples.withUnsafeBufferPointer { whisper_full(context, params, $0.baseAddress, Int32($0.count)) }
                }
                guard status == 0 else {
                    continuation.resume(throwing: WhisperError.transcribe("whisper_full failed (\(status))"))
                    return
                }
                let text = (0..<whisper_full_n_segments(context)).map { String(cString: whisper_full_get_segment_text(context, $0)) }.joined()
                continuation.resume(returning: text)
            }
        }
    }
}

public final class WhisperEngine: TranscriptionEngine {
    public let model: WhisperModel
    /// Whisper language code; nil detects it per chunk.
    public let language: String?
    let runner: any WhisperRunner

    init(model: WhisperModel, language: String?, runner: any WhisperRunner) {
        self.model = model
        self.language = language
        self.runner = runner
    }

    public func transcribe(samples: [Float]) async throws -> [Segment] {
        guard !samples.isEmpty else { return [] }
        // whisper.cpp returns nothing for input under one second; pad with silence instead.
        let minimum = Int(transcriptionSampleRate) + 160
        let padded = samples.count < minimum ? samples + [Float](repeating: 0, count: minimum - samples.count) : samples
        let text = try await runner.run(padded, language: language).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [Segment(text: text, start: 0, end: Double(samples.count) / transcriptionSampleRate)]
    }
}

/// Whisper catalog, download/cancel/delete, and the one loaded model.
public actor WhisperModels {
    public static let huggingFace = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main")!

    public let directory: URL
    public let catalog: [WhisperModel]
    let baseURL: URL
    let load: @Sendable (URL) throws -> any WhisperRunner
    private var downloads: [String: (task: Task<Void, any Error>, progress: Double)] = [:]
    private var current: (model: WhisperModel, runner: any WhisperRunner)?

    public init(directory: URL) {
        self.init(directory: directory, catalog: WhisperModel.catalog, load: { try WhisperContext(model: $0) })
    }

    init(directory: URL, catalog: [WhisperModel], baseURL: URL = huggingFace, load: @escaping @Sendable (URL) throws -> any WhisperRunner) {
        self.directory = directory
        self.catalog = catalog
        self.baseURL = baseURL
        self.load = load
    }

    public var loaded: WhisperModel? { current?.model }

    private func file(_ model: WhisperModel) -> URL { directory.appending(path: model.file) }
    private func encoder(_ model: WhisperModel) -> URL { directory.appending(path: model.encoderFolder, directoryHint: .isDirectory) }

    public func status(_ model: WhisperModel) -> ModelStatus {
        if let download = downloads[model.name] { return .downloading(download.progress) }
        let size = (try? file(model).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var isDirectory: ObjCBool = false
        let hasEncoder = FileManager.default.fileExists(atPath: encoder(model).path, isDirectory: &isDirectory) && isDirectory.boolValue
        // 90% of the catalog size, as the Tauri corruption check allowed.
        return Double(size) >= Double(model.sizeMB) * 900_000 && hasEncoder ? .available : .missing
    }

    public func models() -> [(model: WhisperModel, status: ModelStatus)] { catalog.map { ($0, status($0)) } }

    /// Downloads the model, then its Core ML encoder, then loads it once so the encoder is compiled for the
    /// Neural Engine now rather than mid-meeting. Progress stays below 1 until it is ready.
    public func download(_ model: WhisperModel, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard downloads[model.name] == nil else { throw WhisperError.busy(model.name) }
        let (file, encoder, directory, base, load) = (file(model), encoder(model), directory, baseURL, load)
        let report: @Sendable (Double) -> Void = { value in
            Task { await self.setProgress(model, value) }
            progress(value)
        }
        let task = Task {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // The model is ~43% of the bytes (834 MB of 1,953 MB with its encoder).
            try await fetch(base.appending(path: model.file), to: file) { report($0 * 0.43) }
            let zip = directory.appending(path: model.encoderFolder + ".zip")
            defer { try? FileManager.default.removeItem(at: zip) }
            try await fetch(base.appending(path: model.encoderFolder + ".zip"), to: zip) { report(0.43 + $0 * 0.55) }
            try install(zip: zip, as: encoder)
            report(0.99)
            _ = try load(file)
            try Task.checkCancellation()
        }
        downloads[model.name] = (task, 0)
        let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        downloads[model.name] = nil
        if case .failure = result {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: encoder)
        }
        if task.isCancelled { throw CancellationError() }
        try result.get()
        progress(1)
    }

    private func setProgress(_ model: WhisperModel, _ value: Double) {
        downloads[model.name]?.progress = value
    }

    public func cancelDownload(_ model: WhisperModel) async {
        guard let task = downloads[model.name]?.task else { return }
        task.cancel()
        _ = await task.result
        while downloads[model.name] != nil { await Task.yield() }
    }

    public func delete(_ model: WhisperModel) throws {
        guard downloads[model.name] == nil else { throw WhisperError.busy(model.name) }
        if current?.model == model { current = nil }
        for url in [file(model), encoder(model)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// A prepared engine for `model` in `language` (nil = detect), loading the model if needed.
    public func engine(_ model: WhisperModel, language: String?) async throws -> WhisperEngine {
        if let current, current.model == model { return WhisperEngine(model: model, language: language, runner: current.runner) }
        guard downloads[model.name] == nil else { throw WhisperError.busy(model.name) }
        guard status(model) == .available else { throw WhisperError.notDownloaded(model.name) }
        current = nil
        let runner = try load(file(model))
        current = (model, runner)
        return WhisperEngine(model: model, language: language, runner: runner)
    }

    public func unload() { current = nil }
}

/// Unzips with macOS's `ditto` into a scratch folder, then swaps it into place.
private func install(zip: URL, as destination: URL) throws {
    let scratch = destination.deletingLastPathComponent().appending(path: ".encoder-unpack-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-x", "-k", zip.path, scratch.path]
    try ditto.run()
    ditto.waitUntilExit()
    let unpacked = scratch.appending(path: destination.lastPathComponent)
    guard ditto.terminationStatus == 0, FileManager.default.fileExists(atPath: unpacked.path) else {
        throw WhisperError.load("\(zip.lastPathComponent) did not contain \(destination.lastPathComponent)")
    }
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: unpacked, to: destination)
}

/// Downloads `url` to `destination` with fractional progress; cancelling the task cancels the transfer.
func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
    let running = Mutex<(task: URLSessionDownloadTask?, observation: NSKeyValueObservation?)>((nil, nil))
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let task = URLSession.shared.downloadTask(with: url) { temp, response, error in
                running.withLock { $0.observation = nil }
                if let error {
                    continuation.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
                    return
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    continuation.resume(throwing: URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLErrorKey: url]))
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temp!, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            let last = Mutex(-1.0)
            let observation = task.progress.observe(\.fractionCompleted) { p, _ in
                let value = min(p.fractionCompleted, 1)
                // KVO fires per received block; pass on 0.5 % steps.
                guard last.withLock({ old in value - old >= 0.005 ? { old = value; return true }() : false }) else { return }
                progress(value)
            }
            running.withLock { $0 = (task, observation) }
            task.resume()
            if Task.isCancelled { task.cancel() }
        }
    } onCancel: {
        running.withLock { $0.task?.cancel() }
    }
}
