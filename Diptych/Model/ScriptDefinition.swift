import Foundation

/// What a script can be run on.
enum ScriptKind: String, Sendable, CaseIterable {
    case file, directory, link
}

/// One thing a script is about to be run on.
struct ScriptTarget: Sendable, Equatable {
    var url: URL
    var kind: ScriptKind
}

/// Something wrong with a script file, said in the words its author needs.
///
/// Reported rather than skipped. The whole point of this feature is that one
/// person writes the scripts and another uses them, so a script that silently
/// fails to appear is unfixable from the other end of a telephone.
struct ScriptProblem: Identifiable, Sendable, Equatable {
    var file: String
    var line: Int?
    var message: String
    var id: String { "\(file):\(line ?? 0):\(message)" }
}

/// A script, or a definition that calls one, out of `~/.diptych/scripts`.
///
/// The first line is skipped: it belongs to the shebang. The comment lines
/// after it say when the script applies and how to call it. Everything from
/// the first line that is not a comment is the script's own body.
struct ScriptDefinition: Identifiable, Sendable, Equatable {

    /// One piece of the command line, already separated.
    ///
    /// The template is split into these *before* anything is substituted, so a
    /// value can never become two arguments or an option. That is what makes
    /// the whole feature safe without a single quoting rule: no shell is
    /// involved at any point, and a file called `my notes (draft).txt` needs no
    /// thought from anybody.
    enum Token: Sendable, Equatable {
        case literal(String)
        /// `$0`: this file.
        case script
        /// `$1`, `$2`, ...: one selected item, counting from one.
        case argument(Int)
        /// `$@`: every selected item, one argument each.
        case everything
    }

    var url: URL
    var name: String
    var summary: String
    /// Lower-cased, without dots. Empty means any.
    var extensions: [String]
    var fewestItems: Int
    /// Nil means no upper limit.
    var mostItems: Int?
    var kinds: Set<ScriptKind>
    var call: [Token]
    /// Canonical folder paths the items must be *in*, and paths they must be
    /// at or under. Empty means anywhere.
    var onlyIn: [String]
    var onlyUnder: [String]
    var contents: String

    var id: String { url.path }

    /// A parsed value, or the sentence to show its author.
    private enum Parsed<Value> {
        case value(Value)
        case wrong(String)
    }

    // MARK: - Reading one

    static func read(_ url: URL, contents: String) -> (ScriptDefinition?, [ScriptProblem]) {
        var problems: [ScriptProblem] = []
        let name = url.lastPathComponent
        func complain(_ line: Int?, _ message: String) {
            problems.append(ScriptProblem(file: name, line: line, message: message))
        }

        let lines = contents.components(separatedBy: .newlines)
        var headers: [(key: String, value: String, line: Int)] = []

        // From the second line, because the first is the shebang, until the
        // first line that is not a comment. Everything from there is the body.
        for (offset, line) in lines.enumerated().dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard trimmed.hasPrefix("#") else { break }

            let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            guard let colon = body.firstIndex(of: ":") else { continue }
            let key = body[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.append((key, value, offset + 1))
        }

        var definition = ScriptDefinition(
            url: url, name: url.deletingPathExtension().lastPathComponent, summary: "",
            extensions: [], fewestItems: 1, mostItems: 1, kinds: Set(ScriptKind.allCases),
            call: [], onlyIn: [], onlyUnder: [], contents: contents)
        var sawArgs = false
        var sawCall = false

        for header in headers {
            switch header.key {
            case "name":
                definition.name = header.value
            case "description":
                definition.summary = header.value

            case "extensions":
                definition.extensions = list(header.value)
                    .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }

            case "apply-to":
                let kinds = list(header.value).compactMap { ScriptKind(rawValue: $0) }
                let unknown = list(header.value).filter { ScriptKind(rawValue: $0) == nil }
                for word in unknown {
                    complain(header.line, "\u{201C}\(word)\u{201D} is not one of file, "
                             + "directory or link.")
                }
                if !kinds.isEmpty { definition.kinds = Set(kinds) }

            case "args":
                sawArgs = true
                switch range(of: header.value) {
                case .value(let bounds):
                    definition.fewestItems = bounds.0
                    definition.mostItems = bounds.1
                case .wrong(let message):
                    complain(header.line, message)
                }

            case "call":
                sawCall = true
                switch tokens(of: header.value) {
                case .value(let parsed):
                    definition.call = parsed
                case .wrong(let message):
                    complain(header.line, message)
                }

            case "only-in":
                definition.onlyIn = list(header.value, lowercasing: false).map(canonical)
            case "only-under":
                definition.onlyUnder = list(header.value, lowercasing: false).map(canonical)

            default:
                // Reported rather than ignored, because "# extension:" for
                // "# extensions:" would otherwise do nothing at all and say
                // nothing about it.
                complain(header.line, "\u{201C}\(header.key)\u{201D} is not a setting Diptych "
                         + "knows. The ones it knows are name, description, extensions, "
                         + "apply-to, args, call, only-in and only-under.")
            }
        }

