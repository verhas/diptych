import AppKit

/// Remembers how wide the user dragged each column.
///
/// SwiftUI has `TableColumnCustomization` for exactly this, and it does record
/// widths into its Codable form -- but with columns built by
/// `TableColumnForEach` it never applies a restored width, which is measurable:
/// widths written to config.json come back on the next launch and are ignored.
/// So the widths are stored as plain numbers and pushed onto the NSTableColumns
/// underneath, which does hold.
@MainActor
enum ColumnWidths {

    /// NSTableColumn identifiers are UUIDs SwiftUI invents, so columns are
    /// matched by position -- which is exact, because the table is built from
    /// the same ordered list.
    static func apply(in window: NSWindow) {
        let configuration = ConfigStore.shared.configuration
        guard !configuration.columnWidths.isEmpty else { return }

        for table in tables(in: window) {
            let pane = TableFinder.pane(of: table, in: window)
            let columns = configuration.columns(inTrash: pane?.isTrashListing ?? false,
                                                onServer: pane?.isServerListing ?? false)
            guard table.tableColumns.count == columns.count else { continue }
            for (index, column) in columns.enumerated() {
                guard let width = configuration.columnWidths[column.rawValue], width > 0 else { continue }
                table.tableColumns[index].width = CGFloat(width)
            }
        }
    }

    static func startObserving() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(
            forName: NSTableView.columnDidResizeNotification,
            object: nil, queue: .main
        ) { note in
            guard let table = note.object as? NSTableView else { return }
            MainActor.assumeIsolated { resized(table) }
        }
    }

    private static var observing = false

    /// Only a column the user is dragging is remembered. AppKit says columns
    /// resized for its own reasons too -- the window growing, the last column
    /// filling the space, a table laid out again when a folder loads -- and
    /// writing those down changed the settings with nobody touching them.
    private static func resized(_ table: NSTableView) {
        guard let header = table.headerView, header.resizedColumn >= 0,
              let window = table.window,
              tables(in: window).contains(where: { $0 === table }) else { return }
        record(from: table)
    }

    private static func record(from table: NSTableView) {
        let pane = table.window.flatMap { TableFinder.pane(of: table, in: $0) }
        let columns = ConfigStore.shared.configuration.columns(inTrash: pane?.isTrashListing ?? false,
                                                               onServer: pane?.isServerListing ?? false)
        guard table.tableColumns.count == columns.count else { return }

        var widths = ConfigStore.shared.configuration.columnWidths
        for (index, column) in columns.enumerated() {
            widths[column.rawValue] = Double(table.tableColumns[index].width)
        }
        // ConfigStore debounces the write, so a live drag costs one save.
        guard widths != ConfigStore.shared.configuration.columnWidths else { return }
        ConfigStore.shared.configuration.columnWidths = widths
    }

    /// The panes' tables only: Text Edit's tree has columns too, and its
    /// widths are not the panes'.
    private static func tables(in window: NSWindow) -> [NSTableView] {
        TableFinder.tables(in: window)
    }
}
