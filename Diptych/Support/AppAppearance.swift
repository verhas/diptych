import AppKit

/// Applies the chosen light/dark theme to the whole application at once, by
/// setting `NSApplication`'s appearance rather than each window's.
///
/// A per-window `.preferredColorScheme` reaches only the window it is on, so
/// Text Edit, Bin Edit, Release Notes, Info, Compare and the rest -- each its
/// own scene -- kept opening in the system appearance whatever the setting
/// said. The application's appearance is the default every window inherits
/// unless it overrides it, and nothing here does, so setting it once themes
/// them all, the ones already open included, and the AppKit views inside them.
enum AppAppearance {

    /// Callable from anywhere -- config can change off the main thread. AppKit's
    /// appearance must be set on it, so this applies synchronously when already
    /// there and hops over when not.
    static func apply(_ theme: Configuration.AppearanceTheme) {
        let appearance: NSAppearance? = switch theme {
        case .system: nil   // nil hands the choice back to the Mac's own setting
        case .light:  NSAppearance(named: .aqua)
        case .dark:   NSAppearance(named: .darkAqua)
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { NSApplication.shared.appearance = appearance }
        } else {
            Task { @MainActor in NSApplication.shared.appearance = appearance }
        }
    }
}
