import AppKit
import Core

/// The opt-in dictation history: newest first, each with its app and time, one click to copy.
final class DictationHistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: Store
    private var entries: [DictationEntry] = []
    private let table = NSTableView()
    private let empty = EmptyStateView(symbol: "clock", title: "No dictations saved",
                                       message: "Turn on history in Settings › Dictation to keep the last seven days here.", action: nil)
    private lazy var deleteAll = NSButton.meety("Delete All…", symbol: "trash", target: self, action: #selector(confirmDeleteAll))

    init(store: Store) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.title = "Dictation History"
        window.minSize = NSSize(width: 420, height: 320)
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let column = NSTableColumn(identifier: .init("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.usesAutomaticRowHeights = true
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let bar = NSStackView(views: [NSView(), deleteAll])
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 14, right: 16)
        let stack = NSStackView(views: [scroll, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let content = NSView()
        for view in [stack, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: content.centerXAnchor), empty.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        window.contentView = content
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    func show() {
        reload()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func reload() {
        Task {
            entries = (try? await store.dictations()) ?? []
            table.reloadData()
            empty.isHidden = !entries.isEmpty
            deleteAll.isEnabled = !entries.isEmpty
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let text = NSTextField.meety(entry.text, font: Typography.body)
        text.isSelectable = true
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let when = entry.createdDate?.formatted(date: .abbreviated, time: .shortened) ?? ""
        let caption = NSTextField.meety([entry.app, when].compactMap { $0 }.joined(separator: " · "), font: Typography.caption, color: .secondaryLabelColor)
        let lines = NSStackView(views: [text, caption])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 4
        let copy = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")!, target: self, action: #selector(copyEntry(_:)))
        copy.isBordered = false
        copy.contentTintColor = .secondaryLabelColor
        copy.toolTip = entry.heard == entry.text ? "Copy" : "Copy. Option-click copies the text as heard"
        copy.tag = row
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let cell = NSStackView(views: [lines, spacer, copy])
        cell.alignment = .top
        cell.spacing = 12
        cell.edgeInsets = NSEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        return cell
    }

    @objc private func copyEntry(_ sender: NSButton) {
        guard entries.indices.contains(sender.tag) else { return }
        let entry = entries[sender.tag]
        let asHeard = NSEvent.modifierFlags.contains(.option)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(asHeard ? entry.heard : entry.text, forType: .string)
    }

    @objc private func confirmDeleteAll() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete all saved dictations?"
        alert.informativeText = "This can't be undone."
        alert.addButton(withTitle: "Delete All").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task {
                try? await self.store.deleteDictations()
                self.reload()
            }
        }
    }
}
