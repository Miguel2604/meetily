import Core
import Foundation
import Observation
import Summary
import Transcription

/// Every local model's download, cancel, delete and prepare state, shared by Settings and Onboarding,
/// so a download started in one shows its progress in the other.
@Observable
final class ModelLibrary {
    enum Item: Hashable {
        case parakeet(ParakeetModel)
        case whisper(WhisperModel)
        case builtIn(BuiltInModel)

        var title: String {
            switch self {
            case .parakeet(.ultra): "Parakeet Ultra"
            case .parakeet(.phonon2): "Phonon-2"
            case .whisper: "Whisper large-v3-turbo"
            case .builtIn(let model): model.displayName
            }
        }

        var detail: String {
            switch self {
            case .parakeet(let model): model.description
            case .whisper(let model): model.description
            case .builtIn(let model): model.description
            }
        }

        var sizeMB: Int {
            switch self {
            case .parakeet(let model): model.sizeMB
            case .whisper(let model): model.sizeMB
            case .builtIn(let model): model.sizeMB
            }
        }

        static let transcription: [Item] = ParakeetModel.allCases.map(Item.parakeet) + WhisperModel.catalog.map(Item.whisper)
        static let summary: [Item] = BuiltInModel.catalog.map(Item.builtIn)
    }

    enum State: Equatable {
        case missing
        /// Download progress; at 0.99 the model is being compiled for the Neural Engine.
        case downloading(Double)
        /// Loading a downloaded model into memory after it was picked (D9).
        case preparing
        case ready
        case failed(String)
    }

    private(set) var states: [Item: State] = [:]
    private(set) var transcription: TranscriptConfig?
    private(set) var summary: SummaryConfig?
    @ObservationIgnored private unowned let app: AppModel

    init(app: AppModel) { self.app = app }

    func state(_ item: Item) -> State { states[item] ?? .missing }

    func isSelected(_ item: Item) -> Bool {
        switch item {
        case .parakeet(let model):
            transcription?.provider == "parakeet" && (ParakeetModel(rawValue: transcription?.model ?? "") ?? .default) == model
        case .whisper: transcription?.provider == "localWhisper"
        case .builtIn(let model): summary?.provider == .builtin && summary?.model == model.name
        }
    }

    /// Re-reads disk status and the saved selections. Rows that are busy here keep their live state.
    func refresh() async {
        // Assign only on change: panes reset their forms when these change.
        let transcription = try? await app.store.transcriptConfig(), summary = try? await SummaryConfig.load(store: app.store)
        if transcription != self.transcription { self.transcription = transcription }
        if summary != self.summary { self.summary = summary }
        var fresh: [Item: ModelStatus] = [:]
        for info in await app.parakeet.models() { fresh[.parakeet(info.model)] = info.status }
        for entry in await app.whisper.models() { fresh[.whisper(entry.model)] = entry.status }
        for entry in await app.builtIn.models() { fresh[.builtIn(entry.model)] = entry.status }
        for (item, status) in fresh {
            switch (states[item], status) {
            case (.downloading?, _), (.preparing?, _): continue
            case (.failed?, .missing): continue // keep the error visible until the next try
            case (_, .missing): states[item] = .missing
            case (_, .downloading(let progress)): states[item] = .downloading(progress)
            case (_, .available): states[item] = .ready
            }
        }
    }

    /// Downloads and prepares the model. Cancelling returns it to `.missing`.
    func download(_ item: Item) async {
        if case .downloading = state(item) { return }
        states[item] = .downloading(0)
        let report: @Sendable (Double) -> Void = { value in
            Task { @MainActor in
                if case .downloading = self.state(item) { self.states[item] = .downloading(value) }
            }
        }
        do {
            switch item {
            case .parakeet(let model): try await app.parakeet.download(model, progress: report)
            case .whisper(let model): try await app.whisper.download(model, progress: report)
            case .builtIn(let model): try await app.builtIn.download(model, progress: report)
            }
            states[item] = .ready
        } catch is CancellationError {
            states[item] = .missing
        } catch {
            states[item] = .failed("Couldn't download \(item.title): \(error.localizedDescription)")
        }
    }

    /// After a failure: use the model if it is on disk, else download it again.
    func retry(_ item: Item) async {
        states[item] = nil
        await refresh()
        if state(item) == .ready { await use(item) } else { await download(item) }
    }

    func cancel(_ item: Item) async {
        switch item {
        case .parakeet(let model): await app.parakeet.cancelDownload(model)
        case .whisper(let model): await app.whisper.cancelDownload(model)
        case .builtIn(let model): await app.builtIn.cancelDownload(model)
        }
    }

    func delete(_ item: Item) async {
        do {
            switch item {
            case .parakeet(let model): try await app.parakeet.delete(model)
            case .whisper(let model): try await app.whisper.delete(model)
            case .builtIn(let model): try await app.builtIn.delete(model)
            }
            states[item] = .missing
        } catch {
            states[item] = .failed("Couldn't delete \(item.title): \(error.localizedDescription)")
        }
    }

    /// Makes `item` the model in use: saves the selection, then loads a transcription model now so
    /// the first recording doesn't wait for it (D9).
    func use(_ item: Item) async {
        do {
            switch item {
            case .parakeet(let model):
                try await app.store.saveTranscriptConfig(provider: "parakeet", model: model.rawValue)
                await refresh()
                states[item] = .preparing
                _ = try await app.parakeet.engine(model)
            case .whisper(let model):
                try await app.store.saveTranscriptConfig(provider: "localWhisper", model: model.name)
                await refresh()
                states[item] = .preparing
                _ = try await app.whisper.engine(model, language: nil)
            case .builtIn(let model):
                var config = try await SummaryConfig.load(store: app.store)
                (config.provider, config.model) = (.builtin, model.name)
                try await config.save(store: app.store)
                app.settings.builtInSummaryModel = model.name
                await refresh()
            }
            states[item] = .ready
        } catch {
            states[item] = .failed("Couldn't prepare \(item.title): \(error)")
        }
    }
}
