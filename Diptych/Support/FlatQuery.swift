import Foundation

/// The flat view's filter: which items under a folder are listed, and which
/// folders are walked into -- a small language much like `find`'s.
///
///     (directory and name = "myDir") or (file and name = "*.txt")
///     directory traversed, name ~ /-\d\d\.pdf$/i
///
/// Keywords and the values compared are both case-insensitive; a regular
/// expression, between slashes, is not unless an `i` follows it. A comma is
/// OR, AND binds tighter; NOT and parentheses are there too. A backslash
/// means nothing special in a quoted text: it is for regular expressions.
///
/// A folder is asked twice: once whether to list it, once whether to walk
/// into it. `directory` is true both times, `directory listed` only the
/// first, `directory traversed` only the second. An expression that says
/// neither `directory` nor `file` is about files alone: every folder is then
/// listed and walked into.
nonisolated struct FlatQuery: Sendable {

    /// What was written, as it was written.
    let source: String
    /// Nil for an empty expression, which keeps everything.
    let expression: Expression?
    /// Whether `directory` or `file` appears anywhere in it.
    let namesKinds: Bool
    /// What parses but cannot be what was meant: a part that is never true,
    /// an expression that lists nothing. Running it is still allowed.
    var warnings: [Problem] = []

    // MARK: - The tree

    indirect enum Expression: Sendable, Equatable {
        case and(Expression, Expression)
        case or(Expression, Expression)
        case not(Expression)
        case primitive(Primitive)
    }

    enum Comparison: String, Sendable, CaseIterable {
        case equal = "=", notEqual = "!=", less = "<", lessOrEqual = "<="
        case greater = ">", greaterOrEqual = ">="

        func holds<T: Comparable>(_ value: T, _ against: T) -> Bool {
            switch self {
            case .equal:          value == against
            case .notEqual:       value != against
            case .less:           value < against
            case .lessOrEqual:    value <= against
            case .greater:        value > against
            case .greaterOrEqual: value >= against
            }
        }
    }

    /// `=` and `!=` against a text or a shell pattern, `~` and `!~` against a
    /// regular expression.
    enum TextTest: Sendable, Equatable {
        case equals(String, negated: Bool)
        case matches(Regex, negated: Bool)

        static func == (a: TextTest, b: TextTest) -> Bool {
            switch (a, b) {
            case let (.equals(x, n), .equals(y, m)): x == y && n == m
            case let (.matches(x, n), .matches(y, m)): x.source == y.source && n == m
            default: false
            }
        }
    }

    /// A compiled regular expression, with what it was compiled from:
    /// `/…/` and its flags.
    struct Regex: Sendable, Equatable {
        let source: String
        let compiled: NSRegularExpression

        static func == (a: Regex, b: Regex) -> Bool { a.source == b.source }

        func matches(_ text: String) -> Bool {
            compiled.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    enum DirectoryPart: Sendable, Equatable {
        /// `directory`: listed and walked into.
        case both
        /// `directory traversed`: walked into, not listed.
        case traversed
        /// `directory listed`: listed, not walked into.
        case listed
    }

    /// Bits of the mode, and whether each must be set or clear; the rest are
    /// not looked at.
    struct AccessMask: Sendable, Equatable {
        var set: mode_t = 0
        var clear: mode_t = 0

        func holds(_ mode: mode_t) -> Bool { mode & set == set && mode & clear == 0 }
    }

    /// A moment as written, to the precision it was written: a day, a minute
    /// or a second. `=` means within it.
    struct Moment: Sendable, Equatable {
        let start: Date
        let end: Date

        func holds(_ date: Date, _ comparison: Comparison) -> Bool {
            switch comparison {
            case .equal:          start <= date && date < end
            case .notEqual:       !(start <= date && date < end)
            case .less:           date < start
            case .lessOrEqual:    date < end
            case .greater:        date >= end
            case .greaterOrEqual: date >= start
            }
        }
    }

    enum Primitive: Sendable, Equatable {
        case size(Comparison, Int64)
        case name(TextTest)
        case directory(DirectoryPart)
        case file
        case access(AccessMask, negated: Bool)
        case owner(TextTest)
        case group(TextTest)
        case xattrExists(String)
        case xattr(String, TextTest)
        case created(Comparison, Moment)
        case modified(Comparison, Moment)
        case contains(String)
        case containsMatch(Regex)
        /// `true` or `false`: to switch a part off, or on, without deleting it.
        case constant(Bool)
    }

    // MARK: - Errors

    struct Problem: Error, Equatable, Sendable {
        let message: String
        /// Where, in UTF-16 units, as a text view counts: empty at the end of
        /// the text for something missing.
        let range: NSRange
        /// A saved expression that another one uses and that is no longer
        /// saved, by its name in lower case.
        var missing: String? = nil
        /// The saved expression the message last names as using it.
        var user: String? = nil

        static func == (a: Problem, b: Problem) -> Bool {
            a.message == b.message && NSEqualRanges(a.range, b.range)
        }
    }

    // MARK: - Parsing

    /// The query, or where and why it does not parse. `saved` are the
    /// expressions saved under a name, by the name in lower case; a name
    /// used in the expression stands for its expression, in parentheses.
    static func parse(_ text: String, saved: [String: String]? = nil)
        -> Result<FlatQuery, Problem> {
        parse(text, saved: saved ?? FlatFilterStore.shared.expressions(), expanding: [])
    }

    /// `usedBy`: the saved expression `text` is, as its name was written.
    fileprivate static func parse(_ text: String, saved: [String: String],
                                  expanding: Set<String>,
                                  usedBy: String? = nil) -> Result<FlatQuery, Problem> {
        let tokens: [Token]
        switch tokenize(text) {
        case .success(let found): tokens = found
        case .failure(let problem): return .failure(problem)
        }
        if tokens.isEmpty {
            return .success(FlatQuery(source: text, expression: nil, namesKinds: false))
        }
        var parser = Parser(tokens: tokens, end: (text as NSString).length, saved: saved,
                            expanding: expanding, usedBy: usedBy)
        do {
            let expression = try parser.expression()
            if let extra = parser.peek {
                throw Problem(message: "\u{201C}\(extra.text)\u{201D} is not expected here: "
                              + "AND, OR or a closing parenthesis can follow",
                              range: extra.range)
            }
            return .success(FlatQuery(source: text, expression: expression.expression,
                                      namesKinds: parser.sawKind,
                                      warnings: Analysis.warnings(expression,
                                                                  namesKinds: parser.sawKind)))
        } catch let problem as Problem {
            return .failure(problem)
        } catch {
            return .failure(Problem(message: "\(error)", range: NSRange(location: 0, length: 0)))
        }
    }

    // MARK: - Tokens

    struct Token: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case word       // a keyword, a number, a date, a unit
            case string     // "…" or '…', unquoted
            case regex      // /…/ and its flags, without the slashes
            case symbol     // ( ) = != < <= > >= ~ !~ ,
        }
        let kind: Kind
        let text: String
        let range: NSRange
        /// After a regular expression: i, m, s, x.
        var flags = ""

        var lower: String { text.lowercased() }
        func `is`(_ symbol: String) -> Bool { kind == .symbol && text == symbol }
        func isWord(_ word: String) -> Bool { kind == .word && lower == word }
    }

    static func tokenize(_ text: String) -> Result<[Token], Problem> {
        var tokens: [Token] = []
        let characters = Array(text)
        var index = 0
        var offset = 0          // UTF-16
        func width(_ c: Character) -> Int { c.utf16.count }

        while index < characters.count {
            let c = characters[index]
            if c.isWhitespace {
                offset += width(c); index += 1; continue
            }
            let start = offset
            // A comment, /* … */: nothing, wherever it is.
            if c == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                index += 2; offset += 2
                var closed = false
                while index < characters.count {
                    let d = characters[index]
                    if d == "*", index + 1 < characters.count, characters[index + 1] == "/" {
                        index += 2; offset += 2
                        closed = true
                        break
                    }
                    offset += width(d); index += 1
                }
                guard closed else {
                    return .failure(Problem(message: "The comment opened here is not closed "
                                            + "with */",
                                            range: NSRange(location: start, length: 2)))
                }
                continue
            }
            if c == "\"" || c == "'" {
                var value = ""
                index += 1; offset += width(c)
                var closed = false
                // No escapes: a backslash is itself, as a regular
                // expression or a Windows path wants it.
                while index < characters.count {
                    let d = characters[index]
                    offset += width(d); index += 1
                    if d == c { closed = true; break }
                    value.append(d)
                }
                guard closed else {
                    return .failure(Problem(message: "The quote opened here is not closed",
                                            range: NSRange(location: start, length: 1)))
                }
                tokens.append(Token(kind: .string, text: value,
                                    range: NSRange(location: start, length: offset - start)))
                continue
            }
            if c == "/" {
                // A regular expression: to the next slash not escaped by a
                // backslash, the backslashes kept for the expression.
                var pattern = ""
                index += 1; offset += width(c)
                var closed = false
                while index < characters.count {
                    let d = characters[index]
                    offset += width(d); index += 1
                    if d == "\\", index < characters.count {
                        pattern.append(d)
                        pattern.append(characters[index])
                        offset += width(characters[index]); index += 1
                        continue
                    }
                    if d == "/" { closed = true; break }
                    pattern.append(d)
                }
                guard closed else {
                    return .failure(Problem(message: "The regular expression started here is "
                                            + "not closed with a /",
                                            range: NSRange(location: start, length: 1)))
                }
                var flags = ""
                while index < characters.count, characters[index].isLetter {
                    let flag = characters[index]
                    guard "imsx".contains(flag) else {
                        return .failure(Problem(message: "\u{201C}\(flag)\u{201D} is not a flag "
                                                + "of a regular expression: i ignores case, m "
                                                + "makes ^ and $ match at every line, s lets . "
                                                + "match a line break, x allows spaces",
                                                range: NSRange(location: offset, length: width(flag))))
                    }
                    flags.append(flag)
                    offset += width(flag); index += 1
                }
                tokens.append(Token(kind: .regex, text: pattern,
                                    range: NSRange(location: start, length: offset - start),
                                    flags: flags))
                continue
            }
            if "()=<>~!,".contains(c) {
                var symbol = String(c)
                index += 1; offset += width(c)
                if index < characters.count, (c == "<" || c == ">" || c == "!"),
                   characters[index] == "=" || (c == "!" && characters[index] == "~") {
                    symbol.append(characters[index]); index += 1; offset += 1
                }
                if symbol == "!" {
                    return .failure(Problem(message: "\u{201C}!\u{201D} goes with = or ~: "
                                            + "!= or !~ \u{2014} or write NOT",
                                            range: NSRange(location: start, length: 1)))
                }
                tokens.append(Token(kind: .symbol, text: symbol,
                                    range: NSRange(location: start, length: offset - start)))
                continue
            }
            if isWordCharacter(c) {
                var word = ""
                while index < characters.count, isWordCharacter(characters[index]) {
                    word.append(characters[index])
                    offset += width(characters[index]); index += 1
                }
                tokens.append(Token(kind: .word, text: word,
                                    range: NSRange(location: start, length: offset - start)))
                continue
            }
            return .failure(Problem(message: "\u{201C}\(c)\u{201D} has no meaning here",
                                    range: NSRange(location: start, length: width(c))))
        }
        return .success(tokens)
    }

    /// Letters and digits, and what a number or a date has in it.
    static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "." || c == ":" || c == "-" || c == "+"
    }

    // MARK: - The keywords, for completion and hints

    static let primitives = ["size", "name", "directory", "file", "access", "owner", "group",
                             "xattr", "created", "modified", "contains", "true", "false"]
    static let connectives = ["and", "or", "not"]
    /// What a saved expression cannot be called: the language's own words.
    static let reservedWords: Set<String> = Set(primitives + connectives + units.map {
        $0.lowercased()
    } + ["dir", "content", "traversed", "traverse", "listed", "list"])
    /// What an access pattern starts as: every place either way.
    static let anyAccess = "*********"
    static let units = ["B", "KB", "KiB", "MB", "MiB", "GB", "GiB", "TB", "TiB"]

    /// One line on what a keyword takes, for the hint under the field.
    static func hint(for keyword: String) -> String? {
        switch keyword.lowercased() {
        case "size":
            "size =, !=, <, <=, >, >= a number of bytes, or with KB, KiB, MB, MiB, GB, GiB, "
                + "TB, TiB \u{2014} size > 10MB (KB is 1000 bytes, KiB 1024)"
        case "name":
            "name = \"*.txt\" a name or a shell pattern; name ~ /^IMG_\\d+/ a regular "
                + "expression, /\u{2026}/i ignoring case; != and !~ for not"
        case "directory":
            "directory: listed and walked into \u{2014} directory traversed: walked into, not "
                + "listed \u{2014} directory listed: listed, not walked into"
        case "traversed", "traverse":
            "directory traversed: the folder is walked into for what is inside it, but not "
                + "listed itself"
        case "listed", "list":
            "directory listed: the folder is listed, but not walked into"
        case "file":
            "file: true for anything that is not a folder"
        case "access":
            "access = \"rwxr-x---\": r, w, x where set, - where not, * for either; s in the "
                + "user and group x places, t in the last. In the quotes, r w x s t set the "
                + "caret\u{2019}s three, with Shift unset; - + * space set the place itself"
        case "owner":
            "owner = \"name\" the file\u{2019}s owner; owner ~ /regex/"
        case "group":
            "group = \"staff\" the file\u{2019}s group; group ~ /regex/"
        case "xattr":
            "xattr(\"com.apple.quarantine\") exists; xattr(\"name\") = \"value\"; "
                + "xattr(\"name\") ~ /regex/"
        case "created":
            "created <, <=, =, !=, >=, > 2026-01-31, or 2026-01-31T14:30, with +02:00 or Z "
                + "for a zone; a date alone is the whole day. Control-Space for a calendar"
        case "modified":
            "modified <, <=, =, !=, >=, > 2026-01-31, or 2026-01-31T14:30, with +02:00 or Z "
                + "for a zone; a date alone is the whole day. Control-Space for a calendar"
        case "contains", "content":
            "contains \"text\" the file has the text in it; contains ~ /regex/ a line of it "
                + "matches, as grep, /\u{2026}/i ignoring case. Binary files are never "
                + "searched"
        case "true", "false":
            "true, false: always so \u{2014} false and ( \u{2026} ) switches a part off without "
                + "deleting it, as does a comment, /* \u{2026} */"
        case "and":
            "a AND b: both \u{2014} binds tighter than OR"
        case "or":
            "a OR b, or a, b: either"
        case "not":
            "NOT a: the opposite"
        default:
            nil
        }
    }
}

