import Foundation

/// A structured text format Text Edit knows: which parts of a file fold, and
/// where it stops being what its extension says it is.
nonisolated enum TextFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case json, xml, toml, yaml

    var id: String { rawValue }

    var title: String {
        switch self {
        case .json: "JSON"
        case .xml:  "XML"
        case .toml: "TOML"
        case .yaml: "YAML"
        }
    }

    static let defaultExtensions: [TextFormat: [String]] = [
        .json: ["json"], .xml: ["xml"], .toml: ["toml"], .yaml: ["yml", "yaml"],
    ]

    /// The format a file's extension says, by the settings' list.
    static func of(_ url: URL, extensions: [TextFormat: [String]]) -> TextFormat? {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return allCases.first { format in
            (extensions[format] ?? []).contains { $0.lowercased() == ext }
        }
    }
}

/// A part of the text that folds: what is hidden, and what stands for it.
nonisolated struct FoldSpan: Sendable, Equatable {
    /// Zero-based, inclusive.
    let firstLine: Int
    let lastLine: Int
    /// The characters hidden when folded; the text before and after stays.
    let hidden: NSRange
    /// Shown in the badge in place of the hidden text: "4 keys", "12 lines".
    let label: String
}

/// Where the text stops being valid, and why.
nonisolated struct SyntaxProblem: Sendable, Equatable {
    let message: String
    /// UTF-16 offset in the text.
    let location: Int
    /// One-based, as editors count.
    let line: Int
    let column: Int
}

nonisolated struct StructureAnalysis: Sendable, Equatable {
    var folds: [FoldSpan] = []
    var problem: SyntaxProblem?

    static let none = StructureAnalysis()
}

nonisolated enum StructuredText {

    static func analyse(_ text: String, as format: TextFormat) -> StructureAnalysis {
        // Nothing written yet is not an error worth shouting about.
        guard !text.allSatisfy(\.isWhitespace) else { return .none }
        let units = Array(text.utf16)
        let lines = LineIndex(text)
        switch format {
        case .json:
            var analysis = JSONAnalysis(units: units, lines: lines)
            return analysis.run()
        case .xml:
            var analysis = XMLAnalysis(units: units, lines: lines)
            return analysis.run()
        case .toml:
            var analysis = TOMLAnalysis(units: units, lines: lines)
            return analysis.run()
        case .yaml: return YAMLAnalysis(text: text, lines: lines).run()
        }
    }

    static func problem(_ message: String, at offset: Int, in lines: LineIndex) -> SyntaxProblem {
        let offset = min(max(offset, 0), lines.length)
        let line = lines.line(containing: offset)
        return SyntaxProblem(message: message, location: offset, line: line + 1,
                             column: offset - lines.starts[line] + 1)
    }

    /// The span between an opening and a closing character, when they are on
    /// different lines: `{` and `}` stay, what is between them folds.
    static func between(_ open: Int, _ close: Int, lines: LineIndex, label: String) -> FoldSpan? {
        let first = lines.line(containing: open)
        let last = lines.line(containing: close)
        guard last > first, close > open + 1 else { return nil }
        return FoldSpan(firstLine: first, lastLine: last,
                        hidden: NSRange(location: open + 1, length: close - open - 1), label: label)
    }

    /// From the end of `first` to the end of `last`: a header line stays, the
    /// lines under it fold.
    static func under(_ first: Int, through last: Int, lines: LineIndex) -> FoldSpan? {
        guard last > first else { return nil }
        let start = NSMaxRange(lines.contentRange(ofLine: first))
        let end = NSMaxRange(lines.contentRange(ofLine: last))
        guard end > start else { return nil }
        let count = last - first
        return FoldSpan(firstLine: first, lastLine: last,
                        hidden: NSRange(location: start, length: end - start),
                        label: "\(count) line\(count == 1 ? "" : "s")")
    }

    static func plural(_ count: Int, _ word: String) -> String {
        "\(count) \(word)\(count == 1 ? "" : "s")"
    }
}

/// What stops the analysis: the first problem found.
private nonisolated struct Stop: Error {
    let problem: SyntaxProblem
}

// MARK: - JSON

