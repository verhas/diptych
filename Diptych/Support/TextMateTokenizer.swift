import Foundation

/// Where a TextMate tokenizer stands at the end of a line: the regions still
/// open. Two equal states mean the rest of a document tokenizes the same from
/// there -- which is what lets an edit recolour only until they agree again.
nonisolated struct TextMateState: Equatable, @unchecked Sendable {

    struct Frame: Equatable {
        let rule: TextMateRule
        /// The scopes of what is inside the region, its name and content name included.
        let scopes: [String]
        /// The scopes its begin and end are in: its name, not its content name.
        let outer: [String]
        let end: TextMateRegex?
        let whileRegex: TextMateRegex?
        /// Where `\G` holds in the current line; -1 when it does not.
        var anchor: Int

        static func == (a: Frame, b: Frame) -> Bool {
            a.rule === b.rule && a.scopes == b.scopes && a.end?.source == b.end?.source
                && a.whileRegex?.source == b.whileRegex?.source
        }
    }

    var frames: [Frame]

    static func start(_ grammar: TextMateGrammar) -> TextMateState {
        TextMateState(frames: [Frame(rule: grammar.root, scopes: [grammar.scopeName], outer: [grammar.scopeName],
                                     end: nil, whileRegex: nil, anchor: -1)])
    }
}

