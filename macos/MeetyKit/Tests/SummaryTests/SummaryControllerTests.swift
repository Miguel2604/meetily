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

    func controller(_ stub: Stub = fakeLLM(), autosave: Duration = .seconds(60)) -> SummaryController {
        SummaryController(meetingID: meetingID, store: store,
                          service: SummaryService(store: store, client: LLMClient(session: stub.session), builtIn: BuiltInModels(directory: scratch()),
                                                  apiKey: { _ in "sk" }, templatesDirectory: nil),
                          autosaveDelay: autosave)
    }

    /// Waits until the editor's text is saved, or fails after a few seconds.
    func waitUntilSaved(_ summary: SummaryController) async throws {
        for _ in 0..<300 where summary.isDirty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!summary.isDirty)
    }

    @Test func `edits save themselves after a pause in typing`() async throws {
        let summary = controller(autosave: .milliseconds(50))
        await summary.generate(provider: "openai", model: "m", templateID: "standard_meeting", language: "en")
        summary.markdown = "## Points\n- Autosaved"
        try await waitUntilSaved(summary)
        let reloaded = controller()
        await reloaded.load()
        #expect(reloaded.markdown == "## Points\n- Autosaved")
    }

    @Test func `typing again restarts the wait before saving`() async throws {
        let summary = controller(autosave: .milliseconds(400))
        await summary.generate(provider: "openai", model: "m", templateID: "standard_meeting", language: "en")
        summary.markdown = "## Points\n- A"
        try await Task.sleep(for: .milliseconds(200))
        summary.markdown = "## Points\n- AB"
        try await Task.sleep(for: .milliseconds(300)) // 500 ms after the first edit, 300 ms after the second
        #expect(summary.savedMarkdown == "## Points\nShip Friday")
        try await waitUntilSaved(summary)
        #expect(summary.savedMarkdown == "## Points\n- AB")
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

    @Test func `typing during a save keeps the newer text dirty`() async throws {
        let summary = controller()
        await summary.generate(provider: "openai", model: "m", templateID: "standard_meeting", language: "en")
        summary.markdown = "## Points\n- One"
        let save = Task { try await summary.save() }
        await Task.yield() // the save is now waiting on the database
        summary.markdown = "## Points\n- One\n- Two"
        try await save.value
        #expect(summary.isDirty)
        #expect(summary.savedMarkdown == "## Points\n- One")
    }

    @Test func `an edit made just before regenerating survives cancelling the run`() async throws {
        let summary = controller()
        await summary.generate(provider: "openai", model: "m", templateID: "standard_meeting", language: "en")
        let slow = fakeLLM { _, _ in Reply(200, "{}", delay: .seconds(30)) }
        let again = controller(slow)
        await again.load()
        again.markdown = "## Points\n- My edit" // regenerate inside the autosave wait
        async let run: Void = again.generate(provider: "openai", model: "m", templateID: "standard_meeting", language: "en")
        while slow.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        await again.cancel()
        await run
        #expect(again.markdown == "## Points\n- My edit")
        #expect(!again.isDirty)
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