/// RFC 8259, by recursive descent over UTF-16, so every problem has its
/// exact place.
private nonisolated struct JSONAnalysis {
    let units: [UInt16]
    let lines: LineIndex
    var i = 0
    var folds: [FoldSpan] = []

    init(units: [UInt16], lines: LineIndex) {
        self.units = units
        self.lines = lines
    }

    mutating func run() -> StructureAnalysis {
        do {
            try space()
            try value(depth: 0)
            try space()
            if i < units.count {
                throw stop("Only one value can be at the top of a JSON file; this is one more")
            }
            return StructureAnalysis(folds: folds, problem: nil)
        } catch let stop as Stop {
            return StructureAnalysis(folds: folds, problem: stop.problem)
        } catch {
            return StructureAnalysis(folds: folds, problem: nil)
        }
    }

    func stop(_ message: String, at offset: Int? = nil) -> Stop {
        Stop(problem: StructuredText.problem(message, at: offset ?? i, in: lines))
    }

    var current: UInt16? { i < units.count ? units[i] : nil }

    mutating func space() throws {
        while let c = current {
            switch c {
            case 0x20, 0x09, 0x0A, 0x0D:
                i += 1
            case 0x2F where i + 1 < units.count && (units[i + 1] == 0x2F || units[i + 1] == 0x2A):
                throw stop("JSON has no comments")
            default:
                return
            }
        }
    }

    mutating func value(depth: Int) throws {
        guard depth < 512 else { throw stop("Nested too deep") }
        guard let c = current else { throw stop("A value is missing at the end") }
        switch c {
        case 0x7B: try object(depth: depth)
        case 0x5B: try array(depth: depth)
        case 0x22: try string()
        case 0x2D, 0x30...0x39: try number()
        default:
            let start = i
            while let c = current, isWordUnit(c) { i += 1 }
            let word = String(decoding: units[start..<i], as: UTF16.self)
            if ["true", "false", "null"].contains(word) { return }
            if word.isEmpty {
                throw stop("\u{201C}\(Character(UnicodeScalar(c) ?? " "))\u{201D} cannot start a "
                           + "value: a string in double quotes, a number, true, false, null, an "
                           + "object or an array", at: start)
            }
            throw stop("\u{201C}\(word)\u{201D} is not a JSON value: strings are in double "
                       + "quotes, and true, false and null are written in lower case", at: start)
        }
    }

    func isWordUnit(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F
    }

    mutating func object(depth: Int) throws {
        let open = i
        i += 1
        var count = 0
        try space()
        if current == 0x7D {
            i += 1
            return
        }
        while true {
            guard current == 0x22 else {
                if current == 0x7D, count > 0 {
                    throw stop("A comma before } is not allowed in JSON")
                }
                if current == 0x27 { throw stop("Keys are in double quotes in JSON, not single") }
                throw stop(current == nil ? "The object opened here is not closed"
                                          : "A key in double quotes is expected here",
                           at: current == nil ? open : i)
            }
            try string()
            try space()
            guard current == 0x3A else { throw stop("A colon is expected after the key") }
            i += 1
            try space()
            try value(depth: depth + 1)
            count += 1
            try space()
            if current == 0x2C {
                i += 1
                try space()
                continue
            }
            if current == 0x7D {
                if let span = StructuredText.between(open, i, lines: lines,
                                                     label: StructuredText.plural(count, "key")) {
                    folds.append(span)
                }
                i += 1
                return
            }
            throw current == nil ? stop("The object opened here is not closed", at: open)
                                 : stop("A comma or } is expected after the value")
        }
    }

    mutating func array(depth: Int) throws {
        let open = i
        i += 1
        var count = 0
        try space()
        if current == 0x5D {
            i += 1
            return
        }
        while true {
            if current == 0x5D, count > 0 { throw stop("A comma before ] is not allowed in JSON") }
            guard current != nil else { throw stop("The array opened here is not closed", at: open) }
            try value(depth: depth + 1)
            count += 1
            try space()
            if current == 0x2C {
                i += 1
                try space()
                continue
            }
            if current == 0x5D {
                if let span = StructuredText.between(open, i, lines: lines,
                                                     label: StructuredText.plural(count, "item")) {
                    folds.append(span)
                }
                i += 1
                return
            }
            throw current == nil ? stop("The array opened here is not closed", at: open)
                                 : stop("A comma or ] is expected after the value")
        }
    }

    mutating func string() throws {
        let open = i
        i += 1
        while let c = current {
            switch c {
            case 0x22:
                i += 1
                return
            case 0x5C:
                i += 1
                guard let e = current else { break }
                switch e {
                case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    i += 1
                case 0x75:
                    i += 1
                    for _ in 0..<4 {
                        guard let h = current, isHex(h) else {
                            throw stop("\\u takes four hexadecimal digits")
                        }
                        i += 1
                    }
                default:
                    throw stop("\u{201C}\\\(Character(UnicodeScalar(e) ?? " "))\u{201D} is not "
                               + "an escape in JSON: \\\" \\\\ \\/ \\b \\f \\n \\r \\t \\u",
                               at: i - 1)
                }
            case 0x0A, 0x0D:
                throw stop("The string opened here is not closed on its line", at: open)
            case 0x00...0x1F:
                throw stop("A control character must be escaped inside a string")
            default:
                i += 1
            }
        }
        throw stop("The string opened here is not closed", at: open)
    }

    func isHex(_ c: UInt16) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }

    func isDigit(_ c: UInt16?) -> Bool { c.map { $0 >= 0x30 && $0 <= 0x39 } ?? false }

    mutating func number() throws {
        let start = i
        if current == 0x2D { i += 1 }
        guard isDigit(current) else { throw stop("A digit is expected after the minus sign") }
        if current == 0x30 {
            i += 1
            if isDigit(current) { throw stop("A number cannot start with 0 in JSON", at: start) }
        } else {
            while isDigit(current) { i += 1 }
        }
        if current == 0x2E {
            i += 1
            guard isDigit(current) else { throw stop("A digit is expected after the decimal point") }
            while isDigit(current) { i += 1 }
        }
        if current == 0x65 || current == 0x45 {
            i += 1
            if current == 0x2B || current == 0x2D { i += 1 }
            guard isDigit(current) else { throw stop("A digit is expected in the exponent") }
            while isDigit(current) { i += 1 }
        }
        if let c = current, isWordUnit(c) {
            throw stop("Not a number: letters follow the digits", at: start)
        }
    }
}

