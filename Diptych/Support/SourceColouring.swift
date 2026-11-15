import Foundation

/// What colour a TextMate scope gets: the roles Text Edit already draws
/// JSON, XML, YAML and TOML in, so one theme covers every language.
nonisolated enum SourceTheme {

    typealias Role = SyntaxColouring.Role

    /// Checked from the innermost scope outwards; the first scope with an
    /// entry decides. `nil` is an entry too: plain, and no further look.
    private static let table: [(String, Role?)] = [
        ("comment", .comment), ("punctuation.definition.comment", .comment),
        // Code inside a string -- an interpolation -- is code, not string.
        ("meta.embedded", nil), ("source", nil),
        ("string.regexp", .string), ("constant.character.escape", .entity),
        ("constant.other.placeholder", .entity),
        ("string", .string), ("punctuation.definition.string", .string),
        ("constant.numeric", .number), ("constant.other.color", .number),
        ("constant.language", .keyword), ("constant.character", .entity),
        ("variable.language", .keyword),
        ("meta.preprocessor", .instruction), ("keyword.control.directive", .instruction),
        ("punctuation.definition.directive", .instruction), ("keyword.other.special-method", .instruction),
        ("keyword.operator", nil),
        ("keyword", .keyword), ("storage", .keyword),
        ("support.type.property-name", .key), ("meta.object-literal.key", .key), ("entity.name.tag.yaml", .key),
        ("entity.name.tag", .tag), ("entity.other.attribute-name", .attribute),
        ("entity.name.function", .function), ("support.function", .function),
        ("entity.name.type", .type), ("entity.name.class", .type), ("entity.name.struct", .type),
        ("entity.name.enum", .type), ("entity.name.interface", .type), ("entity.name.namespace", .type),
        ("entity.other.inherited-class", .type), ("support.type", .type), ("support.class", .type),
        ("entity.name.section", .keyword), ("markup.heading", .keyword),
        ("markup.inline.raw", .string), ("markup.fenced_code", .string), ("markup.raw", .string),
        ("markup.underline.link", .attribute), ("markup.quote", .comment),
        ("markup.inserted", .type), ("markup.deleted", .string), ("markup.changed", .attribute),
        ("meta.diff.header", .instruction), ("meta.diff.range", .instruction),
    ]

    private static let cache = Cache()

    static func role(for scopes: [String]) -> Role? {
        let key = scopes.suffix(4).joined(separator: " ")
        if let known = cache.get(key) { return known.role }
        var found: Role?
        search: for scope in scopes.reversed() {
            for (prefix, role) in table where scope == prefix || scope.hasPrefix(prefix + ".") {
                found = role
                break search
            }
        }
        cache.set(key, found)
        return found
    }

    private final class Cache: @unchecked Sendable {
        struct Entry { let role: Role? }
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        func get(_ key: String) -> Entry? { lock.lock(); defer { lock.unlock() }; return entries[key] }
        func set(_ key: String, _ role: Role?) {
            lock.lock(); defer { lock.unlock() }
            if entries.count > 20_000 { entries.removeAll() }
            entries[key] = Entry(role: role)
        }
    }
}

/// Colours a document with a TextMate grammar, and colours it again after an
/// edit from the first line that changed only until the tokenizer's state is
/// what it was before: the lines after that colour as they did.
nonisolated final class SourceColourer: @unchecked Sendable {

    typealias Span = SyntaxColouring.Span

    let language: TextMateRegistry.Language
    private let grammar: TextMateGrammar
    private let tokenizer: TextMateTokenizer
    private let lock = NSLock()

    /// Per line, as last coloured: its text, the state it starts in, and its
    /// spans relative to its start.
    private var lines: [String] = []
    private var states: [TextMateState] = []
    private var spans: [[Span]] = []
    /// Lines past this were not reached within the time allowed.
    private var coloured = 0

    init?(language: TextMateRegistry.Language, registry: TextMateRegistry = .shared) {
        guard let grammar = registry.grammar(scope: language.scope) else { return nil }
        self.language = language
        self.grammar = grammar
        tokenizer = TextMateTokenizer(grammar: grammar)
    }

    /// The colours of `text`, worked out again only where it changed. Stops
    /// after `budget` seconds, leaving the rest plain; `complete` says so.
    func colour(_ text: String, budget: TimeInterval = 3) -> (spans: [Span], complete: Bool) {
        lock.lock(); defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(budget)
        let ns = text as NSString
        var newLines: [String] = []
        var offsets: [Int] = []
        var at = 0
        while at < ns.length {
            let range = ns.lineRange(for: NSRange(location: at, length: 0))
            newLines.append(ns.substring(with: range))
            offsets.append(range.location)
            at = NSMaxRange(range)
        }

        // The lines unchanged at the top keep their colours and states.
        var first = 0
        while first < min(lines.count, newLines.count, coloured), lines[first] == newLines[first] { first += 1 }
        // And those unchanged at the bottom, which may be reused once the
        // state reaching them is the same as before.
        // Only start states are kept: a document that grew at the end
        // starts again from its last old line.
        if first > 0, first >= states.count { first = states.count - 1 }
        var tail = 0
        while tail < min(lines.count, newLines.count) - first,
              lines[lines.count - 1 - tail] == newLines[newLines.count - 1 - tail] { tail += 1 }
        let shift = newLines.count - lines.count

        var newStates = Array(states.prefix(first))
        var newSpans = Array(spans.prefix(first))
        var state = first < states.count ? states[first] : TextMateState.start(grammar)
        if first == 0 { state = .start(grammar) }
        var complete = true
        var index = first
        while index < newLines.count {
            // Back on lines that were there before, in the state they began in then.
            let old = index - shift
            if index >= newLines.count - tail, old >= 0, old < states.count, old < coloured, states[old] == state {
                newStates += states[old..<min(coloured, states.count)]
                newSpans += spans[old..<min(coloured, spans.count)]
                index += min(coloured, states.count) - old
                break
            }
            if Date() > deadline { complete = false; break }
            newStates.append(state)
            var lineSpans: [Span] = []
            let content = Self.content(of: newLines[index])
            state = tokenizer.tokenize(line: (content + "\n") as NSString, state: state) { range, scopes in
                let clipped = NSIntersectionRange(range, NSRange(location: 0, length: (content as NSString).length))
                guard clipped.length > 0, let role = SourceTheme.role(for: scopes) else { return }
                if let last = lineSpans.last, last.role == role, NSMaxRange(last.range) == clipped.location {
                    lineSpans[lineSpans.count - 1] = Span(range: NSRange(location: last.range.location,
                                                                         length: last.range.length + clipped.length), role: role)
                } else {
                    lineSpans.append(Span(range: clipped, role: role))
                }
            }
            newSpans.append(lineSpans)
            index += 1
        }
        lines = newLines
        states = newStates
        spans = newSpans
        coloured = min(newSpans.count, newLines.count)

        var all: [Span] = []
        for (line, lineSpans) in newSpans.prefix(newLines.count).enumerated() {
            let base = offsets[line]
            for span in lineSpans {
                all.append(Span(range: NSRange(location: base + span.range.location, length: span.range.length), role: span.role))
            }
        }
        return (all, complete && coloured == newLines.count)
    }

    private static func content(of line: String) -> String {
        var text = line
        while let last = text.unicodeScalars.last, last == "\n" || last == "\r" || last == "\u{2028}" || last == "\u{2029}" {
            text.unicodeScalars.removeLast()
        }
        return text
    }
}
