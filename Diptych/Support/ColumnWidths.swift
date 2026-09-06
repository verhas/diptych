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
        let columns = configuration.columns
        guard !configuration.columnWidths.isEmpty else { return }

        for table in tables(in: window) where table.tableColumns.count == columns.count {
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
        ) { _ in
            // The notification carries the NSTableView, but AppKit objects are
            // not Sendable and the block is, so the object cannot come across.
            // Finding the table again on this side costs nothing and keeps the
            // concurrency checker satisfied.
            MainActor.assumeIsolated { recordFromFrontmostTable() }
        }
    }

    private static var observing = false

    private static func recordFromFrontmostTable() {
        let windows = [NSApp.keyWindow].compactMap { $0 } + NSApp.windows
        for window in windows {
            if let table = tables(in: window).first {
                record(from: table)
                return
            }
        }
    }

    private static func record(from table: NSTableView) {
        let columns = ConfigStore.shared.configuration.columns
        guard table.tableColumns.count == columns.count else { return }

        var widths = ConfigStore.shared.configuration.columnWidths
        for (index, column) in columns.enumerated() {
            widths[column.rawValue] = Double(table.tableColumns[index].width)
        }
        // ConfigStore debounces the write, so a live drag costs one save.
        ConfigStore.shared.configuration.columnWidths = widths
    }

    /// Stops at the table: walking a table's own subviews makes AppKit
    /// materialise row views mid-iteration, which crashes.
    private static func tables(in window: NSWindow) -> [NSTableView] {
        guard let content = window.contentView else { return [] }
        func walk(_ view: NSView) -> [NSTableView] {
            if let table = view as? NSTableView { return [table] }
            let children = (view.subviews as NSArray).copy() as? [NSView] ?? []
            return children.flatMap(walk)
        }
        return walk(content)
    }
}