// MARK: - The parser

/// A part of the expression and where it was written: what the warnings
/// point at.
nonisolated struct FlatNode: Sendable {
    let expression: FlatQuery.Expression
    let range: NSRange
    let parts: [FlatNode]
}

nonisolated private struct Parser {
    typealias Problem = FlatQuery.Problem
    typealias Token = FlatQuery.Token
    typealias Node = FlatNode

    let tokens: [Token]
    /// The length of the text, where "missing" problems point.
    let end: Int
    var position = 0
    var sawKind = false
    /// Saved expressions by name in lower case, and the ones being expanded
    /// on the way here -- one using itself would never end.
    let saved: [String: String]
    let expanding: Set<String>
    /// Set while parsing a saved expression: its name, as written where it
    /// was used. A name in it that is not saved was when it was saved.
    let usedBy: String?

    init(tokens: [Token], end: Int, saved: [String: String] = [:],
         expanding: Set<String> = [], usedBy: String? = nil) {
        self.tokens = tokens
        self.end = end
        self.saved = saved
        self.expanding = expanding
        self.usedBy = usedBy
    }

    var peek: Token? { position < tokens.count ? tokens[position] : nil }

    private var atEnd: NSRange { NSRange(location: end, length: 0) }

    mutating func next() -> Token? {
        defer { position += 1 }
        return peek
    }

    /// From the token at `start` to the last one read.
    private func span(from start: Int) -> NSRange {
        let first = tokens[min(start, tokens.count - 1)].range
        let last = tokens[min(max(position - 1, start), tokens.count - 1)].range
        return NSUnionRange(first, last)
    }

    /// OR, or a comma, which reads as one: `directory traversed, name = "*.txt"`.
    mutating func expression() throws -> Node {
        let start = position
        var left = try conjunction()
        while let token = peek, token.isWord("or") || token.is(",") {
            position += 1
            let right = try conjunction()
            left = Node(expression: .or(left.expression, right.expression),
                        range: span(from: start), parts: [left, right])
        }
        return left
    }

    private mutating func conjunction() throws -> Node {
        let start = position
        var left = try negation()
        while let token = peek, token.isWord("and") {
            position += 1
            let right = try negation()
            left = Node(expression: .and(left.expression, right.expression),
                        range: span(from: start), parts: [left, right])
        }
        return left
    }

    private mutating func negation() throws -> Node {
        let start = position
        if let token = peek, token.isWord("not") {
            position += 1
            let inner = try negation()
            return Node(expression: .not(inner.expression), range: span(from: start),
                        parts: [inner])
        }
        return try primary()
    }

    private mutating func primary() throws -> Node {
        let start = position
        guard let token = next() else {
            throw Problem(message: "Something to test is missing here: size, name, directory, "
                          + "file, \u{2026}, or a parenthesis", range: atEnd)
        }
        if token.is("(") {
            let inner = try expression()
            guard let close = next(), close.is(")") else {
                throw Problem(message: "The parenthesis opened here is not closed",
                              range: token.range)
            }
            return Node(expression: inner.expression, range: span(from: start),
                        parts: inner.parts)
        }
        guard token.kind == .word else {
            throw Problem(message: "\u{201C}\(token.text)\u{201D} cannot start a test: "
                          + "size, name, directory, file, \u{2026}", range: token.range)
        }
        if !FlatQuery.reservedWords.contains(token.lower), let text = saved[token.lower] {
            return try savedExpression(token, text)
        }
        let primitive = try primitive(token)
        return Node(expression: .primitive(primitive), range: span(from: start), parts: [])
    }

    /// A saved expression's name: what it stands for, as if in
    /// parentheses. Its parts are not looked into for warnings one by one.
    private mutating func savedExpression(_ token: Token, _ text: String) throws -> Node {
        guard !expanding.contains(token.lower) else {
            throw Problem(message: "The saved expression \u{201C}\(token.text)\u{201D} uses "
                          + "itself, so it never ends", range: token.range)
        }
        switch FlatQuery.parse(text, saved: saved, expanding: expanding.union([token.lower]),
                               usedBy: token.text) {
        case .failure(let problem) where problem.missing != nil:
            // Gone, not wrong: said as that, down the chain of who uses it.
            let message = problem.user == token.lower ? problem.message
                : problem.message + ", which \u{201C}\(token.text)\u{201D} uses"
            throw Problem(message: message, range: token.range, missing: problem.missing,
                          user: token.lower)
        case .failure(let problem):
            throw Problem(message: "The saved expression \u{201C}\(token.text)\u{201D} does "
                          + "not parse: \(problem.message)", range: token.range)
        case .success(let query):
            if query.namesKinds { sawKind = true }
            return Node(expression: query.expression ?? .primitive(.constant(true)),
                        range: token.range, parts: [])
        }
    }

    private mutating func primitive(_ keyword: Token) throws -> FlatQuery.Primitive {
        switch keyword.lower {
        case "true":
            return .constant(true)
        case "false":
            return .constant(false)
        case "size":
            let comparison = try comparison(after: keyword)
            return .size(comparison, try size(after: keyword))
        case "name":
            return .name(try textTest(after: keyword))
        case "owner":
            return .owner(try textTest(after: keyword))
        case "group":
            return .group(try textTest(after: keyword))
        case "file":
            sawKind = true
            return .file
        case "directory", "dir":
            sawKind = true
            if let part = peek, part.kind == .word {
                switch part.lower {
                case "traversed", "traverse":
                    position += 1
                    return .directory(.traversed)
                case "listed", "list":
                    position += 1
                    return .directory(.listed)
                default:
                    break
                }
            }
            return .directory(.both)
        case "access":
            guard let op = next(), op.is("=") || op.is("!=") else {
                throw Problem(message: "access takes = or != and a pattern: access = "
                              + "\"rwxr-x---\"", range: tokens.indices.contains(position - 1)
                                ? tokens[position - 1].range : atEnd)
            }
            let pattern = try string(after: op, what: "a pattern of nine: \"rwxr-x---\"")
            return .access(try FlatQuery.accessMask(pattern.text, at: pattern.range),
                           negated: op.is("!="))
        case "xattr":
            guard let open = next(), open.is("(") else {
                throw Problem(message: "xattr takes the attribute\u{2019}s name in parentheses: "
                              + "xattr(\"com.apple.quarantine\")",
                              range: lastOr(keyword))
            }
            let name = try string(after: open, what: "the attribute\u{2019}s name")
            guard let close = next(), close.is(")") else {
                throw Problem(message: "The parenthesis after xattr is not closed",
                              range: open.range)
            }
            if let op = peek, op.is("=") || op.is("!=") || op.is("~") || op.is("!~") {
                return .xattr(name.text, try textTest(after: keyword))
            }
            return .xattrExists(name.text)
        case "created", "modified":
            let comparison = try comparison(after: keyword)
            guard let value = next(), value.kind != .symbol else {
                throw Problem(message: "A date is missing: 2026-01-31, or 2026-01-31T14:30",
                              range: lastOr(keyword, missing: true))
            }
            guard let moment = FlatQuery.moment(value.text) else {
                throw Problem(message: "Not a date as ISO 8601 writes it: 2026-01-31, "
                              + "2026-01-31T14:30, 2026-01-31T14:30:00+02:00",
                              range: value.range)
            }
            return keyword.lower == "created" ? .created(comparison, moment)
                                              : .modified(comparison, moment)
        case "contains", "content":
            // `contains ~ /re/`, or the expression straight after it.
            if let op = peek, op.is("~") {
                position += 1
                return .containsMatch(try regex(after: op))
            }
            if let pattern = peek, pattern.kind == .regex {
                return .containsMatch(try regex(after: keyword))
            }
            let text = try string(after: keyword, what: "the text to look for")
            return .contains(text.text)
        case "and", "or", "not":
            throw Problem(message: "\u{201C}\(keyword.text)\u{201D} needs a test before it",
                          range: keyword.range)
        default:
            if let usedBy, FlatFilterStore.isUsable(keyword.text) {
                throw Problem(message: "\u{201C}\(keyword.text)\u{201D} is no longer saved, and "
                              + "\u{201C}\(usedBy)\u{201D} uses it", range: keyword.range,
                              missing: keyword.lower, user: usedBy.lowercased())
            }
            throw Problem(message: "\u{201C}\(keyword.text)\u{201D} is not a test: size, name, "
                          + "directory, file, access, owner, group, xattr, created, modified, "
                          + "contains, true, false \u{2014} or a saved expression",
                          range: keyword.range)
        }
    }

    /// The last token read, or the end of the text when what is missing comes
    /// after everything written.
    private func lastOr(_ token: Token, missing: Bool = false) -> NSRange {
        if position - 1 < tokens.count, position - 1 >= 0, !missing { return tokens[position - 1].range }
        return position >= tokens.count ? atEnd : tokens[position].range
    }

    private mutating func comparison(after keyword: Token) throws -> FlatQuery.Comparison {
        guard let token = peek, token.kind == .symbol,
              let comparison = FlatQuery.Comparison(rawValue: token.text) else {
            throw Problem(message: "\(keyword.lower) takes a comparison: =, !=, <, <=, >, >=",
                          range: peek?.range ?? atEnd)
        }
        position += 1
        return comparison
    }

    private mutating func size(after keyword: Token) throws -> Int64 {
        guard let token = next(), token.kind == .word else {
            throw Problem(message: "A size is missing: 1024, 10KB, 1.5GiB",
                          range: position - 1 < tokens.count ? tokens[position - 1].range : atEnd)
        }
        // "10MB" or "10 MB".
        var text = token.text
        var range = token.range
        if let unit = peek, unit.kind == .word, Double(text) != nil,
           FlatQuery.unitBytes(unit.text) != nil {
            text += unit.text
            range = NSUnionRange(range, unit.range)
            position += 1
        }
        guard let bytes = FlatQuery.bytes(text) else {
            throw Problem(message: "Not a size: a number of bytes, or with B, KB, KiB, MB, "
                          + "MiB, GB, GiB, TB or TiB", range: range)
        }
        return bytes
    }

    private mutating func textTest(after keyword: Token) throws -> FlatQuery.TextTest {
        guard let op = peek, op.is("=") || op.is("!=") || op.is("~") || op.is("!~") else {
            throw Problem(message: "\(keyword.lower) takes = or != and a text or a pattern, or "
                          + "~ and a regular expression", range: peek?.range ?? atEnd)
        }
        position += 1
        let negated = op.text.hasPrefix("!")
        if op.text.hasSuffix("~") {
            return .matches(try regex(after: op), negated: negated)
        }
        if let value = peek, value.kind == .regex {
            throw Problem(message: "= compares with a text or a shell pattern; a regular "
                          + "expression goes with ~: \(keyword.lower) ~ /\(value.text)/",
                          range: value.range)
        }
        let value = try string(after: op, what: "the text, in quotes")
        return .equals(value.text, negated: negated)
    }

    /// A quoted text. A plain word is taken too, where it cannot be mistaken
    /// for a keyword: `name = readme.md`.
    private mutating func string(after: Token, what: String) throws -> Token {
        guard let token = peek, token.kind == .string
                || (token.kind == .word && !["and", "or", "not"].contains(token.lower)) else {
            throw Problem(message: "\(what.prefix(1).uppercased() + what.dropFirst()) is missing",
                          range: peek?.range ?? atEnd)
        }
        position += 1
        return token
    }

    /// `/…/`, with its flags. A quoted text is not taken: the quotes would
    /// leave it unclear what a backslash means.
    private mutating func regex(after: Token) throws -> FlatQuery.Regex {
        guard let token = peek, token.kind == .regex else {
            if let token = peek, token.kind == .string {
                throw Problem(message: "A regular expression goes between slashes, not quotes: "
                              + "/\(token.text)/ \u{2014} /\(token.text)/i to ignore case",
                              range: token.range)
            }
            throw Problem(message: "A regular expression is missing: /\u{2026}/, or "
                          + "/\u{2026}/i to ignore case", range: peek?.range ?? atEnd)
        }
        position += 1
        var options: NSRegularExpression.Options = []
        if token.flags.contains("i") { options.insert(.caseInsensitive) }
        if token.flags.contains("m") { options.insert(.anchorsMatchLines) }
        if token.flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        if token.flags.contains("x") { options.insert(.allowCommentsAndWhitespace) }
        do {
            return FlatQuery.Regex(source: "/\(token.text)/\(token.flags)",
                                   compiled: try NSRegularExpression(pattern: token.text,
                                                                     options: options))
        } catch {
            throw Problem(message: "Not a regular expression that compiles", range: token.range)
        }
    }
}

