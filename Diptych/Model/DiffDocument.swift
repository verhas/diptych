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

    /// Which side the user has unlocked, and nil while the window is read only.
    private(set) var editable: Side?
    /// Set once the choice has been made, so the other padlock stays shut even
    /// after a save.
    private(set) var choiceIsMade = false

    private(set) var lines: [Side: [String]] = [:]
    private var asRead: [Side: [String]] = [:]

    private(set) var diff = TextDiff(left: [], right: [])
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
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(pair: DiffPair) {
        self.pair = pair
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
            recompute()
        case .failure(let error):
            failure = (error as? TextDiff.Failure)?.message ?? error.localizedDescription
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
        guard !choiceIsMade else { return .alreadyChosen }
        guard let file = file(side) else { return nil }
        guard file.isWritable else {
            return .notWritable(name: side == .left ? pair.left.lastPathComponent
                                                    : pair.right.lastPathComponent)
        }
        editable = side
        choiceIsMade = true
        return nil
    }

    // MARK: - Editing

    /// Replace one line. Called when the caret leaves it, not on every
    /// keystroke: recomputing the alignment under a moving cursor makes the
    /// rows jump mid-word.
    func setLine(_ index: Int, to text: String) {
        guard let side = editable, var current = lines[side],
              current.indices.contains(index), current[index] != text else { return }
        record(Step(start: index, newCount: 1, previous: [current[index]]))
        current[index] = text
        lines[side] = current
        recompute()
    }

    /// Return in the middle of a line.
    func splitLine(_ index: Int, at offset: Int) {
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
        guard let side = editable, var current = lines[side],
              current.indices.contains(index), index > 0 else { return }
        record(Step(start: index - 1, newCount: 1,
                    previous: [current[index - 1], current[index]]))
        current.replaceSubrange((index - 1)...index, with: [current[index - 1] + current[index]])
        lines[side] = current
        recompute()
    }

    func deleteLine(_ index: Int) {
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

    func undo() { apply(popping: &undoStack, pushing: &redoStack) }
    func redo() { apply(popping: &redoStack, pushing: &undoStack) }

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

    // MARK: - Saving

    enum SaveOutcome: Equatable {
        case saved
        case nothingToDo
        case changedUnderneath(name: String)
        case failed(String)
    }

    func save() -> SaveOutcome {
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
            return .failed(error.localizedDescription)
        }

        asRead[side] = lines[side]
        var refreshed = file
        refreshed.modified = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        if side == .left { left = refreshed } else { right = refreshed }
        return .saved
    }

    /// Written beside the original and swapped in.
    ///
    /// `replaceItemAt` keeps the original file's permissions, ownership and
    /// extended attributes by default, which matters here more than usual: in a
    /// file manager, losing somebody's Finder tags when they fix a typo would
    /// be its own small betrayal.
    private nonisolated static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".diptych-save-\(UUID().uuidString)")
        try data.write(to: temporary)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// After the file has been read again following an outside change.
    func reload() async {
        let side = editable
        await load()
        editable = side
        undoStack.removeAll()
        redoStack.removeAll()
    }

    // MARK: - The comparison

    private func recompute() {
        let l = lines[.left] ?? []
        let r = lines[.right] ?? []
        diff = ignoreWhitespace
            ? TextDiff(left: l, right: r, comparing: TextDiff.withoutSpacing)
            : TextDiff(left: l, right: r)
        recomputeEdits()
    }
}
