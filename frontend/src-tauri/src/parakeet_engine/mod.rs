//! English speech recognition on the Apple Neural Engine (Parakeet Ultra, Phonon-2).
//!
//! - `parakeet_engine`: model catalog, download/load lifecycle, transcription
//! - `sidecar`: the `asr-helper` Swift process that runs the models through FluidAudio
//! - `commands`: Tauri command interface for frontend integration

pub mod parakeet_engine;
pub mod sidecar;
pub mod commands;

pub use parakeet_engine::{ParakeetEngine, ParakeetEngineError, QuantizationType, ModelInfo, ModelStatus, DownloadProgress};
pub use commands::*;
