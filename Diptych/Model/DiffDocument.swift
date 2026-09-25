import Foundation

/// A file as it was read, with everything needed to write it back unchanged
/// except for the text.
///
/// All three of these are invisible and all three are easy to destroy. A file
/// written on Windows must not come back with Unix endings, a file that never
/// ended in a newline must not acquire one, and a file that could only be read
/// as Latin-1 must not be written as UTF-8. Saving a document must change what
/// the user changed and nothing else.
struct SourceFile: Sendable {
    var lines: [String]
    var lineEnding: String
    var hasFinalNewline: Bool
    var encoding: String.Encoding
    /// What the file's date was when it was read, so a change made by somebody
    /// else in the meantime can be noticed instead of overwritten.
    var modified: Date?
    var isWritable: Bool

    func text(from lines: [String]) -> String {
        lines.joined(separator: lineEnding) + (hasFinalNewline && !lines.isEmpty ? lineEnding : "")
    }
}

/// The state of one comparison window: two files, at most one of them editable.
///
/// Exactly one side can be unlocked, and once chosen it cannot be swapped for
/// the life of the window. That is deliberate and it is restrictive: editing
/// both halves of a comparison in one sitting invites losing track of which
/// side is the one you mean, and the way out is to save, close, and open the
/// comparison again. It also makes everything else unambiguous -- one file can
/// be dirty, undo belongs to one file, and taking a difference has only one
/// direction to go.
@MainActor
@Observable
final class DiffDocument {

    enum Side: Sendable {
        case left, right
        var other: Side { self == .left ? .right : .left }
    }

    /// One undoable change to the editable side.
    ///
    /// Every edit is the same shape -- some lines replaced by some other lines
    /// -- so one case covers typing in a line, splitting it, joining two, and
    /// taking a whole difference from the other side. Taking a difference then
    /// undoes in one step rather than line by line, which is what somebody who
    /// pressed one button expects.
    private struct Step {
        var start: Int
        var newCount: Int
        var previous: [String]
    }

    let pair: DiffPair

    private(set) var left: SourceFile?
    private(set) var right: SourceFile?
    private(set) var failure: String?

    /// The byte-by-byte answer, when one of the two is not text.
    ///
    /// A line comparison has nothing to say about a JPEG, so the window shows
    /// this instead -- and shows none of the text machinery with it.
    private(set) var binary: BinaryComparison?
    private(set) var isComparingBytes = false

    /// Which side the user has unlocked, and nil while the window is read only.
    private(set) var editable: Side?
    /// Whether anything has actually been written yet.
    ///
    /// The padlock is only binding once it has: unlocking a side by mistake,
    /// or typing and undoing it all, must be undoable too. Requiring a restart
    /// for a decision nothing came of is punishment for a misclick.
    private(set) var hasSaved = false

    private(set) var lines: [Side: [String]] = [:]
    private var asRead: [Side: [String]] = [:]

    private(set) var diff = TextDiff(left: [], right: [])
    /// The longest line in either file, in characters. Needed to know how wide
    /// the columns have to be before they can be scrolled sideways, and worked
    /// out here rather than in the view so it is not recomputed on every
    /// redraw of a hundred thousand rows.
    private(set) var longestLine = 0
    var ignoreWhitespace = false {
        didSet { if ignoreWhitespace != oldValue { recompute() } }
    }

    private var undoStack: [Step] = []
    private var redoStack: [Step] = []
    /// Bounded, because a document of a hundred thousand lines should not be
    /// able to fill memory with its own history.
    private static let stepLimit = 200

    var isDirty: Bool {
        guard let editable else { return false }
        return lines[editable] != asRead[editable]
    }
    var canUndo: Bool { !undoStack.isEmpty || sessionIsOpen }
    var canRedo: Bool { !redoStack.isEmpty }

    /// True while the choice of side can still be changed: nothing unsaved,
    /// and nothing saved either.
    var canChooseAgain: Bool { !isDirty && !hasSaved }

    /// The line being typed into, and what it held when typing began.
    ///
    /// Typing reaches `lines` at once -- so Save, Undo and the dirty mark are
    /// all true immediately, which they were not when the document only heard
    /// about a line as the caret left it -- but the *alignment* is left alone
    /// until the line is finished. Recomputing it per keystroke makes the rows
    /// jump under the caret; not recomputing it at all made a one-line file
    /// impossible to save, because there was no other line to move to.
    private var session: (index: Int, text: String)?
    private var sessionIsOpen: Bool { session != nil }

    init(pair: DiffPair) {
        self.pair = pair
    }

