import CryptoKit
import Foundation
import GRDB

/// The meetings database, shared file-for-file with the Tauri app (D3).
public final class Store: Sendable {
    public let pool: DatabasePool

    public init(path: String = Paths.database.path) throws {
        var config = Configuration()
        config.busyMode = .timeout(5)
        pool = try DatabasePool(path: path, configuration: config)
        try pool.write(Self.applyMissingMigrations)
    }

    // MARK: Schema

    /// Applies the bundled sqlx migrations a fresh file lacks, recording them the way sqlx does,
    /// so the Tauri app sees them as already applied.
    static func applyMissingMigrations(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS _sqlx_migrations (
                version BIGINT PRIMARY KEY, description TEXT NOT NULL,
                installed_on TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, success BOOLEAN NOT NULL,
                checksum BLOB NOT NULL, execution_time BIGINT NOT NULL)
            """)
        let applied = Set(try Int64.fetchAll(db, sql: "SELECT version FROM _sqlx_migrations"))
        let dir = Bundle.module.url(forResource: "migrations", withExtension: nil)!
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sql" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            let split = name.firstIndex(of: "_")!
            let version = Int64(name[..<split])!
            guard !applied.contains(version) else { continue }
            let data = try Data(contentsOf: file)
            let started = Date()
            try db.execute(sql: String(decoding: data, as: UTF8.self))
            try db.execute(
                sql: "INSERT INTO _sqlx_migrations (version, description, success, checksum, execution_time) VALUES (?, ?, 1, ?, ?)",
                arguments: [version, name[name.index(after: split)...].replacingOccurrences(of: "_", with: " "),
                            Data(SHA384.hash(data: data)), Int64(Date().timeIntervalSince(started) * 1e9)])
        }
    }

    // MARK: Meetings

    public func meetings() async throws -> [Meeting] {
        try await pool.read { try Meeting.fetchAll($0, sql: "SELECT * FROM meetings ORDER BY created_at DESC") }
    }

    public func meeting(id: String) async throws -> Meeting? {
        try await pool.read { try Meeting.fetchOne($0, key: id) }
    }

    /// Creates a meeting and its segments in one transaction; returns the new meeting id.
    public func saveMeeting(title: String, segments: [NewSegment], folderPath: String?) async throws -> String {
        let id = "meeting-\(UUID().uuidString.lowercased())"
        try await pool.write { db in
            let now = Timestamp.now()
            try Meeting(id: id, title: title, createdAt: now, updatedAt: now, folderPath: folderPath).insert(db)
            try Self.insert(segments, meetingID: id, db)
        }
        return id
    }

    /// Swaps a meeting's transcript for a new one (retranscription), atomically.
    public func replaceTranscripts(meetingID: String, segments: [NewSegment]) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM transcripts WHERE meeting_id = ?", arguments: [meetingID])
            try Self.insert(segments, meetingID: meetingID, db)
            try db.execute(sql: "UPDATE meetings SET updated_at = ? WHERE id = ?", arguments: [Timestamp.now(), meetingID])
        }
    }

    private static func insert(_ segments: [NewSegment], meetingID: String, _ db: Database) throws {
        for s in segments {
            try Transcript(
                id: "transcript-\(UUID().uuidString.lowercased())", meetingID: meetingID, transcript: s.text,
                timestamp: s.timestamp, audioStartTime: s.audioStartTime, audioEndTime: s.audioEndTime,
                duration: s.audioEndTime - s.audioStartTime, speaker: s.speaker
            ).insert(db)
        }
    }

    public func renameMeeting(id: String, title: String) async throws -> Bool {
        try await pool.write { db in
            try db.execute(sql: "UPDATE meetings SET title = ?, updated_at = ? WHERE id = ?", arguments: [title, Timestamp.now(), id])
            guard db.changesCount > 0 else { return false }
            try db.execute(sql: "UPDATE transcript_chunks SET meeting_name = ? WHERE meeting_id = ?", arguments: [title, id])
            return true
        }
    }

    /// Deletes a meeting; foreign keys cascade to transcripts, chunks, summaries and notes.
    public func deleteMeeting(id: String) async throws -> Bool {
        try await pool.write { db in
            for table in ["transcript_chunks", "summary_processes", "transcripts", "meeting_notes"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE meeting_id = ?", arguments: [id])
            }
            return try Meeting.deleteOne(db, key: id)
        }
    }

    // MARK: Transcripts

    public func transcripts(meetingID: String) async throws -> [Transcript] {
        try await pool.read {
            try Transcript.fetchAll($0, sql: "SELECT * FROM transcripts WHERE meeting_id = ? ORDER BY audio_start_time ASC, timestamp ASC", arguments: [meetingID])
        }
    }

    /// Port of `search_transcripts`: case-insensitive substring match, ~100 characters of context.
    public func searchTranscripts(_ query: String) async throws -> [SearchResult] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let escaped = query.lowercased().replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT m.id, m.title, t.transcript, t.timestamp FROM meetings m
                JOIN transcripts t ON m.id = t.meeting_id
                WHERE LOWER(t.transcript) LIKE ? ESCAPE '\\'
                """, arguments: ["%\(escaped)%"]).map { row in
                SearchResult(id: row[0], title: row[1], matchContext: Self.matchContext(row[2], query), timestamp: row[3])
            }
        }
    }

    static func matchContext(_ text: String, _ query: String) -> String {
        guard let match = text.range(of: query, options: .caseInsensitive) else { return String(text.prefix(200)) }
        let start = text.index(match.lowerBound, offsetBy: -100, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: 100, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "..." : "") + text[start..<end] + (end < text.endIndex ? "..." : "")
    }

    public func saveTranscriptChunk(meetingID: String, text: String, model: String, modelName: String, chunkSize: Int, overlap: Int) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO transcript_chunks (meeting_id, meeting_name, transcript_text, model, model_name, chunk_size, overlap, created_at)
                VALUES (?, (SELECT title FROM meetings WHERE id = ?), ?, ?, ?, ?, ?, ?)
                ON CONFLICT(meeting_id) DO UPDATE SET transcript_text = excluded.transcript_text, model = excluded.model,
                    model_name = excluded.model_name, chunk_size = excluded.chunk_size, overlap = excluded.overlap,
                    created_at = excluded.created_at
                """, arguments: [meetingID, meetingID, text, model, modelName, chunkSize, overlap, Timestamp.now()])
        }
    }

    // MARK: Summaries (ports SummaryProcessesRepository; start_time is the compare-and-set token)

    public func summaryProcess(meetingID: String) async throws -> SummaryProcess? {
        try await pool.read { try SummaryProcess.fetchOne($0, sql: "SELECT * FROM summary_processes WHERE meeting_id = ?", arguments: [meetingID]) }
    }

    public func createOrResetProcess(meetingID: String, startedAt: String) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO summary_processes (meeting_id, status, created_at, updated_at, start_time, result, error)
                VALUES (?, 'PENDING', ?, ?, ?, NULL, NULL)
                ON CONFLICT(meeting_id) DO UPDATE SET status = 'PENDING', updated_at = excluded.updated_at,
                    start_time = excluded.start_time, result_backup = result,
                    result_backup_timestamp = excluded.updated_at, result = result, error = NULL
                """, arguments: [meetingID, startedAt, startedAt, startedAt])
        }
    }

    public func completeProcess(meetingID: String, startedAt: String, result: String, chunkCount: Int, processingTime: Double) async throws -> Bool {
        try await pool.write { db in
            let now = Timestamp.now()
            try db.execute(sql: """
                UPDATE summary_processes SET status = 'completed', result = ?, updated_at = ?, end_time = ?, chunk_count = ?,
                    processing_time = ?, error = NULL, result_backup = NULL, result_backup_timestamp = NULL
                WHERE meeting_id = ? AND start_time = ? AND LOWER(status) = 'pending'
                """, arguments: [result, now, now, chunkCount, processingTime, meetingID, startedAt])
            return db.changesCount == 1
        }
    }

    public func failProcess(meetingID: String, startedAt: String, error: String) async throws -> Bool {
        try await finish(meetingID, startedAt, status: "failed", error: error)
    }

    public func cancelProcess(meetingID: String, startedAt: String) async throws -> Bool {
        try await finish(meetingID, startedAt, status: "cancelled", error: "Generation was cancelled by user")
    }

    private func finish(_ meetingID: String, _ startedAt: String, status: String, error: String) async throws -> Bool {
        try await pool.write { db in
            let now = Timestamp.now()
            try db.execute(sql: """
                UPDATE summary_processes SET status = ?, error = ?, updated_at = ?, end_time = ?,
                    result = COALESCE(result_backup, result), result_backup = NULL, result_backup_timestamp = NULL
                WHERE meeting_id = ? AND start_time = ? AND LOWER(status) = 'pending'
                """, arguments: [status, error, now, now, meetingID, startedAt])
            return db.changesCount == 1
        }
    }

    /// The user edited the summary: replace the stored result JSON (`update_meeting_summary`).
    public func updateSummaryResult(meetingID: String, result: String) async throws -> Bool {
        try await pool.write { db in
            let now = Timestamp.now()
            try db.execute(sql: "UPDATE summary_processes SET result = ?, updated_at = ? WHERE meeting_id = ?", arguments: [result, now, meetingID])
            guard db.changesCount > 0 else { return false }
            try db.execute(sql: "UPDATE meetings SET updated_at = ? WHERE id = ?", arguments: [now, meetingID])
            return true
        }
    }

    // MARK: Notes

    public func notes(meetingID: String) async throws -> String? {
        try await pool.read { try String.fetchOne($0, sql: "SELECT notes_markdown FROM meeting_notes WHERE meeting_id = ?", arguments: [meetingID]) }
    }

    public func saveNotes(meetingID: String, markdown: String) async throws {
        try await pool.write { db in
            let now = Timestamp.now()
            try db.execute(sql: """
                INSERT INTO meeting_notes (meeting_id, notes_markdown, created_at, updated_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(meeting_id) DO UPDATE SET notes_markdown = excluded.notes_markdown, updated_at = excluded.updated_at
                """, arguments: [meetingID, markdown, now, now])
        }
    }

    // MARK: Settings rows

    public func modelConfig() async throws -> ModelConfig? {
        try await pool.read { try ModelConfig.fetchOne($0, sql: "SELECT * FROM settings WHERE id = '1'") }
    }

    public func saveModelConfig(provider: String, model: String, whisperModel: String, ollamaEndpoint: String?) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO settings (id, provider, model, whisperModel, ollamaEndpoint) VALUES ('1', ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET provider = excluded.provider, model = excluded.model,
                    whisperModel = excluded.whisperModel, ollamaEndpoint = excluded.ollamaEndpoint
                """, arguments: [provider, model, whisperModel, ollamaEndpoint])
        }
    }

    /// `customOpenAIConfig` JSON: {endpoint, apiKey, model, maxTokens, temperature, topP}. The key stays in the Keychain.
    public func saveCustomOpenAIConfig(_ json: String?) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO settings (id, provider, model, whisperModel, customOpenAIConfig) VALUES ('1', 'custom-openai', '', 'large-v3', ?)
                ON CONFLICT(id) DO UPDATE SET customOpenAIConfig = excluded.customOpenAIConfig
                """, arguments: [json])
        }
    }

    public func transcriptConfig() async throws -> TranscriptConfig? {
        try await pool.read { try TranscriptConfig.fetchOne($0, sql: "SELECT id, provider, model FROM transcript_settings WHERE id = '1'") }
    }

    public func saveTranscriptConfig(provider: String, model: String) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO transcript_settings (id, provider, model) VALUES ('1', ?, ?)
                ON CONFLICT(id) DO UPDATE SET provider = excluded.provider, model = excluded.model
                """, arguments: [provider, model])
        }
    }
}
