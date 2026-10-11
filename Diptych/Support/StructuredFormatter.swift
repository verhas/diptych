import Foundation

/// Format ▸ Format Document: JSON and XML laid out again by Settings'
/// indentation and style. Nothing but the layout changes -- keys keep their
/// order, numbers and strings stay exactly as written, XML text that means
/// something is left alone. YAML is laid out by its indentation already, so
/// there is nothing to format; TOML neither.
nonisolated enum StructuredFormatter {

    enum Failure: Error, Equatable {
        /// The file breaks its format here: formatting would guess.
        case invalid(SyntaxProblem)
        case notFormattable
    }

    static func canFormat(_ format: TextFormat?) -> Bool { format == .json || format?.markup == .xml }

    static func format(_ text: String, as format: TextFormat?, style: TextStyle) -> Result<String, Failure> {
        guard let format, canFormat(format) else { return .failure(.notFormattable) }
        if let problem = StructuredText.analyse(text, as: format).problem { return .failure(.invalid(problem)) }
        let indent = style.indent(for: format)
        let formatted = switch format {
        case .json: JSONLayout(text, indent: indent, style: style).pretty()
        default: XMLLayout(text, indent: indent, style: style).pretty()
        }
        return .success(formatted + (text.hasSuffix("\n") || text.isEmpty ? "\n" : ""))
    }

    /// JSON on one line, without a space.
    static func compact(_ text: String) -> Result<String, Failure> {
        if let problem = StructuredText.analyse(text, as: .json).problem { return .failure(.invalid(problem)) }
        return .success(JSONLayout(text, indent: .two, style: TextStyle()).compact()
                        + (text.hasSuffix("\n") ? "\n" : ""))
    }
}

// MARK: - JSON

nonisolated struct JSONToken: Equatable {
    enum Kind: Equatable { case open, close, comma, colon, string, scalar, comment }
    let kind: Kind
    let text: String
    let range: NSRange
    /// Line breaks between the token before and this one.
    let breaksBefore: Int
}

nonisolated enum JSONTokenizer {
    /// The tokens of JSON as written: strings with their quotes and escapes,
    /// numbers and words as they are, `//` and `/* */` comments.
    static func tokens(_ text: NSString) -> [JSONToken] {
        var tokens: [JSONToken] = []
        let count = text.length
        var i = 0
        var breaks = 0
        func add(_ kind: JSONToken.Kind, _ start: Int) {
            let range = NSRange(location: start, length: i - start)
            tokens.append(JSONToken(kind: kind, text: text.substring(with: range), range: range,
                                    breaksBefore: breaks))
            breaks = 0
        }
        while i < count {
            let c = text.character(at: i)
            let start = i
            switch c {
            case 0x0A: breaks += 1; i += 1
            case 0x20, 0x09, 0x0D: i += 1
            case 0x7B, 0x5B: i += 1; add(.open, start)
            case 0x7D, 0x5D: i += 1; add(.close, start)
            case 0x2C: i += 1; add(.comma, start)
            case 0x3A: i += 1; add(.colon, start)
            case 0x22:
                i += 1
                while i < count {
                    let d = text.character(at: i)
                    if d == 0x5C { i += 2; continue }
                    i += 1
                    if d == 0x22 || d == 0x0A { break }
                }
                i = min(i, count)
                add(.string, start)
            case 0x2F where i + 1 < count && text.character(at: i + 1) == 0x2F:
                while i < count, text.character(at: i) != 0x0A { i += 1 }
                add(.comment, start)
            case 0x2F where i + 1 < count && text.character(at: i + 1) == 0x2A:
                i += 2
                while i + 1 < count, !(text.character(at: i) == 0x2A && text.character(at: i + 1) == 0x2F) { i += 1 }
                i = min(i + 2, count)
                add(.comment, start)
            default:
                while i < count {
                    let d = text.character(at: i)
                    if [0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x3A, 0x7B, 0x7D, 0x5B, 0x5D, 0x22].contains(d) { break }
                    i += 1
                }
                if i == start { i += 1 }
                add(.scalar, start)
            }
        }
        return tokens
    }
}

