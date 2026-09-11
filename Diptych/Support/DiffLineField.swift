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

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.delegate = context.coordinator
        view.string = text
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
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
        view.textContainer?.widthTracksTextView = wraps
        view.isHorizontallyResizable = !wraps
        if !wraps {
            view.textContainer?.containerSize = CGSize(width: 1e7, height: 1e7)
        }
    }

    /// Asked for the row's height, which is what keeps the two columns level
    /// when a long line wraps on one side and not the other.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView,
                      context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        guard width > 0, let container = nsView.textContainer,
              let layout = nsView.layoutManager else { return nil }
        if wraps { container.containerSize = CGSize(width: width, height: 1e6) }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        return CGSize(width: width, height: max(used, 15))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: DiffLineField
        private(set) var isEditing = false
        private var handled = false

        init(_ parent: DiffLineField) { self.parent = parent }

        func textDidBeginEditing(_ note: Notification) { isEditing = true }

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
            case #selector(NSResponder.insertTab(_:)),
                 #selector(NSResponder.insertBacktab(_:)):
                handled = true
                parent.onType(view.string)
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