/// Splits lines into scoped tokens with a grammar's rules.
nonisolated struct TextMateTokenizer {


    let grammar: TextMateGrammar
    /// Lines longer than this are left plain: a minified file is one
    /// enormous line, and some patterns go quadratic.
    var longestLine = 10_000

    init(grammar: TextMateGrammar) {
        self.grammar = grammar
    }

    /// Tokenizes one line -- `line` holds it with its line break -- calling
    /// `emit` for each token in order. Returns the state at its end.
    func tokenize(line: NSString, state: TextMateState, depth: Int = 0,
                  emit: (NSRange, [String]) -> Void) -> TextMateState {
        // Too long to tokenize: left plain, and the state it began in passed
        // on, as VS Code does. Stopping part-way left the rest of the file in
        // whatever the cut was in the middle of -- a string, for one.
        guard line.length <= longestLine else {
            emit(NSRange(location: 0, length: line.length), state.frames[state.frames.count - 1].scopes)
            return state
        }
        var run = Run(line: line, base: grammar, depth: depth)
        var stack = state.frames
        for index in stack.indices { stack[index].anchor = -1 }
        let limit = line.length
        var pos = 0

        // A begin/while region goes on for as long as its while pattern
        // matches each new line.
        var index = 1
        while index < stack.count {
            guard let whileRegex = stack[index].whileRegex else { index += 1; continue }
            stack[index].anchor = pos
            guard let match = run.find(whileRegex, from: pos, limit: limit, anchor: pos) else {
                stack.removeSubrange(index...)
                break
            }
            run.emitMatch(match, captures: stack[index].rule.whileCaptures, scopes: stack[index].outer,
                          rule: stack[index].rule, from: &pos, emit: emit)
            if match.range.upperBound > pos { pos = match.range.upperBound }
            stack[index].anchor = pos
            index += 1
        }

        // Rules that match nothing can push and pop at one place for ever:
        // that many turns without moving on, and the line is left as it is.
        var stuck = 0
        var lastPos = -1
        while pos < limit {
            if pos == lastPos { stuck += 1 } else { stuck = 0; lastPos = pos }
            guard stuck < 32 else { break }

            let frame = stack[stack.count - 1]
            let candidates = frame.rule.candidates(base: grammar)
            var best: NSTextCheckingResult?
            var bestRule: TextMateRule?
            var bestIsEnd = false
            if let end = frame.end, !frame.rule.applyEndPatternLast,
               let match = run.find(end, from: pos, limit: limit, anchor: frame.anchor) {
                best = match
                bestIsEnd = true
            }
            for rule in candidates {
                if let best, best.range.location == pos { break }
                guard let regex = rule.match ?? rule.begin,
                      let match = run.find(regex, from: pos, limit: limit, anchor: frame.anchor) else { continue }
                if best == nil || match.range.location < best!.range.location {
                    best = match
                    bestRule = rule
                    bestIsEnd = false
                }
            }
            if let end = frame.end, frame.rule.applyEndPatternLast,
               let match = run.find(end, from: pos, limit: limit, anchor: frame.anchor),
               best == nil || match.range.location < best!.range.location {
                best = match
                bestRule = nil
                bestIsEnd = true
            }

            guard let match = best else { break }
            if match.range.location > pos {
                emit(NSRange(location: pos, length: match.range.location - pos), frame.scopes)
                pos = match.range.location
            }

            if bestIsEnd {
                guard stack.count > 1 else { break }
                run.emitMatch(match, captures: frame.rule.endCaptures, scopes: frame.outer, rule: frame.rule,
                              from: &pos, emit: emit)
                stack.removeLast()
                pos = max(pos, match.range.upperBound)
                continue
            }
            guard let rule = bestRule else { break }
            if rule.begin != nil {
                let outer = frame.scopes + Self.scopes(rule.name, match, line)
                run.emitMatch(match, captures: rule.beginCaptures, scopes: outer, rule: rule, from: &pos, emit: emit)
                pos = max(pos, match.range.upperBound)
                let captured = (0..<match.numberOfRanges).map { group -> String? in
                    let range = match.range(at: group)
                    return range.location == NSNotFound ? nil : line.substring(with: range)
                }
                let end = rule.end ?? rule.endSource.map {
                    TextMateRegex(TextMateRegex.resolvingBackReferences($0, captures: captured))
                }
                let whileRegex = rule.whileRegex ?? rule.whileSource.map {
                    TextMateRegex(TextMateRegex.resolvingBackReferences($0, captures: captured))
                }
                stack.append(TextMateState.Frame(rule: rule, scopes: outer + Self.scopes(rule.contentName, match, line),
                                                 outer: outer, end: end, whileRegex: whileRegex, anchor: pos))
            } else {
                let scopes = frame.scopes + Self.scopes(rule.name, match, line)
                run.emitMatch(match, captures: rule.captures, scopes: scopes, rule: rule, from: &pos, emit: emit)
                if match.range.length == 0 {
                    // Matched nothing, so it would match here again: on, past one character.
                    emit(NSRange(location: pos, length: 1), frame.scopes)
                    pos += 1
                } else {
                    pos = max(pos, match.range.upperBound)
                }
            }
        }
        if pos < line.length {
            emit(NSRange(location: pos, length: line.length - pos), stack[stack.count - 1].scopes)
        }
        return TextMateState(frames: stack)
    }

    /// A rule's name as scopes: several, space-separated, and `$1`…
    /// replaced by what was captured.
    static func scopes(_ name: String?, _ match: NSTextCheckingResult, _ line: NSString) -> [String] {
        guard var name, !name.isEmpty else { return [] }
        if name.contains("$") {
            for group in stride(from: min(match.numberOfRanges - 1, 9), through: 0, by: -1) {
                let range = match.range(at: group)
                let text = range.location == NSNotFound ? "" : line.substring(with: range).lowercased()
                name = name.replacingOccurrences(of: "${\(group):/downcase}", with: text)
                    .replacingOccurrences(of: "$\(group)", with: text)
            }
        }
        return name.split(separator: " ").map(String.init)
    }

    /// One line's searches, remembered: a pattern searched from an earlier
    /// position whose match is still ahead need not be searched again.
    private struct Run {
        let line: NSString
        let text: String
        let base: TextMateGrammar
        /// How many captures' patterns deep this is: a capture whose patterns
        /// lead back to its own rule would otherwise never end.
        let depth: Int
        private var cache: [Key: (from: Int, limit: Int, match: NSTextCheckingResult?)] = [:]

        struct Key: Hashable {
            let regex: ObjectIdentifier
            let anchored: Bool
        }

        init(line: NSString, base: TextMateGrammar, depth: Int) {
            self.line = line
            text = line as String
            self.base = base
            self.depth = depth
        }

        mutating func find(_ regex: TextMateRegex, from pos: Int, limit: Int, anchor: Int) -> NSTextCheckingResult? {
            let anchored = regex.usesG && pos == anchor
            let key = Key(regex: ObjectIdentifier(regex), anchored: anchored)
            if let known = cache[key], known.from <= pos, known.limit == limit {
                if let match = known.match {
                    if match.range.location >= pos { return match }
                } else {
                    return nil
                }
            }
            guard pos <= limit, let expression = regex.expression(atAnchor: anchored) else { return nil }
            let match = expression.firstMatch(in: text, options: regex.options(atAnchor: anchored),
                                              range: NSRange(location: pos, length: limit - pos))
            cache[key] = (pos, limit, match)
            return match
        }

        /// A match's text, scoped by its captures -- nested ones inside the
        /// ones that hold them -- and a capture with patterns of its own
        /// tokenized by them.
        mutating func emitMatch(_ match: NSTextCheckingResult, captures: [Int: TextMateRule.Capture], scopes: [String],
                                rule: TextMateRule, from pos: inout Int, emit: (NSRange, [String]) -> Void) {
            let whole = match.range
            guard whole.length > 0 else { return }
            if captures.isEmpty {
                emit(whole, scopes)
                pos = whole.upperBound
                return
            }
            struct Item { let index: Int; let range: NSRange; let names: [String]; let patterns: TextMateRule? }
            var items: [Item] = []
            for (index, capture) in captures.sorted(by: { $0.key < $1.key }) where index < match.numberOfRanges {
                let range = match.range(at: index)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                items.append(Item(index: index, range: range,
                                  names: TextMateTokenizer.scopes(capture.name, match, line),
                                  patterns: rule.captureRule(capture, key: "\(ObjectIdentifier(rule))-\(index)-\(captures.count)")))
            }
            var cuts = Set([whole.location, whole.upperBound])
            for item in items { cuts.insert(item.range.location); cuts.insert(item.range.upperBound) }
            let points = cuts.filter { $0 >= whole.location && $0 <= whole.upperBound }.sorted()
            var at = whole.location
            for (a, b) in zip(points, points.dropFirst()) where b > a && a >= at {
                let holding = items.filter { $0.range.location <= a && $0.range.upperBound >= b }
                if let patterned = holding.first(where: { $0.patterns != nil }), let patterns = patterned.patterns {
                    // The capture's own patterns over all of its text, once.
                    let inner = scopes + holding.filter { $0.index <= patterned.index }.flatMap(\.names)
                    tokenizeCapture(patterned.range, rule: patterns, scopes: inner, emit: emit)
                    at = patterned.range.upperBound
                    continue
                }
                emit(NSRange(location: a, length: b - a), scopes + holding.flatMap(\.names))
                at = b
            }
            pos = whole.upperBound
        }

        private func tokenizeCapture(_ range: NSRange, rule: TextMateRule, scopes: [String],
                                     emit: (NSRange, [String]) -> Void) {
            guard let grammar = rule.grammar, depth < 6 else { emit(range, scopes); return }
            let tokenizer = TextMateTokenizer(grammar: grammar)
            let frame = TextMateState.Frame(rule: rule, scopes: scopes, outer: scopes, end: nil, whileRegex: nil, anchor: -1)
            // The captured text alone, as a line of its own; its tokens moved back to where it is.
            let piece = line.substring(with: range) as NSString
            _ = tokenizer.tokenize(line: piece, state: TextMateState(frames: [frame]), depth: depth + 1) { token, scoped in
                emit(NSRange(location: token.location + range.location, length: token.length), scoped)
            }
        }
    }
}
