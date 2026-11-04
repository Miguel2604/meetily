import AppKit
import Core

/// Source-list sidebar (Sidebar/index.tsx): Home and meetings by date. Its transcript search field lives in the toolbar.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSMenuItemValidation {
    private final class Node {
        enum Kind { case home, group(String), meeting(Meeting, snippet: String?) }
        let kind: Kind
        let children: [Node]
        init(_ kind: Kind, _ children: [Node] = []) { self.kind = kind; self.children = children }
        var meeting: Meeting? { if case .meeting(let m, _) = kind { m } else { nil } }
    }

    private let model: AppModel
    private let outline = SidebarOutlineView()
    let search = NSSearchField()
    private let emptyLabel = NSTextField.meety("", font: Typography.callout, color: .secondaryLabelColor)
    private var roots: [Node] = []
    private var matches: [SearchResult] = []
    private var searchTask: Task<Void, Never>?
    private var syncingSelection = false

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    override func loadView() {
        search.placeholderString = "Search transcripts"
        search.setAccessibilityLabel("Search transcripts")
        search.target = self
        search.action = #selector(searchChanged(_:))

        let column = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.usesAutomaticRowHeights = true
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.autosaveExpandedItems = false
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        emptyLabel.alignment = .center
        let root = NSView()
        for v in [scroll, emptyLabel] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 80),
            emptyLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            emptyLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        track { [weak self] in
            guard let self else { return }
            _ = model.meetings
            rebuild()
        }
        track { [weak self] in
            guard let self else { return }
            _ = model.route
            selectRoute()
        }
    }

    func focusSearch() { view.window?.makeFirstResponder(search) }

    // MARK: Data

    private func rebuild() {
        let query = search.stringValue
        let meetings = MeetingList.filtered(model.meetings, query: query, matches: matches)
        let snippets = Dictionary(matches.map { ($0.id, $0.matchContext) }, uniquingKeysWith: { first, _ in first })
        roots = [Node(.home)] + MeetingList.grouped(meetings).map { group in
            Node(.group(group.title), group.meetings.map { Node(.meeting($0, snippet: snippets[$0.id])) })
        }
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        emptyLabel.stringValue = query.isEmpty ? "Recorded meetings will appear here." : "No meetings match that search."
        emptyLabel.isHidden = !meetings.isEmpty
        selectRoute()
    }

    private func selectRoute() {
        let row: Int
        switch model.route {
        case .home: row = outline.row(forItem: roots.first)
        case .meeting(let id):
            row = (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? Node)?.meeting?.id == id } ?? -1
        }
        guard row != outline.selectedRow else { return }
        syncingSelection = true
        if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false); outline.scrollRowToVisible(row) }
        else { outline.deselectAll(nil) }
        syncingSelection = false
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        searchTask?.cancel()
        let query = sender.stringValue
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { matches = []; rebuild(); return }
        searchTask = Task {
            let found = (try? await model.store.searchTranscripts(query)) ?? []
            guard !Task.isCancelled, query == search.stringValue else { return }
            matches = found
            rebuild()
        }
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? Node)?.children.isEmpty ?? true) }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        if case .group = (item as? Node)?.kind { true } else { false }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !self.outlineView(outlineView, isGroupItem: item)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        switch node.kind {
        case .group(let title):
            let cell = reuse("group") { SidebarCell(header: true) }
            cell.set(title: title, snippet: nil, symbol: nil)
            return cell
        case .home:
            let cell = reuse("row") { SidebarCell(header: false) }
            cell.set(title: "Home", snippet: nil, symbol: "house")
            return cell
        case .meeting(let meeting, let snippet):
            let cell = reuse("row") { SidebarCell(header: false) }
            cell.set(title: meeting.title, snippet: snippet, symbol: nil)
            return cell
        }
    }

    private func reuse(_ id: String, make: () -> SidebarCell) -> SidebarCell {
        if let cell = outline.makeView(withIdentifier: .init(id), owner: self) as? SidebarCell { return cell }
        let cell = make()
        cell.identifier = .init(id)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection, let node = outline.item(atRow: outline.selectedRow) as? Node else { return }
        switch node.kind {
        case .home: model.route = .home
        case .meeting(let meeting, _): model.route = .meeting(meeting.id)
        case .group: break
        }
    }

    // MARK: Rename, delete, reveal (context menu, keyboard and Edit menu)

    private var targetMeeting: Meeting? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return (outline.item(atRow: row) as? Node)?.meeting
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard targetMeeting != nil else { return }
        menu.addItem(withTitle: "Rename…", action: #selector(renameMeeting(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show in Finder", action: #selector(revealMeeting(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete…", action: #selector(delete(_:)), keyEquivalent: "").target = self
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(revealMeeting(_:)) { return targetMeeting?.folderPath != nil }
        return targetMeeting != nil
    }

    @objc func renameMeeting(_ sender: Any?) {
        guard let meeting = targetMeeting, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename meeting"
        let field = NSTextField(string: meeting.title)
        field.placeholderString = "Enter meeting title"
        field.frame.size.width = 280
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [model] response in
            guard response == .alertFirstButtonReturn else { return }
            if field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty { NSSound.beep(); return }
            Task { await model.rename(meeting.id, to: field.stringValue) }
        }
    }

    @objc func delete(_ sender: Any?) {
        guard let meeting = targetMeeting, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(meeting.title)”?"
        alert.informativeText = "Are you sure you want to delete this meeting? This action cannot be undone."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [model] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { await model.delete(meeting.id) }
        }
    }

    @objc func revealMeeting(_ sender: Any?) {
        guard let path = targetMeeting?.folderPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// Return renames and Delete deletes the selected meeting, as in Finder.
final class SidebarOutlineView: NSOutlineView {
    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .delete?, .deleteForward?: NSApp.sendAction(#selector(SidebarViewController.delete(_:)), to: nil, from: self)
        case .carriageReturn?, .enter?: NSApp.sendAction(#selector(SidebarViewController.renameMeeting(_:)), to: nil, from: self)
        default: super.keyDown(with: event)
        }
    }
}

/// A sidebar row: title (and a transcript-match snippet while searching), or a section header.
final class SidebarCell: NSTableCellView {
    private let snippet = NSTextField.meety("", font: Typography.caption, color: .secondaryLabelColor)

    init(header: Bool) {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: "")
        title.lineBreakMode = .byTruncatingTail
        title.font = header ? Typography.caption : Typography.body
        title.textColor = header ? .secondaryLabelColor : .labelColor
        textField = title
        let icon = NSImageView()
        imageView = icon
        snippet.maximumNumberOfLines = 2
        snippet.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [title, snippet])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [icon, text])
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        snippet.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    func set(title: String, snippet text: String?, symbol: String?) {
        textField?.stringValue = title
        textField?.toolTip = title
        snippet.stringValue = text ?? ""
        snippet.isHidden = text == nil
        imageView?.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        imageView?.isHidden = symbol == nil
    }
}
