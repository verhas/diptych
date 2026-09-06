import SwiftUI
import AppKit

/// In-place editor for the nine rwx bits.
///
/// Not a text field: the content is a fixed nine-slot grid where each slot
/// accepts only three keys, typing overwrites rather than inserts, and the
/// column header has to follow the caret. A plain NSView handling its own
/// keyDown is far less work than bending NSTextField into that shape.
final class PermissionEditorView: NSView {

    var characters: [Character] = Array("---------") { didSet { needsDisplay = true } }
    var cursor = 0 {
        didSet {
            guard cursor != oldValue else { return }
            onCursorChange?(cursor)
            needsDisplay = true
        }
    }

    var onCursorChange: ((Int) -> Void)?
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    /// Matches the font the non-editing cells use, so an edited row's columns
    /// of characters line up with the rows above and below it.
    static let fontSize: CGFloat = 13

    private let font = NSFont.monospacedSystemFont(ofSize: PermissionEditorView.fontSize,
                                                   weight: .regular)
    private var slotWidth: CGFloat {
        ("m" as NSString).size(withAttributes: [.font: font]).width
    }

    private var group: Int { cursor / 3 }

    /// Which letter each slot means: r, w, x.
    static func letter(at index: Int) -> Character {
        switch index % 3 {
        case 0:  "r"
        case 1:  "w"
        default: "x"
        }
    }

    static func scope(at index: Int) -> String {
        switch index / 3 {
        case 0:  "user"
        case 1:  "group"
        default: "other"
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        let focused = window?.firstResponder === self

        // The whole group is tinted, because r/w/x act on the group rather than
        // on the single slot under the caret; the caret itself is what -, + and
        // space act on.
        if focused {
            let groupRect = NSRect(x: CGFloat(group * 3) * slotWidth, y: 0,
                                   width: slotWidth * 3, height: bounds.height)
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            groupRect.fill()
        }

        for (index, character) in characters.enumerated() {
            let slot = NSRect(x: CGFloat(index) * slotWidth, y: 0,
                              width: slotWidth, height: bounds.height)
            var colour = NSColor.labelColor

            if index == cursor && focused {
                NSColor.controlAccentColor.setFill()
                slot.fill()
                colour = .white
            } else if character == "-" {
                colour = .tertiaryLabelColor
            }

            let text = String(character) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: slot.midX - size.width / 2,
                                  y: slot.midY - size.height / 2),
                      withAttributes: attributes)
        }
    }

    private func advance() {
        if cursor < 8 { cursor += 1 } else { needsDisplay = true }
    }

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        // charactersIgnoringModifiers is why Option works here: Option-r would
        // otherwise arrive as "®".
        let option = event.modifierFlags.contains(.option)

        switch event.keyCode {
        // Arrows always move one bit. They used to jump a whole group, which
        // meant the caret could only ever sit on a group's `r` bit -- so `-`
        // could not clear write or execute at all. Group jumping is a
        // shortcut, and lives on Tab.
        case 123: cursor = max(0, cursor - 1); return          // left
        case 124: cursor = min(8, cursor + 1); return          // right
        case 48:                                                // tab
            cursor = shift ? max(0, (group - 1) * 3) : min(8, (group + 1) * 3)
            return
        case 115: cursor = 0; return                           // home
        case 119: cursor = 8; return                           // end
        case 36, 76: onCommit?(String(characters)); return     // return
        case 53:  onCancel?(); return                          // escape
        case 51:                                               // backspace
            // Steps back and clears, which pairs with `-` and `+` advancing.
            cursor = max(0, cursor - 1)
            characters[cursor] = "-"
            return
        default:
            break
        }

        guard let typed = event.charactersIgnoringModifiers?.lowercased().first else { return }

        switch typed {
        case "r", "w", "x":
            // Acts on the matching bit of the *current group*, wherever the
            // caret sits inside it, and leaves the caret alone: Shift clears,
            // Option toggles, bare sets.
            let offset: Int = typed == "r" ? 0 : (typed == "w" ? 1 : 2)
            let index = group * 3 + offset
            if option {
                characters[index] = characters[index] == "-" ? typed : "-"
            } else {
                characters[index] = shift ? "-" : typed
            }
            needsDisplay = true

        // The caret-scoped edits advance, so a whole mode can be typed straight
        // through: "-+-" and so on. The group-scoped letters above do not,
        // because they act on a bit the caret is not sitting on.
        case "-":
            characters[cursor] = "-"
            advance()

        case "+":
            characters[cursor] = Self.letter(at: cursor)
            advance()

        case " ":
            characters[cursor] = characters[cursor] == "-" ? Self.letter(at: cursor) : "-"
            advance()

        default:
            NSSound.beep()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursor = min(8, max(0, Int(point.x / slotWidth)))
        window?.makeFirstResponder(self)
    }
}

struct PermissionField: NSViewRepresentable {

    let text: String
    let onCursor: (Int) -> Void
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> PermissionEditorView {
        let view = PermissionEditorView()
        view.characters = Array(text)
        view.onCursorChange = onCursor
        view.onCommit = onCommit
        view.onCancel = onCancel

        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
            onCursor(view.cursor)
        }
        return view
    }

    func updateNSView(_ view: PermissionEditorView, context: Context) {
        view.onCursorChange = onCursor
        view.onCommit = onCommit
        view.onCancel = onCancel
        if String(view.characters) != text {
            view.characters = Array(text)
        }
    }
}
