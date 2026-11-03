//! English transcription on the Apple Neural Engine: Parakeet Ultra and Phonon-2, both derivatives
//! of NVIDIA's Parakeet TDT 0.6B v3, run through the `asr-helper` sidecar (FluidAudio).

use super::sidecar::{self, AsrSidecar, DownloadEvent, DownloadProcess};
use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::fs;
use tokio::sync::{watch, Mutex, RwLock};
use tokio::time::timeout;
use tokio_util::sync::CancellationToken;

/// Encoder weight format, shown as a badge in the model picker.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub enum QuantizationType {
    Int8,       // int8-linear encoder (Parakeet Ultra)
    Palettized, // five learned values per row, kept as fp16 palettes (Phonon-2)
}

/// Model status for Parakeet models
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ModelStatus {
    Available,
    Missing,
    Downloading { progress: u8 },
    Error(String),
    Corrupted { file_size: u64, expected_min_size: u64 },
}

/// Detailed download progress info (MB-based with speed)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadProgress {
    pub downloaded_bytes: u64,
    pub total_bytes: u64,
    pub downloaded_mb: f64,
    pub total_mb: f64,
    pub speed_mbps: f64,
    /// Percentage complete (0-100)
    pub percent: u8,
}

impl DownloadProgress {
    pub fn new(downloaded: u64, total: u64, speed_mbps: f64) -> Self {
        let percent = if total > 0 {
            ((downloaded as f64 / total as f64) * 100.0).min(100.0) as u8
        } else {
            0
        };
        Self {
            downloaded_bytes: downloaded,
            total_bytes: total,
            downloaded_mb: downloaded as f64 / (1024.0 * 1024.0),
            total_mb: total as f64 / (1024.0 * 1024.0),
            speed_mbps,
            percent,
        }
    }
}

/// Information about a Parakeet model
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelInfo {
    pub name: String,
    pub path: PathBuf,
    pub size_mb: u32,
    pub quantization: QuantizationType,
    pub speed: String,
    pub status: ModelStatus,
    pub description: String,
}

struct ModelSpec {
    /// Also the folder FluidAudio stores the model in, so it must match its repo folder name.
    name: &'static str,
    helper_model: &'static str,
    size_mb: u32,
    quantization: QuantizationType,
    speed: &'static str,
    description: &'static str,
}

/// First entry is the default. Sizes are the download sizes FluidAudio reports.
const MODEL_SPECS: &[ModelSpec] = &[
    ModelSpec {
        name: "parakeet-ultra",
        helper_model: "ultra",
        size_mb: 630,
        quantization: QuantizationType::Int8,
        speed: "Ultra Fast (Neural Engine)",
        description: "Most accurate. moondream's Parakeet Ultra, best for English meetings",
    },
    ModelSpec {
        name: "phonon-2",
        helper_model: "phonon2",
        size_mb: 360,
        quantization: QuantizationType::Palettized,
        speed: "Ultra Fast (Neural Engine)",
        description: "Smallest and fastest. Fermion Research's Phonon-2, English only",
    },
];

fn find_spec(model_name: &str) -> Result<&'static ModelSpec> {
    MODEL_SPECS
        .iter()
        .find(|spec| spec.name == model_name)
        .ok_or_else(|| anyhow!("Unsupported Parakeet model: {}", model_name))
}

struct ActiveDownload {
    cancellation: CancellationToken,
    completion: watch::Sender<bool>,
}

#[derive(Debug, thiserror::Error)]
#[error("Download cancelled by user")]
pub(crate) struct DownloadCancelled;

