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

    private struct WeakWindow { weak var window: NSWindow? }
    private var windows: [WeakWindow] = []

    /// A `WindowGroup(for:)` scene can hold onto a "closed" window's state --
    /// `NSWindow.willCloseNotification` still fires the moment AppKit closes
    /// it, regardless of whatever SwiftUI keeps alive behind the scenes, so
    /// pruning off that rather than waiting for the weak reference to go nil
    /// is what keeps a closed window from being cycled back to.
    private init() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.unregister(window) }
        }
    }

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

    func unregister(_ window: NSWindow) {
        windows.removeAll { $0.window == nil || $0.window === window }
    }

    /// Currently open windows, with anything closed since pruned away.
    var live: [NSWindow] {
        windows.compactMap(\.window)
    }
}
