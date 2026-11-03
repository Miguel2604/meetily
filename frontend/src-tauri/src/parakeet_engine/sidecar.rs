//! The `asr-helper` Swift sidecar (asr-helper/ at the repo root): Parakeet Ultra and Phonon-2 on the
//! Apple Neural Engine through FluidAudio. Protocol: see asr-helper/Sources/asr-helper/main.swift.

use anyhow::{anyhow, Result};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};

/// Covers a cold Neural Engine compile, should the download-time warm-up have been skipped.
const LOAD_TIMEOUT: Duration = Duration::from_secs(300);
const TRANSCRIBE_TIMEOUT: Duration = Duration::from_secs(120);

/// The sidecar binary, or `None` when it isn't built.
pub fn helper_path() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("MEETILY_ASR_HELPER") {
        return Some(PathBuf::from(path)).filter(|p| p.is_file());
    }
    let exe_dir = std::env::current_exe().ok()?.parent()?.to_path_buf();
    let mut candidates = vec![
        exe_dir.join("asr-helper"),
        exe_dir.join("asr-helper-aarch64-apple-darwin"),
    ];
    if cfg!(debug_assertions) {
        candidates.push(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../asr-helper/.build/release/asr-helper"),
        );
    }
    candidates.into_iter().find(|p| p.is_file())
}

fn spawn(helper: &Path, command: &str, model: &str, dir: &Path) -> Result<Child> {
    Command::new(helper)
        .args([command, "--model", model, "--dir"])
        .arg(dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| anyhow!("Failed to start asr-helper: {}", e))
}

/// An error the helper reported for one request; the protocol stays in sync after it.
#[derive(Debug, thiserror::Error)]
#[error("{0}")]
struct HelperError(String);

async fn next_json(lines: &mut Lines<BufReader<ChildStdout>>) -> Result<Value> {
    let line = lines
        .next_line()
        .await?
        .ok_or_else(|| anyhow!("asr-helper exited unexpectedly"))?;
    let value: Value =
        serde_json::from_str(&line).map_err(|e| anyhow!("Bad asr-helper output {:?}: {}", line, e))?;
    match value.get("error").and_then(Value::as_str) {
        Some(error) => Err(HelperError(error.to_string()).into()),
        None => Ok(value),
    }
}

fn stdout_lines(child: &mut Child) -> Lines<BufReader<ChildStdout>> {
    BufReader::new(child.stdout.take().expect("piped stdout")).lines()
}

pub async fn is_downloaded(helper: &Path, model: &str, dir: &Path) -> bool {
    let Ok(mut child) = spawn(helper, "status", model, dir) else { return false };
    let mut lines = stdout_lines(&mut child);
    let downloaded = next_json(&mut lines)
        .await
        .ok()
        .and_then(|v| v.get("downloaded").and_then(Value::as_bool))
        .unwrap_or(false);
    let _ = child.wait().await;
    downloaded
}

pub enum DownloadEvent {
    /// Fraction complete, 0..=1.
    Progress(f64),
    /// Files are down; the helper is building the Neural Engine plan.
    Preparing,
    Done,
}

/// A running `asr-helper download`. Dropping it kills the process.
pub struct DownloadProcess {
    child: Child,
    lines: Lines<BufReader<ChildStdout>>,
}

impl DownloadProcess {
    pub fn start(helper: &Path, model: &str, dir: &Path) -> Result<Self> {
        let mut child = spawn(helper, "download", model, dir)?;
        let lines = stdout_lines(&mut child);
        Ok(Self { child, lines })
    }

    pub async fn next_event(&mut self) -> Result<DownloadEvent> {
        let value = next_json(&mut self.lines).await?;
        if value.get("done").is_some() {
            let _ = self.child.wait().await;
            return Ok(DownloadEvent::Done);
        }
        if value.get("preparing").is_some() {
            return Ok(DownloadEvent::Preparing);
        }
        let fraction = value
            .get("progress")
            .and_then(Value::as_f64)
            .ok_or_else(|| anyhow!("Unexpected asr-helper download output: {}", value))?;
        Ok(DownloadEvent::Progress(fraction.clamp(0.0, 1.0)))
    }
}

/// A running `asr-helper serve` with the model loaded. Dropping it kills the process.
pub struct AsrSidecar {
    _child: Child,
    stdin: ChildStdin,
    lines: Lines<BufReader<ChildStdout>>,
    broken: bool,
}

impl AsrSidecar {
    pub async fn start(helper: &Path, model: &str, dir: &Path) -> Result<Self> {
        let mut child = spawn(helper, "serve", model, dir)?;
        let stdin = child.stdin.take().expect("piped stdin");
        let mut lines = stdout_lines(&mut child);
        tokio::time::timeout(LOAD_TIMEOUT, next_json(&mut lines))
            .await
            .map_err(|_| anyhow!("Model took too long to load"))??;
        Ok(Self { _child: child, stdin, lines, broken: false })
    }

    /// True after a timeout or I/O failure, when replies may no longer match requests.
    pub fn is_broken(&self) -> bool {
        self.broken
    }

    /// Transcribe 16 kHz mono samples.
    pub async fn transcribe(&mut self, samples: &[f32]) -> Result<String> {
        let result = self.round_trip(samples).await;
        if let Err(error) = &result {
            self.broken = !error.is::<HelperError>();
        }
        result
    }

    async fn round_trip(&mut self, samples: &[f32]) -> Result<String> {
        let mut frame = Vec::with_capacity(4 + samples.len() * 4);
        frame.extend_from_slice(&(samples.len() as u32).to_le_bytes());
        for sample in samples {
            frame.extend_from_slice(&sample.to_le_bytes());
        }
        self.stdin.write_all(&frame).await?;
        self.stdin.flush().await?;
        let value = tokio::time::timeout(TRANSCRIBE_TIMEOUT, next_json(&mut self.lines))
            .await
            .map_err(|_| anyhow!("Transcription timed out"))??;
        Ok(value.get("text").and_then(Value::as_str).unwrap_or_default().to_string())
    }
}