// MARK: - XML

/// XML 1.0 well-formedness, by a scanner of its own: libxml's positions and
/// messages through XMLParser are too vague to point at a place. Tags in
/// pairs, attributes once each and in quotes, entities, comments, CDATA,
/// processing instructions, one root. Elements, comments and CDATA that span
/// lines fold between their delimiters.
private nonisolated struct XMLAnalysis {
    let units: [UInt16]
    let lines: LineIndex
    var i = 0
    var folds: [FoldSpan] = []
    var open: [(name: String, at: Int, close: Int, children: Int)] = []
    var rootClosed = false
    var sawRoot = false

    init(units: [UInt16], lines: LineIndex) {
        self.units = units
        self.lines = lines
    }

    var current: UInt16? { i < units.count ? units[i] : nil }

    func stop(_ message: String, at offset: Int? = nil) -> Stop {
        Stop(problem: StructuredText.problem(message, at: offset ?? i, in: lines))
    }

    func starts(_ text: String, at offset: Int) -> Bool {
        let probe = Array(text.utf16)
        guard offset + probe.count <= units.count else { return false }
        return Array(units[offset..<(offset + probe.count)]) == probe
    }

    /// The offset where `text` next starts, from `offset` on.
    func find(_ text: String, from offset: Int) -> Int? {
        var at = offset
        while at < units.count {
            if starts(text, at: at) { return at }
            at += 1
        }
        return nil
    }

    func isNameStart(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x3A || c >= 0x80
    }

    func isName(_ c: UInt16) -> Bool {
        isNameStart(c) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2E
    }

    func isSpace(_ c: UInt16?) -> Bool { c.map { [0x20, 0x09, 0x0A, 0x0D].contains($0) } ?? false }

    mutating func spaces() { while isSpace(current) { i += 1 } }

    mutating func name() -> String? {
        guard let c = current, isNameStart(c) else { return nil }
        let start = i
        while let c = current, isName(c) { i += 1 }
        return String(decoding: units[start..<i], as: UTF16.self)
    }

    mutating func run() -> StructureAnalysis {
        do {
            while i < units.count {
                switch units[i] {
                case 0x3C: try markup()
                case 0x26: try entity()
                default:
                    if open.isEmpty, !isSpace(units[i]) {
                        throw stop(sawRoot ? "Only one root element: nothing but comments can "
                                   + "follow it" : "Text before the root element")
                    }
                    i += 1
                }
            }
            if let element = open.last {
                throw stop("The file ends while <\(element.name)> is still open",
                           at: element.at)
            }
            if !sawRoot { throw stop("There is no element", at: 0) }
            return StructureAnalysis(folds: folds, problem: nil)
        } catch let stop as Stop {
            return StructureAnalysis(folds: folds, problem: stop.problem)
        } catch {
            return StructureAnalysis(folds: folds, problem: nil)
        }
    }

    mutating func entity() throws {
        let start = i
        i += 1
        if current == 0x23 {
            i += 1
            let hex = current == 0x78
            if hex { i += 1 }
            let digits = i
            while let c = current, (c >= 0x30 && c <= 0x39)
                    || (hex && ((c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66))) { i += 1 }
            guard i > digits, current == 0x3B else {
                throw stop("A character reference is &#123; or &#x7B;", at: start)
            }
        } else {
            guard name() != nil, current == 0x3B else {
                throw stop("A lone & is written &amp;", at: start)
            }
        }
        i += 1
    }

    /// What follows a <.
    mutating func markup() throws {
        let start = i
        if starts("<!--", at: i) {
            guard let close = find("-->", from: i + 4) else {
                throw stop("The comment opened here is not closed with -->")
            }
            if let span = StructuredText.between(start + 3, close, lines: lines, label: "comment") {
                folds.append(span)
            }
            i = close + 3
        } else if starts("<![CDATA[", at: i) {
            guard let close = find("]]>", from: i + 9) else {
                throw stop("The CDATA section opened here is not closed with ]]>")
            }
            if let span = StructuredText.between(start + 8, close, lines: lines, label: "CDATA") {
                folds.append(span)
            }
            i = close + 3
        } else if starts("<?", at: i) {
            guard let close = find("?>", from: i + 2) else {
                throw stop("The processing instruction opened here is not closed with ?>")
            }
            i = close + 2
        } else if starts("<!", at: i) {
            try declaration()
        } else if starts("</", at: i) {
            try endTag()
        } else {
            try startTag()
        }
    }

    /// <!DOCTYPE …>, with an internal subset in [ ] and quoted parts.
    mutating func declaration() throws {
        let start = i
        i += 2
        var depth = 0
        while let c = current {
            if c == 0x22 || c == 0x27 {
                i += 1
                while let d = current, d != c { i += 1 }
            } else if c == 0x5B {
                depth += 1
            } else if c == 0x5D {
                depth -= 1
            } else if c == 0x3E, depth <= 0 {
                i += 1
                return
            }
            i += 1
        }
        throw stop("The declaration opened here is not closed with >", at: start)
    }

    mutating func startTag() throws {
        let start = i
        i += 1
        guard let element = name() else {
            throw stop("A < in text is written &lt;", at: start)
        }
        if open.isEmpty {
            if rootClosed || sawRoot {
                throw stop("Only one root element: <\(element)> is a second one", at: start)
            }
            sawRoot = true
        }
        var attributes: Set<String> = []
        while true {
            let hadSpace = isSpace(current)
            spaces()
            guard let c = current else {
                throw stop("The tag <\(element)> opened here is not closed with >", at: start)
            }
            if c == 0x3E || (c == 0x2F && i + 1 < units.count && units[i + 1] == 0x3E) {
                let selfClosing = c == 0x2F
                i += selfClosing ? 2 : 1
                if !open.isEmpty { open[open.count - 1].children += 1 }
                if selfClosing {
                    if open.isEmpty { rootClosed = true }
                } else {
                    open.append((element, start, i - 1, 0))
                }
                return
            }
            let attributeStart = i
            guard hadSpace, let attribute = name() else {
                throw stop(hadSpace ? "An attribute name, > or /> is expected here"
                                    : "A space is needed before the next attribute")
            }
            guard !attributes.contains(attribute) else {
                throw stop("The attribute \u{201C}\(attribute)\u{201D} is given twice",
                           at: attributeStart)
            }
            attributes.insert(attribute)
            spaces()
            guard current == 0x3D else {
                throw stop("= and a value in quotes are expected after \u{201C}\(attribute)\u{201D}")
            }
            i += 1
            spaces()
            guard let quote = current, quote == 0x22 || quote == 0x27 else {
                throw stop("An attribute value is in quotes")
            }
            let valueStart = i
            i += 1
            while let d = current, d != quote {
                if d == 0x3C { throw stop("A < in an attribute value is written &lt;") }
                if d == 0x26 { try entity(); continue }
                i += 1
            }
            guard current == quote else {
                throw stop("The value opened here is not closed", at: valueStart)
            }
            i += 1
        }
    }

    mutating func endTag() throws {
        let start = i
        i += 2
        guard let element = name() else { throw stop("A name is expected after </") }
        spaces()
        guard current == 0x3E else { throw stop("> is expected to close </\(element)") }
        i += 1
        guard let last = open.popLast() else {
            throw stop("</\(element)> closes nothing: no element is open", at: start)
        }
        guard last.name == element else {
            throw stop("</\(element)> does not close <\(last.name)>, which is open since line "
                       + "\(lines.line(containing: last.at) + 1)", at: start)
        }
        if open.isEmpty { rootClosed = true }
        let label = last.children > 0 ? StructuredText.plural(last.children, "element")
                                      : "\u{2026}"
        if let span = StructuredText.between(last.close, start, lines: lines, label: label) {
            folds.append(span)
        }
    }
}

