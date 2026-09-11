import SwiftUI
import AppKit

/// Two files side by side, which is the shape this whole application is named
/// after. At most one of them editable.
///
/// One scroll view holding rows of two columns, rather than two scroll views
/// kept in step: the columns cannot drift apart if they are the same row, and
/// a line that wraps simply makes its row taller on both sides. Two scrollers
/// synchronised by hand is the version of this that never quite works.
struct DiffView: View {

    @State private var document: DiffDocument
    @State private var atChange = 0
    @State private var notice: String?
    @State private var wraps = true
    @State private var query = ""
    @State private var atMatch = 0
    @State private var guard_ = CloseGuard()
    @State private var window: NSWindow?

    private var pair: DiffPair { document.pair }
    private var diff: TextDiff { document.diff }

    init(pair: DiffPair) {
        _document = State(initialValue: DiffDocument(pair: pair))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if let notice {
                Divider()
                HStack {
                    Text(notice).font(.subheadline).foregroundStyle(.orange)
                    Spacer()
                    Button("OK") { self.notice = nil }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .task { await document.load() }
        // SwiftUI cannot refuse a window close and this window needs to:
        // closing with unsaved edits must ask rather than discard.
        .background(WindowAccessor { found in
            guard let found else { return }
            // Held, rather than looked up later: `NSApp.keyWindow` is whichever
            // window happens to be in front, which is not necessarily this one.
            if window !== found { window = found }
            guard found.delegate !== guard_ else { return }
            guard_.shouldClose = { closeIsAllowed() }
            guard_.willClose = { DiffWindows.shared.release(pair) }
            found.delegate = guard_
        })
        .onChange(of: document.isDirty) { _, dirty in
            // The dot in the close button, and the only unsaved-changes cue
            // macOS gives a window that is not an NSDocument.
            window?.isDocumentEdited = dirty
        }
        .onAppear { DiffWindows.shared.claim(pair) }
        // Belt and braces: the window delegate is what actually frees it, but
        // this costs nothing and covers a view that goes away without one.
        .onDisappear { DiffWindows.shared.release(pair) }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                side(.left)
                side(.right)
            }
            HStack(spacing: 12) {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(diff.isIdentical ? .secondary : .primary)
                Spacer()
                find
                Toggle("Wrap", isOn: $wraps)
                    .toggleStyle(.checkbox)
                    .help("Wrap long lines on both sides")
                Toggle("Ignore spacing", isOn: $document.ignoreWhitespace)
                    .toggleStyle(.checkbox)
                if document.editable != nil {
                    Button("Undo") { act { document.undo() } }
                        .disabled(!document.canUndo)
                        .keyboardShortcut("z", modifiers: .command)
                    Button("Redo") { act { document.redo() } }
                        .disabled(!document.canRedo)
                        .keyboardShortcut("z", modifiers: [.command, .shift])
                    Button("Save") { act { saveNow() } }
                        .disabled(!document.isDirty)
                        .keyboardShortcut("s", modifiers: .command)
                }
                if !diff.isIdentical {
                    Button { step(-1) } label: { Image(systemName: "chevron.up") }
                        .help("Previous difference")
                    Button { step(1) } label: { Image(systemName: "chevron.down") }
                        .help("Next difference")
                    Text("\(min(atChange + 1, diff.changeStarts.count)) of "
                         + "\(diff.changeStarts.count)")
                        .font(.caption).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// One file's name, its folder when that is what tells the two apart, and
    /// its padlock.
    private func side(_ which: DiffDocument.Side) -> some View {
        let url = which == .left ? pair.left : pair.right
        let folders = pair.folders
        return HStack(spacing: 6) {
            Button {
                if document.editable == which { relock() } else { unlock(which) }
            } label: {
                Image(systemName: document.editable == which ? "lock.open" : "lock")
            }
            .buttonStyle(.borderless)
            .help(document.editable == which
                  ? (document.canChooseAgain
                     ? "Lock \(url.lastPathComponent) again"
                     : "\(url.lastPathComponent) can be edited")
                  : "Edit \(url.lastPathComponent)")
            // Only shut once something has actually come of the choice. A
            // padlock opened by mistake, or opened and then everything undone,
            // must be closable again -- needing to restart the comparison over
            // a misclick is a punishment.
            .disabled(document.editable != nil && document.editable != which
                      && !document.canChooseAgain)

            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Shown only when the two files are in different folders, which
                // is the case where the names alone leave the reader guessing
                // which side is which. Truncated at the *front*, because the
                // end of a path is the part that distinguishes it.
                if let folder = which == .left ? folders?.left : folders?.right {
                    Text(folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .help(url.path)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var find: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .onSubmit { stepMatch(1) }
            if !query.isEmpty {
                Text(matches.isEmpty ? "none"
                     : "\(min(atMatch + 1, matches.count)) of \(matches.count)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button { stepMatch(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(matches.isEmpty)
                Button { stepMatch(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(matches.isEmpty)
            }
        }
    }

    /// Rows holding the search text, on either side.
    ///
    /// Find only: replace was ruled out, and a find that has to be told which
    /// column to look in would be a worse tool than no find at all.
    private var matches: [Int] {
        guard query.count > 1 else { return [] }
        return diff.rows.filter { row in
            [row.left, row.right].contains { $0?.localizedCaseInsensitiveContains(query) == true }
        }.map(\.id)
    }

    private var summary: String {
        if let failure = document.failure { return failure }
        guard !diff.isIdentical else { return "These two files are the same." }
        let count = diff.changeStarts.count
        return "\(count) difference\(count == 1 ? "" : "s")"
            + (document.isDirty ? "  \u{2022}  not saved yet" : "")
    }

    // MARK: - The comparison

    @ViewBuilder
    private var content: some View {
        if let failure = document.failure {
            message(failure)
        } else if document.left == nil {
            message("Reading\u{2026}")
        } else if diff.isIdentical && !document.isDirty {
            message("Every line matches, including the blank ones.")
        } else {
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(diff.rows) { row in
                            line(row).id(row.id)
                        }
                    }
                }
                .onChange(of: atChange) { _, index in
                    guard diff.changeStarts.indices.contains(index) else { return }
                    withAnimation { scroller.scrollTo(diff.changeStarts[index], anchor: .center) }
                }
                .onChange(of: atMatch) { _, index in
                    let found = matches
                    guard found.indices.contains(index) else { return }
                    withAnimation { scroller.scrollTo(found[index], anchor: .center) }
                }
                .onChange(of: query) { _, _ in atMatch = 0 }
            }
        }
    }

    private func message(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func line(_ row: TextDiff.Row) -> some View {
        HStack(alignment: .top, spacing: 0) {
            half(row, side: .left)
            // The button lives between the columns and points into the side
            // that can take it, so there is never a question which way the
            // text is about to move.
            takeButton(row)
            half(row, side: .right)
        }
    }

    @ViewBuilder
    private func takeButton(_ row: TextDiff.Row) -> some View {
        if let editable = document.editable, row.kind.isChange,
           diff.changeStarts.contains(row.id) {
            Button {
                document.takeDifference(atRow: row.id)
            } label: {
                Image(systemName: editable == .left ? "arrow.left" : "arrow.right")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .frame(width: 18)
            .help("Make this difference the same as the other side")
        } else {
            Divider().frame(width: 18)
        }
    }

    private func half(_ row: TextDiff.Row, side: DiffDocument.Side) -> some View {
        let text = side == .left ? row.left : row.right
        let number = side == .left ? row.leftNumber : row.rightNumber
        let spans = side == .left ? row.leftSpans : row.rightSpans
        let tint: Color? = text == nil ? nil
            : (row.kind == .same ? nil : (side == .left ? .red : .green))
        let index = number.map { $0 - 1 }
        let isEditable = document.editable == side && index != nil

        return HStack(alignment: .top, spacing: 6) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)
            // Stacked with the diff colour rather than competing with it: the
            // background says how this line differs from the other file, the
            // bar says you changed it.
            Rectangle()
                .fill(document.isEdited(side, line: index) ? Color.accentColor : .clear)
                .frame(width: 3)
            // A marker as well as a colour, so the two sides are still telling
            // the reader apart when the colours are not.
            Text(row.kind == .same ? " " : (text == nil ? " " : (side == .left ? "\u{2212}" : "+")))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 10)

            if isEditable, let index {
                // The field owns its text while it is being typed into and the
                // document owns it the rest of the time, which is why the
                // binding is constant: a two-way binding here would push every
                // keystroke into the document and recompute the alignment
                // under the caret. No tap gesture either -- one placed over a
                // text field swallows the click that would put the caret where
                // the user pointed.
                DiffLineField(text: text ?? "",
                              wraps: wraps,
                              onType: { document.typing(index, $0) },
                              onFinish: { document.endLine() },
                              onSplit: { document.splitLine(index, at: $0) },
                              onJoin: { document.joinWithPrevious(index) },
                              onRevert: { document.revertLine() })
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                body(of: text ?? "", spans: spans, tint: tint)
                    .textSelection(.enabled)
                    .lineLimit(wraps ? nil : 1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
        .padding(.trailing, 6)
        // Light enough to read through in either theme. A missing line is
        // shaded too, so the gap reads as part of the comparison rather than
        // as the end of the file.
        .background(tint?.opacity(0.16) ?? (text == nil ? Color.secondary.opacity(0.06) : .clear))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The line, with the words that actually changed picked out when the two
    /// versions still resemble each other.
    ///
    /// One `Text` holding an `AttributedString` rather than several joined
    /// together: only the single string wraps as one paragraph, and a line
    /// broken into separate views would wrap at every span boundary.
    private func body(of text: String, spans: [TextDiff.Span], tint: Color?) -> Text {
        guard !spans.isEmpty, let tint else { return Text(text) }
        var built = AttributedString()
        for span in spans {
            var piece = AttributedString(span.text)
            if span.changed {
                // Stronger than the line's own wash, so it reads as "this part"
                // against "this line".
                piece.backgroundColor = tint.opacity(0.45)
            }
            built += piece
        }
        return Text(built)
    }

    // MARK: - Editing

    private func unlock(_ side: DiffDocument.Side) {
        if let refusal = document.unlock(side) { notice = refusal.message }
    }

    private func relock() {
        guard document.relock() else {
            notice = "There are changes to save first. Save them, or undo them, and the "
                   + "padlock can be shut again."
            return
        }
    }

    /// Take focus off the line before acting on the document.
    ///
    /// Clicking a button does this by itself, but the keyboard shortcut does
    /// not, and a Save or an Undo that ran while a line still held the caret
    /// would act on a document the text view had not finished telling about.
    private func act(_ body: () -> Void) {
        window?.makeFirstResponder(nil)
        body()
    }

    private func stepMatch(_ by: Int) {
        let found = matches
        guard !found.isEmpty else { return }
        atMatch = (atMatch + by + found.count) % found.count
    }

    private func step(_ by: Int) {
        guard !diff.changeStarts.isEmpty else { return }
        // Wrapping, because the alternative is a button that stops working and
        // does not say why.
        atChange = (atChange + by + diff.changeStarts.count) % diff.changeStarts.count
    }

    // MARK: - Saving and closing

    private func saveNow() {
        switch document.save() {
        case .saved, .nothingToDo:
            notice = nil
        case .changedUnderneath(let name):
            notice = "\u{201C}\(name)\u{201D} was changed by something else since this window "
                   + "opened. Saving now would throw that away. Close this window and compare "
                   + "the files again."
        case .failed(let reason):
            notice = reason
        }
    }

    /// Asked by AppKit before the window closes.
    ///
    /// An `NSAlert` run modally, rather than a SwiftUI dialog: the answer is
    /// needed *now*, as a return value, and this view has already spent its one
    /// reliable presentation.
    private func closeIsAllowed() -> Bool {
        guard document.isDirty, let side = document.editable else { return true }
        let name = (side == .left ? pair.left : pair.right).lastPathComponent

        let alert = NSAlert()
        alert.messageText = "Save the changes to \u{201C}\(name)\u{201D}?"
        alert.informativeText = "If you close without saving, what you typed is lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveNow()
            // A save that could not go through must not take the window with
            // it, or the refusal is announced to nobody.
            return !document.isDirty
        case .alertSecondButtonReturn:
            return false
        default:
            return true
        }
    }
}
