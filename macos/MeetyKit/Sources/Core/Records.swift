import Foundation
import GRDB

// Rows of the schema the Tauri app created (D3). Timestamps stay as the stored strings.

public struct Meeting: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meetings"
    public var id: String
    public var title: String
    public var createdAt: String
    public var updatedAt: String
    public var folderPath: String?

    enum CodingKeys: String, CodingKey {
        case id, title, createdAt = "created_at", updatedAt = "updated_at", folderPath = "folder_path"
    }

    public var createdDate: Date? { Timestamp.parse(createdAt) }
}

public struct Transcript: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transcripts"
    public var id: String
    public var meetingID: String
    public var transcript: String
    public var timestamp: String
    public var summary: String?
    public var actionItems: String?
    public var keyPoints: String?
    public var audioStartTime: Double?
    public var audioEndTime: Double?
    public var duration: Double?
    public var speaker: String?

    enum CodingKeys: String, CodingKey {
        case id, meetingID = "meeting_id", transcript, timestamp, summary, actionItems = "action_items",
             keyPoints = "key_points", audioStartTime = "audio_start_time", audioEndTime = "audio_end_time",
             duration, speaker
    }
}

/// A transcript segment before it has a row id.
public struct NewSegment: Sendable, Hashable {
    public var text: String
    public var timestamp: String
    public var audioStartTime: Double
    public var audioEndTime: Double
    public var speaker: String?

    public init(text: String, timestamp: String, audioStartTime: Double, audioEndTime: Double, speaker: String? = nil) {
        self.text = text
        self.timestamp = timestamp
        self.audioStartTime = audioStartTime
        self.audioEndTime = audioEndTime
        self.speaker = speaker
    }
}

public struct SummaryProcess: Codable, Sendable, Hashable, FetchableRecord {
    public var meetingID: String
    public var status: String
    public var createdAt: String?
    public var updatedAt: String?
    public var error: String?
    public var result: String?
    public var startTime: String?
    public var endTime: String?
    public var chunkCount: Int?
    public var processingTime: Double?
    public var metadata: String?
    public var resultBackup: String?
    public var resultBackupTimestamp: String?

    enum CodingKeys: String, CodingKey {
        case meetingID = "meeting_id", status, createdAt = "created_at", updatedAt = "updated_at", error, result,
             startTime = "start_time", endTime = "end_time", chunkCount = "chunk_count",
             processingTime = "processing_time", metadata, resultBackup = "result_backup",
             resultBackupTimestamp = "result_backup_timestamp"
    }
}

/// `settings` row `'1'`: summary provider/model. API key columns are read only for the Keychain import (D10).
public struct ModelConfig: Codable, Sendable, Hashable, FetchableRecord {
    public var id: String
    public var provider: String
    public var model: String
    public var whisperModel: String
    public var groqApiKey: String?
    public var openaiApiKey: String?
    public var anthropicApiKey: String?
    public var ollamaApiKey: String?
    public var openRouterApiKey: String?
    public var ollamaEndpoint: String?
    public var customOpenAIConfig: String?
}

/// `transcript_settings` row `'1'`: transcription provider/model.
public struct TranscriptConfig: Codable, Sendable, Hashable, FetchableRecord {
    public var id: String
    public var provider: String
    public var model: String

    public init(id: String = "1", provider: String, model: String) {
        self.id = id
        self.provider = provider
        self.model = model
    }
}

public struct SearchResult: Sendable, Hashable {
    public var id: String
    public var title: String
    public var matchContext: String
    public var timestamp: String
}

/// One pasted dictation in the opt-in history: `heard` is the transcript, `text` what went into the app.
public struct DictationEntry: Codable, Sendable, Hashable, Identifiable, FetchableRecord {
    public var id: Int64
    public var createdAt: String
    public var app: String?
    public var heard: String
    public var text: String

    enum CodingKeys: String, CodingKey {
        case id, app, heard, text, createdAt = "created_at"
    }

    public var createdDate: Date? { Timestamp.parse(createdAt) }
}
