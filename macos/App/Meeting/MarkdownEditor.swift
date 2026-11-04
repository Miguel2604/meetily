import AppKit
import Summary

/// Shows markdown rendered (headings, lists, bold, tables); a click swaps in a TextKit 2 text view that edits the
/// plain markdown, styled live with the syntax markers dimmed (replaces BlockNote). Leaving it renders again.
final class MarkdownEditor: NSScrollView, NSTextViewDelegate {
    let textView: NSTextView
    /// TextKit 1 on purpose: NSTextTable drops TextKit 2 views back to TextKit 1, so tables live in their own view.
    private let reader = ReadView(usingTextLayoutManager: false)
    /// Called after every user edit with the new markdown.
    var onChange: ((String) -> Void)?

    override init(frame: NSRect) {
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView // a TextKit 2 view; never touch layoutManager (that falls back to TextKit 1)
        super.init(frame: frame)
        documentView = textView
        hasVerticalScroller = true
        drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.font = Typography.body
        textView.textColor = .labelColor
        textView.delegate = self
        textView.setAccessibilityLabel("Markdown editor")

        reader.isEditable = false
        reader.isSelectable = false
        reader.drawsBackground = false
        reader.textContainerInset = textView.textContainerInset
        reader.isVerticallyResizable = true
        reader.autoresizingMask = .width
        reader.textContainer?.widthTracksTextView = true
        reader.minSize = NSSize(width: 0, height: 0)
        reader.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        reader.setAccessibilityLabel("Markdown document")
        reader.onClick = { [weak self] index in self?.beginEditing(near: index) }
        documentView = reader
    }

    override func layout() {
        super.layout()
        // The read view fills the visible area so a click below short text still starts editing.
        reader.minSize = NSSize(width: 0, height: contentView.bounds.height)
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    var markdown: String {
        get { textView.string }
        set {
            guard newValue != textView.string else { return }
            textView.string = newValue
            restyle()
            if documentView === reader { reader.textStorage?.setAttributedString(Self.render(newValue)) }
        }
    }

    var isEditable: Bool {
        get { textView.isEditable }
        set { textView.isEditable = newValue }
    }

    private func beginEditing(near index: Int) {
        guard textView.isEditable else { return }
        let caret = Self.rawLocation(of: index, in: reader.string, raw: textView.string)
        documentView = textView
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        textView.scrollRangeToVisible(NSRange(location: caret, length: 0))
    }

    func textDidEndEditing(_ notification: Notification) {
        reader.textStorage?.setAttributedString(Self.render(textView.string))
        documentView = reader
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(cancelOperation(_:)) else { return false }
        window?.makeFirstResponder(nil) // Escape finishes editing
        return true
    }

    /// Where a click in the rendered text lands in the markdown: the start of the line holding that paragraph's text.
    private static func rawLocation(of index: Int, in rendered: String, raw: String) -> Int {
        let ns = rendered as NSString
        guard ns.length > 0 else { return (raw as NSString).length }
        let paragraph = ns.substring(with: ns.paragraphRange(for: NSRange(location: min(index, ns.length - 1), length: 0)))
        let probe = String(paragraph.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        let found = probe.isEmpty ? NSRange(location: NSNotFound, length: 0) : (raw as NSString).range(of: probe)
        return found.location == NSNotFound ? (raw as NSString).length : found.location
    }

    func textDidChange(_ notification: Notification) {
        restyle()
        onChange?(textView.string)
    }

    private func restyle() {
        guard let storage = textView.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        let body = NSMutableParagraphStyle()
        body.paragraphSpacing = 4
        body.lineHeightMultiple = 1.15
        storage.beginEditing()
        storage.setAttributes([.font: Typography.body, .foregroundColor: NSColor.labelColor, .paragraphStyle: body], range: whole)
        for span in MarkdownSpans.parse(storage.string) {
            switch span.kind {
            case .heading(let level):
                let size: CGFloat = level == 1 ? 22 : level == 2 ? 17 : 14
                let style = NSMutableParagraphStyle()
                style.paragraphSpacingBefore = level <= 2 ? 12 : 6
                style.paragraphSpacing = 4
                storage.addAttributes([.font: NSFont.systemFont(ofSize: size, weight: .semibold), .paragraphStyle: style], range: span.range)
            case .listItem:
                let style = NSMutableParagraphStyle()
                style.headIndent = 18
                style.paragraphSpacing = 2
                storage.addAttribute(.paragraphStyle, value: style, range: span.range)
            case .bold:
                let font = storage.attribute(.font, at: span.range.location, effectiveRange: nil) as? NSFont ?? Typography.body
                storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: span.range)
            case .marker:
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: span.range)
            }
        }
        storage.endEditing()
        textView.typingAttributes = [.font: Typography.body, .foregroundColor: NSColor.labelColor, .paragraphStyle: body]
    }

