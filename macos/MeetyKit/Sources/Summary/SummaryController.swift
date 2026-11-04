import Core
import Foundation
import Observation

/// One meeting's summary pane: load (resuming a run still going), generate, cancel, edit and save.
/// Edits are stored as `{"markdown": ...}` (useSummaryGeneration.ts semantics) and save themselves once typing
/// pauses for `autosaveDelay`.
@MainActor @Observable
public final class SummaryController {
    public let meetingID: String
    public private(set) var isGenerating = false
    public private(set) var error: String?
    /// The editor's text.
    public var markdown = "" { didSet { scheduleAutosave() } }
    public private(set) var savedMarkdown = ""
    /// The meeting title, updated when a summary renames the meeting.
    public private(set) var title: String?

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let service: SummaryService
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var processID: String?
    @ObservationIgnored private var data: [String: Any] = [:]
    @ObservationIgnored private let autosaveDelay: Duration
    @ObservationIgnored private var autosave: Task<Void, Never>?

    public init(meetingID: String, store: Store, service: SummaryService, pollInterval: Duration = .seconds(1), autosaveDelay: Duration = .seconds(1)) {
        self.meetingID = meetingID
        self.store = store
        self.service = service
        self.pollInterval = pollInterval
        self.autosaveDelay = autosaveDelay
    }

    public var hasSummary: Bool { !savedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var isDirty: Bool { markdown != savedMarkdown }

    /// Shows the stored summary; if a run is still pending (started from another screen), waits for it.
    public func load() async {
        do {
            let state = try await service.summary(meetingID: meetingID)
            apply(state)
            guard isRunning(state) else { return }
            processID = state.processID
            isGenerating = true
            while isGenerating {
                try await Task.sleep(for: pollInterval)
                let next = try await service.summary(meetingID: meetingID)
                if !isRunning(next) { apply(next) }
            }
        } catch is CancellationError {
        } catch {
            self.error = "Failed to load the summary: \(error)"
        }
    }

    public func generate(provider: String, model: String, templateID: String, customPrompt: String = "", language: String?) async {
        guard !isGenerating else { return }
        error = nil
        do {
            // A failed or cancelled run restores the stored summary, so pending edits must be stored first.
            if isDirty { try await save() }
            let transcripts = try await store.transcripts(meetingID: meetingID)
            guard !transcripts.isEmpty else { error = "No transcripts available for summary"; return }
            isGenerating = true
            let run = try await service.start(meetingID: meetingID, text: SummaryText.input(transcripts).text, provider: provider,
                                              model: model, customPrompt: customPrompt, templateID: templateID, summaryLanguage: language)
            processID = run.processID
            await run.task.value
            apply(try await service.summary(meetingID: meetingID))
        } catch {
            isGenerating = false
            self.error = String(describing: error)
        }
    }

    public func cancel() async {
        guard isGenerating, let processID else { return }
        _ = try? await service.cancel(meetingID: meetingID, processID: processID)
    }

    /// Stores the editor's markdown, keeping the run's other fields (english cache, metadata).
    public func save() async throws {
        let snapshot = markdown // edits made while the save is in flight stay dirty
        var summary = data
        summary["markdown"] = snapshot
        summary["summary_json"] = nil
        nonisolated(unsafe) let payload = summary // a fresh copy the service only reads
        try await service.save(meetingID: meetingID, summary: payload)
        data = summary
        savedMarkdown = snapshot
    }

    /// Restarts the wait on every edit; a generated or loaded summary is already saved, so nothing fires for it.
    private func scheduleAutosave() {
        autosave?.cancel()
        guard isDirty, !isGenerating else { return }
        autosave = Task { [weak self, autosaveDelay] in
            try? await Task.sleep(for: autosaveDelay)
            guard !Task.isCancelled, let self, isDirty, !isGenerating else { return }
            do { try await save() } catch { self.error = "Couldn't save the summary: \(error)" }
        }
    }

    private func isRunning(_ state: SummaryState) -> Bool { state.status == "pending" || state.status == "processing" }

    private func apply(_ state: SummaryState) {
        title = state.meetingName
        guard !isRunning(state) else { return }
        isGenerating = false
        processID = nil
        if let data = state.data, let text = SummaryText.markdown(from: data) {
            self.data = data
            markdown = text
            savedMarkdown = text
        }
        switch state.status {
        case "failed", "error":
            error = (state.error ?? "Summary generation failed") + (hasSummary ? ". Your previous summary has been restored." : "")
        case "completed" where !hasSummary:
            error = "Summary generation completed without visible content. Please retry."
        default:
            error = nil
        }
    }
}
