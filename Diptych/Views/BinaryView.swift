import SwiftUI

/// A hex editor.
///
/// Rows are built lazily: the file is memory-mapped and only the visible lines
/// become views, which is what lets a 60 MB file open instantly.
struct BinaryView: View {

    @State private var model: BinaryViewModel
    @State private var keys = BinaryKeyMonitor()
    /// A press and a drag arrive through the same gesture, and the first
    /// `onChanged` is the press. Without knowing which is which, every click
    /// extended the selection from wherever the cursor happened to be.
    @State private var dragging = false
    @FocusState private var findFocused: Bool

    init(url: URL) {
        _model = State(initialValue: BinaryViewModel(url: url))
    }

    private static let widths = [8, 16, 32, 48, 64]

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if model.isLoading {
                notice("Reading\u{2026}")
            } else if let error = model.loadError {
                notice(error)
            } else if model.count == 0 {
                notice("The file is empty.")
            } else {
                grid
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 560, minHeight: 320)
        .navigationTitle(model.url.lastPathComponent)
        // The window is needed so the monitor can tell its own keystrokes from
        // another binary view's.
        .background(WindowAccessor { keys.start(window: $0, model: model) })
        .onDisappear { keys.stop() }
        .background {
            // A zero-size button is the only way to give a plain shortcut to
            // something that is not a menu item.
            Button("") { findFocused = true }
                .keyboardShortcut("f")
                .hidden()
            Button("") { model.findNext(); findFocused = false }
                .keyboardShortcut("g")
                .hidden()
            Button("") { model.findPrevious(); findFocused = false }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .hidden()
        }
        .confirmationDialog("Write \u{201C}\(model.url.lastPathComponent)\u{201D}?",
                            isPresented: $model.confirmingSave, titleVisibility: .visible) {
            Button("Overwrite", role: .destructive) { model.save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.saveSummary + ". "
                 + (model.lengthDelta == 0
                    ? "The changed bytes are written in place."
                    : "The file is rewritten and its length changed.")
                 + " There is no undo, and no backup is made.")
        }
    }

    // MARK: - Top

    private var controls: some View {
        HStack(spacing: 18) {
            // A radio group rather than a segmented control: these are five
            // settings of one thing, and macOS spells that with radio buttons.
            Picker("Bytes per line", selection: $model.bytesPerLine) {
                ForEach(Self.widths, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()

            Toggle("Decimal", isOn: $model.decimal)
                .toggleStyle(.checkbox)
                .help("Show each byte as three decimal digits instead of two hex digits")

            Spacer()
            find
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Text or hex, because a hex editor is used for both: looking for a
    /// string in a binary, and looking for a byte sequence that has no
    /// characters at all.
    private var find: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)

            TextField(model.findIsHex ? "48 65 6c" : "Find", text: $model.findQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .focused($findFocused)
                .onSubmit {
                    model.findNext()
                    // Focus goes back to the grid. Keeping it here is what left
                    // the cursor stuck in the box with no obvious way out, and
                    // every hex digit typed afterwards went into the query
                    // instead of into the file.
                    findFocused = false
                }
                // Escape is the other way out, for a search abandoned midway.
                .onExitCommand { findFocused = false }
                // Red while the hex will not parse, the same signal the pane
                // filter gives for a half-typed regular expression.
                .foregroundStyle(model.findIsHex && model.findQuery.count > 1
                                 && model.findPattern == nil ? Color.red : .primary)

            Toggle("Hex", isOn: $model.findIsHex)
                .toggleStyle(.checkbox)
                .help("Read the query as pairs of hex digits instead of text")

            Button {
                model.findPrevious()
                findFocused = false
            } label: {
                Image(systemName: "chevron.up")
            }
            .help("Find previous (\u{21E7}\u{2318}G)")

            Button {
                model.findNext()
                findFocused = false
            } label: {
                Image(systemName: "chevron.down")
            }
            .help("Find next (\u{2318}G)")
        }
        .disabled(model.count == 0)
    }

    // MARK: - The grid

    private var grid: some View {
        ScrollViewReader { scroller in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(0 ..< model.rowCount, id: \.self) { row in
                        line(row).id(row)
                    }
                }
                .padding(.vertical, Self.inset)
                .padding(.horizontal, Self.inset)
                // Without this the content is centred in the scroll view the
                // moment it is narrower or shorter than the window -- which for
                // a small file is always.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .coordinateSpace(name: Self.gridSpace)
                // One gesture for the whole grid, not one per row. A per-row
                // gesture keeps reporting positions in the row it started in,
                // so dragging downwards only ever ran left and right along that
                // one line.
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.gridSpace))
                        .onChanged { touch in
                            // Clicking the bytes means you want to edit bytes.
                            findFocused = false
                            dragging = true

                            let here = byteOffset(at: touch.location)
                            // Shift extends from wherever the cursor already
                            // is: click the start, scroll, Shift-click the end
                            // is how a selection longer than the window is made.
                            if Self.shiftHeld {
                                model.moveCursor(to: here, extending: true)
                            } else {
                                // Both ends from the gesture itself rather than
                                // from a running "am I dragging yet" flag. The
                                // flag could be left set by a gesture that never
                                // ended, and then a plain click extended the
                                // selection instead of placing the cursor.
                                model.select(from: byteOffset(at: touch.startLocation), to: here)
                            }
                        }
                        .onEnded { _ in dragging = false })
            }
            .onChange(of: model.cursor) { _, offset in
                // Never while dragging. Scrolling the cursor's row to the
                // centre slides the content out from under the pointer, which
                // puts a different row there, which moves the cursor, which
                // scrolls again: the view ran away downwards the moment a drag
                // began. Keyboard movement has no such loop -- the pointer is
                // not what decides where the cursor goes.
                guard !dragging else { return }
                scroller.scrollTo(offset / model.columns, anchor: .center)
            }
        }
    }

    private func line(_ row: Int) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Text(model.address(ofRow: row))
                .foregroundStyle(.secondary)
            Text(bytesText(row))
                .padding(.leading, Self.advance * 2)
            Text(charactersText(row))
                .padding(.leading, Self.advance * 2)
        }
        .font(.system(size: 12, design: .monospaced))
        // Pinned rather than measured: the drag has to turn a y position into a
        // row number, and a height it merely guessed at would drift further
        // wrong the further down the file you dragged.
        .frame(height: Self.rowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Which byte a pointer lands on, anywhere in the grid.
    ///
    /// The geometry is known exactly -- fixed row height, monospaced advance,
    /// a fixed address column -- so this is arithmetic rather than hit testing,
    /// which is what lets one gesture serve every row.
    ///
    /// Always an answer, never "nowhere". Returning nothing for a point past
    /// the last row meant a click there did nothing at all, and an undo that
    /// shrinks the file leaves you looking at exactly that: rows that are no
    /// longer there. Clamping is also what a text editor does when you click
    /// past the end of the text.
    private func byteOffset(at point: CGPoint) -> Int {
        guard model.count > 0 else { return 0 }
        let row = min(max(Int((point.y - Self.inset) / Self.rowHeight), 0), model.rowCount - 1)
        let offsets = model.offsets(inRow: row)
        guard !offsets.isEmpty else { return model.count - 1 }

        let addressWidth = Self.advance * CGFloat(model.addressDigits)
        let x = point.x - Self.inset - addressWidth - Self.advance * 2
        guard x >= 0 else { return offsets.lowerBound }

        let column = Int(x / cellWidth)
        return min(offsets.lowerBound + column, offsets.upperBound - 1)
    }

    /// A gesture carries no modifier flags, so the keyboard is asked directly.
    private static var shiftHeld: Bool {
        NSEvent.modifierFlags.contains(.shift)
    }

    private static let gridSpace = "diptych.binary.grid"
    private static let inset: CGFloat = 10

    /// The advance width of the font the grid draws with, which is what turns a
    /// pointer x into a byte index.
    private static let advance: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }()

    private static let rowHeight: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return ceil(font.ascender - font.descender + font.leading) + 2
    }()

    private var cellWidth: CGFloat { Self.advance * CGFloat(model.decimal ? 4 : 3) }

    private func bytesText(_ row: Int) -> AttributedString {
        var line = AttributedString()
        let offsets = model.offsets(inRow: row)

        for offset in model.rowSpan(row) {
            guard offsets.contains(offset) else {
                // Padding for a short last line, so its character column stays
                // under the ones above it.
                line += AttributedString(String(repeating: " ", count: model.decimal ? 4 : 3))
                continue
            }
            let showTyping = offset == model.cursor && !model.typing.isEmpty
            let text = showTyping
                ? model.typing.padding(toLength: model.decimal ? 3 : 2,
                                       withPad: " ", startingAt: 0)
                : model.text(at: offset)

            var cell = AttributedString(text + " ")
            // Red means "differs from the file", and it goes away by itself the
            // moment the byte is typed back to what the file holds.
            if model.isChanged(at: offset) { cell.foregroundColor = .red }
            if model.selection.contains(offset) {
                // The cursor end of a run is darker, so it is clear which way
                // Shift-arrow will grow it.
                cell.backgroundColor = .accentColor.opacity(offset == model.cursor ? 0.45 : 0.22)
            }
            line += cell
        }
        return line
    }

    private func charactersText(_ row: Int) -> AttributedString {
        var line = AttributedString()
        for offset in model.offsets(inRow: row) {
            var cell = AttributedString(model.character(at: offset))
            if model.isChanged(at: offset) { cell.foregroundColor = .red }
            if model.selection.contains(offset) {
                cell.backgroundColor = .accentColor.opacity(offset == model.cursor ? 0.40 : 0.18)
            }
            line += cell
        }
        return line
    }

    // MARK: - Bottom

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let status = model.status {
                Image(systemName: model.statusIsError
                      ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(model.statusIsError ? .orange : .green)
                Text(status).lineLimit(2)
            } else {
                Text(summary).foregroundStyle(.secondary)
            }

            Spacer()

            Button("Insert \(model.selectionCount) Zero"
                   + (model.selectionCount == 1 ? "" : "s")) { model.insertZeros() }
                .help("Insert that many zero bytes before the cursor, pushing the rest up "
                      + "(\u{2318}/)")

            Button("Remove \(model.selectionCount) Byte"
                   + (model.selectionCount == 1 ? "" : "s")) { model.removeSelection() }
                .help("Delete the selected bytes, pulling the rest down (\u{2318}\u{232B})")
                .disabled(model.count == 0)

            Button("Undo") { model.undo() }
                .help("Undo the last change, insert or removal (\u{2318}Z)")
                .disabled(!model.canUndo)

            if model.hasEdits {
                Divider().frame(height: 14)
                Text(changeSummary).foregroundStyle(.red)
                Button("Revert Bytes") { model.revert() }
                    .help("Put the selected bytes back to what the file holds (Delete)")
                Button("Discard All") { model.revertAll() }
            }
            Button("Save\u{2026}") { model.confirmingSave = true }
                .keyboardShortcut("s")
                .disabled(!model.hasEdits)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var changeSummary: String {
        var parts: [String] = []
        if model.changedCount > 0 { parts.append("\(model.changedCount) changed") }
        if model.lengthDelta != 0 {
            parts.append(model.lengthDelta > 0 ? "+\(model.lengthDelta)"
                                               : "\(model.lengthDelta)")
        }
        return parts.joined(separator: ", ")
    }

    private var summary: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(model.count), countStyle: .file)
        let at = String(format: "%0\(model.addressDigits)X", model.cursor)
        let where_ = model.hasSelection
            ? "\(model.selectionCount) bytes from \(String(format: "%0\(model.addressDigits)X", model.selection.lowerBound))"
            : "offset \(at)"
        return "\(size) \u{2022} \(where_) \u{2022} \u{21E7}arrows select, "
             + "type \(model.decimal ? "digits" : "hex digits") to edit, Delete restores"
    }

    private func notice(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
