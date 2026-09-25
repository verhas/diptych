import SwiftUI
import AppKit

/// A plain text editor for one file, whatever application the file normally
/// opens in -- the text counterpart of Bin Edit.
///
/// Deliberately small: typing, undo, find, wrapping, saving. What it takes
/// care over is what a general editor gets wrong on files that are not prose:
/// nothing is "corrected", no quote turns curly, no double hyphen becomes a
/// dash, and the line endings and encoding the file came with are the ones it
/// is saved with.
struct TextEditView: View {

    let url: URL

    @State private var document: TextEditDocument
    @State private var wraps = true
    @State private var guard_ = CloseGuard()
    @State private var finder = FindTrigger()
    @State private var window: NSWindow?

    init(url: URL) {
        self.url = url
        _document = State(initialValue: TextEditDocument(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            if let failure = document.failure {
                ContentUnavailableView {
                    Label("Cannot Edit as Text", systemImage: "doc.text")
                } description: {
                    Text(failure)
                }
            } else {
                PlainTextEditor(document: document, wraps: wraps, finder: finder)
            }
        }
        .navigationTitle(title)
        .background(WindowAccessor { window in
            if let window { AppWindows.shared.register(window) }
            // Resolved on every update; set once, so a closure is not rebuilt
            // and a delegate not reassigned on each keystroke's redraw.
            guard let found = window, found.delegate !== guard_ else { return }
            self.window = found
            guard_.shouldClose = { closeIsAllowed() }
            guard_.willClose = { DiffWindows.shared.releaseFromEditing(url) }
            found.delegate = guard_
        })
        .onChange(of: document.isEdited) { _, edited in
            // The dot in the close button: the unsaved-changes cue every Mac
            // window gives.
            window?.isDocumentEdited = edited
        }
        .onAppear {
            DiffWindows.shared.claimForEditing(url)
            document.load()
        }
    }

    private var title: String {
        "\(url.lastPathComponent) \u{2014} "
            + NamingTemplate.tilde(url.deletingLastPathComponent().path)
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Button("Save") { saveNow() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!document.isEdited || document.isReadOnly)
            Button { finder.show() } label: { Image(systemName: "magnifyingglass") }
                .keyboardShortcut("f", modifiers: .command)
                .help("Find and replace (\u{2318}F)")
                .disabled(document.failure != nil)
            Toggle("Wrap lines", isOn: $wraps)
                .toggleStyle(.checkbox)

            Spacer()

            if document.isReadOnly, document.failure == nil {
                Label("Read only \u{2014} this file cannot be written to",
                      systemImage: "lock")
                    .foregroundStyle(.orange)
            } else if document.isEdited {
                Text("Edited").foregroundStyle(.secondary)
            }
            Text(document.summary)
                .foregroundStyle(.secondary)
                .help("Saving keeps the file's encoding and line endings as they are.")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func saveNow(overwriting: Bool = false) {
        switch document.save(overwriting: overwriting) {
        case .saved, .nothingToDo:
            break
        case .changedUnderneath:
            let alert = NSAlert()
            alert.messageText = "\u{201C}\(url.lastPathComponent)\u{201D} has been changed "
                + "since it was opened here."
            alert.informativeText = "Something else wrote to it in the meantime. Saving now "
                + "replaces that version with what is in this window."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Save Anyway")
            if alert.runModal() == .alertSecondButtonReturn { saveNow(overwriting: true) }
        case .failed(let message):
            let alert = NSAlert()
            alert.messageText = "\u{201C}\(url.lastPathComponent)\u{201D} was not saved."
            alert.informativeText = message
            alert.runModal()
        }
    }

    /// An `NSAlert`, because the answer has to go back to AppKit as the return
    /// value of `windowShouldClose`.
    private func closeIsAllowed() -> Bool {
        guard document.hasUnsavedChanges else { return true }

        let alert = NSAlert()
        alert.messageText = "Save the changes to \u{201C}\(url.lastPathComponent)\u{201D}?"
        alert.informativeText = "If you close without saving, what you typed is lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveNow()
            // A save that did not go through must not take the window with it.
            return !document.hasUnsavedChanges
        case .alertSecondButtonReturn:
            return false
        default:
            return true
        }
    }
}

/// Lets a toolbar button open the text view's find bar.
@MainActor
final class FindTrigger {
    weak var textView: NSTextView?

    func show() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.performTextFinderAction(
            NSMenuItem.findItem(NSTextFinder.Action.showFindInterface))
    }
}

private extension NSMenuItem {
    /// `performTextFinderAction` reads the action from its sender's tag.
    static func findItem(_ action: NSTextFinder.Action) -> NSMenuItem {
        let item = NSMenuItem()
        item.tag = action.rawValue
        return item
    }
}

/// An `NSTextView` set up for files rather than prose.
struct PlainTextEditor: NSViewRepresentable {

    let document: TextEditDocument
    let wraps: Bool
    let finder: FindTrigger

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let text = scroll.documentView as? NSTextView else { return scroll }

        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        // Every one of these rewrites what was typed, which in a script, a
        // configuration file or a CSV silently changes what it means.
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.isAutomaticTextCompletionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.isGrammarCheckingEnabled = false
        text.smartInsertDeleteEnabled = false
        text.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        text.textContainerInset = NSSize(width: 6, height: 8)
        text.delegate = context.coordinator

        finder.textView = text
        document.currentText = { [weak text] in text?.string ?? "" }
        context.coordinator.shownRevision = -1
        apply(wraps: wraps, to: scroll, text: text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        context.coordinator.document = document

        // Replaced only when the file was read, never on an ordinary update:
        // setting the string also throws away the undo history.
        if context.coordinator.shownRevision != document.revision {
            context.coordinator.shownRevision = document.revision
            text.string = document.saved
            text.undoManager?.removeAllActions()
            let end = (text.string as NSString).length
            text.setSelectedRange(NSRange(location: end, length: 0))
            // Without this, an empty file opened with nothing else in the
            // window able to take first responder left the caret nowhere:
            // the very first keystroke reached no text view at all and rang
            // the system bell instead of typing. Deferred a turn because the
            // window may not be key yet the instant this view is installed.
            DispatchQueue.main.async { text.window?.makeFirstResponder(text) }
        }
        text.isEditable = !document.isReadOnly
        apply(wraps: wraps, to: scroll, text: text)
    }

    /// Wrapping is a property of the text container, not of the view: the
    /// container either follows the width of the view or is as wide as the
    /// longest line, and the scroll view offers a horizontal bar to match.
    private func apply(wraps: Bool, to scroll: NSScrollView, text: NSTextView) {
        guard let container = text.textContainer else { return }
        let big = CGFloat.greatestFiniteMagnitude
        if wraps {
            guard !container.widthTracksTextView else { return }
            scroll.hasHorizontalScroller = false
            text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]
            container.widthTracksTextView = true
            text.frame.size.width = scroll.contentSize.width
            container.containerSize = NSSize(width: scroll.contentSize.width, height: big)
        } else {
            guard container.widthTracksTextView else { return }
            scroll.hasHorizontalScroller = true
            text.isHorizontallyResizable = true
            text.autoresizingMask = []
            text.maxSize = NSSize(width: big, height: big)
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: big, height: big)
        }
        text.layoutManager?.ensureLayout(for: container)
    }

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var document: TextEditDocument
        var shownRevision = -1

        init(document: TextEditDocument) { self.document = document }

        func textDidChange(_ notification: Notification) {
            document.noteEdit()
        }
    }
}
