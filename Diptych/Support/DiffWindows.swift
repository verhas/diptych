import SwiftUI
import AppKit

/// Which files are open in a comparison window or in Text Edit.
///
/// Two windows editing one file is a way to lose work with no warning at all:
/// each saves the whole file from its own copy, so whichever is saved second
/// quietly wins. Refused rather than reconciled.
///
/// It refuses even when neither side is unlocked, which is slightly more than
/// strictly necessary -- two read-only comparisons of the same file harm
/// nothing. The narrower rule would have to change the moment somebody unlocks
/// a side, which is exactly when they are least expecting to be stopped.
@MainActor
final class DiffWindows {

    static let shared = DiffWindows()
    private var open: Set<String> = []
    /// Files open in Text Edit. Kept apart from comparisons so a second Text
    /// Edit on the same file can bring its window forward instead of being
    /// refused -- while a comparison and a Text Edit of one file, which would
    /// each save over the other, are still refused either way round.
    private var editing: Set<String> = []

    private init() {}

    func alreadyOpen(_ pair: DiffPair) -> URL? {
        for url in [pair.left, pair.right] {
            let path = FileOperations.canonicalPath(url)
            if open.contains(path) || editing.contains(path) { return url }
        }
        return nil
    }

    func isInComparison(_ url: URL) -> Bool {
        open.contains(FileOperations.canonicalPath(url))
    }

    func claimForEditing(_ url: URL) {
        editing.insert(FileOperations.canonicalPath(url))
    }

    func releaseFromEditing(_ url: URL) {
        editing.remove(FileOperations.canonicalPath(url))
    }

    func claim(_ pair: DiffPair) {
        open.insert(FileOperations.canonicalPath(pair.left))
        open.insert(FileOperations.canonicalPath(pair.right))
    }

    func release(_ pair: DiffPair) {
        open.remove(FileOperations.canonicalPath(pair.left))
        open.remove(FileOperations.canonicalPath(pair.right))
    }
}

/// Holds a window's close question, so the answer can be given from AppKit
/// while the state lives in SwiftUI.
@MainActor
final class CloseGuard: NSObject, NSWindowDelegate {

    /// What to ask about, and what to do about it. Returning true lets the
    /// window close.
    var shouldClose: (() -> Bool)?
    /// Run once the window really is closing.
    ///
    /// This, not `onDisappear`: SwiftUI does not reliably call that when a
    /// window is closed, which left the file registered as open for the rest
    /// of the session and refused every later attempt to compare it. Cmd-W
    /// showed it every time.
    var willClose: (() -> Void)?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldClose?() ?? true
    }

    func windowWillClose(_ note: Notification) {
        willClose?()
        willClose = nil
    }
}

/// Asks before a browser window closes while its agent terminal is busy.
///
/// The browser window's delegate is SwiftUI's own, and it does a great deal
/// -- tabs, restoring, the scene -- so this does not replace it, as the
/// Compare and Text Edit windows' `CloseGuard` does. It stands in front of
/// it: `windowShouldClose` is answered here, and every other delegate message
/// is passed straight through to SwiftUI's.
@MainActor
final class BrowserCloseGuard: NSObject, NSWindowDelegate {

    /// Read by `responds(to:)` and `forwardingTarget(for:)`, which AppKit
    /// declares nonisolated; it calls them, like every delegate message, on
    /// the main thread, and this is set once, before the guard is installed.
    nonisolated(unsafe) private weak var original: NSWindowDelegate?
    private weak var model: AppModel?

    /// Puts a guard in front of the window's current delegate, once.
    static func install(on window: NSWindow, for model: AppModel) -> BrowserCloseGuard? {
        guard !(window.delegate is BrowserCloseGuard) else { return nil }
        let guard_ = BrowserCloseGuard()
        guard_.original = window.delegate
        guard_.model = model
        window.delegate = guard_
        return guard_
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let name = model?.terminal?.runningCommandName, !confirm(sender, name) { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    /// A busy agent terminal ends with its window -- the agent, the task it
    /// was in the middle of, and the conversation with it. Asked only then: a
    /// shell waiting at its prompt has nothing to lose.
    private func confirm(_ window: NSWindow, _ name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Close this window and end \u{201C}\(name)\u{201D}?"
        alert.informativeText = "\u{201C}\(name)\u{201D} is still running in this window\u{2019}s "
            + "agent terminal. Closing the window ends it, along with anything it is in the "
            + "middle of."
        alert.addButton(withTitle: "Close Window")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        // Cancel on Return: closing is the one that cannot be taken back.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    // Everything else is SwiftUI's business.
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}