// MARK: - TOML

/// TOML 1.0, line by line with a value parser: tables, keys, strings of
/// every kind, numbers, dates, arrays and inline tables. Tables fold to the
/// next header; arrays and strings that span lines fold too.
private nonisolated struct TOMLAnalysis {
    let units: [UInt16]
    let lines: LineIndex
    var i = 0
    var folds: [FoldSpan] = []
    /// Tables defined with [name], and keys set in each table, as paths.
    var tables: Set<String> = []
    var keys: Set<String> = []
    var table = ""
    var headerLine: Int?

    init(units: [UInt16], lines: LineIndex) {
        self.units = units
        self.lines = lines
    }

    var current: UInt16? { i < units.count ? units[i] : nil }

    func stop(_ message: String, at offset: Int? = nil) -> Stop {
        Stop(problem: StructuredText.problem(message, at: offset ?? i, in: lines))
    }

    mutating func run() -> StructureAnalysis {
        do {
            while i < units.count {
                try line()
            }
            closeSection(before: lines.count)
            return StructureAnalysis(folds: folds, problem: nil)
        } catch let stop as Stop {
            return StructureAnalysis(folds: folds, problem: stop.problem)
        } catch {
            return StructureAnalysis(folds: folds, problem: nil)
        }
    }

    mutating func blanks() {
        while current == 0x20 || current == 0x09 { i += 1 }
    }

    /// A comment, then the end of the line -- or what does not belong there.
    mutating func endOfLine(_ what: String) throws {
        blanks()
        if current == 0x23 {
            while let c = current, c != 0x0A { i += 1 }
        }
        if current == 0x0D, i + 1 < units.count, units[i + 1] == 0x0A { i += 1 }
        guard current == nil || current == 0x0A else {
            throw stop("Only a comment can follow \(what) on its line")
        }
        if current == 0x0A { i += 1 }
    }

    mutating func line() throws {
        blanks()
        guard let c = current else { return }
        switch c {
        case 0x0A, 0x0D, 0x23:
            try endOfLine("this")
        case 0x5B:
            try header()
        default:
            try keyValue()
        }
    }

    /// The last table's lines fold under its header.
    mutating func closeSection(before line: Int) {
        guard let first = headerLine else { return }
        var last = line - 1
        while last > first,
              String(decoding: units[lines.contentRange(ofLine: last).location
                                    ..< NSMaxRange(lines.contentRange(ofLine: last))],
                     as: UTF16.self).trimmingCharacters(in: .whitespaces).isEmpty {
            last -= 1
        }
        if let span = StructuredText.under(first, through: last, lines: lines) {
            folds.append(span)
        }
    }

    mutating func header() throws {
        let start = i
        let line = lines.line(containing: start)
        i += 1
        let isArray = current == 0x5B
        if isArray { i += 1 }
        blanks()
        let path = try key()
        blanks()
        guard current == 0x5D else {
            throw stop(isArray ? "]] is expected after the table name" : "] is expected after "
                       + "the table name")
        }
        i += 1
        if isArray {
            guard current == 0x5D else { throw stop("]] is expected after the table name") }
            i += 1
        }
        let name = path.joined(separator: ".")
        if !isArray {
            guard !tables.contains(name) else {
                throw stop("The table [\(name)] is defined twice", at: start)
            }
            tables.insert(name)
        }
        // Each [[array]] entry is a table of its own: its keys start afresh.
        if isArray { keys = keys.filter { !$0.hasPrefix(name + ".") } }
        table = name
        try endOfLine("a table header")
        closeSection(before: line)
        headerLine = line
    }

    mutating func keyValue() throws {
        let start = i
        let path = try key()
        blanks()
        guard current == 0x3D else {
            throw stop(current == nil || current == 0x0A
                       ? "= and a value are expected after the key"
                       : "= is expected after the key")
        }
        i += 1
        blanks()
        let full = (table.isEmpty ? "" : table + ".") + path.joined(separator: ".")
        guard !keys.contains(full) else {
            throw stop("\u{201C}\(path.joined(separator: "."))\u{201D} is set twice in this table",
                       at: start)
        }
        keys.insert(full)
        try value(depth: 0)
        try endOfLine("a value")
    }

    func isBare(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39)
            || c == 0x5F || c == 0x2D
    }

    /// A key, dotted or not: bare, "basic" or 'literal' parts.
    mutating func key() throws -> [String] {
        var parts: [String] = []
        while true {
            blanks()
            guard let c = current else { throw stop("A key is expected") }
            if c == 0x22 || c == 0x27 {
                let start = i
                try singleLineString(c)
                parts.append(String(decoding: units[(start + 1)..<(i - 1)], as: UTF16.self))
            } else if isBare(c) {
                let start = i
                while let c = current, isBare(c) { i += 1 }
                parts.append(String(decoding: units[start..<i], as: UTF16.self))
            } else {
                throw stop("\u{201C}\(Character(UnicodeScalar(c) ?? " "))\u{201D} cannot be in "
                           + "a key: letters, digits, _ and - -- or the key in quotes")
            }
            blanks()
            guard current == 0x2E else { return parts }
            i += 1
        }
    }

    /// Spaces, line breaks and comments, inside an array.
    mutating func gaps() {
        while let c = current {
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                i += 1
            } else if c == 0x23 {
                while let c = current, c != 0x0A { i += 1 }
            } else {
                return
            }
        }
    }

    mutating func value(depth: Int) throws {
        guard depth < 256 else { throw stop("Nested too deep") }
        guard let c = current, c != 0x0A, c != 0x0D, c != 0x23 else {
            throw stop("A value is expected after =")
        }
        switch c {
        case 0x22, 0x27:
            if i + 2 < units.count, units[i + 1] == c, units[i + 2] == c {
                try multiLineString(c)
            } else {
                try singleLineString(c)
            }
        case 0x5B:
            try array(depth: depth)
        case 0x7B:
            try inlineTable(depth: depth)
        default:
            try scalar()
        }
    }

    mutating func singleLineString(_ quote: UInt16) throws {
        let open = i
        i += 1
        while let c = current {
            if c == quote {
                i += 1
                return
            }
            if c == 0x0A || c == 0x0D {
                throw stop("The string opened here is not closed on its line", at: open)
            }
            if c == 0x5C, quote == 0x22 { try escape() } else { i += 1 }
        }
        throw stop("The string opened here is not closed", at: open)
    }

    mutating func escape() throws {
        i += 1
        guard let e = current else { return }
        switch e {
        case 0x62, 0x74, 0x6E, 0x66, 0x72, 0x65, 0x22, 0x5C:
            i += 1
        case 0x75, 0x55:
            let count = e == 0x75 ? 4 : 8
            i += 1
            for _ in 0..<count {
                guard let h = current, (h >= 0x30 && h <= 0x39) || (h >= 0x41 && h <= 0x46)
                        || (h >= 0x61 && h <= 0x66) else {
                    throw stop("\\\(e == 0x75 ? "u" : "U") takes \(count) hexadecimal digits")
                }
                i += 1
            }
        default:
            throw stop("\u{201C}\\\(Character(UnicodeScalar(e) ?? " "))\u{201D} is not an escape "
                       + "in TOML: \\b \\t \\n \\f \\r \\e \\\" \\\\ \\u \\U -- or use single "
                       + "quotes, which take no escapes", at: i - 1)
        }
    }

    mutating func multiLineString(_ quote: UInt16) throws {
        let open = i
        i += 3
        while let c = current {
            if c == quote, i + 2 < units.count, units[i + 1] == quote, units[i + 2] == quote {
                // Up to two more quotes may belong to the content.
                var end = i + 3
                while end < units.count, units[end] == quote, end - i < 5 { end += 1 }
                if let span = StructuredText.between(open + 2, end - 3, lines: lines,
                                                     label: "\u{2026}") {
                    folds.append(span)
                }
                i = end
                return
            }
            if c == 0x5C, quote == 0x22 {
                // A backslash at the end of a line joins it to the next.
                if i + 1 < units.count, [0x0A, 0x0D, 0x20, 0x09].contains(units[i + 1]) {
                    i += 1
                } else {
                    try escape()
                }
            } else {
                i += 1
            }
        }
        throw stop("The string opened here is not closed", at: open)
    }

    mutating func array(depth: Int) throws {
        let open = i
        i += 1
        var count = 0
        while true {
            gaps()
            guard let c = current else { throw stop("The array opened here is not closed", at: open) }
            if c == 0x5D {
                if let span = StructuredText.between(open, i, lines: lines,
                                                     label: StructuredText.plural(count, "item")) {
                    folds.append(span)
                }
                i += 1
                return
            }
            try value(depth: depth + 1)
            count += 1
            gaps()
            if current == 0x2C {
                i += 1
                continue
            }
            guard current == 0x5D else {
                throw current == nil ? stop("The array opened here is not closed", at: open)
                                     : stop("A comma or ] is expected after the value")
            }
        }
    }

    mutating func inlineTable(depth: Int) throws {
        let open = i
        i += 1
        blanks()
        if current == 0x7D {
            i += 1
            return
        }
        var seen: Set<String> = []
        while true {
            blanks()
            let start = i
            let path = try key().joined(separator: ".")
            guard !seen.contains(path) else {
                throw stop("\u{201C}\(path)\u{201D} is set twice in this inline table", at: start)
            }
            seen.insert(path)
            blanks()
            guard current == 0x3D else { throw stop("= is expected after the key") }
            i += 1
            blanks()
            try value(depth: depth + 1)
            blanks()
            if current == 0x2C {
                i += 1
                blanks()
                if current == 0x7D {
                    throw stop("A comma before } is not allowed in an inline table")
                }
                continue
            }
            if current == 0x7D {
                i += 1
                return
            }
            if current == nil || current == 0x0A || current == 0x0D {
                throw stop("An inline table must be closed on the line it starts", at: open)
            }
            throw stop("A comma or } is expected after the value")
        }
    }

    static let patterns: [NSRegularExpression] = [
        #"^[+-]?(0|[1-9](_?[0-9])*)$"#,
        #"^0x[0-9A-Fa-f](_?[0-9A-Fa-f])*$"#,
        #"^0o[0-7](_?[0-7])*$"#,
        #"^0b[01](_?[01])*$"#,
        #"^[+-]?(0|[1-9](_?[0-9])*)((\.[0-9](_?[0-9])*)([eE][+-]?[0-9](_?[0-9])*)?|[eE][+-]?[0-9](_?[0-9])*)$"#,
        #"^[+-]?(inf|nan)$"#,
        #"^(true|false)$"#,
        #"^\d{4}-\d{2}-\d{2}([Tt ]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})?)?$"#,
        #"^\d{2}:\d{2}:\d{2}(\.\d+)?$"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// A number, a boolean or a date: up to a space, a comma, a bracket, a
    /// comment or the end of the line -- a date's space before its time kept.
    mutating func scalar() throws {
        let start = i
        func ends(_ c: UInt16) -> Bool {
            [0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D, 0x23].contains(c)
        }
        while let c = current, !ends(c) { i += 1 }
        var word = String(decoding: units[start..<i], as: UTF16.self)
        // 1979-05-27 07:32:00: the date and its time, apart.
        if word.count == 10, current == 0x20, i + 1 < units.count,
           units[i + 1] >= 0x30, units[i + 1] <= 0x39 {
            let save = i
            i += 1
            while let c = current, !ends(c) { i += 1 }
            let joined = String(decoding: units[start..<i], as: UTF16.self)
            if Self.matches(joined) { word = joined } else { i = save }
        }
        guard Self.matches(word) else {
            if word.isEmpty {
                throw stop("A value is expected here")
            }
            throw stop("\u{201C}\(word)\u{201D} is not a TOML value: text is in quotes; numbers, "
                       + "true, false and dates are written bare", at: start)
        }
    }

    static func matches(_ word: String) -> Bool {
        let range = NSRange(word.startIndex..., in: word)
        return patterns.contains { $0.firstMatch(in: word, range: range) != nil }
    }
}