    deinit {
        leftWatcher?.cancel()
        rightWatcher?.cancel()
    }

    // MARK: - Watching the files

    /// A window left open across an edit made somewhere else -- in Text Edit,
    /// in another app, from the command line -- used to go on showing
    /// whatever it read when it opened, forever: nothing ever told it to look
    /// again. `reload()` already existed for exactly this; nothing called it.
    @ObservationIgnored private var leftWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var rightWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    func startWatching() {
        stopWatching()
        leftWatcher = watch(pair.left)
        rightWatcher = watch(pair.right)
    }

    func stopWatching() {
        leftWatcher?.cancel()
        rightWatcher?.cancel()
        leftWatcher = nil
        rightWatcher = nil
        reloadTask?.cancel()
    }

    private func watch(_ url: URL) -> DispatchSourceFileSystemObject? {
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.diskChanged(url) }
        }
        // The cancel handler owns closing the descriptor; closing it anywhere
        // else races the source and can shut down an unrelated file.
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        return source
    }

    private func diskChanged(_ url: URL) {
        // A save that replaces the file -- write-to-a-temporary-name and
        // rename over the original, which is how this app's own `save()`
        // writes, and how many editors do -- swaps in a new inode at this
        // path. The descriptor above was watching the old one, and having
        // seen it renamed or deleted will not see anything at this path
        // again, so the watch is re-established on whatever is there now.
        if url == pair.left {
            leftWatcher?.cancel()
            leftWatcher = watch(url)
        } else {
            rightWatcher?.cancel()
            rightWatcher = watch(url)
        }

        // Never discard unsaved typing to reflect a change made elsewhere --
        // `save()` already refuses to save over a file changed underneath it,
        // which is the moment this conflict actually needs deciding.
        guard !isDirty else { return }

        // Coalesced: a save is often more than one filesystem event, and
        // reloading on each would re-run the comparison for nothing.
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    // MARK: - Reading

    func load() async {
        let pair = pair
        let outcome: Result<(SourceFile, SourceFile), Error> = await BlockingWork.run {
            do { return .success((try TextDiff.load(pair.left), try TextDiff.load(pair.right))) }
            catch { return .failure(error) }
        }
        switch outcome {
        case .success(let (leftFile, rightFile)):
            left = leftFile
            right = rightFile
            lines = [.left: leftFile.lines, .right: rightFile.lines]
            asRead = lines
            failure = nil
            // A full reset, because reading is where a comparison starts.
            // SwiftUI keeps a window's state against the value it was opened
            // with, so comparing the same pair again came back with the old
            // undo history and the old padlock still open on a file that had
            // since been saved.
            editable = nil
            hasSaved = false
            forgetHistory()
            recompute()
        case .failure(let error):
            // Not text? Then the question is a different one, and it has an
            // answer: compare the bytes.
            if let trouble = error as? TextDiff.Failure, case .notText = trouble {
                await compareBytes()
                return
            }
            failure = (error as? TextDiff.Failure)?.message ?? error.localizedDescription
        }
    }

    private func compareBytes() async {
        isComparingBytes = true
        defer { isComparingBytes = false }

        let pair = pair
        let outcome: Result<BinaryComparison, Error> = await BlockingWork.run {
            do { return .success(try BinaryComparison.compare(pair.left, pair.right)) }
            catch { return .failure(error) }
        }
        switch outcome {
        case .success(let comparison):
            binary = comparison
            failure = nil
        case .failure(let error):
            failure = "These files could not be compared: \(error.localizedDescription)"
        }
    }

    func file(_ side: Side) -> SourceFile? { side == .left ? left : right }

    /// Lines of the editable side that differ from what was read.
    ///
    /// Worked out by diffing the file against itself-as-read rather than by
    /// remembering which lines were touched: indices move when a line is
    /// inserted or removed, so a list of touched positions goes stale
    /// immediately and marks every line below the edit.
    ///
    /// Reported in the gutter and not as a background, because "differs from
    /// the other file" and "you changed this" are two different facts and one
    /// background cannot say both.
    private(set) var editedLines: Set<Int> = []

    func isEdited(_ side: Side, line index: Int?) -> Bool {
        guard let index, side == editable else { return false }
        return editedLines.contains(index)
    }

    private func recomputeEdits() {
        guard let side = editable, let original = asRead[side], let current = lines[side],
              original != current else {
            editedLines = []
            return
        }
        var marked: Set<Int> = []
        for row in TextDiff(left: original, right: current).rows where row.kind.isChange {
            if let number = row.rightNumber { marked.insert(number - 1) }
        }
        editedLines = marked
    }

    // MARK: - Unlocking

    enum UnlockRefusal {
        case alreadyChosen
        case notWritable(name: String)

        var message: String {
            switch self {
            case .alreadyChosen:
                "Only one side can be edited at a time. Save and open the comparison "
                + "again to work on the other file."
            case .notWritable(let name):
                "\u{201C}\(name)\u{201D} cannot be written to. Change its permissions "
                + "first, in Get Info."
            }
        }
    }

    func unlock(_ side: Side) -> UnlockRefusal? {
        guard editable != side else { return nil }
        guard editable == nil || canChooseAgain else { return .alreadyChosen }
        guard let file = file(side) else { return nil }
        guard file.isWritable else {
            return .notWritable(name: side == .left ? pair.left.lastPathComponent
                                                    : pair.right.lastPathComponent)
        }
        editable = side
        forgetHistory()
        return nil
    }

    /// Shut the padlock again, which is only allowed while there is nothing to
    /// lose by it.
    @discardableResult
    func relock() -> Bool {
        guard canChooseAgain else { return false }
        editable = nil
        forgetHistory()
        recompute()
        return true
    }

    private func forgetHistory() {
        session = nil
        undoStack.removeAll()
        redoStack.removeAll()
        recomputeEdits()
    }

    // MARK: - Editing

    /// A keystroke. Reaches the text at once and the alignment not at all.
    func typing(_ index: Int, _ text: String) {
        guard let side = editable, var current = lines[side],
              current.indices.contains(index) else { return }
        if session?.index != index {
            endLine()
            session = (index, current[index])
        }
        guard current[index] != text else { return }
        current[index] = text
        lines[side] = current
    }

    /// The caret has left the line, so the alignment can move without moving
    /// the ground under anybody's cursor.
    func endLine() {
        guard let open = session, let side = editable, let current = lines[side] else { return }
        session = nil
        if current.indices.contains(open.index), current[open.index] != open.text {
            record(Step(start: open.index, newCount: 1, previous: [open.text]))
        }
        recompute()
    }

    /// Put the line back to what it held when typing began.
    func revertLine() {
        guard let open = session, let side = editable, var current = lines[side],
              current.indices.contains(open.index) else { return }
        session = nil
        current[open.index] = open.text
        lines[side] = current
        recompute()
    }

    /// Replace a line outright, as one undoable step.
    func setLine(_ index: Int, to text: String) {
        typing(index, text)
        endLine()
    }

    /// Return in the middle of a line.
    func splitLine(_ index: Int, at offset: Int) {
        session = nil
        guard let side = editable, var current = lines[side],
              current.indices.contains(index) else { return }
        let line = current[index]
        let cut = line.index(line.startIndex, offsetBy: min(max(offset, 0), line.count))
        record(Step(start: index, newCount: 2, previous: [line]))
        current.replaceSubrange(index...index, with: [String(line[..<cut]),
                                                      String(line[cut...])])
        lines[side] = current
        recompute()
    }

    /// Backspace at the very start of a line.
    func joinWithPrevious(_ index: Int) {
        session = nil
        guard let side = editable, var current = lines[side],
              current.indices.contains(index), index > 0 else { return }
        record(Step(start: index - 1, newCount: 1,
                    previous: [current[index - 1], current[index]]))
        current.replaceSubrange((index - 1)...index, with: [current[index - 1] + current[index]])
        lines[side] = current
        recompute()
    }

    func deleteLine(_ index: Int) {
        session = nil
        guard let side = editable, var current = lines[side],
              current.indices.contains(index) else { return }
        record(Step(start: index, newCount: 0, previous: [current[index]]))
        current.remove(at: index)
        lines[side] = current
        recompute()
    }

    // MARK: - Taking a difference from the other side

    /// Make the editable side match the other one, for the whole difference
    /// that `row` belongs to.
    ///
    /// A difference, not a line: a reader who presses this means "make this
    /// bit the same", and a run of changed lines is one bit. Undone in one
    /// step for the same reason.
    func takeDifference(atRow row: Int) {
        endLine()
        guard let side = editable, var current = lines[side] else { return }
        guard let span = run(containing: row) else { return }

        let incoming = diff.rows[span].compactMap { text($0, on: side.other) }
        let mine = diff.rows[span].compactMap { number($0, on: side) }

        if let first = mine.first, let last = mine.last {
            let range = (first - 1)...(last - 1)
            guard current.indices.contains(range.lowerBound),
                  current.indices.contains(range.upperBound) else { return }
            record(Step(start: range.lowerBound, newCount: incoming.count,
                        previous: Array(current[range])))
            current.replaceSubrange(range, with: incoming)
        } else {
            // The other side has lines here and this one has none, so there is
            // nothing to replace -- they are inserted after the last line of
            // mine that comes before this difference.
            var at = 0
            for index in 0..<span.lowerBound {
                if let number = number(diff.rows[index], on: side) { at = number }
            }
            record(Step(start: at, newCount: incoming.count, previous: []))
            current.insert(contentsOf: incoming, at: min(at, current.count))
        }
        lines[side] = current
        recompute()
    }

    /// The stretch of rows making up one difference.
    private func run(containing row: Int) -> ClosedRange<Int>? {
        guard diff.rows.indices.contains(row), diff.rows[row].kind.isChange else { return nil }
        var first = row
        while first > 0, diff.rows[first - 1].kind.isChange { first -= 1 }
        var last = row
        while last + 1 < diff.rows.count, diff.rows[last + 1].kind.isChange { last += 1 }
        return first...last
    }

    private func text(_ row: TextDiff.Row, on side: Side) -> String? {
        side == .left ? row.left : row.right
    }

    private func number(_ row: TextDiff.Row, on side: Side) -> Int? {
        side == .left ? row.leftNumber : row.rightNumber
    }

    // MARK: - Undo

    private func record(_ step: Step) {
        undoStack.append(step)
        if undoStack.count > Self.stepLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        endLine()
        apply(popping: &undoStack, pushing: &redoStack)
    }

    func redo() {
        endLine()
        apply(popping: &redoStack, pushing: &undoStack)
    }

    private func apply(popping source: inout [Step], pushing destination: inout [Step]) {
        guard let side = editable, var current = lines[side], let step = source.popLast()
        else { return }
        let upper = min(step.start + step.newCount, current.count)
        guard step.start <= upper else { return }
        let replaced = Array(current[step.start..<upper])
        current.replaceSubrange(step.start..<upper, with: step.previous)
        destination.append(Step(start: step.start, newCount: step.previous.count,
                                previous: replaced))
        lines[side] = current
        recompute()
    }

    // MARK: - Finishing a clash that was set aside

    /// The side holding a `(my version)` copy of the file on the other side.
    ///
    /// Nil unless the pair is exactly that: the same folder, the same
    /// extension, and a name that is the other one with `(my version)` on the
    /// end. A number may follow it, because a second clash on the same file
    /// makes `(my version)-1`.
    var keptCopySide: Side? {
        if Self.isKeptCopy(of: pair.left, pair.right) { return .right }
        if Self.isKeptCopy(of: pair.right, pair.left) { return .left }
        return nil
    }

    static func isKeptCopy(of original: URL, _ candidate: URL) -> Bool {
        guard FileOperations.canonicalPath(original.deletingLastPathComponent())
                == FileOperations.canonicalPath(candidate.deletingLastPathComponent()),
              original.pathExtension == candidate.pathExtension else { return false }

        let stem = original.deletingPathExtension().lastPathComponent
        let mine = candidate.deletingPathExtension().lastPathComponent
        let marked = stem + " (my version)"
        guard mine.hasPrefix(marked) else { return false }
        let tail = mine.dropFirst(marked.count)
        return tail.isEmpty || (tail.hasPrefix("-") && tail.dropFirst().allSatisfy(\.isNumber))
    }

    /// Whether there is a clash here that this window could finish.
    ///
    /// Offered whether or not the copy has been edited: "drop theirs, mine
    /// stands as it is" is a decision like any other, and the commonest one
    /// after keeping a copy in the first place. Which file wins is never in
    /// question either, since only one of the two is named `(my version)`.
    ///
    /// Withheld in exactly one case: unsaved changes on the *other* side.
    /// That side is about to go to the Trash, and it would take them with it.
    var canReplaceOriginal: Bool {
        guard let side = keptCopySide else { return false }
        if let editable, editable != side, isDirty { return false }
        return true
    }

    var originalName: String {
        guard let side = keptCopySide else { return "" }
        return (side == .left ? pair.right : pair.left).lastPathComponent
    }

    enum ReplaceOutcome: Equatable {
        case done
        case notApplicable
        case failed(String)
    }

    /// Save, put the copy in the original's place, and send the original to
    /// the Trash.
    ///
    /// The end of the clash the send dialog set aside: two files that were one
    /// file become one file again. The old version goes to the Trash rather
    /// than being destroyed -- this is a single press with no dialog in front
    /// of it, and a single press that cannot be undone is a different thing
    /// altogether.
    func replaceOriginal() async -> ReplaceOutcome {
        guard canReplaceOriginal, let side = keptCopySide else { return .notApplicable }
        let copy = side == .left ? pair.left : pair.right
        let original = side == .left ? pair.right : pair.left

        // Only the copy's own unsaved work is worth saving here; the other
        // side is on its way to the Trash.
        if editable == side, isDirty {
            switch save() {
            case .saved, .nothingToDo:
                break
            case .changedUnderneath(let name):
                return .failed("\u{201C}\(name)\u{201D} was changed by something else since "
                               + "this window opened.")
            case .failed(let reason):
                return .failed(reason)
            }
        }

        if FileManager.default.fileExists(atPath: original.path) {
            let outcome = await FileOperations.shared.trash([original])
            if let failure = outcome.failures.first {
                return .failed(failure.1)
            }
        }
        do {
            try FileManager.default.moveItem(at: copy, to: original)
        } catch {
            return .failed(error.localizedDescription)
        }
        return .done
    }

    // MARK: - Saving

    enum SaveOutcome: Equatable {
        case saved
        case nothingToDo
        case changedUnderneath(name: String)
        case failed(String)
    }

    func save() -> SaveOutcome {
        // What is on screen, including a line still being typed into.
        endLine()
        guard let side = editable, let file = file(side), isDirty else { return .nothingToDo }
        let url = side == .left ? pair.left : pair.right

        // Somebody else may have written it while this window was open, and in
        // this application that somebody is quite likely Get the Latest. Saving
        // over that silently would throw away exactly the work this window
        // exists to protect.
        let now = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
        if let stamped = file.modified, let now = now as? Date,
           abs(now.timeIntervalSince(stamped)) > 1 {
            return .changedUnderneath(name: url.lastPathComponent)
        }

        guard let text = lines[side].map({ file.text(from: $0) }),
              let data = text.data(using: file.encoding) else {
            return .failed("The text could not be written in this file's original encoding.")
        }

        do {
            try Self.write(data, to: url)
        } catch {
            // Worked out from the file, not repeated from the system: macOS
            // says "you do not have permission" for failures that have nothing
            // to do with permission, and sends the reader off checking things
            // that were never wrong.
            return .failed(WriteTrouble.explaining(error, writing: url))
        }

        asRead[side] = lines[side]
        hasSaved = true
        var refreshed = file
        refreshed.modified = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        if side == .left { left = refreshed } else { right = refreshed }
        return .saved
    }

    /// Written beside the original and swapped in, or straight into the file
    /// when that cannot be done.
    ///
    /// `replaceItemAt` is the safe way: the old file survives untouched until
    /// the new one is complete, and it keeps the original's permissions,
    /// ownership and extended attributes -- in a file manager, losing
    /// somebody's Finder tags when they fix a typo would be its own small
    /// betrayal.
    ///
    /// But it can only do that by *copying* the metadata, and some of it
    /// cannot be copied. A file that a sandboxed program has opened carries
    /// `com.apple.security.private.scoped-bookmark-token`, which no ordinary
    /// process may even read: `getxattr` answers EPERM. The replacement then
    /// fails, and macOS reports it as "you do not have permission to save the
    /// file" -- which is untrue and unhelpful, since the file itself is
    /// perfectly writable and opening it for writing proves so.
    ///
    /// So when the swap will not go through, the bytes go into the file that
    /// is already there. Nothing is copied, so nothing can fail to copy: the
    /// inode is the same one, and with it every permission, owner, ACL and
    /// attribute the file had. The cost is that a crash halfway through leaves
    /// a half-written file, which is why it is the second choice and not the
    /// first.
    /// Shared with Text Edit, which saves the same way for the same reasons.
    nonisolated static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".diptych-save-\(UUID().uuidString)")
        do {
            try data.write(to: temporary)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            return
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
    }

    /// After the file has been read again following an outside change.
    /// After the file has been read again following an outside change: the
    /// text starts over, the choice of side does not.
    func reload() async {
        let side = editable
        let saved = hasSaved
        await load()
        editable = side
        hasSaved = saved
        forgetHistory()
    }

    // MARK: - The comparison

    private func recompute() {
        let l = lines[.left] ?? []
        let r = lines[.right] ?? []
        diff = ignoreWhitespace
            ? TextDiff(left: l, right: r, comparing: TextDiff.withoutSpacing)
            : TextDiff(left: l, right: r)
        recomputeEdits()
        longestLine = max(lines[.left]?.reduce(0) { max($0, $1.count) } ?? 0,
                          lines[.right]?.reduce(0) { max($0, $1.count) } ?? 0)
    }
}
