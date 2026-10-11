import Foundation

/// Text Edit's editing by lines and by indentation, as IntelliJ does it:
/// moving lines, deleting, copying and cutting the caret's line, Tab and
/// Shift-Tab, Return that keeps -- and opens -- the indentation, closing
/// brackets and quotes, comments on and off. Each is worked out here as an
/// `Edit` on the text, and applied by the text view as one undoable change.
nonisolated enum LineEditing {

    /// Replace `range` with `replacement`, then select `selection`.
    struct Edit: Equatable {
        var range: NSRange
        var replacement: String
        var selection: NSRange
    }

    /// One level of indentation, as Settings has it for the format.
    struct Indent: Equatable, Codable, Sendable {
        var tabs: Bool
        var width: Int

        var unit: String { tabs ? "\t" : String(repeating: " ", count: max(1, width)) }

        static let standard = Indent(tabs: false, width: 4)
        static let two = Indent(tabs: false, width: 2)
    }

    // MARK: - Lines

    /// The whole lines the selection touches, with the last one's line break.
    /// A selection that ends at the start of a line does not take that line.
    static func lines(of selection: NSRange, in text: NSString) -> NSRange {
        var end = NSMaxRange(selection)
        if selection.length > 0, end > selection.location, end <= text.length,
           text.character(at: end - 1) == 0x0A {
            end -= 1
        }
        let first = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let last = text.lineRange(for: NSRange(location: max(selection.location, end), length: 0))
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }

    static func endsWithBreak(_ range: NSRange, in text: NSString) -> Bool {
        range.length > 0 && text.character(at: NSMaxRange(range) - 1) == 0x0A
    }

    /// Shift-Command-Up and -Down: the lines swap with the one above or below,
    /// the selection going with them.
    static func move(_ selection: NSRange, in text: NSString, up: Bool) -> Edit? {
        let block = lines(of: selection, in: text)
        if up {
            guard block.location > 0 else { return nil }
            let above = text.lineRange(for: NSRange(location: block.location - 1, length: 0))
            var moving = text.substring(with: block)
            var other = text.substring(with: above)
            if !endsWithBreak(block, in: text) {
                // The last line, without a break: the breaks change places.
                moving += "\n"
                other.removeLast()
            }
            let shift = above.location - block.location
            return Edit(range: NSRange(location: above.location, length: above.length + block.length),
                        replacement: moving + other,
                        selection: NSRange(location: selection.location + shift, length: selection.length))
        } else {
            let end = NSMaxRange(block)
            guard end < text.length, endsWithBreak(block, in: text) else { return nil }
            let below = text.lineRange(for: NSRange(location: end, length: 0))
            var moving = text.substring(with: block)
            var other = text.substring(with: below)
            if !endsWithBreak(below, in: text) {
                other += "\n"
                moving.removeLast()
            }
            let shift = (other as NSString).length
            return Edit(range: NSRange(location: block.location, length: block.length + below.length),
                        replacement: other + moving,
                        selection: NSRange(location: selection.location + shift, length: selection.length))
        }
    }

    /// Command-Delete: the lines go, the caret stays in its column on the
    /// line that comes up.
    static func delete(_ selection: NSRange, in text: NSString) -> Edit {
        var block = lines(of: selection, in: text)
        let column = selection.location - block.location
        if !endsWithBreak(block, in: text), block.location > 0 {
            // The last line: the break before it goes with it.
            block = NSRange(location: block.location - 1, length: block.length + 1)
            let previous = text.lineRange(for: NSRange(location: block.location, length: 0))
            let width = block.location - previous.location
            return Edit(range: block, replacement: "",
                        selection: NSRange(location: previous.location + min(column, width), length: 0))
        }
        let after = text.length - NSMaxRange(block)
        var width = 0
        if after > 0 {
            let next = text.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
            width = next.length - (endsWithBreak(next, in: text) ? 1 : 0)
        }
        return Edit(range: block, replacement: "",
                    selection: NSRange(location: block.location + min(column, width), length: 0))
    }

    /// What Command-C and Command-X take with nothing selected: the caret's
    /// line, with its break.
    static func wholeLine(at caret: Int, in text: NSString) -> (range: NSRange, text: String) {
        let range = text.lineRange(for: NSRange(location: caret, length: 0))
        var line = text.substring(with: range)
        if !line.hasSuffix("\n") { line += "\n" }
        return (range, line)
    }

    /// A whole line pasted with nothing selected goes in above the caret's
    /// line, as it was copied, and the caret stays where it was in the text.
    static func pasteLine(_ line: String, at caret: Int, in text: NSString) -> Edit {
        let start = text.lineRange(for: NSRange(location: caret, length: 0)).location
        var inserted = line
        if start == text.length, start > 0, text.character(at: start - 1) != 0x0A {
            // After a last line with no break: a break first.
            inserted = "\n" + line.dropLast()
        }
        return Edit(range: NSRange(location: start, length: 0), replacement: inserted,
                    selection: NSRange(location: caret + (inserted as NSString).length, length: 0))
    }

    // MARK: - Indentation

    /// The spaces and tabs a line starts with.
    static func leading(ofLineAt location: Int, in text: NSString) -> String {
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        var end = line.location
        while end < NSMaxRange(line), [0x20, 0x09].contains(text.character(at: end)) { end += 1 }
        return text.substring(with: NSRange(location: line.location, length: end - line.location))
    }

    /// Tab with lines selected, Shift-Tab always: every line one level in or
    /// out. The selection keeps covering the same text.
    static func shift(_ selection: NSRange, in text: NSString, by indent: Indent, outwards: Bool) -> Edit? {
        let block = lines(of: selection, in: text)
        let original = text.substring(with: block)
        var rows = original.components(separatedBy: "\n")
        let trailing = original.hasSuffix("\n")
        if trailing { rows.removeLast() }
        var startShift = 0
        var total = 0
        for (index, row) in rows.enumerated() {
            let changed: String
            if outwards {
                changed = removingOneLevel(from: row, indent: indent)
            } else {
                changed = row.isEmpty ? row : indent.unit + row
            }
            let delta = (changed as NSString).length - (row as NSString).length
            if index == 0 { startShift = delta }
            total += delta
            rows[index] = changed
        }
        guard total != 0 else { return nil }
        let replacement = rows.joined(separator: "\n") + (trailing ? "\n" : "")
        return Edit(range: block, replacement: replacement,
                    selection: following(selection, block: block, firstShift: startShift, total: total))
    }

    /// The selection over the same text after its lines changed by `total`,
    /// the first by `firstShift`. A selection from a line's start keeps it.
    static func following(_ selection: NSRange, block: NSRange, firstShift: Int, total: Int) -> NSRange {
        let fromLineStart = selection.location == block.location && selection.length > 0
        let start = fromLineStart ? block.location : max(block.location, selection.location + firstShift)
        guard selection.length > 0 else { return NSRange(location: start, length: 0) }
        let end = max(start, NSMaxRange(selection) + total)
        return NSRange(location: start, length: end - start)
    }

    static func removingOneLevel(from row: String, indent: Indent) -> String {
        if row.hasPrefix("\t") { return String(row.dropFirst()) }
        let spaces = row.prefix { $0 == " " }.count
        return String(row.dropFirst(min(spaces, max(1, indent.width))))
    }

    /// Return: the new line indented as the caret's, one level more after
    /// what opens a block -- `{`, `[`, a start tag, a YAML key with its value
    /// to come -- and, between a pair, the closing one on a line of its own.
    static func newline(at selection: NSRange, in text: NSString, format: TextFormat?,
                        indent: Indent) -> Edit {
        let caret = selection.location
        let base = leading(ofLineAt: caret, in: text)
        let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
        let before = text.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        let lineEnd = lineEndLocation(after: NSMaxRange(selection), in: text)
        let after = text.substring(with: NSRange(location: NSMaxRange(selection),
                                                 length: lineEnd - NSMaxRange(selection)))
        let trimmedBefore = before.trimmingCharacters(in: .whitespaces)
        let trimmedAfter = after.trimmingCharacters(in: .whitespaces)
        // Spaces right after the caret do not move down with the rest.
        let skipped = (after as NSString).length - (after.drop { $0 == " " || $0 == "\t" } as Substring).utf16.count
        let replaced = NSRange(location: caret, length: selection.length + skipped)

        var opens = false
        var closesRightAfter = false
        let format = format?.markup
        switch format {
        case .json, .toml, .yaml:
            if let last = trimmedBefore.last, last == "{" || last == "[" {
                opens = true
                if let first = trimmedAfter.first, (last == "{" && first == "}") || (last == "[" && first == "]") {
                    closesRightAfter = true
                }
            }
            if format == .yaml, !opens, opensYAMLBlock(trimmedBefore) { opens = true }
        case .xml, .plist:
            if let tag = openTagBefore(before) {
                opens = true
                closesRightAfter = trimmedAfter.hasPrefix("</\(tag)")
            }
        case nil:
            break
        }
        let inner = opens ? base + indent.unit : base
        if closesRightAfter {
            let replacement = "\n" + inner + "\n" + base
            return Edit(range: replaced, replacement: replacement,
                        selection: NSRange(location: caret + 1 + (inner as NSString).length, length: 0))
        }
        let replacement = "\n" + inner
        return Edit(range: replaced, replacement: replacement,
                    selection: NSRange(location: caret + (replacement as NSString).length, length: 0))
    }

    static func lineEndLocation(after location: Int, in text: NSString) -> Int {
        var end = location
        while end < text.length, text.character(at: end) != 0x0A { end += 1 }
        return end
    }

    /// `key:` with nothing after it but a comment, or `- ` alone: what is
    /// under it is indented.
    static func opensYAMLBlock(_ line: String) -> Bool {
        var body = line
        if let hash = body.range(of: " #") { body = String(body[..<hash.lowerBound]) }
        body = body.trimmingCharacters(in: .whitespaces)
        if body == "-" { return true }
        return body.hasSuffix(":") || body.hasSuffix(": |") || body.hasSuffix(": >")
            || body.hasSuffix(": |-") || body.hasSuffix(": >-")
    }

    /// The name of a start tag that ends the text, not closed in it.
    static func openTagBefore(_ text: String) -> String? {
        guard text.hasSuffix(">"), !text.hasSuffix("/>"), !text.hasSuffix("?>"),
              !text.hasSuffix("-->"), !text.hasSuffix("]]>"),
              let open = text.range(of: "<", options: .backwards) else { return nil }
        let tag = text[open.upperBound...]
        guard let first = tag.first, first != "/", first != "!", first != "?" else { return nil }
        let name = tag.prefix { !$0.isWhitespace && $0 != ">" && $0 != "/" }
        guard !name.isEmpty else { return nil }
        // Already closed on the same line: <a>x</a>
        if text[open.upperBound...].contains("</") { return nil }
        return String(name)
    }

    // MARK: - Pairs

    /// What typing `typed` does beyond inserting it: a pair closed, a closing
    /// character typed over, a line taken a level out. Nil: just type it.
    static func typing(_ typed: String, at selection: NSRange, in text: NSString,
                       format: TextFormat?, indent: Indent, pairs: Bool) -> Edit? {
        guard let format = format?.markup, typed.count == 1, let c = typed.utf16.first else { return nil }
        let caret = selection.location
        let next: UInt16? = NSMaxRange(selection) < text.length ? text.character(at: NSMaxRange(selection)) : nil
        let previous: UInt16? = caret > 0 ? text.character(at: caret - 1) : nil

        // A closing character over the same one: step over it.
        if pairs, selection.length == 0, [0x7D, 0x5D, 0x22, 0x27].contains(c), next == c,
           c != 0x27 || format != .json {
            if c == 0x22 || c == 0x27 {
                // Only the closing quote of the string the caret is in.
                if previous == 0x5C { return nil }
            }
            return Edit(range: NSRange(location: caret, length: 0), replacement: "",
                        selection: NSRange(location: caret + 1, length: 0))
        }

        // A closer typed first on its line: a level out.
        if c == 0x7D || c == 0x5D, format != .xml, selection.length == 0 {
            let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
            let before = text.substring(with: NSRange(location: lineStart, length: caret - lineStart))
            if !before.isEmpty, before.allSatisfy({ $0 == " " || $0 == "\t" }) {
                let out = removingOneLevel(from: before, indent: indent)
                return Edit(range: NSRange(location: lineStart, length: caret - lineStart),
                            replacement: out + typed,
                            selection: NSRange(location: lineStart + (out as NSString).length + 1, length: 0))
            }
        }

        guard pairs else { return nil }
        let closing: String? = switch c {
        case 0x7B where format != .xml: "}"
        case 0x5B where format != .xml: "]"
        case 0x22: "\""
        case 0x27 where format == .yaml || format == .toml || format == .xml: "'"
        default: nil
        }
        guard let closing else { return nil }
        if selection.length > 0 {
            // Around what is selected.
            let inside = text.substring(with: selection)
            return Edit(range: selection, replacement: typed + inside + closing,
                        selection: NSRange(location: caret + 1, length: selection.length))
        }
        // Only where nothing follows that would be swallowed: a space, a
        // closer, a comma, the end of the line.
        if let next, ![0x20, 0x09, 0x0A, 0x0D, 0x7D, 0x5D, 0x2C, 0x3E, 0x2F].contains(next) { return nil }
        if c == 0x22 || c == 0x27 {
            // Not right after a word or a backslash: that is the end of something.
            if let previous, isWordUnit(previous) || previous == 0x5C || previous == c { return nil }
            if format == .xml, !insideXMLTag(caret, in: text) { return nil }
        }
        return Edit(range: selection, replacement: typed + closing,
                    selection: NSRange(location: caret + 1, length: 0))
    }

    /// Delete between an empty pair: both go.
    static func deletingPair(at selection: NSRange, in text: NSString, pairs: Bool) -> Edit? {
        let caret = selection.location
        guard pairs, selection.length == 0, caret > 0, caret < text.length else { return nil }
        let open = text.character(at: caret - 1), close = text.character(at: caret)
        let matches = (open == 0x7B && close == 0x7D) || (open == 0x5B && close == 0x5D)
            || (open == 0x22 && close == 0x22) || (open == 0x27 && close == 0x27)
        guard matches else { return nil }
        return Edit(range: NSRange(location: caret - 1, length: 2), replacement: "",
                    selection: NSRange(location: caret - 1, length: 0))
    }

    static func isWordUnit(_ c: UInt16) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
    }

    /// Between the < and > of a tag: where a quote opens an attribute value.
    static func insideXMLTag(_ caret: Int, in text: NSString) -> Bool {
        var at = caret - 1
        while at >= 0 {
            let c = text.character(at: at)
            if c == 0x3E { return false }
            if c == 0x3C { return true }
            at -= 1
        }
        return false
    }

    // MARK: - Comments

    /// Command-/: the lines made comments, or made code again when all of
    /// them are comments. `#` in YAML and TOML; `<!-- -->` around them in XML.
    /// JSON has no comments.
    static func toggleComment(_ selection: NSRange, in text: NSString, format: TextFormat?) -> Edit? {
        switch format?.markup {
        case .yaml, .toml: return toggleLineComments(selection, in: text)
        case .xml: return toggleBlockComment(selection, in: text)
        case .json, .plist, nil: return nil
        }
    }

    private static func toggleLineComments(_ selection: NSRange, in text: NSString) -> Edit? {
        let block = lines(of: selection, in: text)
        let original = text.substring(with: block)
        var rows = original.components(separatedBy: "\n")
        let trailing = original.hasSuffix("\n")
        if trailing { rows.removeLast() }
        let filled = rows.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !filled.isEmpty else { return nil }
        let commented = filled.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        // The marks line up at the least indented line.
        let column = filled.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        var firstDelta = 0
        var total = 0
        for (index, row) in rows.enumerated() where !row.trimmingCharacters(in: .whitespaces).isEmpty {
            let changed: String
            if commented {
                let hash = row.firstIndex(of: "#")!
                var rest = row[row.index(after: hash)...]
                if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                changed = String(row[..<hash]) + rest
            } else {
                let at = row.index(row.startIndex, offsetBy: column)
                changed = String(row[..<at]) + "# " + row[at...]
            }
            let delta = (changed as NSString).length - (row as NSString).length
            if index == 0 { firstDelta = delta }
            total += delta
            rows[index] = changed
        }
        let replacement = rows.joined(separator: "\n") + (trailing ? "\n" : "")
        return Edit(range: block, replacement: replacement,
                    selection: following(selection, block: block, firstShift: firstDelta, total: total))
    }

    private static func toggleBlockComment(_ selection: NSRange, in text: NSString) -> Edit? {
        let block = lines(of: selection, in: text)
        var content = block
        if endsWithBreak(content, in: text) { content.length -= 1 }
        let original = text.substring(with: content)
        let leading = original.prefix { $0 == " " || $0 == "\t" }
        let body = original.dropFirst(leading.count)
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("<!--"), trimmed.hasSuffix("-->") {
            var inner = String(trimmed.dropFirst(4).dropLast(3))
            if inner.hasPrefix(" ") { inner.removeFirst() }
            if inner.hasSuffix(" ") { inner.removeLast() }
            return Edit(range: content, replacement: String(leading) + inner,
                        selection: NSRange(location: content.location + (String(leading) as NSString).length,
                                           length: (inner as NSString).length))
        }
        guard !trimmed.isEmpty, !body.contains("--") else { return nil }
        let commented = "<!-- " + body + " -->"
        return Edit(range: content, replacement: String(leading) + commented,
                    selection: NSRange(location: content.location + (String(leading) as NSString).length,
                                       length: (commented as NSString).length))
    }
}
