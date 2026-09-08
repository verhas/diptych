import SwiftUI
import AppKit

/// The font the panes draw with, in the several forms the code needs it.
///
/// One place decides, because the pieces have to agree: the permissions column
/// is drawn by SwiftUI in the listing and by an NSView while being edited, and
/// if those two disagree by a point the characters stop lining up between the
/// row you are editing and the rows above it.
@MainActor
enum PaneFont {

    static var size: CGFloat { CGFloat(ConfigStore.shared.configuration.fontSize) }

    /// Empty means the system font. A named font that is no longer installed
    /// falls back to the system font rather than to whatever AppKit substitutes.
    static var name: String? {
        let name = ConfigStore.shared.configuration.fontName
        guard !name.isEmpty, NSFont(name: name, size: size) != nil else { return nil }
        return name
    }

    static var swiftUI: Font {
        name.map { Font.custom($0, fixedSize: size) } ?? .system(size: size)
    }

    /// Permissions stay monospaced whatever the chosen family, because
    /// `rwxr-xr-x` is a grid of nine columns and a proportional font makes it
    /// ragged -- and unusable to edit in place, where the caret addresses a slot.
    static var monospacedSwiftUI: Font { .system(size: size, design: .monospaced) }

    static var appKit: NSFont {
        name.flatMap { NSFont(name: $0, size: size) } ?? .systemFont(ofSize: size)
    }

    static var monospacedAppKit: NSFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Icons grow with the text, or a large font leaves postage stamps beside
    /// it. Rounded to whole points because icons are bitmaps at heart.
    static var iconSize: CGFloat { (size * 1.45).rounded() }

    /// Row height for the AppKit table underneath. SwiftUI's `Table` reports
    /// `usesAutomaticRowHeights == true` and then keeps every row at 24 points
    /// whatever the content -- measured, with 20-point text and 105 rows -- so
    /// the height has to be pushed down to the NSTableView by hand.
    static var rowHeight: CGFloat { max(iconSize, size * 1.6).rounded() + 6 }

    // MARK: - Zooming

    static func zoom(by step: Double) {
        set(ConfigStore.shared.configuration.fontSize + step)
    }

    static func reset() {
        set(Configuration.defaultFontSize)
    }

    static func set(_ size: Double) {
        let range = Configuration.fontSizes
        ConfigStore.shared.configuration.fontSize =
            min(max(size, range.lowerBound), range.upperBound)
    }

    /// Families worth offering. The full font list runs to hundreds of entries,
    /// most of them display faces that are unreadable at 11 points in a table.
    static var availableNames: [String] {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return ["SF Mono", "Menlo", "Monaco", "Courier New", "Andale Mono",
                "Helvetica Neue", "Lucida Grande", "Verdana", "Georgia"]
            .filter { installed.contains($0) || NSFont(name: $0, size: 12) != nil }
    }
}
