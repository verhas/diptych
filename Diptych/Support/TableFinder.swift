import AppKit

/// Finds the pane tables inside a window.
///
/// Shared by everything that has to reach the AppKit table underneath SwiftUI,
/// so the "stop at the table" rule lives in one place: walking a table's own
/// subviews makes AppKit materialise row views mid-iteration, which crashes.
@MainActor
enum TableFinder {

    /// In layout order, which is left pane then right pane.
    static func tables(in window: NSWindow) -> [NSTableView] {
        guard let content = window.contentView else { return [] }
        return walk(content)
    }

    private static func walk(_ view: NSView) -> [NSTableView] {
        if let table = view as? NSTableView { return [table] }
        let children = (view.subviews as NSArray).copy() as? [NSView] ?? []
        return children.flatMap(walk)
    }
}
