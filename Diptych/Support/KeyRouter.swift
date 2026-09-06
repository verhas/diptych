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
        case f1 = 122, f2 = 120, f3 = 99, f4 = 118
        case f5 = 96, f6 = 97, f7 = 98, f8 = 100
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
                guard let self, let window = NSApp.keyWindow else { return false }

                // A sheet owns the keyboard while it is up.
                if window.attachedSheet != nil { return false }

                // Never steal keys from a text field: Return in the path bar
                // must mean "commit", not "enter directory".
                if let responder = window.firstResponder,
                   responder is NSText || responder.isKind(of: NSTextView.self) {
                    return false
                }

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
}
