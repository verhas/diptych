import AppKit

/// Every window Diptych itself owns -- the two-pane browser and every tool
/// window opened from it (Get Info, Compare, Bin Edit, Text Edit, Rename
/// Many) -- so Option-Tab can cycle all of them.
///
/// `KeyRouter.models` already tracks the browser windows, one `AppModel`
/// each, but a Get Info or Compare window has no `AppModel` behind it at all.
/// This is the one list every kind of window registers with, browser windows
/// included.
@MainActor
final class AppWindows {

    static let shared = AppWindows()
    private init() {}

    private struct WeakWindow { weak var window: NSWindow? }
    private var windows: [WeakWindow] = []

    /// Kept in the order each window first opened, not most-recently-used:
    /// `register` is called again on every SwiftUI update of a window already
    /// registered, and moving it to the end each time would make Option-Tab's
    /// cycle reshuffle under it mid-use. A fixed order is what makes cycling
    /// *through all of them* mean something, rather than just "the next one
    /// AppKit happens to remember".
    func register(_ window: NSWindow) {
        windows.removeAll { $0.window == nil }
        guard !windows.contains(where: { $0.window === window }) else { return }
        windows.append(WeakWindow(window: window))
    }

    /// Currently open windows, with anything closed since pruned away.
    var live: [NSWindow] {
        windows.compactMap(\.window)
    }
}
