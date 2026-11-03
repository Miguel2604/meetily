import FluidAudio
import Foundation

/// English models on the Neural Engine, both Parakeet TDT 0.6B v3 derivatives run through FluidAudio.
/// The raw value is also the folder FluidAudio stores the model in, so models the Tauri app downloaded are reused.
public enum ParakeetModel: String, CaseIterable, Sendable {
    case ultra = "parakeet-ultra"
    case phonon2 = "phonon-2"

    public static let `default` = ParakeetModel.ultra

    public var sizeMB: Int { self == .ultra ? 630 : 360 }
    public var description: String {
        switch self {
        case .ultra: "Most accurate. moondream's Parakeet Ultra, best for English meetings"
        case .phonon2: "Smallest and fastest. Fermion Research's Phonon-2, English only"
        }
    }

    var version: AsrModelVersion { self == .ultra ? .ultra : .phonon2 }
}

public enum ParakeetError: Error, Equatable, CustomStringConvertible {
    case notDownloaded(String)
    case busy(String)
    case engine(String)

    public var description: String {
        switch self {
        case .notDownloaded(let name): "Parakeet model \(name) is not downloaded"
        case .busy(let name): "Parakeet model \(name) is downloading"
        case .engine(let message): message
        }
    }
}

/// Transcribes one independent chunk of 16 kHz audio.
protocol ChunkTranscriber: Sendable {
    func transcribe(_ samples: [Float]) async throws -> String
}

/// The FluidAudio calls, swappable so the catalog logic is testable without models or network.
struct ParakeetBackend: Sendable {
    var isDownloaded: @Sendable (URL, ParakeetModel) -> Bool
    var download: @Sendable (URL, ParakeetModel, @escaping @Sendable (Double) -> Void) async throws -> Void
    var load: @Sendable (URL, ParakeetModel) async throws -> any ChunkTranscriber

    static let fluidAudio = ParakeetBackend(
        isDownloaded: { AsrModels.modelsExist(at: $0, version: $1.version) },
        download: { dir, model, progress in
            _ = try await AsrModels.download(to: dir, version: model.version) { progress($0.fractionCompleted) }
        },
        load: { dir, model in
            let asr = AsrManager(config: .default)
            try await asr.loadModels(AsrModels.load(from: dir, version: model.version))
            return FluidChunks(asr: asr)
        })
}

struct FluidChunks: ChunkTranscriber {
    let asr: AsrManager
    func transcribe(_ samples: [Float]) async throws -> String {
        var state = try TdtDecoderState() // each chunk is independent speech, so it starts fresh
        return try await asr.transcribe(samples, decoderState: &state).text
    }
}

public final class ParakeetEngine: TranscriptionEngine {
    public let model: ParakeetModel
    let chunks: any ChunkTranscriber

    init(model: ParakeetModel, chunks: any ChunkTranscriber) {
        self.model = model
        self.chunks = chunks
    }

    public func transcribe(samples: [Float]) async throws -> [Segment] {
        guard !samples.isEmpty else { return [] }
        // FluidAudio rejects chunks under 0.3 s; pad short VAD chunks with silence instead.
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: Int(transcriptionSampleRate))
        let padded = samples.count < minimum ? samples + [Float](repeating: 0, count: minimum - samples.count) : samples
        let text = try await chunks.transcribe(padded).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [Segment(text: text, start: 0, end: Double(samples.count) / transcriptionSampleRate)]
    }
}

/// Catalog, download/cancel/delete, and the one loaded model (only one in memory at a time).
public actor ParakeetModels {
    public struct Info: Sendable, Hashable {
        public let model: ParakeetModel
        public let status: ModelStatus
    }

    public let directory: URL
    let backend: ParakeetBackend
    private var downloads: [ParakeetModel: (task: Task<Void, any Error>, progress: Double)] = [:]
    private var current: ParakeetEngine?

    public init(directory: URL) { self.init(directory: directory, backend: .fluidAudio) }

    init(directory: URL, backend: ParakeetBackend) {
        self.directory = directory
        self.backend = backend
    }

    public var loaded: ParakeetModel? { current?.model }

    public func folder(_ model: ParakeetModel) -> URL { directory.appending(path: model.rawValue, directoryHint: .isDirectory) }

    public func status(_ model: ParakeetModel) -> ModelStatus {
        if let download = downloads[model] { return .downloading(download.progress) }
        return backend.isDownloaded(folder(model), model) ? .available : .missing
    }

    public func models() -> [Info] { ParakeetModel.allCases.map { Info(model: $0, status: status($0)) } }

    /// Downloads, then compiles and warms the model on the Neural Engine (one time, up to minutes for
    /// Phonon-2). Progress stays below 1 until the model is ready. Throws `CancellationError` when cancelled.
    public func download(_ model: ParakeetModel, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard downloads[model] == nil else { throw ParakeetError.busy(model.rawValue) }
        let dir = folder(model)
        let backend = backend
        let task = Task {
            try await backend.download(dir, model) { fraction in
                let capped = min(fraction, 0.99)
                Task { await self.setProgress(model, capped) }
                progress(capped)
            }
            try Task.checkCancellation()
            progress(0.99)
            _ = try await backend.load(dir, model) // the first load builds the ANE plan; pay it now
            try Task.checkCancellation()
        }
        downloads[model] = (task, 0)
        let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        downloads[model] = nil
        if task.isCancelled {
            try? FileManager.default.removeItem(at: dir) // partial files; start clean next time
            throw CancellationError()
        }
        try result.get()
        progress(1)
    }

    private func setProgress(_ model: ParakeetModel, _ value: Double) {
        downloads[model]?.progress = value
    }

    /// Cancels and waits for the download to clean up.
    public func cancelDownload(_ model: ParakeetModel) async {
        guard let task = downloads[model]?.task else { return }
        task.cancel()
        _ = await task.result
        while downloads[model] != nil { await Task.yield() } // the download call clears it after cleanup
    }

    public func delete(_ model: ParakeetModel) throws {
        guard downloads[model] == nil else { throw ParakeetError.busy(model.rawValue) }
        if current?.model == model { current = nil }
        let dir = folder(model)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
    }

    /// The prepared engine for `model`, loading it (and dropping any other) if needed.
    public func engine(_ model: ParakeetModel) async throws -> ParakeetEngine {
        if let current, current.model == model { return current }
        guard downloads[model] == nil else { throw ParakeetError.busy(model.rawValue) }
        guard backend.isDownloaded(folder(model), model) else { throw ParakeetError.notDownloaded(model.rawValue) }
        current = nil
        let engine: ParakeetEngine
        do {
            engine = ParakeetEngine(model: model, chunks: try await backend.load(folder(model), model))
        } catch let error as ParakeetError {
            throw error
        } catch {
            throw ParakeetError.engine("Failed to load Parakeet model \(model.rawValue): \(error)")
        }
        current = engine
        return engine
    }

    public func unload() { current = nil }
}