private nonisolated struct JSONLayout {
    let tokens: [JSONToken]
    let indent: LineEditing.Indent
    let style: TextStyle

    init(_ text: String, indent: LineEditing.Indent, style: TextStyle) {
        tokens = JSONTokenizer.tokens(text as NSString)
        self.indent = indent
        self.style = style
    }

    func pad(_ level: Int) -> String { String(repeating: indent.unit, count: max(0, level)) }

    func blank(before token: JSONToken) -> String {
        String(repeating: "\n", count: min(max(0, token.breaksBefore - 1), style.keepBlankLines))
    }

    /// The index of the token that closes the one opened at `open`.
    func closing(_ open: Int) -> Int? {
        var depth = 0
        for k in open..<tokens.count {
            switch tokens[k].kind {
            case .open: depth += 1
            case .close:
                depth -= 1
                if depth == 0 { return k }
            default: break
            }
        }
        return nil
    }

    /// An array of nothing but scalars and strings, for one line.
    func isShortArray(_ open: Int) -> Bool {
        guard style.jsonShortArraysOnOneLine, tokens[open].text == "[", let close = closing(open) else {
            return false
        }
        return tokens[(open + 1)..<close].allSatisfy { [.string, .scalar, .comma].contains($0.kind) }
            && close - open < 40
    }

    func pretty() -> String {
        var out = ""
        var level = 0
        var k = 0
        let colon = style.jsonSpaceBeforeColon ? " : " : ": "
        func newline(before next: Int) {
            out += "\n"
            if next < tokens.count { out += blank(before: tokens[next]) }
            out += pad(level)
        }
        while k < tokens.count {
            let token = tokens[k]
            switch token.kind {
            case .open:
                if k + 1 < tokens.count, tokens[k + 1].kind == .close {
                    out += token.text + tokens[k + 1].text
                    k += 2
                    continue
                }
                if isShortArray(k), let close = closing(k) {
                    out += "["
                    for inner in tokens[(k + 1)..<close] {
                        out += inner.kind == .comma ? ", " : inner.text
                    }
                    out += "]"
                    k = close + 1
                    continue
                }
                out += token.text
                level += 1
                newline(before: k + 1)
            case .close:
                level -= 1
                out += "\n" + pad(level) + token.text
            case .comma:
                out += ","
                newline(before: k + 1)
            case .colon:
                out += colon
            case .comment:
                // A comment after something on its line stays on that line.
                if token.breaksBefore == 0, !out.hasSuffix(pad(level)) || out.isEmpty {
                    out += " " + token.text
                } else {
                    out += token.text
                }
                if token.text.hasPrefix("//") || (k + 1 < tokens.count && tokens[k + 1].breaksBefore > 0) {
                    if k + 1 < tokens.count, tokens[k + 1].kind != .close { newline(before: k + 1) }
                }
            case .string, .scalar:
                out += token.text
            }
            k += 1
        }
        // Lines left with nothing but indentation, by a comment's break.
        return out.components(separatedBy: "\n")
            .map { $0.allSatisfy { $0 == " " || $0 == "\t" } ? "" : $0 }
            .joined(separator: "\n")
    }

    func compact() -> String {
        tokens.filter { $0.kind != .comment }.map(\.text).joined()
    }
}

// MARK: - XML

/// XML read as a tree of what it is made of, each part with its place in the
/// text: enough to lay it out again, and for the tree view.
nonisolated struct XMLNode: Equatable {
    enum Kind: Equatable { case element, text, comment, cdata, instruction, declaration }
    struct Attribute: Equatable {
        var name: String
        /// With its quotes.
        var rawValue: String
        var nameRange: NSRange
        /// Inside the quotes.
        var valueRange: NSRange
        /// From the name to the closing quote.
        var range: NSRange
    }
    var kind: Kind
    /// The element's name; the raw text of anything else.
    var name: String
    var attributes: [Attribute] = []
    var children: [XMLNode] = []
    var selfClosing = false
    /// All of it, from < to >.
    var range: NSRange
    /// The start tag.
    var startTag: NSRange
    /// The name in the start tag and in the end tag.
    var nameRange: NSRange
    var endNameRange: NSRange?
    /// Between the start and end tags.
    var inner: NSRange?
}

