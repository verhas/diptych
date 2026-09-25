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

    func register(_ window: NSWindow) {
        windows.removeAll { $0.window == nil || $0.window === window }
        windows.append(WeakWindow(window: window))
    }

    /// Currently open windows, with anything closed since pruned away.
    var live: [NSWindow] {
        windows.compactMap(\.window)
    }
}
