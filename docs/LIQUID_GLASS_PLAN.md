# Liquid Glass redesign plan

Goal: redesign every Meety screen in the macOS 26 design language. Liquid Glass goes on the navigation and control layer: toolbar, sidebar, floating controls, popovers. Content sits under it and stays plain. The app should look and behave like a first-party Apple app (Voice Memos, Notes, Journal). The look changes, the features stay. MeetyKit doesn't change, except one summary autosave helper (G9).

Branch: `redesign/liquid-glass`, off `enhance/swift-port`. Still AppKit, built in code (D5). No SwiftUI, no new dependencies (D8).

## Decisions

| # | Decision | Why |
|---|---|---|
| G1 | Glass only on the control layer. Transcripts, summaries and notes never sit on glass. | Apple's rule for Liquid Glass. Text on glass is hard to read. |
| G2 | Use the stock glass first: `NSToolbar` items, `NSSplitViewItem` sidebar and inspector, `.glass` bezel, `NSSearchToolbarItem`. Use `NSGlassEffectView` / `NSGlassEffectContainerView` only for the custom floating bars. | The system handles Reduce Transparency, Increase Contrast, tinting, dark mode and focus for free. Less code. |
| G3 | Stay on macOS 26.0. Skip 26.1+ APIs (`NSScrollEdgeEffectStyle`) and 27 APIs (`effectIsInteractive`). Wrap any use in `#available`. | The SDK on this Mac is 27.2, so newer APIs compile but would crash a 26.0 install. The automatic scroll edge effect under the toolbar already works on 26.0. |
| G4 | Colors: system semantic colors plus one `AccentColor` asset (Meety blue `#5b93e8`). Recording uses `systemRed`. The 14 ledger tokens are mapped to system colors first, then deleted as screens are rebuilt. | Glass changes how colors look underneath it. Fixed fills fight vibrancy. Red means recording on Apple platforms. |
| G5 | Type: `NSFont.preferredFont(forTextStyle:)` (largeTitle, title1–3, headline, body, callout, subheadline, footnote, caption). Monospaced digits stay for timestamps. | Same scale and weights as Apple's apps. |
| G6 | Corners follow their container: layout guides from `layoutGuide(for: .safeArea(cornerAdaptation:))`, capsules for floating bars. No fixed 8 pt radius. | Liquid Glass corners are concentric with the window. |
| G7 | Search moves from the sidebar into an `NSSearchToolbarItem`. It still filters the sidebar and still searches transcripts. | Notes and Mail do this on 26. The sidebar gets lighter. |
| G8 | The Home screen drops its "Recent meetings" list. The sidebar already shows them. | The same list twice is noise. The hero Record button gets the room. |
| G9 | Summary edits autosave with a 1 s debounce, the same as notes. The Save button goes away. ⌘S still saves. | Apple apps don't have Save buttons for documents. |
| G10 | Each screen gets a light and a dark snapshot before its slice is committed. Snapshots go in `docs/redesign/` and are linked from the phase report. | UI is checked by running the app (CLAUDE.md). The snapshots are the before/after record. |

## Target design