    // MARK: Rendering

    static func render(_ markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func paragraph(spacingBefore: CGFloat = 0, spacing: CGFloat = 8, indent: CGFloat = 0, head: CGFloat? = nil) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.15
            style.paragraphSpacingBefore = spacingBefore
            style.paragraphSpacing = spacing
            style.firstLineHeadIndent = indent
            style.headIndent = head ?? indent
            return style
        }
        for block in MarkdownBlocks.parse(markdown) {
            switch block {
            case .heading(let level, let text):
                let size: CGFloat = level == 1 ? 22 : level == 2 ? 17 : 14
                out.append(inline(text, font: .systemFont(ofSize: size, weight: .semibold),
                                  style: paragraph(spacingBefore: level <= 2 ? 12 : 6, spacing: 4)))
            case .paragraph(let text, let quote):
                out.append(inline(text, font: Typography.body, style: paragraph(indent: quote ? 16 : 0),
                                  color: quote ? .secondaryLabelColor : .labelColor))
            case .listItem(let depth, let marker, let text):
                let indent = CGFloat(depth) * 18
                let style = paragraph(spacing: 3, indent: indent - 18, head: indent)
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                let line = NSMutableAttributedString(string: "\(marker)\t", attributes: [.font: Typography.body, .foregroundColor: NSColor.secondaryLabelColor])
                line.append(inline(text, font: Typography.body, style: style))
                line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
                out.append(line)
            case .table(let rows):
                let table = NSTextTable()
                table.numberOfColumns = rows.map(\.count).max() ?? 1
                table.collapsesBorders = true
                table.setContentWidth(100, type: .percentageValueType)
                // Columns share the width by their longest cell, so a long Task column isn't squeezed like a short Due one.
                let weights = (0..<table.numberOfColumns).map { c in
                    sqrt(CGFloat(min(max(rows.map { $0.indices.contains(c) ? $0[c].characters.count : 0 }.max() ?? 0, 10), 80)))
                }
                let total = weights.reduce(0, +)
                for (r, row) in rows.enumerated() {
                    for (c, cell) in row.enumerated() {
                        let box = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                        box.setWidth(6, type: .absoluteValueType, for: .padding)
                        box.setWidth(1, type: .absoluteValueType, for: .border)
                        box.setValue(weights[c] / total * 100, type: .percentageValueType, for: .width)
                        box.setBorderColor(.separatorColor)
                        if r == 0 { box.backgroundColor = .quaternarySystemFill }
                        let style = paragraph(spacing: 0)
                        style.textBlocks = [box]
                        out.append(inline(cell, font: r == 0 ? NSFont.systemFont(ofSize: Typography.body.pointSize, weight: .semibold) : Typography.body, style: style))
                    }
                }
                // Space after the table: an empty paragraph outside it.
                out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
            case .rule:
                let line = NSTextBlock()
                line.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                line.setBorderColor(.separatorColor)
                let style = paragraph(spacingBefore: 4, spacing: 12)
                style.textBlocks = [line]
                out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4), .paragraphStyle: style]))
            }
        }
        return out
    }

    /// One paragraph: the block's inline runs (bold, italic, code, strikethrough, links) plus a newline.
    private static func inline(_ text: AttributedString, font: NSFont, style: NSParagraphStyle, color: NSColor = .labelColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for run in text.runs {
            var runFont = font
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
            if intent.contains(.code) { runFont = .monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular) }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: color, .paragraphStyle: style]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            out.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        out.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style]))
        return out
    }
}

/// The read-only rendered markdown; a click hands its character index to the editor.
private final class ReadView: NSTextView {
    var onClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?(characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)))
    }

    override func resetCursorRects() { addCursorRect(visibleRect, cursor: .iBeam) }
}
