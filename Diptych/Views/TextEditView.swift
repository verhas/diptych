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
    @State private var link = EditorLink()
    @State private var window: NSWindow?
    @Bindable private var store = ConfigStore.shared

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
                if let problem = document.problem, let format = document.format {
                    problemBar(problem, format: format)
                    Divider()
                }
                PlainTextEditor(document: document, wraps: wraps, finder: finder, link: link,
                                lineNumbers: store.configuration.textLineNumbers,
                                formats: store.configuration.textFormats)
            }
        }
        .navigationTitle(title)
        .background(WindowAccessor { window in
            if let window {
                AppWindows.shared.register(window)
                WindowSubjects.shared.register(window, kind: "textEdit", description: url.path)
            }
            // Registered on every update, not only the first: `AppModel`
            // looks a document up here by URL to force a reload the moment
            // the user asks to open this file again, which must work even if
            // `WindowGroup(for:)` handed back a window whose delegate is
            // already `guard_` -- see `OpenTextDocuments`.
            OpenTextDocuments.shared.register(document, for: url)
            // The rest is guarded to run once per *real* window rather than
            // on `.onAppear`: a `WindowGroup(for:)` scene can keep a closed
            // window's state and never call `.onAppear` again when the same
            // URL is reopened. The delegate check below is `true` exactly
            // once per actual AppKit window, reopened or not.
            guard let found = window, found.delegate !== guard_ else { return }
            self.window = found
            document.load()
            DiffWindows.shared.claimForEditing(url)
            guard_.shouldClose = { closeIsAllowed() }
            guard_.willClose = { DiffWindows.shared.releaseFromEditing(url) }
            found.delegate = guard_
        })
        // A commit made elsewhere moves the base of the commit bar.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
            note in
            if let window, note.object as? NSWindow === window { link.controller?.loadBaseline() }
        }
        .onChange(of: document.isEdited) { _, edited in
            // The dot in the close button: the unsaved-changes cue every Mac
            // window gives.
            window?.isDocumentEdited = edited
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
            Button {
                store.configuration.textLineNumbers = store.configuration.textLineNumbers.next
            } label: {
                Image(systemName: store.configuration.textLineNumbers.icon)
            }
            .help("\(store.configuration.textLineNumbers.title) \u{2014} click for "
                  + "\(store.configuration.textLineNumbers.next.title.lowercased())")
            if document.format != nil {
                Button { link.controller?.foldAll() } label: {
                    Image(systemName: "rectangle.compress.vertical")
                }
                .help("Fold everything that folds")
                Button { link.controller?.unfoldAll() } label: {
                    Image(systemName: "rectangle.expand.vertical")
                }
                .help("Unfold everything")
            }

            Spacer()

            if document.isReadOnly, document.failure == nil {
                Label("Read only \u{2014} this file cannot be written to",
                      systemImage: "lock")
                    .foregroundStyle(.orange)
            } else if document.isEdited {
                Text("Edited").foregroundStyle(.secondary)
            }
            if let format = document.format, document.problem == nil {
                Label(format.title, systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                    .help("Well-formed \(format.title), by its extension")
            }
            Text(document.summary)
                .foregroundStyle(.secondary)
                .help("Saving keeps the file's encoding and line endings as they are.")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Where the file breaks its format, and a way to it.
    private func problemBar(_ problem: SyntaxProblem, format: TextFormat) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text("Not valid \(format.title) \u{2014} line \(problem.line), column "
                 + "\(problem.column): \(problem.message)")
                .foregroundStyle(.red)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer()
            Button("Show") { link.controller?.revealProblem() }
                .help("Put the caret where the problem is")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func saveNow(overwriting: Bool = false) {
        switch document.save(overwriting: overwriting) {
        case .saved:
            link.controller?.saved()
        case .nothingToDo:
            break
        case .changedUnderneath:
            let alert = NSAlert()
            alert.messageText = "\u{201C}\(url.lastPathComponent)\u{201D} has been changed "
                + "since it was opened here."
            alert.informativeText = "Something else wrote to it in the meantime. Saving now "
                + "replaces that version with what is in this window."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Save Anyway")
            if alert.runSelectable() == .alertSecondButtonReturn { saveNow(overwriting: true) }
        case .failed(let message):
            let alert = NSAlert()
            alert.messageText = "\u{201C}\(url.lastPathComponent)\u{201D} was not saved."
            alert.informativeText = message
            alert.runSelectable()
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

        switch alert.runSelectable() {
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

/// The editor, from the window's bar: its problem, its folds.
@MainActor
final class EditorLink {
    weak var controller: TextEditController?
}

/// An `NSTextView` set up for files rather than prose, with Text Edit's
/// gutter: line numbers, folds, changes since the commit and the save.
struct PlainTextEditor: NSViewRepresentable {

    let document: TextEditDocument
    let wraps: Bool
    let finder: FindTrigger
    let link: EditorLink
    let lineNumbers: TextLineNumbers
    /// Settings' formats by extension, so a change there reaches the window.
    let formats: [TextFormat: [String]]

    func makeNSView(context: Context) -> NSScrollView {
        let controller = TextEditController(document: document)
        context.coordinator.controller = controller
        let text = controller.textView

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
        link.controller = controller
        document.currentText = { [weak text] in text?.string ?? "" }
        context.coordinator.shownRevision = -1
        controller.lineNumbers = lineNumbers
        apply(wraps: wraps, to: controller.scrollView, text: text)
        return controller.scrollView
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let controller = context.coordinator.controller else { return }
        let text = controller.textView
        context.coordinator.document = document
        controller.document = document

        // Replaced only when the file was read, never on an ordinary update:
        // setting the string also throws away the undo history.
        if context.coordinator.shownRevision != document.revision {
            context.coordinator.shownRevision = document.revision
            controller.loaded(text: document.saved)
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
        controller.lineNumbers = lineNumbers
        controller.refreshFormat()
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
        var controller: TextEditController?
        var shownRevision = -1

        init(document: TextEditDocument) { self.document = document }

        func textDidChange(_ notification: Notification) {
            document.noteEdit()
            controller?.textChanged()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            controller?.selectionChanged()
        }
    }
}
