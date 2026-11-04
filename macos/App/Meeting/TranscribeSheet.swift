import AppKit
import Core
import Transcription

/// Import an audio file as a new meeting (ImportAudioDialog.tsx), or transcribe a meeting's recording again
/// with another model or language (RetranscribeDialog.tsx).
final class TranscribeSheet: NSViewController {
    enum Job {
        case importFile(URL)
        case retranscribe(meetingID: String)
    }

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
    private let job: Job
    /// The meeting that was created or retranscribed; nil when cancelled.
    private let onDone: (String?) -> Void
    private let titleField = NSTextField()
    private let language = NSPopUpButton()
    private let engine = NSPopUpButton()
    private let progress = NSProgressIndicator()
    private let status = NSTextField.meety("", font: Typography.callout, color: .secondaryLabelColor)
    private lazy var run = NSButton.meety("", role: .primary, target: self, action: #selector(start))
    private lazy var cancel = NSButton.meety("Cancel", target: self, action: #selector(cancelOrClose))
    private var task: Task<Void, Never>?

    init(model: AppModel, job: Job, onDone: @escaping (String?) -> Void) {
        self.model = model
        self.job = job
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    override func loadView() {
        language.addItems(withTitles: Self.languages.map(\.name))
        language.selectItem(at: Self.languages.firstIndex { $0.code == model.settings.language } ?? 0)
        engine.addItems(withTitles: Model.allCases.map(\.title))
        engine.selectItem(at: model.settings.language == "en" ? 0 : 2)
        for popup in [language, engine] {
            popup.target = self
            popup.action = #selector(choiceChanged)
        }
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        run.keyEquivalent = "\r"
        cancel.keyEquivalent = "\u{1b}"
        var rows: [(String, NSView)] = [("Language", language), ("Model", engine)]
        let heading: String
        switch job {
        case .importFile(let url):
            heading = "Import audio"
            status.stringValue = "\(url.lastPathComponent) becomes a new meeting with a transcript."
            titleField.stringValue = url.deletingPathExtension().lastPathComponent
            titleField.placeholderString = "Enter meeting title"
            titleField.widthAnchor.constraint(equalToConstant: 280).isActive = true
            rows.insert(("Meeting title", titleField), at: 0)
            run.title = "Import"
        case .retranscribe:
            heading = "Retranscribe meeting"
            status.stringValue = "Re-process the audio with different language settings"
            run.title = "Retranscribe"
        }
        let form = FormSection(rows: rows)
        let buttons = NSStackView(views: [NSView(), cancel, run])
        let stack = NSStackView(views: [NSTextField.meety(heading, font: Typography.headline), status, form, progress, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for v in [form, progress, buttons, status] as [NSView] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        stack.widthAnchor.constraint(equalToConstant: 440).isActive = true
        view = stack
    }

    @objc private func start() {
        let code = Self.languages[language.indexOfSelectedItem].code
        let choice = Model.allCases[engine.indexOfSelectedItem]
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .importFile = job, title.isEmpty {
            status.stringValue = "Enter a meeting title."
            return
        }
        run.isEnabled = false
        language.isEnabled = false
        engine.isEnabled = false
        progress.isHidden = false
        status.stringValue = "Loading model…"
        titleField.isEnabled = false
        let model = self.model, job = self.job
        task = Task { [weak self] in
            do {
                let transcriber: any TranscriptionEngine = switch choice {
                case .parakeetUltra: try await model.parakeet.engine(.ultra)
                case .phonon2: try await model.parakeet.engine(.phonon2)
                case .whisperTurbo: try await model.whisper.engine(.turbo, language: code == "auto" ? nil : code)
                }
                let detector = try await model.voiceDetector()
                let report: @Sendable (OfflineTranscription.Progress) -> Void = { update in
                    Task { @MainActor in
                        self?.progress.doubleValue = update.fraction
                        self?.status.stringValue = "Processing audio... (\(update.stage.rawValue))"
                    }
                }
                switch job {
                case .importFile(let url):
                    let result = try await OfflineTranscription.importAudio(
                        url, title: title, recordingsFolder: model.settings.saveFolder, store: model.store, engine: transcriber,
                        detector: detector, progress: report)
                    self?.finish(result.meetingID)
                case .retranscribe(let meetingID):
                    _ = try await OfflineTranscription.retranscribe(meetingID: meetingID, store: model.store, engine: transcriber,
                                                                    detector: detector, progress: report)
                    self?.finish(meetingID)
                }
            } catch is CancellationError {
                self?.finish(nil)
            } catch {
                self?.task = nil // Cancel now closes the sheet
                self?.status.stringValue = "An error occurred: \(error)"
                self?.run.isEnabled = true
                self?.language.isEnabled = true
                self?.engine.isEnabled = true
                self?.titleField.isEnabled = true
                self?.progress.isHidden = true
            }
        }
    }

    private func finish(_ meetingID: String?) {
        task = nil
        onDone(meetingID)
        dismiss(nil)
    }

    /// A previous run's error no longer applies once the model or language changes.
    @objc private func choiceChanged() { if task == nil, status.stringValue.hasPrefix("An error occurred") { status.stringValue = "" } }

    @objc private func cancelOrClose() {
        if let task { task.cancel(); status.stringValue = "Cancelled" } else { dismiss(nil) }
    }
}
