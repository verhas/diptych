import Foundation
import Observation

/// The bytes of one file, and the edits not yet written to it.
///
/// Two modes, because they have very different costs. While every edit is an
/// *overwrite*, the file stays memory-mapped and the changes are a sparse
/// offset-to-byte map: opening a 60 MB file costs nothing and saving seeks to
/// each run. The first **structural** edit -- an insert or a removal -- moves
/// every later byte, so the content is materialised into an array and saving
/// rewrites the file and sets its new length.
///
/// Nothing switches back. Once the length can change there is no sparse patch
/// that describes the result.
@MainActor
@Observable
final class BinaryViewModel {

    /// Rendering a row costs a view; a hex editor over a DVD image would ask
    /// SwiftUI for a hundred million of them. This is the point past which a
    /// different kind of tool is wanted.
    static let maximumSize = 64 << 20

    let url: URL
    /// The file as it is on disk, mapped.
    private(set) var bytes: Data
    private(set) var loadError: String?
    private(set) var isLoading = true

    // MARK: - Edit state

    /// Overwrite-only mode: what was typed, keyed by offset.
    private(set) var edits: [Int: UInt8] = [:]

    /// Structural mode: the whole content, and what each changed byte held
    /// before it was typed. `pristine` is what makes Delete able to restore a
    /// byte after inserts have moved it away from its original address.
    private(set) var working: [UInt8]?
    private var pristine: [Int: UInt8] = [:]
    /// Offsets holding bytes that were never in the file.
    private(set) var inserted = IndexSet()

    var isStructural: Bool { working != nil }

    var bytesPerLine = 16 { didSet { clearTyping() } }
    var decimal = false { didSet { clearTyping() } }

    /// The selection is a run, never a block: a rectangle over a hex dump
    /// selects bytes that are not next to each other in the file, which is not
    /// a thing anyone can act on.
    private(set) var anchor = 0
    var cursor = 0
    var selection: ClosedRange<Int> { min(anchor, cursor) ... max(anchor, cursor) }
    var selectionCount: Int { count == 0 ? 0 : selection.count }
    var hasSelection: Bool { anchor != cursor }

    private(set) var typing = ""
    /// Reversals for what has been done, newest last.
    ///
    /// Each entry is a closure taking the model rather than capturing it, so
    /// the stack cannot retain the very object that owns it. Operations, not
    /// snapshots: a snapshot of the content would be the whole file, and the
    /// reversal of an insert is a removal.
    private var undoStack: [(BinaryViewModel) -> Void] = []
    /// Deep enough to cover a session of poking at a header, shallow enough
    /// that a removal of half a file cannot be held a hundred times over.
    private static let undoDepth = 100

    var canUndo: Bool { !undoStack.isEmpty }

    // MARK: - Finding

    var findQuery = "" { didSet { findError = nil } }
    /// Read the query as hex pairs rather than as text.
    var findIsHex = false { didSet { findError = nil } }
    private(set) var findError: String?
    /// Where the last hit was, so repeating the search steps past it while a
    /// first search still finds a match sitting under the cursor.
    private var lastMatch: Int?

