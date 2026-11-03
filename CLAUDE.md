# CLAUDE.md

Guidance for Claude Code in this repository.

## Project

**Meety** is a privacy-first meeting assistant: it records microphone and system audio, transcribes live on the Mac, and summarizes with a local or chosen LLM provider. It is a native **Swift 6 + AppKit** app for macOS 26 on Apple Silicon, in `macos/`. The old Tauri app (Rust + Next.js) was removed; `docs/SWIFT_PORT_PLAN.md` records the port's decisions (D1–D10) and what was dropped. `backend/` is the archived Python/FastAPI backend: unsupported, don't build on it.

## Commands

```bash
cd macos
scripts/test.sh                 # swift test in MeetyKit, then a Debug build of the app
scripts/build.sh                # xcodegen + Debug build (CONFIG=Release for Release)
scripts/package.sh              # signed Release build into macos/build/Meety.app (see README)
(cd MeetyKit && swift test --filter <Suite>)
```

XcodeGen is at `~/.local/bin/xcodegen`; `Meety.xcodeproj` is generated, never edit it. `xcodebuild` sometimes prints "failed with exit code 0"; that is harmless. macOS has no `timeout`; use `perl -e 'alarm N; exec @ARGV' <cmd>`.

## Layout

```
macos/
  project.yml   Meety.app target: Info.plist keys, entitlements, main-actor-by-default, hardened runtime
  App/          AppKit UI built in code: AppDelegate, MainMenu, StatusItem, Notifier, AppModel,
                Design/ (tokens, type, house views), Main/, Recording/, Meeting/, Settings/, Onboarding/
  MeetyKit/     SwiftPM package, no AppKit
    Sources/Core/           GRDB Store, records, Settings (UserDefaults), Keychain, Paths, Download
    Sources/Audio/          devices, mic capture, system tap, DSP, ring buffer, mixer, RecordingWriter
    Sources/Transcription/  engine protocol, Parakeet (FluidAudio), Whisper (whisper.cpp), VAD,
                            RecordingSession actor, Recorder (@Observable), offline import/retranscribe
    Sources/Summary/        LLM clients, built-in llama.cpp, templates, processor, SummaryService
    Tests/                  Swift Testing, one target per module; audio fixtures in Tests/Fixtures
```

## Conventions

- **AppKit only, in code** (no SwiftUI, storyboards or XIBs). Reuse the house views in `App/Design/` (`NSButton.meety`, `CardView`, `EmptyStateView`, `NSColor.meety*`, `Typography`, `Metrics`).
- **State:** `AppModel` and the MeetyKit models are `@Observable`; views bind with `track { }` (in `AppModel.swift`), a `withObservationTracking` loop.
- **Concurrency:** Swift 6 strict. The app target is main-actor by default; MeetyKit APIs are `nonisolated`, heavy work is `@concurrent`. Real-time audio callbacks never allocate, lock, log or touch actors: they write into the `Synchronization.Atomic` SPSC ring buffer (D7).
- **Dependencies:** FluidAudio 0.18.2, GRDB, llama.cpp and whisper.cpp xcframeworks. Everything else comes from the SDK. Don't add packages.
- **Models** compile and warm when downloaded or selected, with progress, never at record time (D9). The Core ML ANE cache is keyed by bundle id, so keep `com.meetily.ai`.
- **Tests first** for logic in MeetyKit. UI is checked by running the app. Real hardware/model tests are opt-in: `MEETY_REAL_DB`, `MEETY_REAL_MODELS`, `MEETY_REAL_WHISPER`, `MEETY_REAL_LLAMA`, `MEETY_REAL_DEVICES`, `MEETY_PERF`.
- Logging: `os.Logger` with subsystem `com.meetily.ai` and a category per area.

## Data safety

- The app shares `~/Library/Application Support/com.meetily.ai/` (`meeting_minutes.sqlite`, `models/`) with the user's installed app. **Never write to the real database during development.** Tests build temp DBs from `MeetyKit/Sources/Core/Resources/migrations`. Schema changes must be additive (D3).
- Dev runs: copy the DB into a scratch dir and launch with `MEETY_DATA_DIR=<dir>`. That also switches preferences to the `com.meetily.ai.dev` defaults suite and keys to the `com.meetily.ai.dev.api-keys` Keychain service. A `models` symlink to the real models dir makes model deletes and downloads real.
- Window autosave frames still go to the real `com.meetily.ai` defaults domain; delete `NSWindow Frame MainWindow`, `NSWindow Frame SettingsWindow` and `NSSplitView Subview Frames MainSplit` after dev runs.
- Don't install over `/Applications` without asking: `package.sh` only installs with `INSTALL=1`.

## Checking UI without a person (Debug builds)

`MEETY_SNAPSHOT=/path.png` (+ `MEETY_SNAPSHOT_DELAY`) renders the front window to a PNG and exits. `MEETY_DEMO_RECORDING=1` records a synthetic tone with a canned engine. `MEETY_OPEN_MEETING=<id>`, `MEETY_SETTINGS_TAB=0…4`, `MEETY_ONBOARDING=1`, `MEETY_IMPORT=<audio>` open those screens. Each launch logs `window visible N ms after process start` (category `launch`).

## Platform notes

- Microphone, system audio capture (`NSAudioCaptureUsageDescription`) and notifications need TCC grants that can't be given unattended.
- System audio uses a Core Audio process tap and a private aggregate device; no virtual audio driver.
- Release builds must be signed with a real identity: ad-hoc signed embedded frameworks fail library validation under the hardened runtime.
