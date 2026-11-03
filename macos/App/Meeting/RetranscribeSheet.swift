import AppKit
import Core
import Transcription

/// Transcribe a meeting's recording again with another model or language (RetranscribeDialog.tsx).
final class RetranscribeSheet: NSViewController {
    static let languages: [(code: String, name: String)] = [
        ("auto", "Auto-detect"), ("en", "English"), ("tl", "Tagalog"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("pt", "Portuguese"), ("it", "Italian"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"), ("hi", "Hindi"),
        ("id", "Indonesian"), ("vi", "Vietnamese"),
    ] // shortcut: a short list instead of Whisper's ~100 languages; extend if another language is needed.

    enum Model: CaseIterable {
        case parakeetUltra, phonon2, whisperTurbo
        var title: String {
            switch self {
            case .parakeetUltra: "Parakeet Ultra (English)"
            case .phonon2: "Phonon-2 (English, fastest)"
            case .whisperTurbo: "Whisper large-v3-turbo (any language)"
            }
        }
    }

    private let model: AppModel
    private let meetingID: String
    private let onDone: () -> Void
    private let language = NSPopUpButton()
    private let engine = NSPopUpButton()
    private let progress = NSProgressIndicator()
    private let status = NSTextField.meety("Re-process the audio with different language settings", font: Typography.callout, color: .meetyMutedForeground)
    private lazy var run = NSButton.meety("Retranscribe", role: .primary, target: self, action: #selector(start))
    private lazy var cancel = NSButton.meety("Cancel", target: self, action: #selector(cancelOrClose))
    private var task: Task<Void, Never>?

    init(model: AppModel, meetingID: String, onDone: @escaping () -> Void) {
        self.model = model
        self.meetingID = meetingID
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    override func loadView() {
        language.addItems(withTitles: Self.languages.map(\.name))
        language.selectItem(at: Self.languages.firstIndex { $0.code == model.settings.language } ?? 0)
        engine.addItems(withTitles: Model.allCases.map(\.title))
        engine.selectItem(at: model.settings.language == "en" ? 0 : 2)
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        run.keyEquivalent = "\r"
        cancel.keyEquivalent = "\u{1b}"
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Language"), language],
            [NSTextField(labelWithString: "Model"), engine],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        let buttons = NSStackView(views: [NSView(), cancel, run])
        let stack = NSStackView(views: [NSTextField.meety("Retranscribe meeting", font: Typography.headline), status, grid, progress, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for v in [progress, buttons, status] as [NSView] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        stack.widthAnchor.constraint(equalToConstant: 440).isActive = true
        view = stack
    }

    @objc private func start() {
        let code = Self.languages[language.indexOfSelectedItem].code
        let choice = Model.allCases[engine.indexOfSelectedItem]
        run.isEnabled = false
        language.isEnabled = false
        engine.isEnabled = false
        progress.isHidden = false
        status.stringValue = "Loading model…"
        let model = self.model, meetingID = self.meetingID
        task = Task { [weak self] in
            do {
                let transcriber: any TranscriptionEngine = switch choice {
                case .parakeetUltra: try await model.parakeet.engine(.ultra)
                case .phonon2: try await model.parakeet.engine(.phonon2)
                case .whisperTurbo: try await model.whisper.engine(.turbo, language: code == "auto" ? nil : code)
                }
                let detector = try await model.voiceDetector()
                let count = try await OfflineTranscription.retranscribe(
                    meetingID: meetingID, store: model.store, engine: transcriber, detector: detector) { update in
                    Task { @MainActor in
                        self?.progress.doubleValue = update.fraction
                        self?.status.stringValue = "Processing audio... (\(update.stage.rawValue))"
                    }
                }
                self?.finish("Done: \(count) segments.")
            } catch is CancellationError {
                self?.finish(nil)
            } catch {
                self?.status.stringValue = "An error occurred during retranscription: \(error)"
                self?.run.isEnabled = true
                self?.progress.isHidden = true
            }
        }
    }

    private func finish(_ message: String?) {
        task = nil
        onDone()
        dismiss(nil)
    }

    @objc private func cancelOrClose() {
        if let task { task.cancel(); status.stringValue = "Retranscription cancelled" } else { dismiss(nil) }
    }
}
