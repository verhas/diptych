import AppKit

/// What a non-browser ("tool") window is showing -- one file, a pair of
/// files, a folder -- keyed by the `NSWindow` itself.
///
/// `AppWindows` already tracks every window Diptych owns so Option-Tab can
/// cycle through them, but it only knows they exist, not what each one is
/// for. `KeyRouter` answers that for the two-pane browser windows (one
/// `AppModel` each); this is the same answer for Get Info, Compare, Bin
/// Edit, Text Edit and Rename Many, which have no `AppModel` behind them at
/// all. Needed so code outside the view hierarchy (the MCP server) can
/// describe every open window, not just the browser ones.
@MainActor
final class WindowSubjects {

    static let shared = WindowSubjects()

    struct Subject {
        let kind: String
        let description: String
        /// The live model behind this window -- `DiffDocument`,
        /// `DirectoryDiffModel` -- for a caller that needs more than kind
        /// and description can say (e.g. the MCP diff-query tools). Weak,
        /// same as the window itself: this registry must never be what
        /// keeps either alive.
        weak var model: AnyObject?
    }

    private struct WeakEntry { weak var window: NSWindow?; let subject: Subject }
    private var entries: [WeakEntry] = []

    private init() {}

    func register(_ window: NSWindow, kind: String, description: String, model: AnyObject? = nil) {
        entries.removeAll { $0.window == nil || $0.window === window }
        entries.append(WeakEntry(window: window,
                                 subject: Subject(kind: kind, description: description, model: model)))
    }

    func subject(for window: NSWindow) -> Subject? {
        entries.first { $0.window === window }?.subject
    }
}
