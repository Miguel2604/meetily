import AppKit

/// Colors are the system's semantic colors (they adapt under Liquid Glass) plus `AccentColor` in the asset
/// catalog, which tints prominent controls and marks live data. Recording is `systemRed`.

/// Type scale on the system text styles, with weight where a role needs it.
enum Typography {
    static let largeTitle = font(.largeTitle, .bold)
    static let title = font(.title1, .semibold)
    static let headline = NSFont.preferredFont(forTextStyle: .headline)
    static let body = NSFont.preferredFont(forTextStyle: .body)
    static let bodyMedium = font(.body, .medium)
    static let callout = NSFont.preferredFont(forTextStyle: .callout)
    static let caption = NSFont.preferredFont(forTextStyle: .subheadline)
    /// Timestamps and durations: digits that don't jitter as they change.
    static let timestamp = NSFont.monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .regular)

    private static func font(_ style: NSFont.TextStyle, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.preferredFont(forTextStyle: style)
        return NSFont(descriptor: base.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]]), size: 0) ?? base
    }
}

extension NSTextField {
    /// A non-editable, wrapping label in the house type scale.
    static func meety(_ text: String, font: NSFont = Typography.body, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        return label
    }
}
