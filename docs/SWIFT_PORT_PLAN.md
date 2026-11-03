# Meety native port: Swift + AppKit

Goal: replace the Tauri app (Rust core + Next.js UI + `asr-helper` and `llama-helper` sidecars) with one native macOS app written in Swift, with an AppKit UI and no SwiftUI or web views. Feature parity with the current app, minus the items under "Dropped".

Branch: `enhance/swift-port`. New code lives in `macos/`. The Tauri app stays buildable until slice 24 deletes it.

## Decisions (defaults, veto before the slice that needs them)

| # | Decision | Why |
|---|---|---|
| D1 | macOS 26 minimum, Apple Silicon only | Personal fork on an M5. Core Audio process taps, TextKit 2, `NSView.displayLink`, Swift 6.2 all available. |
| D2 | Bundle id stays `com.meetily.ai` | Same `~/Library/Application Support/com.meetily.ai/` data dir, so no data migration. The Core ML ANE compile cache is keyed by bundle id, so Debug and Release builds share the prepared Phonon-2/Ultra programs (the thing that broke in the Tauri app). |
| D3 | Same SQLite file (`meeting_minutes.sqlite`) and the same schema; no schema changes until cutover | Both apps can run against the same data during the port. WAL mode covers concurrent opens. Any later Swift migration must be additive. |
| D4 | XcodeGen `project.yml` + one local SwiftPM package `MeetyKit` | Diffable project file (XcodeGen is installed). Logic tests run with `swift test`, no simulator or app launch. |
| D5 | AppKit only, UI built in code: no SwiftUI, storyboards or XIBs | Performance as asked, and diffable UI. |
| D6 | Swift 6 language mode, strict concurrency. App target is main-actor by default. | Data-race safety across capture, ASR and UI. |
| D7 | Real-time audio callbacks never allocate, lock, log or touch Swift actors. They write into a lock-free SPSC ring buffer built on the stdlib `Synchronization.Atomic`. | Avoid glitches. |
| D8 | Dependencies: FluidAudio (pinned `0.18.2` as in `asr-helper`), GRDB.swift, llama.cpp xcframework (binary target), and the Whisper engine chosen in slice 10. Nothing else. | Everything else is in the SDK: AVFoundation, Core Audio, Accelerate, NaturalLanguage, UserNotifications, Security. |
| D9 | Models are compiled and warmed when downloaded or selected, with visible progress, never at record time | Phonon-2's cold ANE compile takes 3+ minutes. See memory `ane-compile-cache`. |
| D10 | API keys move to the Keychain. They are copied from the `settings` table on first run, and the DB columns are left alone until cutover. | Today they sit in plaintext SQLite. Leaving the columns untouched keeps the Tauri app working during the port. |

## Dropped (not ported)

- PostHog analytics (`analytics/`, 31 commands, `analytics.json`)
- Tauri updater, licensing table, Pro license, Windows, Linux, CUDA and Vulkan builds
- Legacy/Homebrew database import (`database/commands.rs` import flow, `DatabaseImport/`)
- Console toggle, the parallel-processing command set, the audio backend selector (Core Audio taps is the only backend), `audio_v2/`, `*_old*.rs`
- ffmpeg sidecar and checkpoint merge/recovery. Recording writes a fragmented MP4 with `AVAssetWriter`, which stays playable after a crash, so a recovery flow isn't needed.
- Gemini key field (UI only, no backend), cloud STT stubs (commented out today)
- Speaker diarization: `speaker` stays the source label (microphone/system), as today

## Target layout

```
macos/
  project.yml                 XcodeGen: Meety.app target, entitlements, Info.plist
  App/                        AppKit UI only (Meety target)
    AppDelegate.swift, MainMenu.swift, StatusItem.swift
    Design/                   colors (asset catalog), type, house views
    Main/                     window, split view, sidebar
    Recording/, Meeting/, Settings/, Onboarding/, Import/
  MeetyKit/                   SwiftPM package, no AppKit imports
    Sources/Core/             models, GRDB store, settings, keychain, paths
    Sources/Audio/            devices, mic capture, system tap, DSP, mixer, writer
    Sources/Transcription/    engine protocol, FluidAudio, Whisper, VAD, session
    Sources/Summary/          LLM clients, built-in llama, templates, pipeline
    Tests/                    Swift Testing, per target
  scripts/build.sh, test.sh, package.sh
```

