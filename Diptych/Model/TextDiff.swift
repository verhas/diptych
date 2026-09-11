import Foundation

/// Comparing two text files, line by line.
///
/// The diff itself comes from the standard library: `difference(from:)` is
/// Myers, it is already there, and it is better tested than anything that could
/// be written here. This type does the part the standard library does not --
/// turning a list of insertions and removals back into two columns that line up
/// on screen, which is the whole point of looking at a diff side by side.
struct TextDiff: Sendable {

    enum Kind: Sendable {
        /// Present on both sides, unchanged.
        case same
        /// On the right only.
        case added
        /// On the left only.
        case removed
        /// Both sides have a line here and they differ.
        case changed

        var isChange: Bool { self != .same }
    }

    /// One line of the comparison. Either side may be empty, which is how a
    /// line that exists in one file and not the other keeps the two columns
    /// aligned all the way down.
    struct Row: Identifiable, Sendable {
        let id: Int
        var kind: Kind
        var left: String?
        var right: String?
        var leftNumber: Int?
        var rightNumber: Int?
    }

    var rows: [Row] = []
    /// Row indices where a change begins, for jumping between them. Runs of
    /// changed lines count once: the reader wants the next *difference*, not
    /// the next line of the one they are already looking at.
    var changeStarts: [Int] = []
    var isIdentical: Bool { changeStarts.isEmpty }

    /// Beyond this, `difference(from:)` is no longer something to run while
    /// somebody waits. Files this size are not what this window is for.
    static let lineLimit = 100_000

    enum Failure: Error, Sendable {
        case notText(name: String)
        case tooBig(name: String, lines: Int)

        var message: String {
            switch self {
            case .notText(let name):
                "\u{201C}\(name)\u{201D} is not text that Diptych can read. "
                + "The binary view opens files like that."
            case .tooBig(let name, let lines):
                "\u{201C}\(name)\u{201D} has \(lines) lines, which is more than this "
                + "window can compare."
            }
        }
    }

    // MARK: - Building

    init(left: [String], right: [String]) {
        // Offsets in a `CollectionDifference` are into the two original
        // collections -- removals into the left, insertions into the right --
        // so both can be walked in step to rebuild the alignment.
        var removals: [Int: String] = [:]
        var insertions: [Int: String] = [:]
        for change in right.difference(from: left) {
            switch change {
            case .remove(let offset, let element, _): removals[offset] = element
            case .insert(let offset, let element, _): insertions[offset] = element
            }
        }

        var leftIndex = 0
        var rightIndex = 0
        var wasChange = false

        while leftIndex < left.count || rightIndex < right.count {
            let removed = removals[leftIndex]
            let inserted = insertions[rightIndex]
            let row: Row

            switch (removed, inserted) {
            case (.some(let gone), .some(let arrived)):
                // A removal and an insertion at the same place is one line
                // rewritten. Shown as a pair rather than as a deletion followed
                // by an addition, which is what it looks like to a reader.
                row = Row(id: rows.count, kind: .changed, left: gone, right: arrived,
                          leftNumber: leftIndex + 1, rightNumber: rightIndex + 1)
                leftIndex += 1
                rightIndex += 1

            case (.some(let gone), .none):
                row = Row(id: rows.count, kind: .removed, left: gone, right: nil,
                          leftNumber: leftIndex + 1, rightNumber: nil)
                leftIndex += 1

            case (.none, .some(let arrived)):
                row = Row(id: rows.count, kind: .added, left: nil, right: arrived,
                          leftNumber: nil, rightNumber: rightIndex + 1)
                rightIndex += 1

            case (.none, .none):
                guard leftIndex < left.count, rightIndex < right.count else {
                    // Only reachable if the difference did not account for
                    // every line, which would be a bug rather than a file.
                    leftIndex = left.count
                    rightIndex = right.count
                    continue
                }
                row = Row(id: rows.count, kind: .same, left: left[leftIndex],
                          right: right[rightIndex],
                          leftNumber: leftIndex + 1, rightNumber: rightIndex + 1)
                leftIndex += 1
                rightIndex += 1
            }

            if row.kind.isChange && !wasChange { changeStarts.append(rows.count) }
            wasChange = row.kind.isChange
            rows.append(row)
        }
    }

    // MARK: - Reading files

    /// Split the way a diff needs rather than the way `components` does: a
    /// trailing newline ends the last line, it does not begin an empty one.
    static func lines(of text: String) -> [String] {
        var lines = text.components(separatedBy: .newlines)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Read a file as text, or say why not.
    ///
    /// UTF-8 first, then whatever the file claims: a document written years ago
    /// on this Mac may well be Latin-1, and refusing to compare it would be
    /// obtuse when the system can tell us what it is.
    static func read(_ url: URL) throws -> [String] {
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            throw Failure.notText(name: name)
        }
        // A NUL byte in the first stretch is the oldest and still the best test
        // for "this is not a text file".
        if data.prefix(8000).contains(0) { throw Failure.notText(name: name) }

        var text = String(data: data, encoding: .utf8)
        if text == nil {
            var encoding = String.Encoding.utf8
            text = try? String(contentsOf: url, usedEncoding: &encoding)
        }
        guard let text else { throw Failure.notText(name: name) }

        let lines = Self.lines(of: text)
        guard lines.count <= lineLimit else {
            throw Failure.tooBig(name: name, lines: lines.count)
        }
        return lines
    }

    static func compare(_ left: URL, _ right: URL) throws -> TextDiff {
        TextDiff(left: try read(left), right: try read(right))
    }
}

/// What a diff window is opened for. `WindowGroup(for:)` needs one value, and
/// two URLs are two values, so they travel as a pair.
struct DiffPair: Hashable, Codable, Sendable {
    var left: URL
    var right: URL
}
