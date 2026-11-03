import AppKit

/// The main window: sidebar of meetings and a content area routed by `AppModel.route`.
final class MainWindowController: NSWindowController {
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
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    @objc func focusSearch(_ sender: Any?) { sidebar.focusSearch() }

    @objc func newRecording(_ sender: Any?) { model.route = .home }
}

/// Swaps the content pane for the current route.
final class ContentRouter: NSViewController {
    private let model: AppModel
    private var shown: AppModel.Route?

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
            return Placeholder(EmptyStateView(symbol: "waveform", title: "Welcome to Meety", message: "Record a meeting to see its live transcript here."))
        case .meeting(let id):
            let title = model.meetings.first { $0.id == id }?.title ?? "Meeting"
            return Placeholder(EmptyStateView(symbol: "doc.text", title: title, message: "Meeting details arrive in the next slice."))
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