UI talks to MeetyKit through `@MainActor @Observable` model objects observed with `withObservationTracking`. Tauri commands become async methods and events become `AsyncStream`s. No IPC layer.

## Testing rules

- Each slice starts with red tests in `MeetyKit/Tests`, then makes them pass.
- Where Rust has unit tests that encode behavior (`summary/processor.rs`, `summary/service.rs`, `audio/pipeline.rs` mixing, `parakeet_engine`, `recording_preferences.rs`), port them 1:1 first. They are the parity spec.
- Real-model tests are opt-in through an env var (`MEETY_REAL_MODELS=1`), mirroring `real_helper_smoke` / `real_whisper_smoke`. Use the existing `frontend/src-tauri/tests/fixtures` audio.
- UI slices test their non-trivial controller logic. Views are checked by running the app.
- `scripts/test.sh` = `swift test` in `MeetyKit` + `xcodebuild build`. Each slice ends green, then gets committed and pushed.

## Phase 0: Foundation (session 1)

**S1. Scaffold.** `macos/project.yml`, `MeetyKit` package with the four targets, `AppDelegate` with a code-built `NSWindow` and main menu, entitlements and Info.plist keys copied from `frontend/src-tauri` (`NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription`, audio-input). `scripts/build.sh`, `scripts/test.sh`. Done when an empty window launches as `com.meetily.ai` and one test passes.

**S2. Database.** GRDB `DatabasePool` on the existing file path. Records and repositories for `meetings`, `transcripts`, `summary_processes`, `transcript_chunks`, `meeting_notes`, `settings`, `transcript_settings`. Leave `_sqlx_migrations` and schema alone (D3). Tests build a DB by applying the 10 files in `frontend/src-tauri/migrations` in order, then cover CRUD, cascade delete, and transcript search (port `api_search_transcripts` semantics). Done when it reads the real DB read-only in an opt-in test.

**S3. Settings, secrets, paths.** Read `preferences.json`, `recording_preferences.json` and `onboarding-status.json` into a `Settings` model backed by `UserDefaults`, imported once. Keychain store for provider API keys, imported from `settings` (D10). Paths: models dir, recordings folder default, meeting folder naming (port `sanitize_filename` and its tests).

## Phase 1: Audio (session 2)

**S4. Devices + microphone capture.** Core Audio HAL device listing, default-device and device-list listeners (port the events: device switched, mic unavailable, recovered). Mic capture via `AVAudioEngine` input node, with the device set on its audio unit. Output: 48 kHz mono float frames into the ring buffer (D7). Level metering (RMS/peak) published at ≤60 Hz. Permission request helper.

