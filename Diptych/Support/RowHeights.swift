import AppKit

/// Pushes the pane row height onto the NSTableView underneath.
///
/// SwiftUI's `Table` has no row-height control, and its rows do not follow their
/// content: measured on a settled window with 105 rows and 20-point text, the
/// table reported `usesAutomaticRowHeights == true` and kept every row view at
/// exactly 24 points. So a larger font would simply be clipped.
///
/// Same shape as `ColumnWidths` for the same reason -- SwiftUI does not do it,
/// AppKit does, and the table is right there.
@MainActor
enum RowHeights {

    static func apply(in window: NSWindow) {
        let height = PaneFont.rowHeight

        for table in TableFinder.tables(in: window) {
            guard table.rowHeight != height else { continue }
            // Automatic heights would otherwise win and pin every row back to
            // 24: the flag is what makes rowHeight advisory.
            table.usesAutomaticRowHeights = false
            table.rowHeight = height
            // Not reloadData(): SwiftUI owns this table's data source and
            // reloading it from outside is asking for trouble. Noting the
            // heights is the documented way to make AppKit lay the rows out
            // again without touching the contents.
            guard table.numberOfRows > 0 else { continue }
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0 ..< table.numberOfRows))
        }
    }

    /// Every window, for when the size changes rather than when one appears.
    static func applyEverywhere() {
        for window in NSApp.windows { apply(in: window) }
    }
}
