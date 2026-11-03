import AppKit

enum Clock {
    /// `[mm:ss]` from seconds of audio (VirtualizedTranscriptView.tsx).
    static func stamp(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return String(format: "[%02d:%02d]", s / 60, s % 60)
    }

    /// `m:ss`, or `h:mm:ss` past an hour.
    static func duration(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// A transcript as a view-based table; cell reuse keeps long meetings cheap. Follows new lines while
/// scrolled to the bottom.
final class TranscriptListView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    struct Row: Hashable {
        var start: Double
        var text: String
        var source: String?
    }

    private(set) var rows: [Row] = []
    /// Called when the user selects a line (click or arrow keys).
    var onSelect: ((Row) -> Void)?
    private let table = NSTableView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: .init("line"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.usesAutomaticRowHeights = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Transcript")
        documentView = table
        hasVerticalScroller = true
        drawsBackground = false
        automaticallyAdjustsContentInsets = false
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    func set(_ new: [Row]) {
        let following = isAtBottom
        let old = rows
        rows = new
        if new.count > old.count, Array(new.prefix(old.count)) == old {
            table.insertRows(at: IndexSet(old.count..<new.count))
        } else if new != old {
            table.reloadData()
        }
        if following, !rows.isEmpty { table.scrollRowToVisible(rows.count - 1) }
    }

    private var isAtBottom: Bool {
        contentView.bounds.maxY >= table.bounds.maxY - 40
    }

    private var measuredWidth: CGFloat = 0

    override func layout() {
        super.layout()
        // Wrapped lines change height with the width.
        guard table.bounds.width != measuredWidth else { return }
        measuredWidth = table.bounds.width
        if table.numberOfRows > 0 { table.noteHeightOfRows(withIndexesChanged: IndexSet(0..<table.numberOfRows)) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("line"), owner: self) as? TranscriptCell ?? TranscriptCell()
        cell.identifier = .init("line")
        cell.set(rows[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0 else { return }
        onSelect?(rows[table.selectedRow])
    }
}

private final class TranscriptCell: NSTableCellView {
    private let time = NSTextField(labelWithString: "")
    private let source = NSTextField(labelWithString: "")
    private let text = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        time.font = Typography.timestamp
        time.textColor = .meetyMutedForeground
        source.font = Typography.caption
        source.textColor = .meetyMutedForeground
        text.font = Typography.body
        text.textColor = .labelColor
        text.isSelectable = true
        textField = text
        let meta = NSStackView(views: [time, source])
        meta.orientation = .vertical
        meta.alignment = .leading
        meta.spacing = 1
        for v in [meta, text] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            meta.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            meta.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            meta.widthAnchor.constraint(equalToConstant: 68),
            meta.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -5),
            text.leadingAnchor.constraint(equalTo: meta.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    override func layout() {
        super.layout()
        // Wrap at the cell's width so automatic row heights fit multi-line text.
        if text.preferredMaxLayoutWidth != text.frame.width { text.preferredMaxLayoutWidth = text.frame.width }
    }

    func set(_ row: TranscriptListView.Row) {
        time.stringValue = Clock.stamp(row.start)
        source.stringValue = row.source ?? ""
        source.isHidden = row.source == nil
        text.stringValue = row.text
        setAccessibilityLabel("\(Clock.stamp(row.start)) \(row.source ?? "") \(row.text)")
    }
}
