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
    /// Every window ever registered, closed ones included, so one that
    /// SwiftUI shows again can be put back on the list.
    private var known: [WeakWindow] = []

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
        // A `WindowGroup` asked again for the same value -- the same images
        // in the EXIF editor, the same file's siblings -- shows the window it
        // closed before, and its view is not built again, so nothing in it
        // registers it a second time. It was left out of Option-Tab and the
        // Dock's list. Coming to the front is what puts it back.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard let self, self.known.contains(where: { $0.window === window }) else { return }
                self.register(window)
            }
        }
    }

    /// Kept in the order each window first opened, not most-recently-used:
    /// `register` is called again on every SwiftUI update of a window already
    /// registered, and moving it to the end each time would make Option-Tab's
    /// cycle reshuffle under it mid-use. A fixed order is what makes cycling
    /// *through all of them* mean something, rather than just "the next one
    /// AppKit happens to remember".
    func register(_ window: NSWindow) {
        // In the Window menu, which is also the list the Dock shows: a
        // SwiftUI `Window` scene leaves its window out of it.
        if window.isExcludedFromWindowsMenu { window.isExcludedFromWindowsMenu = false }
        known.removeAll { $0.window == nil }
        if !known.contains(where: { $0.window === window }) {
            known.append(WeakWindow(window: window))
        }
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
