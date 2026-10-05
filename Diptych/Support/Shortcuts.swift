import AppKit
import SwiftUI

/// Every command's key, written down once.
///
/// The menu bar and the right-click menus both show them, and two copies of
/// "which key does Paste as Link" would drift apart the first time one was
/// changed. A right-click menu shows the key only as a reminder: SwiftUI does
/// not make a context menu's shortcut work while the menu is closed, so the
/// menu bar -- or `KeyRouter`, for the function keys -- stays what answers it.
extension KeyboardShortcut {
    static let newTab           = KeyboardShortcut("t")
    static let newFolder        = KeyboardShortcut("n", modifiers: [.command, .shift])
    static let newFile          = KeyboardShortcut("n", modifiers: [.command, .option])
    static let newFromClipboard = KeyboardShortcut("v", modifiers: [.command, .shift])

    static let open             = KeyboardShortcut(.downArrow, modifiers: .command)
    static let getInfo          = KeyboardShortcut("i")
    /// ⌥↩: Return opens, Option is "the other way" -- run, with arguments.
    static let runWithArguments = KeyboardShortcut(.return, modifiers: .option)
    static let compare          = KeyboardShortcut("d", modifiers: .command)
    /// F2, answered by `KeyRouter`. A menu-bar item cannot carry it: the key
    /// would then rename a file while someone was typing in the path bar.
    static let rename           = KeyboardShortcut(.f2, modifiers: [])
    static let renameMany       = KeyboardShortcut("r", modifiers: [.command, .control])
    static let renameSuggested  = KeyboardShortcut(.f2, modifiers: .command)

    static let copyToOtherPane  = KeyboardShortcut("c", modifiers: [.command, .shift])
    static let moveToOtherPane  = KeyboardShortcut("m", modifiers: [.command, .shift])
    static let changePermissions = KeyboardShortcut("p", modifiers: [.command, .option])

    static let sendWork         = KeyboardShortcut("s", modifiers: [.command, .shift])
    static let getLatest        = KeyboardShortcut("d", modifiers: [.command, .shift])
    static let checkForChanges  = KeyboardShortcut("k", modifiers: [.command, .shift])

    /// Straight to the Trash, no question: the menu bar's Move to Trash.
    static let trashNow         = KeyboardShortcut(.delete, modifiers: .command)
    /// Asks first: the right-click menu's Move to Trash, which is what plain
    /// Delete does (and F8, which a menu has no room to show as well).
    static let trash            = KeyboardShortcut(.delete, modifiers: [])

    static let revealInFinder   = KeyboardShortcut("r", modifiers: [.command, .option])
    static let openTerminal     = KeyboardShortcut("t", modifiers: [.command, .option])

    static let cut              = KeyboardShortcut("x")
    static let copy             = KeyboardShortcut("c")
    static let paste            = KeyboardShortcut("v")
    static let pasteAsLink      = KeyboardShortcut("v", modifiers: [.command, .control])
    static let selectAll        = KeyboardShortcut("a")
    static let copyNames        = KeyboardShortcut("c", modifiers: [.command, .option])
    static let copyPaths        = KeyboardShortcut("c", modifiers: [.command, .option, .shift])
    static let copyContent      = KeyboardShortcut("c", modifiers: [.command, .control])

    static let refresh          = KeyboardShortcut("r", modifiers: .command)

    /// Control-backquote, as in VS Code. Nothing else in Diptych uses the key.
    static let toggleTerminal   = KeyboardShortcut("`", modifiers: .control)
}

extension KeyEquivalent {
    /// The function keys' own code points; SwiftUI has no names for them.
    static let f2 = KeyEquivalent("\u{F705}")
}

extension NSMenuItem {
    /// The same key, for a menu built in AppKit rather than SwiftUI.
    func show(_ shortcut: KeyboardShortcut) {
        keyEquivalent = String(shortcut.key.character)
        var mask: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { mask.insert(.command) }
        if shortcut.modifiers.contains(.shift) { mask.insert(.shift) }
        if shortcut.modifiers.contains(.option) { mask.insert(.option) }
        if shortcut.modifiers.contains(.control) { mask.insert(.control) }
        keyEquivalentModifierMask = mask
    }
}
