import Foundation
import GRDB
import Testing
@testable import Core

func tempStore() throws -> Store {
    let dir = FileManager.default.temporaryDirectory.appending(path: "meety-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try Store(path: dir.appending(path: "meeting_minutes.sqlite").path)
}

func segment(_ text: String, _ start: Double) -> NewSegment {
    NewSegment(text: text, timestamp: Timestamp.now(), audioStartTime: start, audioEndTime: start + 1, speaker: "mic")
}

@Suite struct StoreTests {
    let store: Store
    init() throws { store = try tempStore() }

    @Test func `fresh database gets the sqlx schema and migration rows`() throws {
        let versions = try store.pool.read { try Int64.fetchAll($0, sql: "SELECT version FROM _sqlx_migrations ORDER BY version") }
        #expect(versions.count == 11)
        #expect(versions.first == 20250916100000)
        let columns = try store.pool.read { try $0.columns(in: "transcripts").map(\.name) }
        #expect(columns.contains("speaker"))
        // Reopening an already migrated file is a no-op.
        _ = try Store(path: store.pool.path)
    }

    @Test func `save, list, rename and delete a meeting`() async throws {
        let id = try await store.saveMeeting(title: "Standup", segments: [segment("b", 2), segment("a", 1)], folderPath: "/tmp/x")
        #expect(id.hasPrefix("meeting-"))
        let meetings = try await store.meetings()
        #expect(meetings.map(\.title) == ["Standup"])
        #expect(meetings[0].folderPath == "/tmp/x")
        #expect(Timestamp.parse(meetings[0].createdAt) != nil)

        let transcripts = try await store.transcripts(meetingID: id)
        #expect(transcripts.map(\.transcript) == ["a", "b"])
        #expect(transcripts[0].duration == 1)
        #expect(transcripts[0].speaker == "mic")

        try await store.saveTranscriptChunk(meetingID: id, text: "a b", model: "ollama", modelName: "m", chunkSize: 100, overlap: 10)
        #expect(try await store.renameMeeting(id: id, title: "Daily"))
        #expect(try await store.meeting(id: id)?.title == "Daily")
        let chunkName = try await store.pool.read { try String.fetchOne($0, sql: "SELECT meeting_name FROM transcript_chunks") }
        #expect(chunkName == "Daily")
        #expect(try await !store.renameMeeting(id: "missing", title: "x"))

        try await store.saveNotes(meetingID: id, markdown: "# notes")
        #expect(try await store.notes(meetingID: id) == "# notes")
        try await store.saveNotes(meetingID: id, markdown: "# edited")
        #expect(try await store.notes(meetingID: id) == "# edited")

        try await store.createOrResetProcess(meetingID: id, startedAt: Timestamp.now())
        #expect(try await store.deleteMeeting(id: id))
        #expect(try await !store.deleteMeeting(id: id))
        let leftovers = try await store.pool.read { db in
            try ["transcripts", "transcript_chunks", "summary_processes", "meeting_notes"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)")!
            }
        }
        #expect(leftovers == [0, 0, 0, 0])
    }

    @Test func `search matches case-insensitively with context`() async throws {
        let long = String(repeating: "x", count: 150) + " The Budget review " + String(repeating: "y", count: 150)
        _ = try await store.saveMeeting(title: "Finance", segments: [segment(long, 0), segment("nothing here", 1)], folderPath: nil)
        let results = try await store.searchTranscripts("budget")
        #expect(results.count == 1)
        #expect(results[0].title == "Finance")
        #expect(results[0].matchContext.hasPrefix("..."))
        #expect(results[0].matchContext.hasSuffix("..."))
        #expect(results[0].matchContext.contains("The Budget review"))
        #expect(try await store.searchTranscripts("  ").isEmpty)
        #expect(try await store.searchTranscripts("100%").isEmpty)
    }

    // Ports summary.rs `terminal_compare_and_set_preserves_first_writer`.
    @Test func `terminal compare-and-set preserves the first writer`() async throws {
        let id = try await store.saveMeeting(title: "m", segments: [], folderPath: nil)
        let start = Timestamp.now()
        try await store.createOrResetProcess(meetingID: id, startedAt: start)
        #expect(try await store.completeProcess(meetingID: id, startedAt: start, result: #"{"markdown":"completed"}"#, chunkCount: 1, processingTime: 1))
        #expect(try await !store.cancelProcess(meetingID: id, startedAt: start))
        #expect(try await store.summaryProcess(meetingID: id)?.status == "completed")

        // Regenerating backs up the previous result; cancelling restores it.
        let second = Timestamp.now() + "1"
        try await store.createOrResetProcess(meetingID: id, startedAt: second)
        let pending = try #require(try await store.summaryProcess(meetingID: id))
        #expect(pending.status == "PENDING")
        #expect(pending.resultBackup == #"{"markdown":"completed"}"#)
        #expect(try await store.cancelProcess(meetingID: id, startedAt: second))
        #expect(try await !store.completeProcess(meetingID: id, startedAt: second, result: "{}", chunkCount: 1, processingTime: 1))
        let cancelled = try #require(try await store.summaryProcess(meetingID: id))
        #expect(cancelled.status == "cancelled")
        #expect(cancelled.result == #"{"markdown":"completed"}"#)
        #expect(cancelled.resultBackup == nil)
    }

    // Ports summary.rs `cancelled_compare_and_set_rejects_stale_start_time`.
    @Test func `cancel rejects a stale start time`() async throws {
        let id = try await store.saveMeeting(title: "m", segments: [], folderPath: nil)
        let start = Timestamp.now()
        try await store.createOrResetProcess(meetingID: id, startedAt: start)
        #expect(try await !store.cancelProcess(meetingID: id, startedAt: "2000-01-01T00:00:00+00:00"))
        #expect(try await store.failProcess(meetingID: id, startedAt: start, error: "boom"))
        let failed = try #require(try await store.summaryProcess(meetingID: id))
        #expect(failed.status == "failed")
        #expect(failed.error == "boom")
    }

    @Test func `model config round-trips through settings row 1`() async throws {
        #expect(try await store.modelConfig() == nil)
        try await store.saveModelConfig(provider: "ollama", model: "llama3", whisperModel: "large-v3", ollamaEndpoint: "http://localhost:11434")
        let config = try #require(try await store.modelConfig())
        #expect(config.provider == "ollama")
        #expect(config.ollamaEndpoint == "http://localhost:11434")
        try await store.saveTranscriptConfig(provider: "parakeet", model: "phonon-2")
        #expect(try await store.transcriptConfig()?.model == "phonon-2")
    }

    @Test func `timestamps match the chrono RFC 3339 form`() {
        let now = Timestamp.now()
        #expect(now.hasSuffix("+00:00"))
        #expect(Timestamp.parse("2026-11-03T13:54:14.055617+00:00") != nil)
        #expect(Timestamp.parse("2026-11-03 13:54:14.055617") != nil)
        #expect(Timestamp.parse("2026-11-03T13:54:14Z") != nil)
    }

    // Opt-in: reads a copy of the live database, never the file itself.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEETY_REAL_DB"] == "1"))
    func `reads a copy of the real database`() async throws {
        let live = URL.applicationSupportDirectory.appending(path: "com.meetily.ai/meeting_minutes.sqlite")
        let dir = FileManager.default.temporaryDirectory.appending(path: "meety-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: live.path + suffix) {
            try FileManager.default.copyItem(atPath: live.path + suffix, toPath: dir.appending(path: "meeting_minutes.sqlite\(suffix)").path)
        }
        let store = try Store(path: dir.appending(path: "meeting_minutes.sqlite").path)
        let versions = try await store.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM _sqlx_migrations") }
        #expect(versions == 11)
        let meetings = try await store.meetings()
        #expect(!meetings.isEmpty)
        let transcripts = try await store.transcripts(meetingID: meetings[0].id)
        #expect(!transcripts.isEmpty)
        _ = try await store.summaryProcess(meetingID: meetings[0].id)
        _ = try await store.modelConfig()
    }
}