// MARK: - YAML

/// YAML by its lines: the mistakes people make -- tabs for indentation, a
/// line indented to no level above it, a key under a value, a line in a
/// mapping that is no key, a key set twice, a quote or a bracket not closed.
/// Not a full YAML parser; anchors, tags and documents pass as they are.
/// What is indented under a line folds under it.
private nonisolated struct YAMLAnalysis {
    let text: String
    let lines: LineIndex
    let rows: [String]

    init(text: String, lines: LineIndex) {
        self.text = text
        self.lines = lines
        rows = (0..<lines.count).map { (text as NSString).substring(with: lines.contentRange(ofLine: $0)) }
    }

    /// One open level of the block structure.
    struct Level {
        let indent: Int
        /// Keys set at this level, for "set twice".
        var keys: Set<String> = []
        var isMapping = false
    }

    func stop(_ message: String, line: Int, column: Int = 0) -> Stop {
        Stop(problem: StructuredText.problem(message, at: lines.starts[line] + column, in: lines))
    }

    func indent(of row: String) -> Int {
        row.prefix { $0 == " " }.count
    }

    /// The line without a comment -- a # after a space, outside quotes.
    func content(_ row: String) -> String {
        var quote: Character?
        var previous: Character = " "
        var result = ""
        for c in row {
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                if previous == " " || previous == ":" || previous == "-" || previous == "["
                    || previous == "{" || previous == "," || result.isEmpty {
                    quote = c
                }
            } else if c == "#", previous == " " || previous == "\t" || result.isEmpty {
                break
            }
            result.append(c)
            previous = c
        }
        return result.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
    }

    /// `key:` or `key: value`, the key as written; nil for anything else.
    func key(of body: String) -> String? {
        var text = Substring(body)
        if text.hasPrefix("? ") { return nil }
        // Quoted keys.
        if let first = text.first, first == "\"" || first == "'" {
            guard let close = text.dropFirst().firstIndex(of: first) else { return nil }
            let after = text[text.index(after: close)...]
            guard after.hasPrefix(":"), after.count == 1 || after.dropFirst().first == " " else {
                return nil
            }
            return String(text[...close])
        }
        guard let colon = text.range(of: ": ")?.lowerBound
                ?? (text.hasSuffix(":") ? text.index(before: text.endIndex) : nil) else { return nil }
        text = text[..<colon]
        guard !text.isEmpty, !text.contains("{"), !text.contains("["), !text.hasPrefix("- ")
        else { return nil }
        return String(text)
    }

    func run() -> StructureAnalysis {
        let folds = foldsByIndentation()
        do {
            try check()
            return StructureAnalysis(folds: folds, problem: nil)
        } catch let stop as Stop {
            return StructureAnalysis(folds: folds, problem: stop.problem)
        } catch {
            return StructureAnalysis(folds: folds, problem: nil)
        }
    }

    func isBlank(_ line: Int) -> Bool {
        let body = rows[line].trimmingCharacters(in: .whitespaces)
        return body.isEmpty || body.hasPrefix("#")
    }

    /// What is indented under a line folds under it.
    func foldsByIndentation() -> [FoldSpan] {
        var folds: [FoldSpan] = []
        for line in rows.indices where !isBlank(line) {
            let own = indent(of: rows[line])
            var last = line
            var next = line + 1
            while next < rows.count {
                if isBlank(next) { next += 1; continue }
                guard indent(of: rows[next]) > own else { break }
                last = next
                next += 1
            }
            if let span = StructuredText.under(line, through: last, lines: lines) {
                folds.append(span)
            }
        }
        return folds
    }

    func check() throws {
        var levels: [Level] = []
        /// A block scalar (| or >) under this indentation: its lines are text.
        var blockScalar: Int?
        /// Open flow brackets and quotes carry over lines.
        var flowDepth = 0
        var flowOpen: (line: Int, column: Int)?
        var previousIndent = 0
        var previousBody = ""
        var previousLine = -1
        /// A quoted value that goes on to later lines, as YAML allows.
        var openQuote: (quote: Character, line: Int, column: Int)?

        for (line, row) in rows.enumerated() {
            if let open = openQuote {
                if Self.closes(row, open.quote) { openQuote = nil }
                continue
            }
            if row.hasPrefix("---") || row.hasPrefix("...") {
                levels = []
                blockScalar = nil
                previousLine = -1
                continue
            }
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            if let base = blockScalar {
                if trimmed.isEmpty || indent(of: row) > base { continue }
                blockScalar = nil
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Indentation is spaces.
            if let tab = row.prefix(while: { $0 == " " || $0 == "\t" }).firstIndex(of: "\t") {
                throw stop("YAML is indented with spaces, not tabs", line: line,
                           column: row.distance(from: row.startIndex, to: tab))
            }
            let indentation = indent(of: row)
            let body = content(String(row.dropFirst(indentation)))

            // Inside a flow collection [ … ] { … }: only the brackets count.
            if flowDepth > 0 {
                try countFlow(body, line: line, column: indentation, depth: &flowDepth,
                              open: &flowOpen)
                continue
            }

            if previousLine >= 0, indentation > previousIndent {
                // Deeper than the line before: that line opens something, or
                // this continues its plain text -- which cannot be a key.
                let opens = previousBody.hasSuffix(":") || previousBody.hasSuffix("-")
                    || previousBody.hasPrefix("- ") || previousBody == "-"
                    || previousBody.hasSuffix("|") || previousBody.hasSuffix(">")
                    || previousBody.range(of: #"[|>][+-]?\d*$"#, options: .regularExpression) != nil
                if !opens, key(of: body) != nil {
                    throw stop("A key cannot be indented under a line that already has its "
                               + "value", line: line, column: indentation)
                }
                if !opens {
                    // A plain scalar going on: nothing new opens.
                    previousLine = line
                    continue
                }
            }

            // Back out to this line's level; it must be one that is open --
            // or a new one, deeper than the line before.
            let deeper = levels.last.map { indentation > $0.indent } ?? true
            while let top = levels.last, top.indent > indentation { levels.removeLast() }
            if let top = levels.last, top.indent < indentation {
                guard deeper else {
                    throw stop("This line is indented to no level above it", line: line,
                               column: indentation)
                }
                levels.append(Level(indent: indentation))
            } else if levels.isEmpty {
                levels.append(Level(indent: indentation))
            }

            // In a mapping, every line at its level is a key or a list item.
            var item = body
            var itemColumn = indentation
            while item.hasPrefix("- ") || item == "-" {
                item = String(item.dropFirst(2))
                itemColumn += 2
            }
            if let key = key(of: item) {
                if item == body {
                    let level = levels.count - 1
                    let name = key.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if levels[level].keys.contains(name) {
                        throw stop("\u{201C}\(name)\u{201D} is set twice in this mapping",
                                   line: line, column: indentation)
                    }
                    levels[level].keys.insert(name)
                    levels[level].isMapping = true
                }
            } else if item == body, levels.last?.isMapping == true, !body.hasPrefix("- "),
                      body != "-", !body.hasPrefix("?"), !body.hasPrefix(":") {
                throw stop("A key and a colon are expected here: key: value", line: line,
                           column: indentation)
            }
            // `- key: value` starts a mapping of its own, at the key.
            if item != body, let key = key(of: item) {
                let name = key.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                levels.append(Level(indent: itemColumn, keys: [name], isMapping: true))
            }

            // A block scalar's text follows, indented.
            if body.range(of: #"(^|\s|:)[|>][+-]?\d*$"#, options: .regularExpression) != nil {
                blockScalar = indentation
            }
            try countFlow(item, line: line, column: itemColumn, depth: &flowDepth, open: &flowOpen)
            if let open = openQuoteStart(item) {
                openQuote = (open.quote, line, itemColumn + open.column)
            }

            previousIndent = indentation
            previousBody = body
            previousLine = line
        }
        if let open = openQuote {
            throw stop("The quote opened here is never closed", line: open.line,
                       column: open.column)
        }
        if flowDepth > 0, let open = flowOpen {
            throw stop("The bracket opened here is not closed", line: open.line, column: open.column)
        }
    }

    /// [ and { opened and closed, outside quotes.
    func countFlow(_ body: String, line: Int, column: Int, depth: inout Int,
                   open: inout (line: Int, column: Int)?) throws {
        var quote: Character?
        for (offset, c) in body.enumerated() {
            if let q = quote {
                if c == q { quote = nil }
                continue
            }
            switch c {
            case "\"", "'":
                if depth > 0 { quote = c }
            case "[", "{":
                if depth == 0 { open = (line, column + offset) }
                depth += 1
            case "]", "}":
                guard depth > 0 else {
                    // A plain scalar may hold them: only flagged as a value
                    // that starts with one.
                    continue
                }
                depth -= 1
            default:
                break
            }
        }
    }

    /// A value that starts with a quote and does not close it on its line:
    /// the quote and where it is.
    func openQuoteStart(_ body: String) -> (quote: Character, column: Int)? {
        let value: Substring
        if let key = key(of: body) {
            value = body.dropFirst(key.count + 1).drop { $0 == " " }
        } else {
            value = Substring(body)
        }
        guard let first = value.first, first == "\"" || first == "'" else { return nil }
        guard !Self.closes(String(value.dropFirst()), first) else { return nil }
        return (first, body.distance(from: body.startIndex, to: value.startIndex))
    }

    /// The quote closes in `text`: a \" escapes in double quotes, '' stands
    /// for one ' in single ones.
    static func closes(_ text: String, _ quote: Character) -> Bool {
        var characters = Array(text)
        var index = 0
        while index < characters.count {
            let c = characters[index]
            if quote == "\"", c == "\\" { index += 2; continue }
            if c == quote {
                if quote == "'", index + 1 < characters.count, characters[index + 1] == "'" {
                    index += 2
                    continue
                }
                return true
            }
            index += 1
        }
        characters.removeAll()
        return false
    }
}