pub(crate) fn is_download_cancelled(error: &anyhow::Error) -> bool {
    error.downcast_ref::<DownloadCancelled>().is_some()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum CancelDownloadOutcome {
    Cancelled,
    Pending,
}

const CANCEL_DOWNLOAD_CLEANUP_TIMEOUT: Duration = Duration::from_secs(5);
const HELPER_MISSING: &str = "asr-helper is not built. Run asr-helper/build.sh, then restart Meetily.";

#[derive(Debug, thiserror::Error)]
pub enum ParakeetEngineError {
    #[error("No model loaded")]
    ModelNotLoaded,
}

pub struct ParakeetEngine {
    models_dir: PathBuf,
    helper: Option<PathBuf>,
    /// The loaded model's name and its running sidecar.
    current: RwLock<Option<(String, AsrSidecar)>>,
    lifecycle: Mutex<()>,
    pub(crate) available_models: Arc<RwLock<HashMap<String, ModelInfo>>>,
    active_downloads: Mutex<HashMap<String, Arc<ActiveDownload>>>,
}

impl ParakeetEngine {
    /// Create a new Parakeet engine with optional custom models directory
    pub fn new_with_models_dir(models_dir: Option<PathBuf>) -> Result<Self> {
        let models_dir = match models_dir {
            Some(dir) => dir.join("parakeet"),
            None if cfg!(debug_assertions) => std::env::current_dir()?.join("models").join("parakeet"),
            None => dirs::data_dir()
                .or_else(dirs::home_dir)
                .ok_or_else(|| anyhow!("Could not find system data directory"))?
                .join("Meetily")
                .join("models")
                .join("parakeet"),
        };
        let helper = sidecar::helper_path();
        if helper.is_none() {
            log::warn!("{}", HELPER_MISSING);
        }
        Self::with_helper(models_dir, helper)
    }

    fn with_helper(models_dir: PathBuf, helper: Option<PathBuf>) -> Result<Self> {
        log::info!("ParakeetEngine using models directory: {}", models_dir.display());
        std::fs::create_dir_all(&models_dir)?;
        Ok(Self {
            models_dir,
            helper,
            current: RwLock::new(None),
            lifecycle: Mutex::new(()),
            available_models: Arc::new(RwLock::new(HashMap::new())),
            active_downloads: Mutex::new(HashMap::new()),
        })
    }

    fn helper(&self) -> Result<&PathBuf> {
        self.helper.as_ref().ok_or_else(|| anyhow!(HELPER_MISSING))
    }

    /// Discover available Parakeet models.
    pub async fn discover_models(&self) -> Result<Vec<ModelInfo>> {
        let mut models = Vec::with_capacity(MODEL_SPECS.len());
        for spec in MODEL_SPECS {
            let path = self.models_dir.join(spec.name);
            let status = match &self.helper {
                None => ModelStatus::Error(HELPER_MISSING.to_string()),
                Some(helper) if sidecar::is_downloaded(helper, spec.helper_model, &path).await => {
                    ModelStatus::Available
                }
                Some(_) => ModelStatus::Missing,
            };
            models.push(ModelInfo {
                name: spec.name.to_string(),
                path,
                size_mb: spec.size_mb,
                quantization: spec.quantization,
                speed: spec.speed.to_string(),
                status,
                description: spec.description.to_string(),
            });
        }

        let active_downloads = self.active_downloads.lock().await;
        let mut available_models = self.available_models.write().await;
        for model in &mut models {
            if active_downloads.contains_key(&model.name) {
                // Keep the progress the running download last reported.
                model.status = match available_models.get(&model.name).map(|m| &m.status) {
                    Some(status @ ModelStatus::Downloading { .. }) => status.clone(),
                    _ => ModelStatus::Downloading { progress: 0 },
                };
            }
        }
        available_models.clear();
        for model in &models {
            available_models.insert(model.name.clone(), model.clone());
        }
        Ok(models)
    }

    /// Load a Parakeet model
    pub async fn load_model(&self, model_name: &str) -> Result<()> {
        let spec = find_spec(model_name)?;
        let _lifecycle = self.lifecycle.lock().await;
        if self.get_current_model().await.as_deref() == Some(model_name) {
            log::info!("Parakeet model {} is already loaded, skipping reload", model_name);
            return Ok(());
        }
        let status = self.available_models.read().await.get(model_name).map(|m| m.status.clone());
        match status {
            Some(ModelStatus::Available) => {}
            Some(ModelStatus::Downloading { .. }) => {
                return Err(anyhow!("Parakeet model {} is currently downloading", model_name))
            }
            Some(ModelStatus::Error(error)) => {
                return Err(anyhow!("Parakeet model {} has error: {}", model_name, error))
            }
            _ => return Err(anyhow!("Parakeet model {} is not downloaded", model_name)),
        }

        // Stop the old sidecar before starting the new one: only one model in memory at a time.
        self.current.write().await.take();
        log::info!("Loading Parakeet model: {}", model_name);
        let sidecar =
            AsrSidecar::start(self.helper()?, spec.helper_model, &self.models_dir.join(spec.name))
                .await
                .map_err(|e| anyhow!("Failed to load Parakeet model {}: {}", model_name, e))?;
        *self.current.write().await = Some((model_name.to_string(), sidecar));
        log::info!("Successfully loaded Parakeet model {} on the Neural Engine", model_name);
        Ok(())
    }

    /// Unload the current model
    pub async fn unload_model(&self) -> bool {
        let _lifecycle = self.lifecycle.lock().await;
        let unloaded = self.current.write().await.take().is_some();
        if unloaded {
            log::info!("Parakeet model unloaded");
        }
        unloaded
    }

    /// Get the currently loaded model name
    pub async fn get_current_model(&self) -> Option<String> {
        self.current.read().await.as_ref().map(|(name, _)| name.clone())
    }

    /// Check if a model is loaded
    pub async fn is_model_loaded(&self) -> bool {
        self.current.read().await.is_some()
    }

    /// Transcribe 16 kHz mono samples using the loaded model
    pub async fn transcribe_audio(&self, audio_data: Vec<f32>) -> Result<String> {
        let mut current = self.current.write().await;
        let (name, sidecar) = current.as_mut().ok_or(ParakeetEngineError::ModelNotLoaded)?;
        log::debug!(
            "Parakeet transcribing {:.1}s with {}",
            audio_data.len() as f64 / 16000.0,
            name
        );
        let result = sidecar.transcribe(&audio_data).await;
        if result.is_err() && sidecar.is_broken() {
            log::error!("asr-helper for {} stopped responding; unloading it", name);
            current.take();
        }
        result.map_err(|e| anyhow!("Parakeet transcription failed: {}", e))
    }

    /// Get the models directory path
    pub async fn get_models_directory(&self) -> PathBuf {
        self.models_dir.clone()
    }

    /// Delete a downloaded (or broken) model
    pub async fn delete_model(&self, model_name: &str) -> Result<String> {
        let spec = find_spec(model_name)?;
        if self.active_downloads.lock().await.contains_key(model_name) {
            return Err(anyhow!("Parakeet model '{}' is downloading", model_name));
        }
        if self.get_current_model().await.as_deref() == Some(model_name) {
            self.unload_model().await;
        }
        let path = self.models_dir.join(spec.name);
        if path.exists() {
            fs::remove_dir_all(&path)
                .await
                .map_err(|e| anyhow!("Failed to delete directory '{}': {}", path.display(), e))?;
        }
        if let Some(model) = self.available_models.write().await.get_mut(model_name) {
            model.status = ModelStatus::Missing;
        }
        Ok(format!("Successfully deleted Parakeet model '{}'", model_name))
    }

    /// Download a Parakeet model (percent-only progress wrapper).
    pub async fn download_model(
        &self,
        model_name: &str,
        progress_callback: Option<Box<dyn Fn(u8) + Send>>,
    ) -> Result<()> {
        let detailed_callback = progress_callback.map(|callback| {
            Box::new(move |progress: DownloadProgress| callback(progress.percent))
                as Box<dyn Fn(DownloadProgress) + Send>
        });
        self.download_model_detailed(model_name, detailed_callback).await
    }

    /// Download a Parakeet model and prepare it for the Neural Engine.
    pub async fn download_model_detailed(
        &self,
        model_name: &str,
        progress_callback: Option<Box<dyn Fn(DownloadProgress) + Send>>,
    ) -> Result<()> {
        let spec = find_spec(model_name)?;
        let helper = self.helper()?.clone();
        let active_download = self.reserve_active_download(model_name).await?;
        self.set_status(model_name, ModelStatus::Downloading { progress: 0 }).await;

        let dir = self.models_dir.join(spec.name);
        let total_bytes = spec.size_mb as u64 * 1_000_000;
        let (result, progress_callback) = self
            .run_download(&helper, spec, &dir, total_bytes, &active_download, progress_callback)
            .await;

        let cancelled = active_download.cancellation.is_cancelled()
            || result.as_ref().err().is_some_and(is_download_cancelled);
        if cancelled {
            // A cancelled download leaves partial files; start clean next time.
            let _ = fs::remove_dir_all(&dir).await;
        }
        let status = if result.is_ok() && !cancelled { ModelStatus::Available } else { ModelStatus::Missing };
        {
            // One critical section, in discover_models' lock order, so a concurrent discovery
            // can't see the owner and overwrite the final status with Downloading.
            let mut active_downloads = self.active_downloads.lock().await;
            let mut available_models = self.available_models.write().await;
            if let Some(model) = available_models.get_mut(model_name) {
                model.status = status;
            }
            active_downloads.remove(model_name);
        }
        active_download.completion.send_replace(true);

        if cancelled {
            return Err(DownloadCancelled.into());
        }
        result?;
        if let Some(callback) = progress_callback {
            callback(DownloadProgress::new(total_bytes, total_bytes, 0.0));
        }
        log::info!("Download completed for Parakeet model: {}", model_name);
        Ok(())
    }

    async fn run_download(
        &self,
        helper: &PathBuf,
        spec: &ModelSpec,
        dir: &PathBuf,
        total_bytes: u64,
        active_download: &ActiveDownload,
        progress_callback: Option<Box<dyn Fn(DownloadProgress) + Send>>,
    ) -> (Result<()>, Option<Box<dyn Fn(DownloadProgress) + Send>>) {
        // The callback is owned (not borrowed) across awaits: it is Send but not Sync.
        let mut process = match DownloadProcess::start(helper, spec.helper_model, dir) {
            Ok(process) => process,
            Err(error) => return (Err(error), progress_callback),
        };
        let started = Instant::now();
        loop {
            let event = tokio::select! {
                _ = active_download.cancellation.cancelled() => return (Err(DownloadCancelled.into()), progress_callback),
                event = process.next_event() => match event {
                    Ok(event) => event,
                    Err(error) => return (Err(error), progress_callback),
                },
            };
            let fraction = match event {
                DownloadEvent::Done => return (Ok(()), progress_callback),
                DownloadEvent::Preparing => {
                    log::info!("Preparing {} for the Neural Engine (one time, up to ~2 min)", spec.name);
                    1.0
                }
                DownloadEvent::Progress(fraction) => fraction,
            };
            let downloaded = (fraction * total_bytes as f64) as u64;
            let mbps = downloaded as f64 / (1024.0 * 1024.0) / started.elapsed().as_secs_f64().max(0.001);
            let mut progress = DownloadProgress::new(downloaded, total_bytes, mbps);
            progress.percent = progress.percent.min(99); // 100 only once the model is ready
            self.set_status(spec.name, ModelStatus::Downloading { progress: progress.percent }).await;
            if let Some(callback) = &progress_callback {
                callback(progress);
            }
        }
    }

    async fn reserve_active_download(&self, model_name: &str) -> Result<Arc<ActiveDownload>> {
        let mut active_downloads = self.active_downloads.lock().await;
        if active_downloads.contains_key(model_name) {
            return Err(anyhow!("Download already in progress for model: {}", model_name));
        }
        let (completion, _) = watch::channel(false);
        let active_download = Arc::new(ActiveDownload { cancellation: CancellationToken::new(), completion });
        active_downloads.insert(model_name.to_string(), Arc::clone(&active_download));
        Ok(active_download)
    }

    async fn set_status(&self, model_name: &str, status: ModelStatus) {
        if let Some(model) = self.available_models.write().await.get_mut(model_name) {
            model.status = status;
        }
    }

    pub async fn cancel_download(&self, model_name: &str) -> Result<CancelDownloadOutcome> {
        self.cancel_download_with_timeout(model_name, CANCEL_DOWNLOAD_CLEANUP_TIMEOUT).await
    }

    async fn cancel_download_with_timeout(
        &self,
        model_name: &str,
        cleanup_timeout: Duration,
    ) -> Result<CancelDownloadOutcome> {
        let active_download = {
            let active_downloads = self.active_downloads.lock().await;
            let Some(active_download) = active_downloads.get(model_name).cloned() else {
                return Ok(CancelDownloadOutcome::Cancelled);
            };
            active_download.cancellation.cancel();
            active_download
        };
        let mut completion = active_download.completion.subscribe();
        if !*completion.borrow() {
            match timeout(cleanup_timeout, completion.changed()).await {
                Ok(Ok(())) => {}
                Ok(Err(_)) => {
                    return Err(anyhow!("Download worker ended before completing cancellation cleanup"))
                }
                Err(_) => return Ok(CancelDownloadOutcome::Pending),
            }
        }
        Ok(CancelDownloadOutcome::Cancelled)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use tempfile::TempDir;

    /// A stand-in for asr-helper that speaks the same protocol without real models.
    /// A model counts as downloaded once `<dir>/ready` exists. A `<dir>.slow` marker makes
    /// download hang (to test cancel); a `<dir>.fail` marker makes serve fail to load.
    const FAKE_HELPER: &str = r#"#!/usr/bin/env python3
import json, os, struct, sys, time
cmd, args = sys.argv[1], sys.argv[2:]
model, d = args[args.index("--model") + 1], args[args.index("--dir") + 1]
out = lambda o: (sys.stdout.write(json.dumps(o) + "\n"), sys.stdout.flush())
if cmd == "status":
    out({"downloaded": os.path.exists(os.path.join(d, "ready"))})
elif cmd == "download":
    os.makedirs(d, exist_ok=True)
    out({"progress": 0.5})
    if os.path.exists(d + ".slow"):
        time.sleep(30)
    out({"preparing": True})
    open(os.path.join(d, "ready"), "w").close()
    out({"done": True})
elif cmd == "serve":
    if os.path.exists(d + ".fail"):
        out({"error": "no Neural Engine plan"}); sys.exit(1)
    out({"ready": True})
    while True:
        header = sys.stdin.buffer.read(4)
        if len(header) < 4: break
        n = struct.unpack("<I", header)[0]
        sys.stdin.buffer.read(n * 4)
        out({"text": f"{model}:{n}"})
"#;

    fn engine_with_fake_helper() -> (TempDir, ParakeetEngine) {
        let temp = tempfile::tempdir().unwrap();
        let helper = temp.path().join("fake-asr-helper");
        std::fs::write(&helper, FAKE_HELPER).unwrap();
        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();
        let engine = ParakeetEngine::with_helper(temp.path().join("models"), Some(helper)).unwrap();
        (temp, engine)
    }

    async fn status(engine: &ParakeetEngine, name: &str) -> ModelStatus {
        engine.available_models.read().await.get(name).unwrap().status.clone()
    }

    #[tokio::test]
    async fn discovery_lists_both_models_with_ultra_as_default() {
        let (_temp, engine) = engine_with_fake_helper();
        let models = engine.discover_models().await.unwrap();
        let names: Vec<_> = models.iter().map(|m| m.name.as_str()).collect();
        assert_eq!(names, ["parakeet-ultra", "phonon-2"]);
        assert!(models.iter().all(|m| matches!(m.status, ModelStatus::Missing)));
        assert_eq!(crate::config::DEFAULT_PARAKEET_MODEL, names[0]);
    }

    #[tokio::test]
    async fn missing_helper_is_reported_instead_of_offering_downloads() {
        let temp = tempfile::tempdir().unwrap();
        let engine = ParakeetEngine::with_helper(temp.path().join("models"), None).unwrap();
        let models = engine.discover_models().await.unwrap();
        assert!(models.iter().all(|m| matches!(&m.status, ModelStatus::Error(e) if e.contains("asr-helper"))));
        assert!(engine.download_model("phonon-2", None).await.is_err());
    }

    #[tokio::test]
    async fn download_reports_progress_then_loads_and_transcribes() {
        let (_temp, engine) = engine_with_fake_helper();
        engine.discover_models().await.unwrap();
        let seen = Arc::new(std::sync::Mutex::new(Vec::new()));
        let sink = Arc::clone(&seen);
        engine
            .download_model("phonon-2", Some(Box::new(move |p| sink.lock().unwrap().push(p))))
            .await
            .unwrap();
        assert_eq!(*seen.lock().unwrap(), [50, 99, 100]);
        assert!(matches!(status(&engine, "phonon-2").await, ModelStatus::Available));

        engine.load_model("phonon-2").await.unwrap();
        assert_eq!(engine.get_current_model().await.as_deref(), Some("phonon-2"));
        assert_eq!(engine.transcribe_audio(vec![0.0; 1600]).await.unwrap(), "phonon2:1600");
        assert!(engine.unload_model().await);
        assert!(!engine.is_model_loaded().await);
    }

    #[tokio::test]
    async fn cancelling_a_download_kills_it_and_cleans_up() {
        let (temp, engine) = engine_with_fake_helper();
        engine.discover_models().await.unwrap();
        let dir = temp.path().join("models/parakeet-ultra");
        std::fs::write(dir.with_extension("slow"), b"").unwrap();
        let engine = Arc::new(engine);
        let download = tokio::spawn({
            let engine = Arc::clone(&engine);
            async move { engine.download_model("parakeet-ultra", None).await }
        });
        while !dir.exists() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert_eq!(engine.cancel_download("parakeet-ultra").await.unwrap(), CancelDownloadOutcome::Cancelled);
        assert!(is_download_cancelled(&download.await.unwrap().unwrap_err()));
        assert!(!dir.exists());
        assert!(matches!(status(&engine, "parakeet-ultra").await, ModelStatus::Missing));
    }

    #[tokio::test]
    async fn load_errors_from_the_helper_reach_the_caller() {
        let (temp, engine) = engine_with_fake_helper();
        engine.discover_models().await.unwrap();
        engine.download_model("parakeet-ultra", None).await.unwrap();
        std::fs::write(temp.path().join("models/parakeet-ultra.fail"), b"").unwrap();
        let error = engine.load_model("parakeet-ultra").await.unwrap_err().to_string();
        assert!(error.contains("no Neural Engine plan"), "{error}");
        assert!(!engine.is_model_loaded().await);
        assert!(engine.load_model("not-a-model").await.is_err());
    }

    #[tokio::test]
    async fn delete_unloads_and_removes_the_model() {
        let (temp, engine) = engine_with_fake_helper();
        engine.discover_models().await.unwrap();
        engine.download_model("parakeet-ultra", None).await.unwrap();
        engine.load_model("parakeet-ultra").await.unwrap();
        engine.delete_model("parakeet-ultra").await.unwrap();
        assert!(!engine.is_model_loaded().await);
        assert!(!temp.path().join("models/parakeet-ultra").exists());
        assert!(matches!(status(&engine, "parakeet-ultra").await, ModelStatus::Missing));
    }

    /// Real models through the real helper (needs network on first run):
    /// cargo test --lib parakeet_engine::parakeet_engine::tests::real_helper -- --ignored --nocapture
    #[tokio::test]
    #[ignore]
    async fn real_helper_smoke() {
        let temp = tempfile::tempdir().unwrap();
        let engine = ParakeetEngine::with_helper(temp.path().to_path_buf(), sidecar::helper_path()).unwrap();
        engine.discover_models().await.unwrap();
        for spec in MODEL_SPECS {
            engine.download_model(spec.name, None).await.unwrap();
            engine.load_model(spec.name).await.unwrap();
            println!("{}: {:?}", spec.name, engine.transcribe_audio(vec![0.0; 16_000]).await.unwrap());
        }
    }
}
