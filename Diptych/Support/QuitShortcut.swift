import AppKit

/// What ⌘Q does: quit Diptych when a two-pane window is in front, and
/// otherwise close the window that is -- a comparison, the Runs window, Text
/// Edit, Settings -- as though it were an application of its own. Pressed
/// over a comparison, quitting the whole of Diptych, two-pane windows and
/// all, was never what was meant.
///
/// Only the key: the system's own Quit -- the Dock's, logging out -- still
/// quits, and asks first as Settings say.
@MainActor
enum QuitShortcut {

    /// The window ⌘Q closes instead of quitting; nil when it should quit. A
    /// sheet stands for the window it hangs from.
    static var windowToClose: NSWindow? {
        guard let key = NSApp.keyWindow else { return nil }
        let window = key.sheetParent ?? key
        let browsers = KeyRouter.shared.allModels.compactMap(\.window)
        return browsers.contains(window) ? nil : window
    }

    /// Closed as its close button would close it, so a window that asks
    /// before closing -- Runs, with something still running -- still asks.
    static func perform() {
        if let window = windowToClose {
            window.performClose(nil)
        } else {
            NSApp.terminate(nil)
        }
    }
}
