import AppKit
import Summary

/// A TextKit 2 text view that stores plain markdown and styles it live: headings, list items, bold,
/// with the syntax markers dimmed (replaces BlockNote).
final class MarkdownEditor: NSScrollView, NSTextViewDelegate {
    let textView: NSTextView
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
    }

    required init?(coder: NSCoder) { fatalError("code-built UI") }

    var markdown: String {
        get { textView.string }
        set {
            guard newValue != textView.string else { return }
            textView.string = newValue
            restyle()
        }
    }

    var isEditable: Bool {
        get { textView.isEditable }
        set { textView.isEditable = newValue }
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
}