// MARK: - What cannot be meant

/// Parts of an expression that are never true, judged by what each test
/// needs -- a file, a folder being listed, a folder being walked into --
/// and by tests joined with AND that contradict each other: a bit both set
/// and clear, a size above and below, a name that a pattern excludes.
/// Without looking at any file, and not every case: the common ones.
nonisolated enum Analysis {

    typealias Expression = FlatQuery.Expression
    typealias Primitive = FlatQuery.Primitive

    private enum Truth { case yes, no, maybe }

    private static let passes: [FlatQuery.Pass] = [.file, .list, .traverse]

    private static func truth(_ expression: Expression, _ pass: FlatQuery.Pass) -> Truth {
        switch expression {
        case .and(let a, let b):
            let (x, y) = (truth(a, pass), truth(b, pass))
            if x == .no || y == .no { return .no }
            if contradiction(conjuncts(expression, NSRange())) != nil { return .no }
            return x == .yes && y == .yes ? .yes : .maybe
        case .or(let a, let b):
            let (x, y) = (truth(a, pass), truth(b, pass))
            if x == .yes || y == .yes { return .yes }
            return x == .no && y == .no ? .no : .maybe
        case .not(let a):
            switch truth(a, pass) {
            case .yes: return .no
            case .no: return .yes
            case .maybe: return .maybe
            }
        case .primitive(let primitive):
            let folder = pass != .file
            switch primitive {
            case .file:
                return folder ? .no : .yes
            case .directory(.both):
                return folder ? .yes : .no
            case .directory(.traversed):
                return pass == .traverse ? .yes : .no
            case .directory(.listed):
                return pass == .list ? .yes : .no
            case .size, .contains, .containsMatch:
                return folder ? .no : .maybe
            default:
                // `true` and `false` too: written on purpose, to switch a
                // part on or off, never a mistake to point out.
                return .maybe
            }
        }
    }

    // MARK: Contradictions

    /// A test, or its opposite, as one of the things an AND asks for.
    private struct Atom {
        let primitive: Primitive
        let positive: Bool
        let range: NSRange
    }

    /// What an AND chain asks for, each with where it was written; `not`
    /// over a test is the test's opposite.
    private static func conjuncts(_ node: FlatNode) -> [(Expression, NSRange)] {
        if case .and = node.expression, node.parts.count == 2 {
            return node.parts.flatMap(conjuncts)
        }
        return conjuncts(node.expression, node.range)
    }

    private static func conjuncts(_ expression: Expression,
                                  _ range: NSRange) -> [(Expression, NSRange)] {
        if case .and(let a, let b) = expression {
            return conjuncts(a, range) + conjuncts(b, range)
        }
        return [(expression, range)]
    }

    private static func atom(_ expression: Expression, _ range: NSRange,
                             positive: Bool = true) -> Atom? {
        switch expression {
        case .not(let inner):
            return atom(inner, range, positive: !positive)
        case .primitive(let primitive):
            return Atom(primitive: normal(primitive).0,
                        positive: positive != normal(primitive).1, range: range)
        default:
            return nil
        }
    }

    /// The test without its own negation, `!=`, `!~`, and whether it had one.
    private static func normal(_ primitive: Primitive) -> (Primitive, Bool) {
        func plain(_ test: FlatQuery.TextTest) -> (FlatQuery.TextTest, Bool) {
            switch test {
            case .equals(let value, let negated): (.equals(value, negated: false), negated)
            case .matches(let regex, let negated): (.matches(regex, negated: false), negated)
            }
        }
        switch primitive {
        case .name(let test):
            let (t, n) = plain(test); return (.name(t), n)
        case .owner(let test):
            let (t, n) = plain(test); return (.owner(t), n)
        case .group(let test):
            let (t, n) = plain(test); return (.group(t), n)
        case .xattr(let name, let test):
            let (t, n) = plain(test); return (.xattr(name.lowercased(), t), n)
        case .xattrExists(let name):
            return (.xattrExists(name.lowercased()), false)
        case .access(let mask, let negated):
            return (.access(mask, negated: false), negated)
        case .size(.notEqual, let bytes):
            return (.size(.equal, bytes), true)
        case .created(.notEqual, let moment):
            return (.created(.equal, moment), true)
        case .modified(.notEqual, let moment):
            return (.modified(.equal, moment), true)
        default:
            return (primitive, false)
        }
    }

    /// Why the tests of one AND can never all hold, and where; nil when
    /// nothing here says so.
    static func contradiction(_ parts: [(Expression, NSRange)]) -> (String, NSRange)? {
        let atoms = parts.compactMap { atom($0.0, $0.1) }
        guard atoms.count > 1 else { return nil }
        func both(_ a: Atom, _ b: Atom) -> NSRange { NSUnionRange(a.range, b.range) }

        // A test and its opposite.
        for (i, a) in atoms.enumerated() {
            for b in atoms[(i + 1)...] where a.primitive == b.primitive && a.positive != b.positive {
                return ("Never true: a test and its opposite are both asked for", both(a, b))
            }
        }
        if let found = accessContradiction(atoms) { return found }
        if let found = sizeContradiction(atoms) { return found }
        for which in ["created", "modified"] {
            if let found = dateContradiction(atoms, which) { return found }
        }
        for field in ["name", "owner", "group"] {
            if let found = textContradiction(atoms, field: field) { return found }
        }
        if let found = xattrContradiction(atoms) { return found }
        return nil
    }

    // Access: one place, two answers.
    private static func accessContradiction(_ atoms: [Atom]) -> (String, NSRange)? {
        let positives = atoms.compactMap { atom -> (FlatQuery.AccessMask, Atom)? in
            guard atom.positive, case .access(let mask, _) = atom.primitive else { return nil }
            return (mask, atom)
        }
        for (i, (a, first)) in positives.enumerated() {
            for (b, second) in positives[(i + 1)...] {
                let clash = (a.set & b.clear) | (a.clear & b.set)
                guard clash != 0, let bit = describe(clash) else { continue }
                return ("Never true: \(bit) cannot be both set and clear",
                        NSUnionRange(first.range, second.range))
            }
        }
        // `access != P` -- or `not access = P` -- where the rest already
        // says P.
        let set = positives.reduce(mode_t(0)) { $0 | $1.0.set }
        let clear = positives.reduce(mode_t(0)) { $0 | $1.0.clear }
        for atom in atoms where !atom.positive {
            guard case .access(let mask, _) = atom.primitive,
                  mask.set & set == mask.set, mask.clear & clear == mask.clear,
                  let other = positives.first else { continue }
            return ("Never true: the other access tests already say what this one says is not "
                    + "so", NSUnionRange(atom.range, other.1.range))
        }
        return nil
    }

    /// `the group's read bit`, for the highest bit in `bits`.
    private static func describe(_ bits: mode_t) -> String? {
        let named: [(mode_t, String)] = [
            (S_ISUID, "setuid"), (S_ISGID, "setgid"), (S_ISVTX, "the sticky bit"),
            (0o400, "the user\u{2019}s read bit"), (0o200, "the user\u{2019}s write bit"),
            (0o100, "the user\u{2019}s execute bit"),
            (0o040, "the group\u{2019}s read bit"), (0o020, "the group\u{2019}s write bit"),
            (0o010, "the group\u{2019}s execute bit"),
            (0o004, "others\u{2019} read bit"), (0o002, "others\u{2019} write bit"),
            (0o001, "others\u{2019} execute bit"),
        ]
        return named.first { bits & $0.0 != 0 }?.1
    }

    /// The comparison that is true exactly where this one is false.
    private static func opposite(_ comparison: FlatQuery.Comparison) -> FlatQuery.Comparison {
        switch comparison {
        case .equal: .notEqual
        case .notEqual: .equal
        case .less: .greaterOrEqual
        case .greaterOrEqual: .less
        case .greater: .lessOrEqual
        case .lessOrEqual: .greater
        }
    }

    // Size: a range that ends before it starts.
    private static func sizeContradiction(_ atoms: [Atom]) -> (String, NSRange)? {
        var low = Int64.min, high = Int64.max
        var lowAtom: Atom?, highAtom: Atom?
        var excluded: [(Int64, Atom)] = []
        for atom in atoms {
            guard case .size(let written, let bytes) = atom.primitive else { continue }
            let comparison = atom.positive ? written : opposite(written)
            switch comparison {
            case .equal:
                if bytes > low { low = bytes; lowAtom = atom }
                if bytes < high { high = bytes; highAtom = atom }
            case .notEqual:
                excluded.append((bytes, atom))
            case .greater:
                if bytes == .max || bytes + 1 > low { low = bytes == .max ? .max : bytes + 1
                                                      lowAtom = atom }
            case .greaterOrEqual:
                if bytes > low { low = bytes; lowAtom = atom }
            case .less:
                if bytes == .min || bytes - 1 < high { high = bytes == .min ? .min : bytes - 1
                                                       highAtom = atom }
            case .lessOrEqual:
                if bytes < high { high = bytes; highAtom = atom }
            }
        }
        if low > high, let lowAtom, let highAtom {
            return ("Never true: no size is in both ranges",
                    NSUnionRange(lowAtom.range, highAtom.range))
        }
        if low == high, let (_, atom) = excluded.first(where: { $0.0 == low }),
           let other = lowAtom ?? highAtom {
            return ("Never true: the only size left is the one excluded",
                    NSUnionRange(atom.range, other.range))
        }
        return nil
    }

    // Dates: the same, as moments of a precision.
    private static func dateContradiction(_ atoms: [Atom], _ which: String)
        -> (String, NSRange)? {
        var low = Date.distantPast, high = Date.distantFuture   // [low, high)
        var lowAtom: Atom?, highAtom: Atom?
        var excluded: [(FlatQuery.Moment, Atom)] = []
        for atom in atoms {
            let found: (FlatQuery.Comparison, FlatQuery.Moment)?
            switch atom.primitive {
            case .created(let c, let m) where which == "created": found = (c, m)
            case .modified(let c, let m) where which == "modified": found = (c, m)
            default: found = nil
            }
            guard let (written, moment) = found else { continue }
            let comparison = atom.positive ? written : opposite(written)
            func from(_ date: Date) { if date > low { low = date; lowAtom = atom } }
            func until(_ date: Date) { if date < high { high = date; highAtom = atom } }
            switch comparison {
            case .equal: from(moment.start); until(moment.end)
            case .notEqual: excluded.append((moment, atom))
            case .less: until(moment.start)
            case .lessOrEqual: until(moment.end)
            case .greater: from(moment.end)
            case .greaterOrEqual: from(moment.start)
            }
        }
        if low >= high, let lowAtom, let highAtom {
            return ("Never true: no \(which) date is in both ranges",
                    NSUnionRange(lowAtom.range, highAtom.range))
        }
        if let (_, atom) = excluded.first(where: { low >= $0.0.start && high <= $0.0.end }),
           let other = lowAtom ?? highAtom {
            return ("Never true: every \(which) date left is excluded",
                    NSUnionRange(atom.range, other.range))
        }
        return nil
    }

    private static func text(_ primitive: Primitive, field: String) -> FlatQuery.TextTest? {
        switch (primitive, field) {
        case (.name(let t), "name"), (.owner(let t), "owner"), (.group(let t), "group"): t
        default: nil
        }
    }

    private static func isPattern(_ value: String) -> Bool {
        value.contains { $0 == "*" || $0 == "?" || $0 == "[" }
    }

    /// Names, owners, groups: one exact value is wanted, and another test
    /// rules it out; or two exact values.
    private static func textContradiction(_ atoms: [Atom], field: String)
        -> (String, NSRange)? {
        let glob = field == "name"
        let tests = atoms.compactMap { atom in text(atom.primitive, field: field).map { ($0, atom) } }
        guard tests.count > 1 else { return nil }
        let exact = tests.compactMap { test, atom -> (String, Atom)? in
            guard atom.positive, case .equals(let value, _) = test,
                  !(glob && isPattern(value)) else { return nil }
            return (value, atom)
        }
        if exact.count > 1 {
            for (value, atom) in exact.dropFirst()
            where value.caseInsensitiveCompare(exact[0].0) != .orderedSame {
                return ("Never true: the \(field) cannot be both \u{201C}\(exact[0].0)\u{201D} "
                        + "and \u{201C}\(value)\u{201D}", NSUnionRange(exact[0].1.range, atom.range))
            }
        }
        if let (value, atom) = exact.first {
            // The exact test itself passes its own value: only another
            // can say no.
            for (test, other) in tests {
                if test.holds(value, glob: glob) != other.positive {
                    return ("Never true: \u{201C}\(value)\u{201D} is ruled out by the other "
                            + "\(field) test", NSUnionRange(atom.range, other.range))
                }
            }
        }
        // Two patterns that are only an ending each: `*.jpg` and `*.png`.
        if glob {
            let endings = tests.compactMap { test, atom -> (String, Atom)? in
                guard atom.positive, case .equals(let value, _) = test, value.hasPrefix("*"),
                      !isPattern(String(value.dropFirst())) else { return nil }
                return (String(value.dropFirst()).lowercased(), atom)
            }
            for (i, a) in endings.enumerated() {
                for b in endings[(i + 1)...] where !a.0.hasSuffix(b.0) && !b.0.hasSuffix(a.0) {
                    return ("Never true: no name ends both in \u{201C}\(a.0)\u{201D} and in "
                            + "\u{201C}\(b.0)\u{201D} \u{2014} OR, or a comma, is either",
                            NSUnionRange(a.1.range, b.1.range))
                }
            }
        }
        return nil
    }

    /// An attribute's value is tested, and the attribute is not to be there.
    private static func xattrContradiction(_ atoms: [Atom]) -> (String, NSRange)? {
        for absent in atoms where !absent.positive {
            guard case .xattrExists(let name) = absent.primitive else { continue }
            for atom in atoms where atom.positive {
                if case .xattr(name, _) = atom.primitive {
                    return ("Never true: the attribute\u{2019}s value is tested, and the "
                            + "attribute is not to be there", NSUnionRange(absent.range, atom.range))
                }
            }
        }
        return nil
    }

    // MARK: Warnings

    static func warnings(_ root: FlatNode, namesKinds: Bool) -> [FlatQuery.Problem] {
        // Without `file` or `directory`, folders are not asked: every one is
        // listed and walked into.
        let asked = namesKinds ? passes : [.file]
        var found: [FlatQuery.Problem] = []

        func never(_ node: FlatNode) -> Bool {
            asked.allSatisfy { truth(node.expression, $0) == .no }
        }
        // The outermost AND that can never hold; what is inside it is not
        // worth saying again.
        func look(_ node: FlatNode) {
            if case .and = node.expression {
                if let (message, range) = contradiction(conjuncts(node)) {
                    found.append(FlatQuery.Problem(message: message, range: range))
                    return
                }
                if never(node) {
                    found.append(FlatQuery.Problem(
                        message: "Never true: nothing passes both sides of this AND \u{2014} a "
                            + "file is not a folder, a folder walked into is not one listed, "
                            + "and a folder has no size or contents", range: node.range))
                    return
                }
            }
            node.parts.forEach(look)
        }
        look(root)

        let expression = root.expression
        if truth(expression, .file) == .no,
           !namesKinds || truth(expression, .list) == .no {
            if found.isEmpty {
                found.append(FlatQuery.Problem(
                    message: namesKinds
                        ? "This lists nothing: no file and no folder passes it \u{2014} "
                            + "directory traversed only walks into folders, add what to list: "
                            + "directory traversed, name = \"*.txt\""
                        : "No file can pass this, so only the folders are listed",
                    range: root.range))
            }
        } else if namesKinds, truth(expression, .traverse) == .no {
            found.append(FlatQuery.Problem(
                message: "No folder is walked into, so only what is directly in this folder "
                    + "is looked at \u{2014} add \u{201C}directory traversed,\u{201D} in "
                    + "front to look below it",
                range: root.range))
        }
        return found
    }
}