nonisolated enum XMLDocumentReader {

    /// The top-level parts of a well-formed document; nil when it is not.
    static func parse(_ text: NSString) -> [XMLNode]? {
        var reader = Reader(text: text)
        return reader.nodes(until: nil)
    }

    private struct Reader {
        let text: NSString
        var i = 0
        var count: Int { text.length }

        func at(_ offset: Int) -> UInt16? { offset < count ? text.character(at: offset) : nil }

        func starts(_ s: String, at offset: Int) -> Bool {
            let probe = s as NSString
            guard offset + probe.length <= count else { return false }
            return text.substring(with: NSRange(location: offset, length: probe.length)) == s
        }

        func find(_ s: String, from offset: Int) -> Int? {
            let found = text.range(of: s, range: NSRange(location: offset, length: count - offset))
            return found.location == NSNotFound ? nil : found.location
        }

        func isSpace(_ c: UInt16?) -> Bool { c.map { [0x20, 0x09, 0x0A, 0x0D].contains($0) } ?? false }

        func isNameUnit(_ c: UInt16) -> Bool {
            !isSpace(c) && ![0x3E, 0x2F, 0x3D, 0x3C, 0x22, 0x27].contains(c)
        }

        mutating func name() -> NSRange {
            let start = i
            while let c = at(i), isNameUnit(c) { i += 1 }
            return NSRange(location: start, length: i - start)
        }

        mutating func spaces() { while isSpace(at(i)) { i += 1 } }

        /// Up to the end tag of `element`, or the end of the text.
        mutating func nodes(until element: String?) -> [XMLNode]? {
            var nodes: [XMLNode] = []
            while i < count {
                let start = i
                if at(i) != 0x3C {
                    let end = find("<", from: i) ?? count
                    let range = NSRange(location: start, length: end - start)
                    nodes.append(XMLNode(kind: .text, name: text.substring(with: range), range: range,
                                         startTag: range, nameRange: range))
                    i = end
                    continue
                }
                if starts("</", at: i) {
                    guard element != nil else { return nil }
                    return nodes
                }
                let simple: [(String, String, XMLNode.Kind)] = [
                    ("<!--", "-->", .comment), ("<![CDATA[", "]]>", .cdata), ("<?", "?>", .instruction),
                ]
                if let (_, close, kind) = simple.first(where: { starts($0.0, at: i) }) {
                    guard let end = find(close, from: i + 2) else { return nil }
                    i = end + (close as NSString).length
                    let range = NSRange(location: start, length: i - start)
                    nodes.append(XMLNode(kind: kind, name: text.substring(with: range), range: range,
                                         startTag: range, nameRange: range))
                    continue
                }
                if starts("<!", at: i) {
                    var depth = 0
                    i += 2
                    while let c = at(i) {
                        if c == 0x22 || c == 0x27 {
                            i += 1
                            while let d = at(i), d != c { i += 1 }
                        } else if c == 0x5B { depth += 1 }
                        else if c == 0x5D { depth -= 1 }
                        else if c == 0x3E, depth <= 0 { break }
                        i += 1
                    }
                    i = min(i + 1, count)
                    let range = NSRange(location: start, length: i - start)
                    nodes.append(XMLNode(kind: .declaration, name: text.substring(with: range), range: range,
                                         startTag: range, nameRange: range))
                    continue
                }
                guard let node = self.element() else { return nil }
                nodes.append(node)
            }
            return element == nil ? nodes : nil
        }

        mutating func element() -> XMLNode? {
            let start = i
            i += 1
            let nameRange = name()
            guard nameRange.length > 0 else { return nil }
            let elementName = text.substring(with: nameRange)
            var attributes: [XMLNode.Attribute] = []
            while true {
                spaces()
                guard let c = at(i) else { return nil }
                if c == 0x3E || (c == 0x2F && at(i + 1) == 0x3E) { break }
                let attributeName = name()
                guard attributeName.length > 0 else { return nil }
                spaces()
                guard at(i) == 0x3D else { return nil }
                i += 1
                spaces()
                guard let quote = at(i), quote == 0x22 || quote == 0x27 else { return nil }
                let valueStart = i
                i += 1
                while let d = at(i), d != quote { i += 1 }
                guard at(i) == quote else { return nil }
                i += 1
                let raw = NSRange(location: valueStart, length: i - valueStart)
                attributes.append(XMLNode.Attribute(
                    name: text.substring(with: attributeName), rawValue: text.substring(with: raw),
                    nameRange: attributeName,
                    valueRange: NSRange(location: valueStart + 1, length: raw.length - 2),
                    range: NSRange(location: attributeName.location, length: i - attributeName.location)))
            }
            var node = XMLNode(kind: .element, name: elementName, attributes: attributes,
                               range: NSRange(location: start, length: 0),
                               startTag: NSRange(location: start, length: 0), nameRange: nameRange)
            if at(i) == 0x2F {
                i += 2
                node.selfClosing = true
                node.startTag.length = i - start
                node.range.length = i - start
                return node
            }
            i += 1
            node.startTag.length = i - start
            let innerStart = i
            guard let children = nodes(until: elementName) else { return nil }
            let innerEnd = i
            i += 2
            let endName = name()
            guard text.substring(with: endName) == elementName else { return nil }
            spaces()
            guard at(i) == 0x3E else { return nil }
            i += 1
            node.children = children
            node.endNameRange = endName
            node.inner = NSRange(location: innerStart, length: innerEnd - innerStart)
            node.range.length = i - start
            return node
        }
    }
}

