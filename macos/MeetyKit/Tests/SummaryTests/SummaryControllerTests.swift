import Core
import Foundation
import Testing
@testable import Summary

@MainActor @Suite struct SummaryControllerTests {
    let store: Store
    let meetingID: String

    init() async throws {
        store = try Store(path: scratch().appending(path: "meeting_minutes.sqlite").path)
        meetingID = try await store.saveMeeting(
            title: "Untitled", segments: [NewSegment(text: "We ship the beta on Friday.", timestamp: Timestamp.now(), audioStartTime: 0, audioEndTime: 2)],
            folderPath: nil)
    }

    func controller(_ stub: Stub = fakeLLM()) -> SummaryController {
        SummaryController(meetingID: meetingID, store: store,
                          service: SummaryService(store: store, client: LLMClient(session: stub.session), builtIn: BuiltInModels(directory: scratch()),
                                                  apiKey: { _ in "sk" }, templatesDirectory: nil))
    }

    @Test func `generating fills the editor and picks up the new title`() async throws {
        let summary = controller()
        await summary.load()
        #expect(!summary.hasSummary)
        await summary.generate(provider: "openai", model: "m", templateID: "standard_meeting", language: "en")
        #expect(summary.markdown == "## Points\nShip Friday")
        #expect(summary.title == "Weekly Sync")
        #expect(!summary.isGenerating && summary.error == nil && !summary.isDirty)
    }

    @Test func `no transcript fails before calling a model`() async throws {
        let empty = try await store.saveMeeting(title: "Empty", segments: [], folderPath: nil)
        let stub = fakeLLM()
        let summary = SummaryController(meetingID: empty, store: store,
                                        service: SummaryService(store: store, client: LLMClient(session: stub.session),
                                                                builtIn: BuiltInModels(directory: scratch()), apiKey: { _ in "sk" }))
        await summary.generate(provider: "openai", model: "m", templateID: "standard_meeting", language: nil)
        #expect(summary.error == "No transcripts available for summary")
        #expect(stub.requests.isEmpty)
    }

    @Test func `edits save as markdown and reload`() async throws {
        let summary = controller()
        await summary.generate(provider: "openai", model: "m", templateID: "standard_meeting", language: "en")
        summary.markdown = "## Points\n- Ship **Friday**"
        #expect(summary.isDirty)
        try await summary.save()
        #expect(!summary.isDirty)
        let reloaded = controller()
        await reloaded.load()
        #expect(reloaded.markdown == "## Points\n- Ship **Friday**")
    }

    @Test func `cancelling a regeneration keeps the previous summary`() async throws {
        let summary = controller()
        await summary.generate(provider: "openai", model: "m", templateID: "standard_meeting", language: "en")
        let slow = fakeLLM { _, _ in Reply(200, "{}", delay: .seconds(30)) }
        let again = controller(slow)
        await again.load()
        async let run: Void = again.generate(provider: "openai", model: "m", templateID: "standard_meeting", language: "en")
        while slow.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(again.isGenerating)
        await again.cancel()
        await run
        #expect(!again.isGenerating)
        #expect(again.markdown == "## Points\nShip Friday")
    }
}