// MARK: - Values

nonisolated extension FlatQuery {

    static func unitBytes(_ unit: String) -> Int64? {
        switch unit.lowercased() {
        case "b":   1
        case "kb":  1000
        case "kib": 1024
        case "mb":  1000 * 1000
        case "mib": 1024 * 1024
        case "gb":  1000 * 1000 * 1000
        case "gib": 1024 * 1024 * 1024
        case "tb":  1000 * 1000 * 1000 * 1000
        case "tib": 1024 * 1024 * 1024 * 1024
        default:    nil
        }
    }

    /// `1024`, `10KB`, `1.5GiB`.
    static func bytes(_ text: String) -> Int64? {
        let digits = text.prefix { $0.isNumber || $0 == "." }
        guard let number = Double(digits), number >= 0 else { return nil }
        let unit = text.dropFirst(digits.count)
        guard let multiplier = unit.isEmpty ? 1 : unitBytes(String(unit)) else { return nil }
        let bytes = number * Double(multiplier)
        guard bytes < Double(Int64.max) else { return nil }
        return Int64(bytes.rounded())
    }

    /// `rwxr-x---`, `*w*******`, `rws*-*--t`: nine places, each its own bit.
    static func accessMask(_ pattern: String, at range: NSRange) throws -> AccessMask {
        let places = Array(pattern.lowercased())
        guard places.count == 9 else {
            throw Problem(message: "access is nine places, rwx for the user, the group and "
                          + "others: \"rwxr-x---\"", range: range)
        }
        let who = ["user", "group", "others"]
        var mask = AccessMask()
        for (index, place) in places.enumerated() {
            let triple = index / 3
            let shift = mode_t((2 - triple) * 3)
            let letter: Character = ["r", "w", "x"][index % 3]
            let bit = mode_t(1 << (2 - index % 3)) << shift
            switch place {
            case "*":
                continue
            case "-":
                mask.clear |= bit
            case letter:
                mask.set |= bit
            case "s" where index == 2:
                mask.set |= S_ISUID
            case "s" where index == 5:
                mask.set |= S_ISGID
            case "t" where index == 8:
                mask.set |= S_ISVTX
            default:
                let allowed = index % 3 == 2
                    ? (index == 8 ? "x, t" : "x, s") : String(letter)
                throw Problem(message: "Place \(index + 1) is the \(who[triple])\u{2019}s "
                              + "\(["read", "write", "execute"][index % 3]) bit: \(allowed), - "
                              + "or *", range: range)
            }
        }
        return mask
    }

    /// ISO 8601, to the precision written: `2026-01-31` is the whole day,
    /// `2026-01-31T14:30` the whole minute. Without a zone, this Mac's.
    static func moment(_ text: String, zone: TimeZone = .current) -> Moment? {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?)?(Z|[+-]\d{2}(?::?\d{2})?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        func part(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        var timeZone = zone
        if let written = part(7)?.uppercased() {
            if written == "Z" {
                timeZone = TimeZone(secondsFromGMT: 0)!
            } else {
                let sign = written.hasPrefix("-") ? -1 : 1
                let digits = written.dropFirst().filter(\.isNumber)
                let hours = Int(digits.prefix(2)) ?? 0
                let minutes = digits.count > 2 ? Int(digits.dropFirst(2)) ?? 0 : 0
                guard hours < 24, minutes < 60,
                      let fixed = TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
                else { return nil }
                timeZone = fixed
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents(year: Int(part(1)!), month: Int(part(2)!),
                                        day: Int(part(3)!))
        let step: DateComponents
        if let hour = part(4).flatMap(Int.init), let minute = part(5).flatMap(Int.init) {
            components.hour = hour
            components.minute = minute
            if let second = part(6).flatMap(Int.init) {
                components.second = second
                step = DateComponents(second: 1)
            } else {
                step = DateComponents(minute: 1)
            }
        } else {
            step = DateComponents(day: 1)
        }
        guard components.isValidDate(in: calendar),
              let start = calendar.date(from: components),
              let end = calendar.date(byAdding: step, to: start) else { return nil }
        return Moment(start: start, end: end)
    }
}

// MARK: - Completion

nonisolated extension FlatQuery {

    /// What could be typed at `caret`, for Control-Space: the words that fit,
    /// starting with what is already typed of the one the caret is in.
    static func completions(in text: String, at caret: Int) -> (range: NSRange, words: [String]) {
        let ns = text as NSString
        let caret = min(max(caret, 0), ns.length)
        // The word being typed, back to the last thing that is not part of one.
        var start = caret
        while start > 0 {
            let unit = ns.character(at: start - 1)
            guard let scalar = UnicodeScalar(unit),
                  isWordCharacter(Character(scalar)) else { break }
            start -= 1
        }
        let partial = ns.substring(with: NSRange(location: start, length: caret - start))
        let before = ns.substring(to: start)
        let candidates = expected(after: before)
        let fitting = candidates.filter {
            partial.isEmpty || $0.lowercased().hasPrefix(partial.lowercased())
        }
        return (NSRange(location: start, length: caret - start), fitting)
    }

    /// What may come after `before`, judged by its last tokens.
    static func expected(after before: String,
                         saved: [String] = FlatFilterStore.shared.names()) -> [String] {
        guard case .success(let tokens) = tokenize(before) else { return [] }
        let starting = primitives + saved + ["not", "("]
        guard let last = tokens.last else { return starting }
        let joining = ["and", "or", ",", ")"]
        let second = tokens.count > 1 ? tokens[tokens.count - 2] : nil

        switch last.kind {
        case .symbol:
            switch last.text {
            case "(":
                if second?.isWord("xattr") == true { return ["\""] }
                return starting
            case ")":
                // After xattr("…"): a comparison may follow, or nothing.
                return joining + ["=", "!=", "~", "!~"]
            case ",":
                return starting
            case "~", "!~":
                return ["/"]
            case "=", "!=":
                if let second, second.isWord("access") { return ["\"\(anyAccess)\""] }
                return ["\""]
            default:
                // < <= > >=, after size, created or modified.
                if second?.isWord("size") == true { return [] }
                return []
            }
        case .string, .regex:
            return joining
        case .word:
            switch last.lower {
            case "and", "or", "not":
                return starting
            case "true", "false":
                return joining
            case "size", "created", "modified":
                return Comparison.allCases.map(\.rawValue)
            case "name", "owner", "group":
                return ["=", "!=", "~", "!~"]
            case "access":
                return ["=", "!="]
            case "xattr":
                return ["("]
            case "contains", "content":
                return ["\"", "~", "/"]
            case "directory", "dir":
                return ["traversed", "listed"] + joining
            default:
                if second?.isWord("size") == true || (tokens.count > 2
                    && tokens[tokens.count - 3].isWord("size")), Double(last.text) != nil {
                    return units + joining
                }
                return joining
            }
        }
    }

    /// The hint for where the caret is: the keyword it is in or just after,
    /// or the nearest one before it.
    static func hint(in text: String, at caret: Int) -> String? {
        guard case .success(let tokens) = tokenize(text) else { return nil }
        let before = tokens.filter { $0.range.location <= caret }
        for token in before.reversed() where token.kind == .word {
            if let hint = hint(for: token.text) { return hint }
            if let saved = FlatFilterStore.shared.saved(token.text) {
                return "\(saved.name), saved: \(saved.expression)"
            }
        }
        return nil
    }
}

// MARK: - Where a date goes

nonisolated extension FlatQuery {

    /// Where a date belongs at `caret` -- after `created` or `modified` and
    /// a comparison -- as the range of the date already there (empty when
    /// there is none yet) and that date as written; nil anywhere else.
    static func dateSlot(in text: String, at caret: Int) -> (range: NSRange, written: String)? {
        let ns = text as NSString
        let caret = min(max(caret, 0), ns.length)
        func isWord(_ index: Int) -> Bool {
            guard let scalar = UnicodeScalar(ns.character(at: index)) else { return false }
            return isWordCharacter(Character(scalar))
        }
        var start = caret
        while start > 0, isWord(start - 1) { start -= 1 }
        var end = caret
        while end < ns.length, isWord(end) { end += 1 }
        guard case .success(let tokens) = tokenize(ns.substring(to: start)), tokens.count >= 2,
              let comparison = tokens.last, comparison.kind == .symbol,
              Comparison(rawValue: comparison.text) != nil,
              tokens[tokens.count - 2].isWord("created")
                || tokens[tokens.count - 2].isWord("modified") else { return nil }
        let range = NSRange(location: start, length: end - start)
        return (range, ns.substring(with: range))
    }

    /// A date as the expression writes it, in this Mac's time: the day
    /// alone, or with the minute when there is a time.
    static func written(_ date: Date, withTime: Bool, zone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = withTime ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Expanding a saved name

nonisolated extension FlatQuery {

    /// What a saved name is to be replaced with, to edit it in place: its
    /// expression, in parentheses unless it is one test and needs none --
    /// `not images` must stay the opposite of all of it. Nil for a text
    /// that is not a saved name.
    static func expansion(of selected: String,
                          saved: [String: String] = FlatFilterStore.shared.expressions())
        -> String? {
        let name = selected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !reservedWords.contains(name), let text = saved[name] else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .success(let tokens) = tokenize(trimmed), !tokens.isEmpty else {
            return "(\(trimmed))"
        }
        // One test needs no parentheses; anything joined does.
        let joined = tokens.contains { $0.isWord("and") || $0.isWord("or") || $0.isWord("not")
                                       || $0.is(",") }
        let wrapped = tokens.first!.is("(") && tokens.last!.is(")")
            && (try? parse(String(trimmed.dropFirst().dropLast()), saved: saved).get()) != nil
        return joined && !wrapped ? "(\(trimmed))" : trimmed
    }
}

// MARK: - Typing an access pattern

nonisolated extension FlatQuery {

    /// The nine places of the access pattern the caret is in -- the text
    /// between the quotes after `access =` -- when it is nine long; nil
    /// anywhere else, where typing is typing.
    static func accessPlaces(in text: String, at caret: Int) -> NSRange? {
        guard case .success(let tokens) = tokenize(text) else { return nil }
        for (index, token) in tokens.enumerated() where token.kind == .string && index >= 2 {
            guard tokens[index - 1].is("=") || tokens[index - 1].is("!="),
                  tokens[index - 2].isWord("access"),
                  token.text.count == 9, token.text.utf16.count == 9,
                  // Quoted: a bare word is not edited in place.
                  token.range.length == 11 else { continue }
            let places = NSRange(location: token.range.location + 1, length: 9)
            if caret >= places.location, caret <= NSMaxRange(places) { return places }
        }
        return nil
    }

    /// A key typed in an access pattern, as the pane's permission editor
    /// takes it -- r, w, x set the caret's three, Shift unsets, Option
    /// toggles; s and t the special bits; - + * and space the place under
    /// the caret, moving on -- with `*`, either, as a place of its own. The
    /// places and the caret after it; nil for a key that means nothing here.
    static func typeAccess(_ key: Character, in places: String, at caret: Int,
                           shift: Bool = false, option: Bool = false) -> (String, Int)? {
        var slots = Array(places)
        guard slots.count == 9 else { return nil }
        let letters: [Character] = ["r", "w", "x"]
        let triple = min(caret, 8) / 3

        func letter(_ index: Int) -> Character { letters[index % 3] }
        func set(_ index: Int, _ on: Character) {
            if option {
                slots[index] = slots[index] == on ? "-" : on
            } else {
                slots[index] = shift ? "-" : on
            }
        }

        switch Character(key.lowercased()) {
        case "r", "w", "x":
            let index = triple * 3 + letters.firstIndex(of: Character(key.lowercased()))!
            set(index, letter(index))
            return (String(slots), caret)
        case "s", "t":
            let special = Character(key.lowercased())
            guard (special == "s") == (triple < 2) else { return nil }
            let index = triple * 3 + 2
            // Unset, a special bit is not a clear execute bit: either.
            if option {
                slots[index] = slots[index] == special ? "*" : special
            } else {
                slots[index] = shift ? "*" : special
            }
            return (String(slots), caret)
        case "-", "+", "*", " ":
            guard caret < 9 else { return nil }
            switch key {
            case "-": slots[caret] = "-"
            case "+": slots[caret] = letter(caret)
            case "*": slots[caret] = "*"
            default:
                // Round the three: set, unset, either.
                slots[caret] = switch slots[caret] {
                case "-": "*"
                case "*": letter(caret)
                default: "-"
                }
            }
            return (String(slots), caret + 1)
        default:
            return nil
        }
    }
}
