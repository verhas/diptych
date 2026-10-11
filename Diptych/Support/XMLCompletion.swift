import Foundation

/// What Text Edit offers while XML is typed: the rest of the markup the caret
/// is in -- the `>` of a tag, the name of the element a `</` closes, the end
/// of a comment -- shown in grey after the caret and taken with Control-Space,
/// and the end tag of an element put in as soon as its start tag is closed.
///
/// A forgiving scanner of its own, unlike `XMLAnalysis`: the text being typed
/// is hardly ever well-formed, and an answer is needed anyway.
nonisolated enum XMLCompletion {

    /// Where the caret is.
    enum Place: Equatable {
        /// Between tags.
        case text
        /// In a start tag, after `<` and what of the name is typed; `quote`
        /// while in an attribute's value, `slash` right after a `/`, and
        /// `attribute` after an attribute's name or its `=`.
        case tag(name: String, quote: UInt16?, slash: Bool, attribute: Attribute? = nil)
        /// In an end tag, after `</` and what of the name is typed; `named`
        /// once a space has ended the name.
        case endTag(typed: String, named: Bool)
        /// In a comment, CDATA, processing instruction or declaration: what
        /// is left of what ends it.
        case closing(rest: String)
        /// After `<!-` or `<![CD`: not yet known what it opens.
        case undecided
    }

    /// What an attribute still needs: `=""` after its name, `""` after its `=`.
    enum Attribute: Equatable {
        case named, equals
    }

    struct State: Equatable {
        var place: Place
        /// The elements open at the caret, outermost first.
        var open: [String]
    }

    /// The grey text after the caret, nil when there is none.
    static func suggestion(in text: NSString, at caret: Int) -> String? {
        let state = state(of: text, at: caret)
        switch state.place {
        case .text, .undecided:
            return nil
        case .tag(_, let quote?, _, _):
            return String(decoding: [quote], as: UTF16.self) + ">"
        case .tag(_, nil, _, .named?):
            return "=\"\""
        case .tag(_, nil, _, .equals?):
            return "\"\""
        case .tag:
            return ">"
        case .endTag(let typed, let named):
            if named { return ">" }
            guard let element = state.open.last else { return typed.isEmpty ? nil : ">" }
            if element.hasPrefix(typed) { return String(element.dropFirst(typed.count)) + ">" }
            return typed.isEmpty ? nil : ">"
        case .closing(let rest):
            return rest
        }
    }

    /// Where the caret goes in a suggestion once it is taken: between the
    /// quotes of an attribute's value, at the end of anything else.
    static func caret(in suggestion: String) -> Int {
        let length = suggestion.utf16.count
        return suggestion.hasSuffix("\"\"") ? length - 1 : length
    }

    /// A `>` just typed before the caret closed the start tag of an element
    /// that nothing after closes: its end tag, to go after the caret.
    static func endTag(in text: NSString, at caret: Int) -> String? {
        guard caret > 0, caret <= text.length, text.character(at: caret - 1) == 0x3E,
              case .tag(let name, nil, false, _) = state(of: text, at: caret - 1).place,
              !name.isEmpty
        else { return nil }
        var scanner = Scanner(text, upTo: text.length)
        scanner.watched = caret - 1
        scanner.run()
        return scanner.watchedClosed ? nil : "</\(name)>"
    }

    static func state(of text: NSString, at caret: Int) -> State {
        var scanner = Scanner(text, upTo: caret)
        return scanner.run()
    }

    // MARK: - The scanner

    private struct Scanner {
        let units: [UInt16]
        var i = 0
        var open: [(name: String, closeAt: Int)] = []
        /// The `>` of a start tag to follow: whether an end tag of its own
        /// closes that element, rather than one further out.
        var watched: Int?
        var watchedClosed = false

        init(_ text: NSString, upTo end: Int) {
            let count = max(0, min(end, text.length))
            var units = [UInt16](repeating: 0, count: count)
            text.getCharacters(&units, range: NSRange(location: 0, length: count))
            self.units = units
        }

        var count: Int { units.count }
        var current: UInt16? { i < count ? units[i] : nil }

        func isNameStart(_ c: UInt16) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x3A || c >= 0x80
        }

        func isName(_ c: UInt16) -> Bool {
            isNameStart(c) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2E
        }

        func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }

        func starts(_ text: String, at offset: Int) -> Bool {
            let probe = Array(text.utf16)
            guard offset + probe.count <= count else { return false }
            return Array(units[offset..<(offset + probe.count)]) == probe
        }

        /// True when the text ends, from `offset` on, with the start of `text`.
        func endsWithStart(of text: String, at offset: Int) -> Bool {
            let probe = Array(text.utf16)
            let left = count - offset
            return left < probe.count && Array(units[offset...]) == Array(probe[..<left])
        }

        func find(_ text: String, from offset: Int) -> Int? {
            var at = offset
            while at < count {
                if starts(text, at: at) { return at }
                at += 1
            }
            return nil
        }

        /// What is left of `terminator`, the text running out before it,
        /// where what is inside began at `inside`.
        func rest(of terminator: String, inside: Int) -> String {
            let probe = Array(terminator.utf16)
            for typed in stride(from: probe.count - 1, through: 1, by: -1)
            where count - typed >= inside && Array(units[(count - typed)...]) == Array(probe[..<typed]) {
                return String(decoding: probe[typed...], as: UTF16.self)
            }
            return terminator
        }

        mutating func name() -> String {
            let start = i
            if let c = current, isNameStart(c) {
                while let c = current, isName(c) { i += 1 }
            }
            return String(decoding: units[start..<i], as: UTF16.self)
        }

        @discardableResult
        mutating func run() -> State {
            while i < count {
                guard units[i] == 0x3C else {
                    i += 1
                    continue
                }
                if let place = markup() { return State(place: place, open: open.map(\.name)) }
            }
            return State(place: .text, open: open.map(\.name))
        }

        /// What follows a <: nil when it ends before the text does, otherwise
        /// where the text runs out.
        mutating func markup() -> Place? {
            let start = i
            for (opening, terminator) in [("<!--", "-->"), ("<![CDATA[", "]]>"), ("<?", "?>")]
            where starts(opening, at: start) {
                let inside = start + opening.utf16.count
                guard let close = find(terminator, from: inside) else {
                    return .closing(rest: rest(of: terminator, inside: inside))
                }
                i = close + terminator.utf16.count
                return nil
            }
            if endsWithStart(of: "<!--", at: start) || endsWithStart(of: "<![CDATA[", at: start),
               count - start > 2 {
                return .undecided
            }
            if starts("<!", at: start) { return declaration() }
            if starts("</", at: start) { return endTag() }
            return startTag()
        }

        /// <!DOCTYPE …>, with an internal subset in [ ] and quoted parts.
        mutating func declaration() -> Place? {
            i += 2
            var depth = 0
            while let c = current {
                if c == 0x22 || c == 0x27 {
                    i += 1
                    while let d = current, d != c { i += 1 }
                    if current == nil { return nil }
                } else if c == 0x5B {
                    depth += 1
                } else if c == 0x5D {
                    depth -= 1
                } else if c == 0x3E, depth <= 0 {
                    i += 1
                    return nil
                }
                i += 1
            }
            return depth <= 0 ? .closing(rest: ">") : nil
        }

        mutating func startTag() -> Place? {
            i += 1
            let element = name()
            if element.isEmpty, current != nil {
                // A < that starts nothing: text.
                return nil
            }
            var attribute: Attribute?
            while let c = current {
                if c == 0x22 || c == 0x27 {
                    i += 1
                    while let d = current, d != c { i += 1 }
                    if current == nil { return .tag(name: element, quote: c, slash: false) }
                    attribute = nil
                } else if isNameStart(c) {
                    _ = name()
                    attribute = .named
                    continue
                } else if c == 0x3D {
                    attribute = attribute == nil ? nil : .equals
                } else if c == 0x3E {
                    let selfClosing = i > 0 && units[i - 1] == 0x2F
                    if !selfClosing, !element.isEmpty { open.append((element, i)) }
                    i += 1
                    return nil
                } else if c == 0x3C {
                    // Never closed: what follows is markup of its own.
                    return nil
                } else if !isSpace(c) {
                    attribute = nil
                }
                i += 1
            }
            return .tag(name: element, quote: nil, slash: units[count - 1] == 0x2F, attribute: attribute)
        }

        mutating func endTag() -> Place? {
            i += 2
            let element = name()
            let named = current.map(isSpace) ?? false
            while let c = current, isSpace(c) { i += 1 }
            guard let c = current else { return .endTag(typed: element, named: named) }
            guard c == 0x3E else { return nil }
            i += 1
            if let at = open.lastIndex(where: { $0.name == element }) {
                if let watched, open[at].closeAt == watched, at == open.count - 1 {
                    watchedClosed = true
                }
                open.removeSubrange(at...)
            }
            return nil
        }
    }
}
