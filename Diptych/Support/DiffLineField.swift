import SwiftUI
import AppKit

/// One editable line of a comparison.
///
/// AppKit rather than a SwiftUI `TextField` for two reasons. The caret: only
/// `doCommandBy` hands over the text view, and only its selected range says
/// *where* in the line Return was pressed -- without which Return can append a
/// line but not split the one you are in, and Backspace at the start cannot
/// join it to the one above.
///
/// And an `NSTextView` rather than an `NSTextField`, because a text field can
/// hold exactly one unwrapped line. The other column is ordinary text and
/// wraps; a field could not, so the two halves of a comparison disagreed about
/// what a long line looks like.
struct DiffLineField: NSViewRepresentable {

    let text: String
    let wraps: Bool
    /// How wide the text is allowed to be, given by the view that lays the
    /// columns out.
    ///
    /// Not taken from the proposal: SwiftUI probes a representable with an
    /// *infinite* width to find its ideal size, and writing that into the text
    /// container made it infinitely wide -- so the line stopped wrapping while
    /// the row kept the height an earlier, finite probe had measured. The
    /// caller already knows the real number; asking it is the only reliable
    /// way to have it.
    let width: CGFloat
    /// Every keystroke. The document takes the text at once -- so Save, Undo
    /// and the dirty mark are immediately true -- and leaves the alignment
    /// alone until the line is finished.
    let onType: (String) -> Void
    /// The caret has left the line.
    let onFinish: () -> Void
    /// Return, with where the caret was.
    let onSplit: (Int) -> Void
    /// Backspace with the caret at the very start and nothing selected.
    let onJoin: () -> Void
    /// Escape: put the line back to what it was when typing began.
    let onRevert: () -> Void
    /// Where the caret is, measured from the start of the line.
    ///
    /// Without this, typing past the right-hand edge of an unwrapped column
    /// carried on off-screen: the text was scrollable but would not follow the
    /// person writing it, which is the one moment it has to.
    let onCaret: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.delegate = context.coordinator
        view.string = text
        view.font = Self.font
        view.drawsBackground = false
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        apply(wraps: wraps, to: view)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.parent = self
        apply(wraps: wraps, to: view)
        // Never overwrite what is being typed.
        if !context.coordinator.isEditing, view.string != text {
            view.string = text
        }
    }

    private func apply(wraps: Bool, to view: NSTextView) {
        // Never `widthTracksTextView`. With it on, the container takes its
        // width from the view, which during measurement is still the width it
        // had *before* the window was resized -- so a narrowed window was
        // measured against the old wide one, every wrapped line was given the
        // height of fewer lines than it needed, and the overflow was drawn on
        // top of the row below. Scrolling away and back fixed it, which is
        // exactly what a stale measurement looks like.
        view.textContainer?.widthTracksTextView = false
        view.isHorizontallyResizable = !wraps
        view.textContainer?.containerSize = CGSize(width: usableWidth, height: 1e6)
    }

    /// Always finite, always positive: an infinite or zero container is a line
    /// that never wraps or wraps at every character.
    private var usableWidth: CGFloat {
        guard wraps else { return 1e7 }
        guard width.isFinite, width > 1 else { return 1e7 }
        return width
    }

    /// The row's height, which is what keeps the two columns level when a long
    /// line wraps on one side and not the other.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView,
                      context: Context) -> CGSize? {
        // An unwrapped row is one line, always, so there is nothing to measure
        // and nothing that can go stale.
        guard wraps else { return CGSize(width: width, height: Self.oneLine) }
        guard let container = nsView.textContainer,
              let layout = nsView.layoutManager else { return nil }

        // Measured at exactly the width the text will be laid out at, because
        // both come from the same number rather than from whatever SwiftUI
        // happens to be proposing at the time.
        container.containerSize = CGSize(width: usableWidth, height: 1e6)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        return CGSize(width: width, height: max(ceil(used) + 1, Self.oneLine))
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    /// One line of that font, rounded up. In the unwrapped case every row is
    /// exactly this, so there is nothing to measure and nothing to get stale.
    static let oneLine = ceil(NSLayoutManager().defaultLineHeight(for: font)) + 1
    /// Monospaced, so one character's width is every character's width.
    static let characterWidth = ("0" as NSString).size(withAttributes: [.font: font]).width

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: DiffLineField
        private(set) var isEditing = false
        private var handled = false

        init(_ parent: DiffLineField) { self.parent = parent }

        func textDidBeginEditing(_ note: Notification) { isEditing = true }

        func textViewDidChangeSelection(_ note: Notification) {
            guard let view = note.object as? NSTextView, view.window?.firstResponder === view,
                  let layout = view.layoutManager, let container = view.textContainer
            else { return }
            let range = view.selectedRange()
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            parent.onCaret(rect.maxX)
        }

        func textDidChange(_ note: Notification) {
            guard let view = note.object as? NSTextView else { return }
            parent.onType(view.string)
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertLineBreak(_:)):
                handled = true
                parent.onType(view.string)
                parent.onSplit(view.selectedRange().location)
                return true

            case #selector(NSResponder.deleteBackward(_:)):
                let range = view.selectedRange()
                guard range.location == 0, range.length == 0 else { return false }
                handled = true
                parent.onJoin()
                return true

            case #selector(NSResponder.cancelOperation(_:)):
                handled = true
                parent.onRevert()
                view.window?.makeFirstResponder(nil)
                return true

            // A single line has nowhere to move the caret to, so there has to
            // be a way out of it that is not the mouse.
            //
            // `handled` is deliberately left alone: dropping first responder
            // ends editing, and that path is what tells the document the line
            // is finished. Marking it handled swallowed exactly that, so the
            // text changed and the colours did not.
            case #selector(NSResponder.insertTab(_:)),
                 #selector(NSResponder.insertBacktab(_:)):
                view.window?.makeFirstResponder(nil)
                return true

            default:
                return false
            }
        }

        func textDidEndEditing(_ note: Notification) {
            isEditing = false
            guard !handled else {
                handled = false
                return
            }
            if let view = note.object as? NSTextView { parent.onType(view.string) }
            parent.onFinish()
        }
    }
}
