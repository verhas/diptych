import AppKit

/// What Text Edit colours in a JSON, XML, YAML or TOML file, and which
/// brackets and tags belong together -- worked out with the rest of the
/// analysis, off the main thread, and drawn as temporary attributes, so the
/// text itself is not touched.
nonisolated struct SyntaxColouring: Sendable, Equatable {

    enum Role: Sendable, Equatable {
        case key, string, number, keyword, comment, tag, attribute, instruction, entity

        @MainActor var colour: NSColor {
            switch self {
            case .key: .systemPurple
            case .string: .systemRed
            case .number: .systemBlue
            case .keyword: .systemPink
            case .comment: .secondaryLabelColor
            case .tag: .systemBlue
            case .attribute: .systemOrange
            case .instruction: .systemBrown
            case .entity: .systemTeal
            }
        }
    }

    struct Span: Sendable, Equatable {
        let range: NSRange
        let role: Role
    }

    /// Two places that belong together: a bracket and its closing one, the
    /// name in a start tag and in its end tag.
    struct Pair: Sendable, Equatable {
        let open: NSRange
        let close: NSRange
    }

    var spans: [Span] = []
    var pairs: [Pair] = []

    static let none = SyntaxColouring()

    /// Beyond this, colouring costs more than it gives.
    static let limit = 2_000_000

    static func of(_ text: String, as format: TextFormat?) -> SyntaxColouring {
        let ns = text as NSString
        guard let format, ns.length <= limit else { return .none }
        switch format {
        case .json: return json(ns)
        case .xml, .plist: return xml(ns)
        case .yaml, .toml: return lines(ns, format: format)
        }
    }

    /// The pair the caret is next to, or in.
    func pair(at caret: Int) -> Pair? {
        pairs.first { pair in
            [pair.open, pair.close].contains { range in
                range.length == 1 ? (caret == range.location || caret == NSMaxRange(range))
                    : (caret >= range.location && caret <= NSMaxRange(range))
            }
        }
    }

    // MARK: - JSON

    static func json(_ text: NSString) -> SyntaxColouring {
        var colouring = SyntaxColouring()
        let tokens = JSONTokenizer.tokens(text)
        var open: [NSRange] = []
        for (k, token) in tokens.enumerated() {
            switch token.kind {
            case .string:
                let isKey = k + 1 < tokens.count && tokens[k + 1].kind == .colon
                colouring.spans.append(Span(range: token.range, role: isKey ? .key : .string))
            case .scalar:
                let role: Role = ["true", "false", "null"].contains(token.text) ? .keyword : .number
                colouring.spans.append(Span(range: token.range, role: role))
            case .comment:
                colouring.spans.append(Span(range: token.range, role: .comment))
            case .open:
                open.append(token.range)
            case .close:
                if let start = open.popLast() { colouring.pairs.append(Pair(open: start, close: token.range)) }
            default:
                break
            }
        }
        return colouring
    }

    // MARK: - XML

    static func xml(_ text: NSString) -> SyntaxColouring {
        var colouring = SyntaxColouring()
        let count = text.length
        var i = 0
        var open: [(name: String, range: NSRange)] = []
        func span(_ from: Int, _ to: Int, _ role: Role) {
            if to > from { colouring.spans.append(Span(range: NSRange(location: from, length: to - from), role: role)) }
        }
        func find(_ s: String, from: Int) -> Int {
            let found = text.range(of: s, range: NSRange(location: from, length: count - from))
            return found.location == NSNotFound ? count : NSMaxRange(found)
        }
        func isNameUnit(_ c: UInt16) -> Bool {
            ![0x20, 0x09, 0x0A, 0x0D, 0x3E, 0x2F, 0x3D, 0x3C, 0x22, 0x27].contains(c)
        }
        while i < count {
            let c = text.character(at: i)
            if c == 0x26 {
                let end = min(find(";", from: i), i + 12)
                span(i, end, .entity)
                i = max(end, i + 1)
                continue
            }
            guard c == 0x3C else { i += 1; continue }
            let start = i
            func starts(_ s: String) -> Bool {
                let probe = s as NSString
                return start + probe.length <= count
                    && text.substring(with: NSRange(location: start, length: probe.length)) == s
            }
            if starts("<!--") {
                i = find("-->", from: start + 4)
                span(start, i, .comment)
            } else if starts("<![CDATA[") {
                i = find("]]>", from: start + 9)
                span(start, i, .string)
            } else if starts("<?") || starts("<!") {
                i = find(">", from: start + 2)
                span(start, i, .instruction)
            } else {
                let closing = starts("</")
                i += closing ? 2 : 1
                let nameStart = i
                while i < count, isNameUnit(text.character(at: i)) { i += 1 }
                let name = NSRange(location: nameStart, length: i - nameStart)
                span(start, i, .tag)
                // Attributes up to the end of the tag.
                while i < count {
                    let d = text.character(at: i)
                    if d == 0x3E || d == 0x3C { break }
                    if d == 0x22 || d == 0x27 {
                        let valueStart = i
                        i += 1
                        while i < count, text.character(at: i) != d { i += 1 }
                        i = min(i + 1, count)
                        span(valueStart, i, .string)
                    } else if isNameUnit(d) {
                        let attributeStart = i
                        while i < count, isNameUnit(text.character(at: i)) { i += 1 }
                        span(attributeStart, i, .attribute)
                    } else {
                        i += 1
                    }
                }
                let selfClosing = i > 0 && i < count && text.character(at: i - 1) == 0x2F
                if i < count, text.character(at: i) == 0x3E {
                    span(selfClosing ? i - 1 : i, i + 1, .tag)
                    i += 1
                }
                guard name.length > 0 else { continue }
                let tag = text.substring(with: name)
                if closing {
                    if let at = open.lastIndex(where: { $0.name == tag }) {
                        colouring.pairs.append(Pair(open: open[at].range, close: name))
                        open.removeSubrange(at...)
                    }
                } else if !selfClosing {
                    open.append((tag, name))
                }
            }
        }
        return colouring
    }

    // MARK: - YAML and TOML

    static func lines(_ text: NSString, format: TextFormat) -> SyntaxColouring {
        var colouring = SyntaxColouring()
        var open: [NSRange] = []
        var at = 0
        var blockIndent: Int?
        while at < text.length {
            let line = text.lineRange(for: NSRange(location: at, length: 0))
            at = NSMaxRange(line)
            let row = text.substring(with: line)
            let indent = row.prefix { $0 == " " }.count
            let trimmed = row.trimmingCharacters(in: .whitespacesAndNewlines)
            if let block = blockIndent {
                if trimmed.isEmpty || indent > block {
                    colouring.spans.append(Span(range: line, role: .string))
                    continue
                }
                blockIndent = nil
            }
            colour(line: line, in: text, format: format, into: &colouring, open: &open)
            if format == .yaml,
               trimmed.range(of: #"(:|-)\s+[|>][-+0-9]*$"#, options: .regularExpression) != nil
                || trimmed == "|" || trimmed == ">" {
                blockIndent = indent
            }
        }
        return colouring
    }

    private static func colour(line: NSRange, in text: NSString, format: TextFormat,
                               into colouring: inout SyntaxColouring, open: inout [NSRange]) {
        var i = line.location
        let end = NSMaxRange(line)
        var keyDone = false
        var wordStart: Int?
        func span(_ from: Int, _ to: Int, _ role: Role) {
            if to > from { colouring.spans.append(Span(range: NSRange(location: from, length: to - from), role: role)) }
        }
        func closeWord(at stop: Int) {
            guard let start = wordStart else { return }
            wordStart = nil
            let word = text.substring(with: NSRange(location: start, length: stop - start))
                .trimmingCharacters(in: .whitespaces)
            let lead = start + (text.substring(with: NSRange(location: start, length: stop - start))
                .prefix { $0 == " " }.count)
            if ["true", "false", "null", "~", "yes", "no", "True", "False", "inf", "nan"].contains(word) {
                span(lead, lead + (word as NSString).length, .keyword)
            } else if Double(word.replacingOccurrences(of: "_", with: "")) != nil
                        || word.range(of: #"^0[xob][0-9a-fA-F_]+$"#, options: .regularExpression) != nil {
                span(lead, lead + (word as NSString).length, .number)
            } else if word.hasPrefix("&") || word.hasPrefix("*") || word.hasPrefix("!") {
                span(lead, lead + (word as NSString).length, .keyword)
            }
        }
        // A TOML [table] or [[array]] header.
        let trimmed = text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
        if format == .toml, trimmed.hasPrefix("[") {
            var headerEnd = end
            while headerEnd > line.location, [0x0A, 0x0D].contains(text.character(at: headerEnd - 1)) { headerEnd -= 1 }
            span(line.location, headerEnd, .tag)
            return
        }
        if format == .yaml, trimmed == "---" || trimmed == "..." {
            span(line.location, line.location + 3, .instruction)
            return
        }
        while i < end {
            let c = text.character(at: i)
            if c == 0x23, i == line.location || [0x20, 0x09].contains(text.character(at: i - 1)) {
                closeWord(at: i)
                var commentEnd = end
                while commentEnd > i, [0x0A, 0x0D].contains(text.character(at: commentEnd - 1)) { commentEnd -= 1 }
                span(i, commentEnd, .comment)
                return
            }
            if c == 0x22 || c == 0x27 {
                closeWord(at: i)
                let start = i
                i += 1
                while i < end {
                    let d = text.character(at: i)
                    if d == 0x5C, c == 0x22 { i += 2; continue }
                    if d == c { break }
                    i += 1
                }
                i = min(i + 1, end)
                var isKey = false
                var after = i
                while after < end, text.character(at: after) == 0x20 { after += 1 }
                if !keyDone, after < end, [0x3A, 0x3D].contains(text.character(at: after)) {
                    isKey = true
                    keyDone = true
                }
                span(start, i, isKey ? .key : .string)
                continue
            }
            if c == 0x5B || c == 0x7B {
                closeWord(at: i)
                open.append(NSRange(location: i, length: 1))
                i += 1
                continue
            }
            if c == 0x5D || c == 0x7D {
                closeWord(at: i)
                if let start = open.popLast() {
                    colouring.pairs.append(Pair(open: start, close: NSRange(location: i, length: 1)))
                }
                i += 1
                continue
            }
            let separator = format == .toml ? c == 0x3D
                : c == 0x3A && (i + 1 == end || [0x20, 0x0A, 0x0D].contains(text.character(at: i + 1)))
            if separator, !keyDone, open.isEmpty {
                // Everything so far on the line, but a dash, is the key.
                var keyStart = line.location
                while keyStart < i, [0x20, 0x2D].contains(text.character(at: keyStart)) { keyStart += 1 }
                var keyEnd = i
                while keyEnd > keyStart, text.character(at: keyEnd - 1) == 0x20 { keyEnd -= 1 }
                span(keyStart, keyEnd, .key)
                keyDone = true
                wordStart = nil
                i += 1
                continue
            }
            if c == 0x2C || c == 0x0A || c == 0x0D {
                closeWord(at: i)
            } else if wordStart == nil, c != 0x20, c != 0x2D || (i + 1 < end && text.character(at: i + 1) != 0x20) {
                wordStart = i
            }
            i += 1
        }
        closeWord(at: end)
    }
}
