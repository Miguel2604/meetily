/// Application configuration constants
///
/// Centralized definitions for default models and settings.
/// Used across database initialization, import, and retranscription.

/// Default Whisper model for transcription when no preference is configured.
/// This is the recommended balance of accuracy and speed.
pub const DEFAULT_WHISPER_MODEL: &str = "large-v3-turbo-q8_0";

/// Default Parakeet model for transcription when no preference is configured.
/// The most accurate of the two Neural Engine models.
pub const DEFAULT_PARAKEET_MODEL: &str = "parakeet-ultra";

/// Whisper model catalog with metadata for all supported models.
/// Used by both WhisperEngine::discover_models() and discover_models_standalone().
///
/// Format: (name, filename, size_mb, accuracy, speed, description)
pub const WHISPER_MODEL_CATALOG: &[(&str, &str, u32, &str, &str, &str)] = &[
    // size_mb is the .bin alone (it drives the corruption check); the Core ML encoder adds 1.1 GB.
    ("large-v3-turbo-q8_0", "ggml-large-v3-turbo-q8_0.bin", 834, "High", "Fast",
     "Best for Tagalog and Taglish. Near full-precision large-v3-turbo, encoder on the Neural Engine"),
];

/// Every catalog file is served from the official whisper.cpp model repository.
pub const WHISPER_MODEL_BASE_URL: &str = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main";