        if !sawArgs {
            definition.fewestItems = 1
            definition.mostItems = 1
        }
        if !sawCall {
            complain(nil, "There is no \u{201C}call:\u{201D} line, so Diptych does not know "
                     + "what to run.")
        }

        // A call that reaches past the most items it can ever be given would
        // fail every time it ran, and only then.
        if let most = definition.mostItems {
            for case .argument(let index) in definition.call where index > most {
                complain(nil, "The call uses $\(index), but this script is never given more "
                         + "than \(most) item\(most == 1 ? "" : "s").")
            }
        }

        return (problems.isEmpty ? definition : nil, problems)
    }

    private static func list(_ value: String, lowercasing: Bool = true) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { lowercasing ? $0.lowercased() : $0 }
    }

    private static func canonical(_ path: String) -> String {
        FileOperations.canonicalPath(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    /// "1,3", "2,", "4".
    private static func range(of value: String) -> Parsed<(Int, Int?)> {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        if parts.count == 1, let only = Int(parts[0]), only >= 0 {
            return .value((only, only))
        }
        guard parts.count == 2, let fewest = Int(parts[0]), fewest >= 0 else {
            return .wrong("\u{201C}\(value)\u{201D} is not a number of items. Write 1,3 for "
                            + "one to three, 2, for two or more, or 1 for exactly one.")
        }
        if parts[1].isEmpty { return .value((fewest, Int?.none)) }
        guard let most = Int(parts[1]), most >= fewest else {
            return .wrong("\u{201C}\(value)\u{201D} counts backwards or is not a number.")
        }
        return .value((fewest, most))
    }

    /// Split first, substitute later.
    private static func tokens(of value: String) -> Parsed<[Token]> {
        var tokens: [Token] = []
        for word in value.split(separator: " ").map(String.init) where !word.isEmpty {
            if word == "$0" { tokens.append(.script) }
            else if word == "$@" { tokens.append(.everything) }
            else if word == "$*" {
                // Refused rather than accepted quietly. In a shell `$*` joins
                // the paths into one argument, which is precisely the thing
                // that breaks on a space -- and the thing this design exists to
                // make impossible.
                return .wrong("Use $@ rather than $*. $@ passes each item as its own "
                                + "argument, which is what keeps names with spaces in them "
                                + "working.")
            } else if word.hasPrefix("$"), let index = Int(word.dropFirst()), index > 0 {
                tokens.append(.argument(index))
            } else {
                tokens.append(.literal(word))
            }
        }
        guard !tokens.isEmpty else { return .wrong("The call line is empty.") }
        return .value(tokens)
    }

    // MARK: - Whether it applies

    /// Whether this script should be offered for exactly these items.
    ///
    /// Every item has to qualify. A selection of three where one is the wrong
    /// kind is not two-thirds applicable; it is a script that would do
    /// something unintended to one of them.
    func applies(to targets: [ScriptTarget]) -> Bool {
        guard targets.count >= fewestItems else { return false }
        if let mostItems, targets.count > mostItems { return false }

        for target in targets {
            guard kinds.contains(target.kind) else { return false }
            if !extensions.isEmpty {
                let suffix = target.url.pathExtension.lowercased()
                guard extensions.contains(suffix) else { return false }
            }
            guard isInScope(target.url) else { return false }
        }
        return true
    }

    /// Where the script is allowed to be used.
    ///
    /// Scoping, not sandboxing: it stops a script being aimed at the wrong
    /// folder by accident. A script that wanted to ignore it could, since by
    /// then it is running.
    func isInScope(_ url: URL) -> Bool {
        guard !onlyIn.isEmpty || !onlyUnder.isEmpty else { return true }
        let folder = FileOperations.canonicalPath(url.deletingLastPathComponent())
        if onlyIn.contains(folder) { return true }
        let path = FileOperations.canonicalPath(url)
        return onlyUnder.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    // MARK: - The command

    /// The command line, with every placeholder replaced.
    ///
    /// Each token becomes exactly one argument, whatever is in it.
    func command(for targets: [ScriptTarget], script: URL) -> [String] {
        var arguments: [String] = []
        for token in call {
            switch token {
            case .literal(let text):
                arguments.append(text)
            case .script:
                arguments.append(script.path)
            case .argument(let index):
                if targets.indices.contains(index - 1) {
                    arguments.append(targets[index - 1].url.path)
                }
            case .everything:
                arguments.append(contentsOf: targets.map(\.url.path))
            }
        }
        return arguments
    }
}