private nonisolated struct XMLLayout {
    let text: NSString
    let indent: LineEditing.Indent
    let style: TextStyle

    init(_ text: String, indent: LineEditing.Indent, style: TextStyle) {
        self.text = text as NSString
        self.indent = indent
        self.style = style
    }

    func pad(_ level: Int) -> String { String(repeating: indent.unit, count: max(0, level)) }

    func isBlank(_ node: XMLNode) -> Bool {
        node.kind == .text && node.name.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
    }

    func pretty() -> String {
        guard let nodes = XMLDocumentReader.parse(text) else { return text as String }
        return lines(nodes, level: 0).trimmingCharacters(in: .newlines)
    }

    /// Children each on a line of their own, with the empty lines kept
    /// between them that Settings allows.
    func lines(_ nodes: [XMLNode], level: Int) -> String {
        var out = ""
        var pendingBreaks = 0
        for node in nodes {
            if isBlank(node) {
                pendingBreaks = node.name.filter { $0 == "\n" }.count
                continue
            }
            if !out.isEmpty {
                out += "\n" + String(repeating: "\n", count: min(max(0, pendingBreaks - 1), style.keepBlankLines))
            }
            out += pad(level) + layout(node, level: level)
            pendingBreaks = 0
        }
        return out
    }

    func layout(_ node: XMLNode, level: Int) -> String {
        guard node.kind == .element else {
            return node.kind == .text ? node.name.trimmingCharacters(in: .whitespacesAndNewlines) : node.name
        }
        let start = startTag(node, level: level)
        if node.selfClosing { return start }
        let end = "</\(node.name)>"
        guard let inner = node.inner else { return start + end }
        let content = node.children.filter { !isBlank($0) }
        if content.isEmpty { return start + end }
        let preserved = node.attributes.contains { $0.name == "xml:space" && $0.rawValue.contains("preserve") }
        let hasText = content.contains { $0.kind == .text || $0.kind == .cdata }
        if preserved || hasText {
            // Text means something where it is, spaces and breaks included --
            // CDATA is text too.
            return start + text.substring(with: inner) + end
        }
        return start + "\n" + lines(node.children, level: level + 1) + "\n" + pad(level) + end
    }

    func startTag(_ node: XMLNode, level: Int) -> String {
        let attributes = node.attributes.map { "\($0.name)=\($0.rawValue)" }
        var tag = "<" + node.name
        if style.xmlAttributesOnLines, attributes.count > 1 {
            tag += attributes.map { "\n" + pad(level + 1) + $0 }.joined()
        } else if !attributes.isEmpty {
            tag += " " + attributes.joined(separator: " ")
        }
        if node.selfClosing { return tag + (style.xmlSpaceBeforeSlash ? " />" : "/>") }
        return tag + ">"
    }
}
