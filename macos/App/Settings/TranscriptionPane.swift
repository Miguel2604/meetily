import AppKit
import Core

/// Parakeet and Whisper models: download with progress, prepare, use, delete, open the folder
/// (TranscriptSettings.tsx, ParakeetModelManager.tsx, WhisperModelManager.tsx).
final class TranscriptionPane: SettingsPane {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init(title: "Transcription")
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let library = model.library
        let rows = ModelLibrary.Item.transcription.map { ModelRowView(item: $0, library: library) }
        section("Parakeet: English, in real time", rows.filter { if case .parakeet = $0.item { true } else { false } })
        section("Whisper: Tagalog, Taglish and other languages", rows.filter { if case .whisper = $0.item { true } else { false } },
                note: "Downloading prepares a model for the Neural Engine, so recording starts right away. The first time can take a few minutes. A new choice takes effect from your next recording.")
        let open = NSButton(title: "Open Models Folder", target: self, action: #selector(openFolder))
        column.addArrangedSubview(open)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        Task { await model.library.refresh() }
    }

    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: Paths.models, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Paths.models)
    }
}
