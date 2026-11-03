import Core
import Foundation

/// One piece of transcript, times in seconds from the start of the samples passed in.
public struct Segment: Sendable, Hashable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// A prepared (compiled, warmed) model. Model stores hand these out ready to use, so recording
/// never pays for a load (D9). Input is 16 kHz mono.
public protocol TranscriptionEngine: AnyObject, Sendable {
    func transcribe(samples: [Float]) async throws -> [Segment]
}

public let transcriptionSampleRate = 16_000.0

/// Catalog status of a downloadable model.
public enum ModelStatus: Sendable, Hashable {
    case missing
    case downloading(Double)
    case available
}

/// Which engine transcribes, from the language preference and the `transcript_settings` row.
public enum EngineChoice: Sendable, Hashable {
    case parakeet(ParakeetModel)
    /// Whisper language code; nil detects it.
    case whisper(WhisperModel, language: String?)

    /// "en" → Parakeet (the configured Parakeet model, else Ultra); "auto" → the configured provider,
    /// Whisper detecting the language; any other code (tl, …) → Whisper in that language.
    public static func route(language: String, config: TranscriptConfig?) -> EngineChoice {
        let parakeet = ParakeetModel(rawValue: config?.provider == "parakeet" ? config?.model ?? "" : "") ?? .default
        switch language {
        case "en": return .parakeet(parakeet)
        case "auto": return config?.provider == "localWhisper" ? .whisper(.turbo, language: nil) : .parakeet(parakeet)
        default: return .whisper(.turbo, language: language)
        }
    }
}
