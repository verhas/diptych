import AppKit

/// Finds the pane tables inside a window.
///
/// Shared by everything that has to reach the AppKit table underneath SwiftUI,
/// so the "stop at the table" rule lives in one place: walking a table's own
/// subviews makes AppKit materialise row views mid-iteration, which crashes.
@MainActor
enum TableFinder {

    /// The pane tables, in layout order: left pane then right pane.
    ///
    /// The sidebar's List is an NSTableView too, and including it broke every
    /// caller at once -- pointer-to-pane mapping, click routing and column
    /// widths all index into this array. SwiftUI renders a `Table` as
    /// SwiftUIOutlineTableView and a `List` as SwiftUIOutlineListView, which is
    /// an exact discriminator and does not depend on layout order.
    static func tables(in window: NSWindow) -> [NSTableView] {
        guard let content = window.contentView else { return [] }
        // Text Edit's tree is a table of Diptych's own, never a pane: taken
        // for one, dragging its columns rearranged the panes' columns.
        let all = walk(content).filter { !($0 is TreeOutlineView) }

        let panes = all.filter { String(describing: type(of: $0)).contains("TableView") }
        if !panes.isEmpty { return panes }

        // Should those private class names ever change, fall back to shape:
        // a pane table carries the configured columns, the sidebar list one.
        let expected = ConfigStore.shared.configuration.columns.count
        let byShape = all.filter { $0.tableColumns.count == expected }
        return byShape.isEmpty ? all : byShape
    }

    /// The pane whose table this is -- matched by position the same way click
    /// routing does, so a trash pane can be told from an ordinary one.
    static func pane(of table: NSTableView, in window: NSWindow) -> PaneModel? {
        guard let model = KeyRouter.shared.allModels.first(where: { $0.window === window })
        else { return nil }
        let panes = tables(in: window)
        guard let index = panes.firstIndex(of: table) else { return nil }
        return panes.count == 1 ? model.active : (index == 0 ? model.left : model.right)
    }

    private static func walk(_ view: NSView) -> [NSTableView] {
        if let table = view as? NSTableView { return [table] }
        let children = (view.subviews as NSArray).copy() as? [NSView] ?? []
        return children.flatMap(walk)
    }
}