**S5. System audio capture.** Core Audio process tap (`CATapDescription`, global, excluding Meety's own process) + private aggregate device, as `audio/capture/core_audio.rs` does via cidre. `NSAudioCaptureUsageDescription` permission flow. Handle output-device changes by rebuilding the tap. Opt-in test: tap produces non-silent frames while `afplay` plays a fixture.

**S6. Mic DSP chain.** Port the per-mic chain from `pipeline.rs`: high-pass filter (vDSP biquad), noise suppression, EBU R128 normalize to −23 LUFS (K-weighting + gating with vDSP). Noise suppression: try Apple voice processing on the input node first, because it adds echo cancellation for speaker bleed (other-audio ducking set to minimum). If it degrades the mic too much on the fixtures, vendor RNNoise as a C target (what `nnnoiseless` ports). Tests: LUFS of a known tone within ±0.5 LU, high-pass attenuation at 50 Hz.

**S7. Mixer + recording writer.** Port `AudioMixerRingBuffer` + `ProfessionalAudioMixer`: 50 ms aligned windows, RMS ducking, clip prevention, using Accelerate. Port the mixing tests first. `RecordingWriter`: `AVAssetWriter` AAC to `audio.mp4` with `movieFragmentInterval` (crash-safe), pause/resume, plus `metadata.json` and `transcripts.json` in the same meeting-folder layout as `recording_saver.rs`. Test: write 10 s of fixture, kill mid-write in a subprocess test, confirm the file still opens.

## Phase 2: Transcription (session 3)

**S8. Engine protocol + Parakeet in-process.** `TranscriptionEngine` protocol (`prepare(progress:)`, `transcribe(samples:) -> [Segment]`). FluidAudio Parakeet Ultra + Phonon-2 called directly, replacing `asr-helper` and its pipe protocol. Model catalog, download with progress/cancel/retry/delete into the existing `models/parakeet` dir, so models already downloaded are reused. `prepare` compiles and warms on the ANE with progress (D9). Port the sub-0.3 s padding rule and the parakeet tests.

**S9. VAD + live transcription session.** FluidAudio's Silero VAD replaces `silero_rs`. `RecordingSession` actor: capture → DSP → mixer → writer, and in parallel the 16 kHz VAD segmenter → ASR queue → segments with `audio_start_time`/`audio_end_time` → DB + `AsyncStream` for the UI. Back-pressure warnings (the old `chunk-drop-warning`), startup progress, stop = drain queue, then save the meeting. Tests drive the session from a file-backed source protocol with a fixture WAV.

**S10. Whisper for Tagalog/Taglish.** Gate first: on the user's own Taglish recordings, compare WhisperKit large-v3-turbo (full ANE) with the whisper.cpp xcframework using the existing `large-v3-turbo-q8_0` + Core ML encoder (validated accuracy, models already on disk). Pick WhisperKit if WER is within 1 point (lighter on the machine), otherwise whisper.cpp. Implement the winner behind the same protocol. Language preference: auto / en / tl routes to an engine.

**S11. Import + retranscription.** `AVAssetReader` decode → 16 kHz mono → the same offline pipeline, with progress and cancel. `shortcut:` formats are whatever AVFoundation decodes (mp3, m4a/aac, wav, flac, caf); ogg/webm are not supported until needed. Retranscribe an existing meeting with another model or language, replacing its transcripts in one transaction.

## Phase 3: Summaries (session 4)

**S12. LLM clients.** One OpenAI-compatible client (OpenAI, Groq, OpenRouter, Ollama `/v1`, custom OpenAI endpoint), an Anthropic Messages client, and ChatGPT via the Codex CLI subprocess as in `llm_client.rs`. Model listing per provider, Ollama pull/delete, the custom-endpoint connection test. Tests use a stub `URLProtocol`.

**S13. Built-in AI.** llama.cpp xcframework in-process on Metal, replacing `llama-helper`. Port the model catalog and the download/delete/ready checks from `summary_engine/models.rs` and `model_manager.rs` into the existing `models/summary` dir. Generation runs off the main actor and can be cancelled.

**S14. Summary pipeline.** Port `processor.rs` (markdown cleaning, token estimate, chunking with overlap, title extraction), `service.rs` (background process, cancel, `result_backup`, the `markdown` + `english_cache` result JSON), templates (bundle the 6 JSON files) and language detection (`NLLanguageRecognizer` replaces `whatlang`). Port all of their Rust tests first. Stored result JSON stays byte-compatible with what the Tauri app reads (D3).

## Phase 4: AppKit UI (sessions 5–6)

**S15. Design system.** Meety tokens from `frontend/src/app/globals.css` (`--ground`, `--signal`, neutrals, destructive) as asset-catalog colors with light/dark variants. Type scale, `MeetyMark` drawn with `CAShapeLayer`, and a small set of house views (primary/secondary button, card, empty state). Layer-backed views throughout.

**S16. Main window shell.** `NSSplitViewController`: sidebar (view-based `NSOutlineView` of meetings grouped by date, `NSSearchField` over transcript search, rename/delete through the context menu and keyboard) and a content router (Home, Meeting). Window frame autosave, full keyboard navigation.

**S17. Home + recording screen.** Record/pause/stop, mic and system device pop-ups, level meters on `CALayer` driven by `NSView.displayLink`, a live transcript in a view-based `NSTableView` (cell reuse gives the virtualization the React view needed), startup progress and status overlays, editable meeting name, the recording-consent notice.

**S18. Meeting details.** Split view: transcript table (timestamps, source label, click to seek in an `AVPlayer`-backed audio bar), and a summary pane with a TextKit 2 `NSTextView` markdown editor (live styling for headings, bullets, bold; stores markdown). Notes tab in the same editor (`meeting_notes.notes_markdown`). Generate / regenerate / cancel, template and model pickers, copy and export, open folder, retranscribe sheet.
`shortcut:` markdown-only editing drops BlockNote's block JSON (`notes_json` is left unwritten). Upgrade only if tables or embeds are ever needed.

**S19. Settings window.** `NSTabViewController` with toolbar tabs: General (language, recordings folder, notifications), Recording (devices, preferences), Transcription (Parakeet + Whisper model lists: download, progress, prepare, delete, open folder), Summary (provider, model, keys in Keychain, endpoint, built-in models, Ollama models), About.

**S20. Onboarding.** First-launch window driven by the imported onboarding status: welcome, permissions (microphone, system audio capture, notifications) with live status, model download + prepare with progress.

**S21. Menu bar, notifications, import UX.** `NSStatusItem` with recording state and start/stop/open. `UNUserNotificationCenter` for recording started/stopped and summary ready, honoring the notification settings. Main-menu shortcuts. Drag-and-drop audio import onto the window, plus File › Import.

## Phase 5: Cutover (session 7)

**S22. Parity + performance pass.** Record the same one-hour meeting in both apps. Targets: window visible < 300 ms after a warm launch; ~0% CPU idle; lower CPU and memory than the Tauri app while recording with live Parakeet, measured in Instruments (Time Profiler, Allocations, Energy). Fix regressions, walk the parity checklist below.

**S23. Packaging.** `scripts/package.sh`: Release build, Developer ID signing with hardened runtime, notarization if a Developer ID is set up (otherwise a local signed build), install to `/Applications/Meety.app`. Expect the permission prompts and a one-time ANE recompile once the signature changes.

**S24. Remove the Tauri app.** *Ask before starting.* Delete `frontend/`, `asr-helper/`, `llama-helper/`, the root Cargo workspace and `target/`, and decide whether `backend/` goes too. Clear the plaintext key columns (D10). Rewrite `README.md` and `CLAUDE.md` for the Swift app. Then the branch review per the global instructions (`codex exec -m gpt-6.1-sol ... service_tier="default"`), `Review:` fix commits, push, stop.

## Parity checklist (from the Tauri command and event surface)

- [ ] Record with mic + system, pause/resume, stop and save; device switching and mic loss mid-recording
- [ ] Live transcript with timestamps; transcription errors and warnings surfaced
- [ ] Parakeet Ultra, Phonon-2, Whisper turbo: download, cancel, retry, delete, prepare, select
- [ ] Language preference routing (auto/en/tl)
- [ ] Meetings list, search, rename, delete, open folder
- [ ] Transcript view with audio playback and seek
- [ ] Summary: every provider, templates, custom prompt, summary language, cancel, regenerate, backup restore
- [ ] Built-in AI model download and generation
- [ ] Notes per meeting
- [ ] Import audio file; retranscribe a meeting
- [ ] Recordings folder preference; notification settings
- [ ] Onboarding and permissions; menu bar item
- [ ] Existing meetings, summaries, models and settings from the Tauri app all show up untouched