    /// The query as bytes, or nil with `findError` set explaining why not.
    var findPattern: [UInt8]? {
        let trimmed = findQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        guard findIsHex else { return Array(trimmed.utf8) }

        // Spaces optional: "4865 6c6c 6f" and "48656c6c6f" are the same query.
        let digits = trimmed.filter { !$0.isWhitespace }
        guard digits.count % 2 == 0 else { return nil }
        var pattern: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let value = UInt8(digits[index ..< next], radix: 16) else { return nil }
            pattern.append(value)
            index = next
        }
        return pattern
    }

    func findNext() { find(forward: true) }
    func findPrevious() { find(forward: false) }

    private func find(forward: Bool) {
        guard let pattern = findPattern, !pattern.isEmpty else {
            findError = findIsHex ? "Not a run of hex byte pairs." : nil
            return note(findError ?? "Nothing to find.", error: findError != nil)
        }
        findError = nil
        guard count >= pattern.count else { return note("Not found.", error: true) }

        // From the cursor, inclusive -- unless the cursor is already sitting on
        // the last hit, in which case step past it so repeating the search
        // walks through the file instead of finding the same place forever.
        let base = selection.lowerBound
        let from = lastMatch == base ? (forward ? base + 1 : base - 1) : base
        guard let match = search(pattern, from: from, forward: forward) else {
            return note("Not found.", error: true)
        }

        anchor = match
        cursor = match + pattern.count - 1
        lastMatch = match
        clearTyping()
        note("Found at \(String(format: "%0\(addressDigits)X", match)).")
    }

    /// Wraps, as a find in any editor does.
    private func search(_ pattern: [UInt8], from: Int, forward: Bool) -> Int? {
        let last = count - pattern.count
        guard last >= 0 else { return nil }

        // Taken once rather than through the accessor per byte: the accessor
        // has to decide which representation is live, and doing that sixty
        // million times is what a scan cannot afford.
        let content = working
        let raw = bytes
        let overrides = edits

        func matches(_ start: Int) -> Bool {
            for (index, wanted) in pattern.enumerated() {
                let offset = start + index
                let value: UInt8
                if let content {
                    value = content[offset]
                } else if let edited = overrides[offset] {
                    value = edited
                } else {
                    value = raw[offset]
                }
                if value != wanted { return false }
            }
            return true
        }

        // The cursor can sit past the last position a match could *start* at --
        // in the last few bytes of the file. Going forwards that means wrapping
        // to the beginning; going backwards it means the last candidate, not
        // the first, which is what a plain modulo would have given.
        let total = last + 1
        var index: Int
        if forward {
            index = (from > last || from < 0) ? 0 : from
        } else {
            index = from < 0 ? last : min(from, last)
        }
        for _ in 0 ..< total {
            if matches(index) { return index }
            index = forward ? (index + 1) % total : (index - 1 + total) % total
        }
        return nil
    }

    private(set) var status: String?
    private(set) var statusIsError = false
    var confirmingSave = false

    init(url: URL) {
        self.url = url
        bytes = Data()
        Task { await load() }
    }

    nonisolated static func formatted(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// Off the main actor. Mapping is cheap, but `stat` and the first faults
    /// are not free on a cold or networked volume, and doing them inline is
    /// what makes a window hang on the way up.
    private func load() async {
        let url = self.url
        let limit = Self.maximumSize

        let loaded: (data: Data?, message: String?) =
            await Task.detached(priority: .userInitiated) {
                do {
                    let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard size <= limit else {
                        return (nil, "This file is \(Self.formatted(Int64(size))), and the "
                                   + "binary view stops at \(Self.formatted(Int64(limit))).")
                    }
                    return (try Data(contentsOf: url, options: .mappedIfSafe), nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }.value

        if let data = loaded.data { bytes = data }
        loadError = loaded.message
        isLoading = false
    }

    // MARK: - Reading

    var count: Int { working?.count ?? bytes.count }

    /// Never wider than the file. A 28-byte file at 64 bytes a line is one row
    /// of 28, not one row followed by 36 columns of nothing.
    var columns: Int { count == 0 ? bytesPerLine : min(bytesPerLine, count) }
    var rowCount: Int { count == 0 ? 0 : (count + columns - 1) / columns }

    var addressDigits: Int { max(4, String(max(count - 1, 0), radix: 16).count) }

    func byte(at offset: Int) -> UInt8? {
        if let working {
            return working.indices.contains(offset) ? working[offset] : nil
        }
        guard bytes.indices.contains(offset) else { return nil }
        return edits[offset] ?? bytes[offset]
    }

    /// Red means "this is not what the file holds": a byte typed over, or one
    /// inserted. A byte merely *moved* by an insert is not changed -- its value
    /// is the same one the file already had.
    func isChanged(at offset: Int) -> Bool {
        if let working {
            if inserted.contains(offset) { return true }
            guard let before = pristine[offset], working.indices.contains(offset) else {
                return false
            }
            return before != working[offset]
        }
        guard let typed = edits[offset], bytes.indices.contains(offset) else { return false }
        return typed != bytes[offset]
    }

    /// Offsets whose content differs from the file, which is what the counter,
    /// the Save button and the writing all go by.
    var changedOffsets: [Int] {
        if working != nil {
            return (Set(pristine.keys).union(inserted)).filter { isChanged(at: $0) }.sorted()
        }
        return edits.keys.filter { isChanged(at: $0) }.sorted()
    }

    var changedCount: Int { changedOffsets.count }
    /// A length change is a pending change even when no byte differs.
    var hasEdits: Bool { changedCount > 0 || count != bytes.count }
    var lengthDelta: Int { count - bytes.count }

    func address(ofRow row: Int) -> String {
        String(format: "%0\(addressDigits)X", row * columns)
    }

    /// Every column of a row, including the ones past the end of the file on a
    /// short last line.
    func rowSpan(_ row: Int) -> Range<Int> {
        let start = row * columns
        return start ..< start + columns
    }

    func offsets(inRow row: Int) -> Range<Int> {
        let start = row * columns
        return start ..< min(start + columns, count)
    }

    func text(at offset: Int) -> String {
        guard let value = byte(at: offset) else { return decimal ? "   " : "  " }
        return decimal ? String(format: "%3d", value) : String(format: "%02X", value)
    }

    /// Only what can be drawn safely. Control characters have no glyph and the
    /// C1 range renders as anything at all depending on the font, so the
    /// character column is printable ASCII and a dot for everything else.
    func character(at offset: Int) -> String {
        guard let value = byte(at: offset) else { return " " }
        return (0x20 ... 0x7E).contains(value) ? String(UnicodeScalar(value)) : "."
    }

    // MARK: - Moving and selecting

    func moveCursor(to offset: Int, extending: Bool = false) {
        cursor = min(max(offset, 0), max(count - 1, 0))
        if !extending { anchor = cursor }
        // Moving away means the next search starts where you now are, rather
        // than stepping past a hit you have left behind.
        lastMatch = nil
        clearTyping()
    }

    func moveCursor(by delta: Int, extending: Bool = false) {
        moveCursor(to: cursor + delta, extending: extending)
    }

    /// Both ends at once, for a drag: the anchor is where the press landed and
    /// the cursor is where the pointer is now. Stated rather than accumulated,
    /// so no "am I dragging" flag can go stale and turn a click into an extend.
    func select(from start: Int, to end: Int) {
        let limit = max(count - 1, 0)
        anchor = min(max(start, 0), limit)
        cursor = min(max(end, 0), limit)
        lastMatch = nil
        clearTyping()
    }

    func selectAll() {
        guard count > 0 else { return }
        anchor = 0
        cursor = count - 1
        clearTyping()
    }

    // MARK: - Undo

    private func push(_ reversal: @escaping (BinaryViewModel) -> Void) {
        undoStack.append(reversal)
        if undoStack.count > Self.undoDepth { undoStack.removeFirst() }
    }

    /// Everything keyed by offset, kept together: an insert or a removal moves
    /// all of it, so the reversal has to put all of it back at once.
    private var bookkeeping: (pristine: [Int: UInt8], inserted: IndexSet) {
        (pristine, inserted)
    }

    private func restoreBookkeeping(_ saved: (pristine: [Int: UInt8], inserted: IndexSet)) {
        pristine = saved.pristine
        inserted = saved.inserted
    }

    func undo() {
        guard let reversal = undoStack.popLast() else { return note("Nothing to undo.") }
        reversal(self)
        clearTyping()
        moveCursor(to: min(cursor, max(count - 1, 0)))
        note("Undone.")
    }

    /// Remembers one byte as it stands, before it is typed over.
    ///
    /// Recorded as values rather than as a change to whichever representation
    /// happens to be current, and applied against whichever is current when it
    /// is undone. The first structural edit switches representation underneath
    /// entries already on the stack, and an entry written in terms of the
    /// sparse map silently did nothing once the content had been materialised.
    private func pushOverwriteUndo(at offset: Int) {
        guard let previous = byte(at: offset) else { return }
        let wasMarked = working != nil ? pristine[offset] != nil : edits[offset] != nil
        let fileValue = fileByte(at: offset)

        push { model in
            if model.working != nil {
                model.working?[offset] = previous
                if wasMarked { model.pristine[offset] = fileValue }
                else { model.pristine.removeValue(forKey: offset) }
            } else if wasMarked {
                model.edits[offset] = previous
            } else {
                model.edits.removeValue(forKey: offset)
            }
        }
    }

    /// What the file holds at this offset, as far as the model still knows --
    /// `pristine` once inserts have moved the byte away from its own address.
    private func fileByte(at offset: Int) -> UInt8? {
        if working != nil { return pristine[offset] }
        return bytes.indices.contains(offset) ? bytes[offset] : nil
    }

    // MARK: - Typing

    private var digitsPerByte: Int { decimal ? 3 : 2 }

    func clearTyping() { typing = "" }

    func accepts(_ character: Character) -> Bool {
        guard count > 0 else { return false }
        return decimal ? character.isNumber : character.isHexDigit
    }

    /// Accepts one digit. A byte is committed when its digits are complete, or
    /// as soon as no further digit could fit -- typing `9` then `9` in decimal
    /// gives 99 and moves on, because 99x cannot be a byte.
    func type(_ character: Character) {
        guard accepts(character) else { return }

        let candidate = typing + String(character)
        guard let value = parse(candidate) else { return }

        // One undo entry per byte, not per digit: the digits of a byte are one
        // act as far as anyone typing them is concerned.
        if typing.isEmpty { pushOverwriteUndo(at: cursor) }
        overwrite(value, at: cursor)
        typing = candidate

        let complete = candidate.count >= digitsPerByte
            || (decimal && parse(candidate + "0") == nil)
        if complete { advance() }
        note(nil)
    }

    private func overwrite(_ value: UInt8, at offset: Int) {
        if working != nil {
            // Remember what was there the first time this byte is typed, so it
            // can be put back however far inserts have since moved it.
            if pristine[offset] == nil { pristine[offset] = working?[offset] }
            working?[offset] = value
            if pristine[offset] == value, !inserted.contains(offset) {
                pristine.removeValue(forKey: offset)
            }
            return
        }
        // Typing a byte back to what the file holds is not an edit, and leaving
        // it in the map is what made the footer claim a change over a byte that
        // was already black again.
        if bytes.indices.contains(offset), bytes[offset] == value {
            edits.removeValue(forKey: offset)
        } else {
            edits[offset] = value
        }
    }

    private func parse(_ text: String) -> UInt8? {
        let value = decimal ? Int(text) : Int(text, radix: 16)
        guard let value, (0 ... 255).contains(value) else { return nil }
        return UInt8(value)
    }

    private func advance() {
        typing = ""
        if cursor + 1 < count { cursor += 1 }
        anchor = cursor
    }

    // MARK: - Reverting

    /// Puts the selection back to what the file holds.
    ///
    /// Reads as backspace when nothing is selected, because that is when it is
    /// reached for: a finished byte leaves the cursor on the *next* one, so
    /// reverting strictly under the cursor undid a byte the user had not
    /// touched and left the one they had just typed standing.
    func revert() {
        if !typing.isEmpty {
            restore(cursor)
            clearTyping()
            return note("Typing cancelled.")
        }

        if hasSelection {
            let range = selection
            let restored = range.filter { isChanged(at: $0) }.count
            pushRestoreUndo(over: range)
            for offset in range { restore(offset) }
            return note(restored == 0 ? "Nothing in the selection had changed."
                                      : "\(restored) byte\(restored == 1 ? "" : "s") restored.")
        }

        if isChanged(at: cursor) {
            pushRestoreUndo(over: cursor ... cursor)
            restore(cursor)
            return note("Byte restored.")
        }
        if cursor > 0, isChanged(at: cursor - 1) {
            moveCursor(to: cursor - 1)
            pushRestoreUndo(over: cursor ... cursor)
            restore(cursor)
            return note("Byte restored.")
        }
        note("Nothing to restore here.")
    }

    /// Only the changed bytes of the range are worth remembering -- select-all
    /// and Revert would otherwise capture the whole file to undo a handful of
    /// edits.
    private func pushRestoreUndo(over range: ClosedRange<Int>) {
        let changed = range.filter { isChanged(at: $0) }
        guard !changed.isEmpty else { return }

        // Same reasoning as the overwrite reversal: values now, representation
        // decided at the moment of undoing.
        let values = changed.reduce(into: [Int: UInt8]()) { $0[$1] = byte(at: $1) }
        let fileValues = changed.reduce(into: [Int: UInt8]()) { $0[$1] = fileByte(at: $1) }

        push { model in
            for (offset, value) in values {
                if model.working != nil {
                    model.working?[offset] = value
                    model.pristine[offset] = fileValues[offset]
                } else {
                    model.edits[offset] = value
                }
            }
        }
    }

    /// One byte back to what the file holds. An *inserted* byte has no earlier
    /// value to go back to -- removing it is a structural change, and Remove
    /// Bytes is the command for that.
    private func restore(_ offset: Int) {
        if working != nil {
            guard let before = pristine[offset] else { return }
            working?[offset] = before
            pristine.removeValue(forKey: offset)
            return
        }
        edits.removeValue(forKey: offset)
    }

    func revertAll() {
        undoStack.removeAll()
        if working != nil {
            // Everything goes, length included: the file as it stands is the
            // only thing "discard" can honestly mean.
            working = nil
            pristine.removeAll()
            inserted.removeAll()
        }
        edits.removeAll()
        clearTyping()
        moveCursor(to: min(cursor, max(count - 1, 0)))
        note("All changes discarded.")
    }

    // MARK: - Structural editing

    /// Copy the content into an array so it can grow and shrink, folding any
    /// sparse overwrites in as we go. One-way: once the length can change,
    /// there is no sparse patch that describes the result.
    private func materialise() {
        guard working == nil else { return }
        var content = [UInt8](bytes)
        for (offset, value) in edits where content.indices.contains(offset) {
            pristine[offset] = content[offset]
            content[offset] = value
        }
        edits.removeAll()
        working = content
    }

    /// Removes the selection, pulling everything after it down.
    func removeSelection() {
        guard count > 0 else { return }
        let range = selection
        materialise()
        guard var content = working else { return }

        let removedBytes = Array(content[range])
        let saved = bookkeeping
        let at = range.lowerBound
        push { model in
            model.working?.insert(contentsOf: removedBytes, at: at)
            model.restoreBookkeeping(saved)
        }

        content.removeSubrange(range)
        working = content
        shiftBookkeeping(from: range.lowerBound, by: -range.count, removing: range)

        let removed = range.count
        moveCursor(to: min(range.lowerBound, max(content.count - 1, 0)))
        note("Removed \(removed) byte\(removed == 1 ? "" : "s"). "
             + "The file will be \(content.count) bytes.")
    }

    /// Inserts zero bytes before the cursor, as many as are selected -- so
    /// selecting four bytes and inserting gives four zeros, which is the only
    /// reading of "insert multiple" that needs no second control.
    func insertZeros(_ requested: Int? = nil) {
        let amount = max(requested ?? selectionCount, 1)
        materialise()
        guard var content = working else { return }

        let at = min(cursor, content.count)
        let saved = bookkeeping
        push { model in
            model.working?.removeSubrange(at ..< at + amount)
            model.restoreBookkeeping(saved)
        }

        content.insert(contentsOf: [UInt8](repeating: 0, count: amount), at: at)
        working = content
        shiftBookkeeping(from: at, by: amount, removing: nil)
        inserted.insert(integersIn: at ..< at + amount)

        anchor = at
        cursor = at + amount - 1
        clearTyping()
        note("Inserted \(amount) zero byte\(amount == 1 ? "" : "s"). "
             + "The file will be \(content.count) bytes.")
    }

    /// Insert and remove move every later byte, so everything keyed by offset
    /// has to move with them or it starts describing the wrong bytes.
    private func shiftBookkeeping(from offset: Int, by delta: Int, removing: ClosedRange<Int>?) {
        var moved: [Int: UInt8] = [:]
        for (key, value) in pristine {
            if let removing, removing.contains(key) { continue }
            moved[key >= offset ? key + delta : key] = value
        }
        pristine = moved

        var movedInserts = IndexSet()
        for index in inserted {
            if let removing, removing.contains(index) { continue }
            movedInserts.insert(index >= offset ? index + delta : index)
        }
        inserted = movedInserts
    }

    // MARK: - Saving

    /// Contiguous runs of changed bytes, which is what the overwrite-only path
    /// actually writes.
    var runs: [(offset: Int, bytes: [UInt8])] {
        var runs: [(Int, [UInt8])] = []
        for offset in changedOffsets {
            guard let value = byte(at: offset) else { continue }
            if var last = runs.last, last.0 + last.1.count == offset {
                last.1.append(value)
                runs[runs.count - 1] = last
            } else {
                runs.append((offset, [value]))
            }
        }
        return runs
    }

    /// What the confirmation has to say before anything is written.
    var saveSummary: String {
        var parts: [String] = []
        if changedCount > 0 {
            parts.append("\(changedCount) byte\(changedCount == 1 ? "" : "s") changed")
        }
        if lengthDelta != 0 {
            parts.append("the length goes from \(bytes.count) to \(count) bytes")
        }
        return parts.isEmpty ? "Nothing has changed." : parts.joined(separator: ", ")
    }

    func save() {
        guard hasEdits else { return }
        let structural = working != nil
        let content = working

        let change = MetadataWrite(
            action: "write \u{201C}\(url.lastPathComponent)\u{201D}",
            url: url,
            apply: { [runs] in
                guard let handle = FileHandle(forUpdatingAtPath: self.url.path) else {
                    return ExtendedAttributes.Failure(code: errno == 0 ? EACCES : errno)
                }
                defer { try? handle.close() }
                do {
                    if structural, let content {
                        // The length can have changed either way, so the whole
                        // content goes down and the file is cut to fit. Written
                        // through the same descriptor rather than replaced, so
                        // the inode, its permissions and its extended
                        // attributes all survive.
                        try handle.seek(toOffset: 0)
                        try handle.write(contentsOf: Data(content))
                        try handle.truncate(atOffset: UInt64(content.count))
                    } else {
                        for run in runs {
                            try handle.seek(toOffset: UInt64(run.offset))
                            try handle.write(contentsOf: Data(run.bytes))
                        }
                    }
                    try handle.synchronize()
                } catch {
                    return ExtendedAttributes.Failure(message: error.localizedDescription)
                }
                return nil
            },
            // No shell equivalent worth offering: patching arbitrary offsets as
            // root through `dd` is a worse idea than saying no.
            command: nil)

        let summary = saveSummary
        switch change.perform() {
        case .succeeded(let warning):
            reload()
            note(warning ?? "Saved: \(summary).")
            if warning != nil { statusIsError = true }
        case .cancelled:
            note("Cancelled. The file is unchanged.", error: true)
        case .failed(let message):
            note("Could not save: \(message)", error: true)
        }
    }

    /// Re-map after writing, so what is shown is what the file now holds and
    /// nothing stays marked as changed.
    private func reload() {
        // Nothing before a save can be undone: the reversals describe edits
        // against content that is now on disk.
        undoStack.removeAll()
        if let fresh = try? Data(contentsOf: url, options: .mappedIfSafe) { bytes = fresh }
        working = nil
        pristine.removeAll()
        inserted.removeAll()
        edits.removeAll()
        clearTyping()
        moveCursor(to: min(cursor, max(count - 1, 0)))
        NotificationCenter.default.post(name: FileInfoModel.didChange, object: url)
    }

    private func note(_ message: String?, error: Bool = false) {
        status = message
        statusIsError = error
    }
}
