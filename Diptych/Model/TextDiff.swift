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

    /// A stretch of one line, and whether it is part of what changed.
    struct Span: Sendable, Equatable {
        var text: String
        var changed: Bool
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
        /// Set only on a rewritten line whose two versions still resemble each
        /// other. Empty means "colour the whole line and leave it at that".
        var leftSpans: [Span] = []
        var rightSpans: [Span] = []
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
                var pair = Row(id: rows.count, kind: .changed, left: gone, right: arrived,
                               leftNumber: leftIndex + 1, rightNumber: rightIndex + 1)
                if let marked = Self.spans(left: gone, right: arrived) {
                    pair.leftSpans = marked.left
                    pair.rightSpans = marked.right
                }
                row = pair
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

    // MARK: - Within one line

    /// Split for comparing, not for spelling: a run of letters or digits is one
    /// token, a run of spaces is one token, and everything else stands alone.
    ///
    /// Word by word rather than letter by letter, because a letter-level diff
    /// of ordinary prose produces confetti -- half the letters of a rewritten
    /// word marked and half not, which is harder to read than no marking.
    static func tokens(of line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentKind: Int?

        for character in line {
            let kind: Int
            if character.isWhitespace { kind = 0 }
            else if character.isLetter || character.isNumber { kind = 1 }
            else { kind = 2 }

            // Punctuation never joins its neighbours, so "one,two" is three
            // tokens and changing the comma marks only the comma.
            if kind == currentKind, kind != 2 {
                current.append(character)
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = String(character)
                currentKind = kind
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Below this the two lines have little in common, and marking the few
    /// words they share is less use than colouring the whole line.
    static let similarEnough = 0.4

    /// Longer than this and the token diff is not worth the wait for a line
    /// nobody can read across anyway.
    static let markingLineLimit = 2000

    private static func isBlank(_ token: String) -> Bool {
        token.allSatisfy(\.isWhitespace)
    }

    /// Which parts of two versions of one line actually differ.
    ///
    /// Nil when the answer would be "all of it" -- a rewritten line marked
    /// entirely is the same as a line not marked at all, with extra noise.
    static func spans(left: String, right: String) -> (left: [Span], right: [Span])? {
        guard left.count <= markingLineLimit, right.count <= markingLineLimit else { return nil }
        let leftTokens = tokens(of: left)
        let rightTokens = tokens(of: right)
        guard !leftTokens.isEmpty, !rightTokens.isEmpty else { return nil }

        let difference = rightTokens.difference(from: leftTokens)

        var removed = Set<Int>()
        var inserted = Set<Int>()
        var changedWords = 0
        for change in difference {
            switch change {
            case .remove(let offset, let token, _):
                removed.insert(offset)
                if !isBlank(token) { changedWords += 1 }
            case .insert(let offset, let token, _):
                inserted.insert(offset)
                if !isBlank(token) { changedWords += 1 }
            }
        }

        // Counted on words, not on everything. Two sentences with nothing
        // whatever in common still share all their spaces, and counting those
        // as agreement made "the quick brown fox" look 43% similar to
        // "entirely unrelated content indeed".
        let words = leftTokens.count { !isBlank($0) } + rightTokens.count { !isBlank($0) }
        guard words > 0 else { return nil }
        let shared = Double(words - changedWords) / Double(words)
        guard shared >= similarEnough else { return nil }
        guard !removed.isEmpty || !inserted.isEmpty else { return nil }

        return (join(leftTokens, marking: removed), join(rightTokens, marking: inserted))
    }

    /// Neighbouring tokens of the same kind become one span, so a changed
    /// phrase is drawn as one block rather than as a row of separate patches.
    private static func join(_ tokens: [String], marking: Set<Int>) -> [Span] {
        var spans: [Span] = []
        for (index, token) in tokens.enumerated() {
            let changed = marking.contains(index)
            if var last = spans.last, last.changed == changed {
                last.text += token
                spans[spans.count - 1] = last
            } else {
                spans.append(Span(text: token, changed: changed))
            }
        }
        return spans
    }

    // MARK: - Reading files

    /// Split the way a diff needs.
    ///
    /// Two things `components(separatedBy: .newlines)` gets wrong here. It
    /// treats CR and LF as separate separators, so a file written on Windows
    /// came back with a phantom blank line after every real one and diffed as
    /// double-spaced nonsense. And a trailing newline ends the last line rather
    /// than beginning an empty one.
    static func lines(of text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var previousWasReturn = false

        for character in text {
            switch character {
            case "\r\n":
                // Swift reads CRLF as a single Character, but a file may also
                // hold a lone CR or LF, so all three are handled.
                lines.append(current)
                current = ""
                previousWasReturn = false
            case "\n":
                lines.append(current)
                current = ""
                previousWasReturn = false
            case "\r":
                lines.append(current)
                current = ""
                previousWasReturn = true
            default:
                previousWasReturn = false
                current.append(character)
            }
        }
        _ = previousWasReturn
        if !current.isEmpty { lines.append(current) }
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

    /// Where each file lives, when that is the only thing telling them apart.
    ///
    /// Two files of the same name in different folders looked identical in the
    /// header, which made the whole window ambiguous -- the reader could not
    /// tell which side was which. What is shown is the part of the two paths
    /// that differs, so it is short *and* guaranteed to contain the answer;
    /// truncating a long path in the middle could hide the very component that
    /// distinguishes them.
    ///
    /// Nil when both files are in one folder: there the names tell them apart.
    var folders: (left: String, right: String)? {
        let leftFolder = left.deletingLastPathComponent()
        let rightFolder = right.deletingLastPathComponent()
        guard FileOperations.canonicalPath(leftFolder)
                != FileOperations.canonicalPath(rightFolder) else { return nil }

        let leftParts = leftFolder.pathComponents
        let rightParts = rightFolder.pathComponents
        var common = 0
        while common < leftParts.count, common < rightParts.count,
              leftParts[common] == rightParts[common] { common += 1 }

        // One inside the other leaves nothing on a side, so both are shown
        // whole rather than one being shown as nothing.
        guard common > 1, common < leftParts.count, common < rightParts.count else {
            return (leftFolder.path.abbreviatingWithTildeInPath,
                    rightFolder.path.abbreviatingWithTildeInPath)
        }
        return ("\u{2026}/" + leftParts[common...].joined(separator: "/"),
                "\u{2026}/" + rightParts[common...].joined(separator: "/"))
    }
}

private extension String {
    var abbreviatingWithTildeInPath: String { (self as NSString).abbreviatingWithTildeInPath }
}
