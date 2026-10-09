import Foundation

/// Where each line of a text starts, for the editor's gutter, its folds and
/// the places its problems are reported -- in UTF-16 offsets, as a text view
/// counts. Ported from Tychedit.
nonisolated struct LineIndex: Sendable, Equatable {

    /// `starts[i]` is the offset of the first character of line `i`.
    let starts: [Int]
    /// Length of the whole text.
    let length: Int

    init(_ text: NSString) {
        var starts = [0]
        let length = text.length
        // Through a buffer: characterAtIndex is a message send per character,
        // and this runs on every keystroke.
        let chunk = 4096
        var buffer = [unichar](repeating: 0, count: chunk)
        var offset = 0
        while offset < length {
            let count = min(chunk, length - offset)
            text.getCharacters(&buffer, range: NSRange(location: offset, length: count))
            for i in 0..<count where buffer[i] == 10 {
                starts.append(offset + i + 1)
            }
            offset += count
        }
        self.starts = starts
        self.length = length
    }

    init(_ text: String) {
        self.init(text as NSString)
    }

    /// Number of lines. An empty text, and one ending in a newline, both have
    /// a last, empty line -- the one the caret sits on after the newline.
    var count: Int { starts.count }

    /// The zero-based line holding `offset`; past the end, the last line.
    func line(containing offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    /// The line's characters, without its newline.
    func contentRange(ofLine line: Int) -> NSRange {
        let start = starts[line]
        let end = line + 1 < starts.count ? starts[line + 1] - 1 : length
        return NSRange(location: start, length: end - start)
    }

    /// The column of `offset` within its line, zero-based, in UTF-16 units.
    func column(of offset: Int) -> Int {
        offset - starts[line(containing: offset)]
    }
}

/// Which lines differ from another version of the text -- the last commit, or
/// the last save -- for the gutter's change bars. Ported from Tychedit.
nonisolated struct LineChanges: Sendable, Equatable {

    enum Kind: Sendable, Equatable {
        /// A line that was not there before.
        case added
        /// A line that took the place of one or more lines.
        case modified
    }

    /// Zero-based line of the current text → how it changed.
    var lines: [Int: Kind] = [:]
    /// Lines were removed just before these current lines; a value equal to
    /// the line count means at the very end.
    var deletions: Set<Int> = []

    static let none = LineChanges()

    var isEmpty: Bool { lines.isEmpty && deletions.isEmpty }

    /// Every line added: a file the other version does not have.
    static func allAdded(_ text: String) -> LineChanges {
        var changes = LineChanges()
        for index in split(text).indices { changes.lines[index] = .added }
        return changes
    }

    /// `current` against `base`, line by line: Myers' diff, as git's own
    /// default is. Removed and inserted runs at one place pair up as
    /// changed lines; what is left over is added or deleted.
    static func compute(base: String, current: String) -> LineChanges {
        let old = split(base)
        let new = split(current)
        guard old != new else { return .none }
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var changes = LineChanges()
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if removed.contains(i) || inserted.contains(j) {
                var removedRun = 0
                while removed.contains(i + removedRun) { removedRun += 1 }
                var insertedRun = 0
                while inserted.contains(j + insertedRun) { insertedRun += 1 }
                for k in 0..<insertedRun {
                    changes.lines[j + k] = k < removedRun ? .modified : .added
                }
                if removedRun > insertedRun { changes.deletions.insert(j + insertedRun) }
                i += removedRun
                j += insertedRun
            } else {
                i += 1
                j += 1
            }
        }
        return changes
    }

    /// Lines without their terminators, so a CRLF checkout and an LF edit agree.
    static func split(_ text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
    }
}
