import AppKit
import QuickLookUI

/// Function-key handling, via AppKit rather than SwiftUI.
///
/// SwiftUI's `.onKeyPress` only fires for the focused view and cannot express
/// F5 as a `KeyEquivalent`. A local NSEvent monitor sees every key-down in the
/// process, which is what a Norton-Commander key bar needs.
///
/// There is exactly one monitor for the whole app, and it routes each keystroke
/// to the `AppModel` of the *key window*. One monitor per window would mean
/// every window reacting to every keystroke -- which is the multi-window bug
/// this design exists to avoid.
@MainActor
final class KeyRouter {

    static let shared = KeyRouter()

    /// Virtual key codes: positional, so they survive non-US keyboard layouts,
    /// unlike `event.characters`.
    enum Key: UInt16 {
        case tab = 48, ret = 36, enter = 76, escape = 53
        case space = 49
        // Two delete keys: 51 is the one marked "delete" on an Apple keyboard
        // (backspace elsewhere), 117 is forward-delete -- which is the key
        // marked "Delete" on a PC keyboard. Both must work.
        case delete = 51, forwardDelete = 117
        case home = 115, end = 119, pageUp = 116, pageDown = 121
        case upArrow = 126, downArrow = 125
        case f1 = 122, f2 = 120, f3 = 99, f4 = 118
        case f5 = 96, f6 = 97, f7 = 98, f8 = 100, f9 = 101
    }

    /// Weak, so closing a window lets its model go.
    private struct WeakModel { weak var model: AppModel? }
    private var models: [WeakModel] = []
    private var monitor: Any?

    func register(_ model: AppModel) {
        models.removeAll { $0.model == nil || $0.model === model }
        models.append(WeakModel(model: model))
        install()
    }

    private func install() {
        guard monitor == nil else { return }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // The monitor block is @Sendable, but NSEvent deliberately is not
            // Sendable -- AppKit objects are main-thread-only and the compiler
            // refuses to let one cross an isolation boundary. So pull out the
            // two plain values we need (UInt16 and an OptionSet, both Sendable)
            // and let only those cross.
            let code = event.keyCode
            let flags = event.modifierFlags
            let characters = event.charactersIgnoringModifiers ?? ""

            // The block already runs on the main thread; assumeIsolated states
            // that as a fact rather than hopping actors (which would be async,
            // and this must answer synchronously). Its result must be Sendable
            // too, which is why this yields Bool and the event is returned
            // outside the closure.
            let consumed = MainActor.assumeIsolated { () -> Bool in
                // Option-Tab moves between Diptych's own windows, the same way
                // plain Tab moves between the two panes of one -- independent
                // of whatever has keyboard focus, a text field included, since
                // switching windows is not something typing should be able to
                // block.
                if code == Key.tab.rawValue, flags.contains(.option),
                   !flags.contains(.command), !flags.contains(.control) {
                    return self?.cycleWindows() ?? false
                }

                guard let self, let window = NSApp.keyWindow else { return false }

                // A sheet owns the keyboard while it is up.
                if window.attachedSheet != nil { return false }

                // Never steal keys from a text field: Return in the path bar
                // must mean "commit", not "enter directory".
                if let responder = window.firstResponder,
                   responder is NSText || responder.isKind(of: NSTextView.self) {
                    return false
                }
                // The permissions editor is a plain NSView, so it does not match
                // the text checks above, but it owns the keyboard while open.
                if window.firstResponder is PermissionEditorView { return false }

                // While the Quick Look panel is key it is the key window, and no
                // model owns it -- so without this fallback every shortcut,
                // F2 included, died the moment a preview opened.
                var target = self.models.lazy.compactMap(\.model)
                    .first { $0.window === window }
                if target == nil, window is QLPreviewPanel {
                    target = QuickLookController.shared.owner
                }
                guard let model = target else { return false }

                if let key = Key(rawValue: code) {
                    return model.handle(key: key, modifiers: flags)
                }

                // Command-= is the unshifted half of "Command-plus". The menu
                // carries Command-+, which AppKit matches by character and so
                // only when Shift is held; people press both, and a menu cannot
                // hold a second, hidden equivalent for the same command.
                if flags.contains(.command), !flags.contains(.control),
                   !flags.contains(.option), characters == "=" {
                    PaneFont.zoom(by: 1)
                    return true
                }

                // Control-Command-Z for Undo or Redo Many, Control-Command-R
                // for Rename Many. Both menu items carry these shortcuts and
                // show them, but Control-Command-Z never arrived at the menu
                // bar -- something between the keyboard and the menu takes it,
                // while plain Command-Z arrives. So both are taken here, where
                // keys are seen first, by the route Command-= already needed.
                if flags.contains(.command), flags.contains(.control),
                   !flags.contains(.option) {
                    switch characters.lowercased() {
                    case "z":
                        model.requestHistoryMany()
                        return true
                    case "r":
                        model.requestRenameMany()
                        return true
                    default:
                        break
                    }
                }

                // Anything else printable is type-select. Modifier combinations
                // are left alone so menu shortcuts still reach the menu bar.
                guard !flags.contains(.command),
                      !flags.contains(.control),
                      !flags.contains(.option),
                      characters.count == 1,
                      let scalar = characters.unicodeScalars.first,
                      !CharacterSet.controlCharacters.contains(scalar),
                      !CharacterSet.illegalCharacters.contains(scalar)
                else { return false }

                return model.typeAhead(characters)
            }

            // nil swallows the event; returning it lets it continue down the
            // responder chain.
            return consumed ? nil : event
        }
    }

    /// Brings the next Diptych window forward, in a fixed rotation through
    /// every kind of window Diptych opens -- not only the browser windows a
    /// per-window `AppModel` tracks. With only one window open, and that one
    /// a browser window, it falls back to swapping that window's own panes
    /// instead, so the key still does something.
    private func cycleWindows() -> Bool {
        let live = AppWindows.shared.live
        guard live.count > 1 else {
            guard let only = live.first,
                  let model = models.compactMap(\.model).first(where: { $0.window === only })
            else { return false }
            model.toggleActiveSide()
            return true
        }

        // `AppWindows.live`, not `NSApp.orderedWindows`: the latter is
        // front-to-back order, which changes every time a window comes
        // forward -- so "the next one" kept meaning "the window that was in
        // front before this one", and pressing the key a second time went
        // straight back where it started instead of on to a third window.
        // Advancing through a list that does not reshuffle itself is what
        // makes this an actual round trip through all of them.
        guard let current = NSApp.keyWindow, let index = live.firstIndex(of: current) else {
            live[0].makeKeyAndOrderFront(nil)
            return true
        }
        live[(index + 1) % live.count].makeKeyAndOrderFront(nil)
        return true
    }
}