@Suite struct DictationHistoryTests {
    @Test func `entries come back newest first, with what was heard and what was pasted`() async throws {
        let store = try tempStore()
        try await store.saveDictation(heard: "um first", text: "First.", app: "Slack", at: Date(timeIntervalSince1970: 1_000))
        try await store.saveDictation(heard: "second", text: "Second.", app: nil, at: Date(timeIntervalSince1970: 2_000))
        let entries = try await store.dictations(now: Date(timeIntervalSince1970: 3_000))
        #expect(entries.map(\.text) == ["Second.", "First."])
        #expect(entries.last?.heard == "um first")
        #expect(entries.last?.app == "Slack")
        #expect(entries.first?.app == nil)
        #expect(entries.last?.createdDate == Date(timeIntervalSince1970: 1_000))
    }

    @Test func `entries past seven days disappear, from reads and from the file`() async throws {
        let store = try tempStore()
        let now = Date(timeIntervalSince1970: 100_000_000)
        try await store.saveDictation(heard: "old", text: "Old.", app: nil, at: now - 8 * 86_400)
        try await store.saveDictation(heard: "new", text: "New.", app: nil, at: now - 6 * 86_400)
        #expect(try await store.dictations(now: now).map(\.text) == ["New."])
        try await store.pruneDictations(now: now)
        let left = try await store.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM dictations") }
        #expect(left == 1)
    }

    @Test func `saving prunes too, and delete all empties it`() async throws {
        let store = try tempStore()
        let now = Date(timeIntervalSince1970: 100_000_000)
        try await store.saveDictation(heard: "old", text: "Old.", app: nil, at: now - 8 * 86_400)
        try await store.saveDictation(heard: "new", text: "New.", app: nil, at: now)
        let left = try await store.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM dictations") }
        #expect(left == 1)
        try await store.deleteDictations()
        #expect(try await store.dictations(now: now).isEmpty)
    }
}
