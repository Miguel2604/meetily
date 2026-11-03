import AppKit

/// Meety tokens (frontend/src/app/globals.css): an achromatic ledger. Ink chrome; `signal` marks live data only.
/// Light/dark values live in Assets.xcassets.
extension NSColor {
    static let meetyBackground = token("Background")
    static let meetyForeground = token("Foreground")
    static let meetyPrimary = token("Primary")
    static let meetyPrimaryForeground = token("PrimaryForeground")
    static let meetySecondary = token("Secondary")
    static let meetyMuted = token("Muted")
    static let meetyMutedForeground = token("MutedForeground")
    static let meetyAccent = token("Accent")
    static let meetyBorder = token("Border")
    static let meetyInput = token("Input")
    static let meetyDestructive = token("Destructive")
    static let meetyGround = token("Ground")
    static let meetySignal = token("Signal")
    static let meetySignalSoft = token("SignalSoft")

    private static func token(_ name: String) -> NSColor {
        guard let color = NSColor(named: name) else { preconditionFailure("missing color asset \(name)") }
        return color
    }
}

/// Type scale. System font: the web app's Hanken Grotesk isn't bundled.
enum Typography {
    static let title = NSFont.systemFont(ofSize: 20, weight: .semibold)
    static let headline = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let body = NSFont.systemFont(ofSize: 13)
    static let bodyMedium = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let callout = NSFont.systemFont(ofSize: 12)
    static let caption = NSFont.systemFont(ofSize: 11)
    /// Timestamps and durations: digits that don't jitter as they change.
    static let timestamp = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
}

enum Metrics {
    static let radius: CGFloat = 8      // --radius
    static let smallRadius: CGFloat = 6 // rounded-md
    static let gutter: CGFloat = 16
}

extension NSTextField {
    /// A non-editable, wrapping label in the house type scale.
    static func meety(_ text: String, font: NSFont = Typography.body, color: NSColor = .meetyForeground) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        return label
    }
}
