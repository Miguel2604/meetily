import AppKit
import Transcription
import UniformTypeIdentifiers

/// The main window: sidebar of meetings and a content area routed by `AppModel.route`.
final class MainWindowController: NSWindowController, NSMenuItemValidation {
    private let model: AppModel
    private let sidebar: SidebarViewController

    init(model: AppModel) {
        self.model = model
        sidebar = SidebarViewController(model: model)
        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 360
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: ContentRouter(model: model)))
        split.splitView.autosaveName = "MainSplit"

        let window = NSWindow(contentViewController: split)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "Meety"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 760, height: 480)
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.autorecalculatesKeyViewLoop = true
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") { window.center() }
        super.init(window: window)
        window.delegate = self
        window.registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    @objc func focusSearch(_ sender: Any?) { sidebar.focusSearch() }

    @objc func newRecording(_ sender: Any?) {
        model.route = .home
        Task { await model.startRecording() }
    }

    @objc func stopRecording(_ sender: Any?) { Task { await model.stopRecording() } }

    @objc func pauseRecording(_ sender: Any?) {
        let recorder = model.recorder
        Task { recorder.phase == .paused ? await recorder.resume() : await recorder.pause() }
    }

    @objc func importAudio(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = OfflineTranscription.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Import an audio file to create a new meeting with transcripts"
        panel.prompt = "Import"
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.importFile(url) }
        }
    }

    func importFile(_ url: URL) {
        guard let content = window?.contentViewController, content.presentedViewControllers?.isEmpty ?? true else { return }
        showWindow(nil)
        content.presentAsSheet(TranscribeSheet(model: model, job: .importFile(url)) { [model] id in
            guard let id else { return }
            Task {
                await model.reloadMeetings()
                model.route = .meeting(id)
            }
        })
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let phase = model.recorder.phase
        let live = phase == .recording || phase == .paused
        switch item.action {
        case #selector(stopRecording(_:)): return live
        case #selector(pauseRecording(_:)):
            item.title = phase == .paused ? "Resume Recording" : "Pause Recording"
            return live
        case #selector(newRecording(_:)), #selector(importAudio(_:)): return !live && phase != .stopping
        default: return true
        }
    }
}

/// The window accepts an audio file dragged anywhere onto it. NSWindow forwards dragging-destination messages
/// to its delegate, so the controller handles them and shows a "Drop audio file to import" overlay (ImportDropOverlay.tsx).
extension MainWindowController: NSWindowDelegate {
    private func audioFile(_ info: any NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard urls.count == 1, let url = urls.first, (try? OfflineTranscription.validate(url)) != nil else { return nil }
        return url
    }

    @objc func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard audioFile(sender) != nil else { return [] }
        showDropOverlay(true)
        return .copy
    }

    @objc func draggingExited(_ sender: (any NSDraggingInfo)?) { showDropOverlay(false) }

    @objc func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        showDropOverlay(false)
        guard let url = audioFile(sender) else { return false }
        importFile(url)
        return true
    }

    private func showDropOverlay(_ show: Bool) {
        let id = NSUserInterfaceItemIdentifier("dropOverlay")
        guard let content = window?.contentView else { return }
        content.subviews.first { $0.identifier == id }?.removeFromSuperview()
        guard show else { return }
        let card = CardView()
        card.identifier = id
        card.fill = NSColor.meetyBackground.withAlphaComponent(0.92)
        card.stroke = .meetyForeground
        let icon = NSImageView(image: NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 32, weight: .light)
        let stack = NSStackView(views: [icon, NSTextField.meety("Drop audio file to import", font: Typography.headline)])
        stack.orientation = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        card.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            card.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            stack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
    }
}

/// Swaps the content pane for the current route.
final class ContentRouter: NSViewController {
    private let model: AppModel
    private var shown: AppModel.Route?
    private lazy var home = HomeViewController(model: model)

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    override func loadView() {
        view = NSView()
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        track { [weak self] in
            guard let self else { return }
            let route = model.route
            guard route != shown else { return }
            shown = route
            show(controller(for: route))
        }
    }

    private func controller(for route: AppModel.Route) -> NSViewController {
        switch route {
        case .home:
            return home
        case .meeting(let id):
            return MeetingViewController(model: model, meetingID: id)
        }
    }

    private func show(_ child: NSViewController) {
        children.forEach { $0.view.removeFromSuperview(); $0.removeFromParent() }
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.width, .height]
        view.addSubview(child.view)
    }
}

/// Wraps a plain view as a view controller.
final class Placeholder: NSViewController {
    init(_ view: NSView) {
        super.init(nibName: nil, bundle: nil)
        self.view = view
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }
}
