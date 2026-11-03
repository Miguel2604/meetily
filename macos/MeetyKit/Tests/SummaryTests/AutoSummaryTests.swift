import Core
import Foundation
import Testing
@testable import Summary

/// Auto summary after a recording stops uses the saved provider and model (SummaryModelSettings' Auto Summary).
@Suite struct AutoSummaryTests {
    let store: Store
    let service: SummaryService

    init() throws {
        store = try Store(path: scratch().appending(path: "meeting_minutes.sqlite").path)
        service = SummaryService(store: store, client: LLMClient(session: fakeLLM().session), builtIn: BuiltInModels(directory: scratch()),
                                 apiKey: { _ in "sk" }, templatesDirectory: nil)
    }

    func meeting(_ text: String? = "We ship the beta on Friday.") async throws -> String {
        try await store.saveMeeting(title: "Untitled", segments: text.map { [NewSegment(text: $0, timestamp: Timestamp.now(), audioStartTime: 0, audioEndTime: 2)] } ?? [],
                                    folderPath: nil)
    }

    @Test func `nothing starts without a saved summary model`() async throws {
        let id = try await meeting()
        #expect(try await service.startWithSavedModel(meetingID: id, templateID: "standard_meeting", language: nil) == nil)
        try await store.saveModelConfig(provider: "builtin-ai", model: "", whisperModel: "large-v3", ollamaEndpoint: nil)
        #expect(try await service.startWithSavedModel(meetingID: id, templateID: "standard_meeting", language: nil) == nil)
    }

    @Test func `nothing starts for a meeting without a transcript`() async throws {
        try await store.saveModelConfig(provider: "openai", model: "gpt-6-astra", whisperModel: "large-v3", ollamaEndpoint: nil)
        let id = try await meeting(nil)
        #expect(try await service.startWithSavedModel(meetingID: id, templateID: "standard_meeting", language: nil) == nil)
    }

    @Test func `the saved provider and model summarize the meeting`() async throws {
        try await store.saveModelConfig(provider: "openai", model: "gpt-6-astra", whisperModel: "large-v3", ollamaEndpoint: nil)
        let id = try await meeting()
        let run = try #require(try await service.startWithSavedModel(meetingID: id, templateID: "standard_meeting", language: nil))
        await run.task.value
        let state = try await service.summary(meetingID: id)
        #expect(state.status == "completed")
        #expect(state.markdown?.contains("Ship Friday") == true)
    }
}