**Window chrome.** A unified `NSToolbar` (there isn't one today), icon-only, glass items. From left to right:
- sidebar toggle and tracking separator
- window title and subtitle per route: "Meety" with "12 meetings" on Home; the meeting title with its date on a meeting
- flexible space
- the route's action group (see below), merged into one glass capsule by `NSToolbarItemGroup`
- search (`NSSearchToolbarItem`)
- **Record**: `style = .prominent`, `backgroundTintColor = .systemRed`. While a recording runs it turns into a stop button with the elapsed time.

Every toolbar item also has a menu command, and items are enabled by the same `validateMenuItem` logic, so the keyboard and VoiceOver work the same as now.

**Sidebar.** Floating glass sidebar (the default on 26 when the content goes full height). Rows:
- Home
- a live "Recording…" row with a pulsing red dot, only while recording
- date groups as today
- meeting rows on two lines: title, then time (`Meeting` has no duration column, D3)

Search snippets show as the second line. The "Record a meeting" button leaves the sidebar for the toolbar. The content view's background goes into an `NSBackgroundExtensionView` so it shows through under the sidebar.

**Home, idle.** Built like Voice Memos:
- a large round glass Record button in the center: `.glass` bezel, `borderShape = .circle`, `controlSize = .extraLarge`, red tint
- under it, "Start Recording ⌘N"
- a glass container with two small pickers: microphone, and system audio on or off
- one quiet line at the bottom: "Audio and transcripts stay on this Mac."

**Home, recording.**
- At the top: a large editable title, and a status line ("Recording · MacBook Pro Microphone + System audio").
- The live transcript fills the window and scrolls under the toolbar and under the floating bar.
- At the bottom, a floating glass bar (`NSGlassEffectContainerView`) holds a red dot, the timer and a live **waveform** in one capsule, then round Pause and Stop buttons. Stop is red.
- While starting or stopping, the capsule shows a spinner and the progress message.
- Device notices show as an orange-tinted glass banner under the toolbar.
- The consent notice is a glass toast, top trailing, that hides itself after 10 s as it does now.
- The idle Record button turns into the recording bar with a glass morph (the container merges glass shapes as they animate). It cross-fades instead under Reduce Motion.

**Meeting.**
- The main column shows **Summary** or **Notes**, picked by a segmented control in the toolbar's center.
- The **transcript** is a trailing inspector (`NSSplitViewItem(inspectorWithViewController:)`). The toolbar button and ⌃⌘I toggle it. It's open by default when the window is wide enough.
- Playback is a floating glass capsule at the bottom of the main column: play/pause, scrubber, times. Clicking a transcript line seeks, as now.
- The summary document starts with a large title and a "date · template" line, then the markdown editor.
- Toolbar action group:
  - **Generate** (sparkles), with a popover holding template, model, language and extra context. Those are the three rows of pop-ups shown today.
  - **Share** (`NSSharingServicePickerToolbarItem`, with the summary text)
  - **More** menu: Copy Transcript, Copy Summary, Export Summary…, Show Recording in Finder, Enhance (Retranscribe)…
- While a summary is generating, the Generate item becomes Stop, and the document shows "Writing the summary…" with a progress bar.
- The empty state keeps its message, with a glass prominent "Generate Summary" button.

**Settings.** Keep the toolbar tabs, as Safari and Mail do. Every pane becomes a grouped form in the System Settings style:
- each section has a title and a rounded inset box
- each row has the label on the left and the control on the right, with hairline separators between rows

Model rows become form rows, with progress shown inline.

**Onboarding.** A full-size-content window with no toolbar. Three pages:
1. Welcome: big app icon, title, three feature rows with SF Symbols in tinted circles, in the style of Apple's "What's New" sheets.
2. Permissions: form rows with live status and a button each.
3. Models: form rows with progress.

A glass prominent Continue capsule sits at the bottom.

**Sheets, alerts, overlay.** TranscribeSheet and Rename use the grouped form. Sheets and alerts get glass on 26 automatically. The drop overlay becomes a glass panel with one large symbol.

**Menu bar item.** Each menu item gets an SF Symbol, as menus show them on 26. The status icon turns red while recording.

## New and changed house views (`App/Design/`)

- `Theme.swift`: tokens mapped to system colors (G4), text styles (G5). Tokens are deleted in the cleanup slice.
- `NSButton.meety` uses the `.glass` bezel:
  - `.primary` sets `tintProminence = .primary` and uses the accent color
  - `.destructive` uses `systemRed`
  - a new `.circle(size:)` style uses `borderShape = .circle`

  Every caller picks up the new look with no other changes.
- `FormSection`: a grouped form section (title, inset rounded box, rows with separators). Used by Settings, sheets and onboarding. It replaces `CardView` there.
- `GlassBar`: a thin wrapper that makes an `NSGlassEffectContainerView` from glass capsules. Used by the recording bar, the audio player and the toasts. It's the only place that builds glass by hand.
- `WaveformView`: a `CAShapeLayer` of bars drawn from the last ~120 level samples. The display link that drives the meters today feeds it. It replaces `LevelMeterView`.
- Deleted by the end: `CardView` (`EmptyStateView` loses its card), `LevelMeterView`, and the unused color sets.

## Slices

Each slice: build, launch it in a scratch data dir (CLAUDE.md, Data safety), take light and dark snapshots of the screens it changed, commit, push. Logic tests come first where there is logic in MeetyKit.

**G0. Snapshot glass.** `cacheDisplay` draws the view tree, but glass and blur are drawn by the window server, so today's snapshots may show flat boxes. Check this first with one `NSGlassEffectView`. If it does flatten them, `MEETY_SNAPSHOT` logs the window number and waits. A new `scripts/snapshot.sh` captures it with `screencapture -l`, which uses the terminal's Screen Recording grant. It runs for both appearances (`-AppleInterfaceStyle Dark`). Done when one script call writes a light and a dark PNG of a window showing glass.

**G1. Foundations.** The `AccentColor` asset; tokens mapped to system colors; text styles; the `.glass` bezel in `NSButton.meety`; `FormSection`; `GlassBar`. Done when the whole app builds and runs with the new colors and buttons, and no layout has changed yet.

**G2. Window chrome.** The `NSToolbar` with a delegate in `MainWindowController`: sidebar toggle, title and subtitle per route, Record and Stop as a prominent item, `NSSearchToolbarItem` wired to the existing transcript search, toolbar validation. Remove the sidebar's Record button and search field. Floating sidebar; content under it with `NSBackgroundExtensionView`.

**G3. Sidebar rows.** Two-line meeting rows, the live recording row, symbols. Rename, delete, reveal and the keyboard keep working as today.

**G4. Home, idle.** The hero Record button, the input pickers in glass, the privacy line. Delete the recent list (G8).

**G5. Home, recording.** `WaveformView`, the floating `GlassBar` with timer, waveform, pause and stop, the starting and stopping states, the notice banner, the consent toast. The transcript's bottom inset clears the bar. Check it with `MEETY_DEMO_RECORDING=1`.

**G6. Record morph.** The idle Record button animates into the recording bar inside one glass container, and back on stop. Under Reduce Motion it cross-fades instead. A polish slice: drop it if the morph looks wrong in AppKit.

**G7. Meeting layout.** The segmented Summary/Notes control in the toolbar, the transcript inspector with its toggle and autosaved width, the floating audio capsule. Check it with `MEETY_OPEN_MEETING=<id>`.

**G8. Summary flow.** The Generate popover, Generate turning into Stop, the generating and empty states, the Share item, the More menu. Test first: summary autosave (G9) goes in `SummaryController` as a debounced `scheduleSave()`, with Swift Testing tests (save fires once after edits stop; `flush` saves right away; nothing is saved when nothing changed). Remove the Save button and keep ⌘S.

**G9. Settings.** Rebuild the five panes on `FormSection`, and turn the model rows into form rows. Check it with `MEETY_SETTINGS_TAB=0…4`.

**G10. Sheets and overlay.** TranscribeSheet and the Rename alert on `FormSection`; the glass drop overlay. Check the sheet with `MEETY_IMPORT=<audio>`.

**G11. Onboarding.** The three pages in the new style. Check it with `MEETY_ONBOARDING=1`.

**G12. Menu bar and menus.** Symbols on the status menu and the main menu items; the red recording icon.

**G13. App icon (optional, needs a GUI).** A layered Liquid Glass icon made in Icon Composer (`.icon`), replacing `AppIcon.appiconset`. Icon Composer is a desktop app, so this goes to Codex computer use (global instructions). Ask before starting.

**G14. Cleanup.** Delete `CardView`, `LevelMeterView`, the unused color sets and dead styling code. Update CLAUDE.md (Conventions: house views, G1 glass rule) and the README screenshots. Then the branch review (`codex exec -m gpt-6.1-sol -c model_reasoning_effort="high" -c service_tier="default" -s read-only`), fixes in `Review:` commits, the phase report with the snapshot gallery, push, stop.

## Checks for every slice

- Light and dark appearance; System Settings › Accessibility › Display: Reduce Transparency, Increase Contrast and Reduce Motion each turned on once per screen.
- Every icon-only glass button has an accessibility label and a tooltip.
- Keyboard: Tab order, menu commands for every toolbar action, Esc closes popovers.
- Window at its minimum size (760×480) and full screen: toolbar items move into the overflow menu instead of clipping, and the inspector folds away.
- No glass behind long text (G1). The live transcript and the editors stay on the window background.
- `scripts/test.sh` green.

## Risks

- **Snapshot fidelity** (G0). If `screencapture` can't get a grant here, checks fall back to Codex computer use looking at the running app.
- **Floating sidebar and inspector over opaque views.** `TranscriptListView` and `MarkdownEditor` draw backgrounds today. They need `drawsBackground = false` and safe area insets, or the glass shows a hard edge.
- **Morph animation.** AppKit has no SwiftUI-style `glassEffectID`. Glass shapes merge only as their frames come within the container's `spacing`. G6 is optional for that reason.
- **Behavior changes** a user will notice: search moves to the toolbar (G7), the recent list on Home goes away (G8), summary autosave (G9), copy and export move into Share and More. Approved 2026-11-04.
- **Window frame autosave.** The new toolbar and inspector change the saved frames. Delete the autosave keys after dev runs, as CLAUDE.md says, plus `NSSplitView Subview Frames MeetingSplit`.
