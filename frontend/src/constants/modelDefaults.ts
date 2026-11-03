/**
 * Default model names for transcription engines.
 * IMPORTANT: Keep in sync with Rust constants in src-tauri/src/config.rs
 */

/**
 * Default Whisper model for transcription when no preference is configured.
 * Best local model for Tagalog/Taglish; its encoder runs on the Neural Engine.
 */
export const DEFAULT_WHISPER_MODEL = 'large-v3-turbo-q8_0';

/**
 * Default Parakeet model for transcription when no preference is configured.
 * Parakeet Ultra on the Neural Engine, the most accurate English model.
 */
export const DEFAULT_PARAKEET_MODEL = 'parakeet-ultra';

/**
 * Model defaults by provider type
 */
export const MODEL_DEFAULTS = {
  whisper: DEFAULT_WHISPER_MODEL,
  localWhisper: DEFAULT_WHISPER_MODEL,
  parakeet: DEFAULT_PARAKEET_MODEL,
} as const;
