import SwiftUI
import AppKit

/// Which files are open in a comparison window.
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

    private init() {}

    func alreadyOpen(_ pair: DiffPair) -> URL? {
        for url in [pair.left, pair.right] where open.contains(FileOperations.canonicalPath(url)) {
            return url
        }
        return nil
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
