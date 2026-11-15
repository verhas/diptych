import Foundation

/// A TextMate grammar, its rules made from its JSON as they are first needed:
/// a large grammar -- C++'s is 680 KB -- is mostly rules a given file never
/// reaches.
nonisolated final class TextMateGrammar: @unchecked Sendable {

    let scopeName: String
    let root: TextMateRule
    let registry: TextMateRegistry?
    fileprivate let repository: TextMateRepository

    init(json: [String: Any], registry: TextMateRegistry?) {
        scopeName = json["scopeName"] as? String ?? ""
        self.registry = registry
        repository = TextMateRepository(raw: json["repository"] as? [String: Any] ?? [:], parent: nil)
        root = TextMateRule(placeholder: ())
        root.grammar = self
        root.repository = repository
        root.rawPatterns = json["patterns"] as? [[String: Any]] ?? []
    }

    convenience init?(data: Data, registry: TextMateRegistry?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        self.init(json: json, registry: registry)
    }

    /// The rule a repository entry of this grammar names.
    func repositoryRule(_ name: String) -> TextMateRule? {
        repository.rule(name, grammar: self)
    }
}

/// The rules a `repository` names, made when first asked for; a nested one
/// sees its own entries first, then its parents'.
nonisolated final class TextMateRepository: @unchecked Sendable {
    private let raw: [String: Any]
    let parent: TextMateRepository?
    private var made: [String: TextMateRule] = [:]
    private let lock = NSLock()

    init(raw: [String: Any], parent: TextMateRepository?) {
        self.raw = raw
        self.parent = parent
    }

    func rule(_ name: String, grammar: TextMateGrammar) -> TextMateRule? {
        lock.lock()
        if let known = made[name] { lock.unlock(); return known }
        guard let entry = raw[name] as? [String: Any] else {
            lock.unlock()
            return parent?.rule(name, grammar: grammar)
        }
        let rule = TextMateRule(json: entry, grammar: grammar, repository: self)
        made[name] = rule
        lock.unlock()
        return rule
    }
}

/// One rule: a match, a begin/end or begin/while region, an include, or just
/// a list of patterns.
nonisolated final class TextMateRule: @unchecked Sendable {

    struct Capture {
        var name: String?
        var patterns: [[String: Any]]
    }

    weak var grammar: TextMateGrammar?
    var repository: TextMateRepository?

    var name: String?
    var contentName: String?
    var match: TextMateRegex?
    var begin: TextMateRegex?
    var endSource: String?
    var whileSource: String?
    var end: TextMateRegex?
    var whileRegex: TextMateRegex?
    var endHasBackReferences = false
    var whileHasBackReferences = false
    var captures: [Int: Capture] = [:]
    var beginCaptures: [Int: Capture] = [:]
    var endCaptures: [Int: Capture] = [:]
    var whileCaptures: [Int: Capture] = [:]
    var applyEndPatternLast = false
    var include: String?
    var rawPatterns: [[String: Any]] = []

    private var children: [TextMateRule]?
    /// By the grammar `$base` is: an embedded grammar's rules lead back to
    /// the document's.
    private var flattened: [ObjectIdentifier?: [TextMateRule]] = [:]
    private var captureRules: [String: TextMateRule] = [:]
    private let lock = NSRecursiveLock()

    fileprivate init(placeholder: Void) {}

    init(json: [String: Any], grammar: TextMateGrammar, repository: TextMateRepository) {
        self.grammar = grammar
        // A rule's own repository is seen by its patterns, before the outer ones.
        if let own = json["repository"] as? [String: Any] {
            self.repository = TextMateRepository(raw: own, parent: repository)
        } else {
            self.repository = repository
        }
        name = json["name"] as? String
        contentName = json["contentName"] as? String
        include = json["include"] as? String
        if let source = json["match"] as? String { match = TextMateRegex(source) }
        if let source = json["begin"] as? String { begin = TextMateRegex(source) }
        if let source = json["end"] as? String {
            endSource = source
            endHasBackReferences = TextMateRegex.hasBackReferences(source)
            if !endHasBackReferences { end = TextMateRegex(source) }
        }
        if let source = json["while"] as? String {
            whileSource = source
            whileHasBackReferences = TextMateRegex.hasBackReferences(source)
            if !whileHasBackReferences { whileRegex = TextMateRegex(source) }
        }
        captures = Self.captures(json["captures"])
        beginCaptures = Self.captures(json["beginCaptures"])
        endCaptures = Self.captures(json["endCaptures"])
        whileCaptures = Self.captures(json["whileCaptures"])
        // A begin/end rule without begin- or end-captures uses `captures` for both.
        if begin != nil, !captures.isEmpty {
            if beginCaptures.isEmpty { beginCaptures = captures }
            if endCaptures.isEmpty, endSource != nil { endCaptures = captures }
            if whileCaptures.isEmpty, whileSource != nil { whileCaptures = captures }
        }
        applyEndPatternLast = (json["applyEndPatternLast"] as? Bool) ?? ((json["applyEndPatternLast"] as? Int) == 1)
        rawPatterns = json["patterns"] as? [[String: Any]] ?? []
    }

    private static func captures(_ value: Any?) -> [Int: Capture] {
        var found: [Int: Capture] = [:]
        if let dictionary = value as? [String: Any] {
            for (key, entry) in dictionary {
                guard let index = Int(key), let entry = entry as? [String: Any] else { continue }
                found[index] = Capture(name: entry["name"] as? String,
                                       patterns: entry["patterns"] as? [[String: Any]] ?? [])
            }
        } else if let array = value as? [Any] {
            // Some grammars give captures as an array, by position.
            for (index, entry) in array.enumerated() {
                guard let entry = entry as? [String: Any] else { continue }
                found[index] = Capture(name: entry["name"] as? String,
                                       patterns: entry["patterns"] as? [[String: Any]] ?? [])
            }
        }
        return found
    }

    var isRegion: Bool { begin != nil }

    /// The rules this rule's patterns are, includes not yet followed.
    func patterns() -> [TextMateRule] {
        lock.lock(); defer { lock.unlock() }
        if let children { return children }
        guard let grammar, let repository else { return [] }
        let made = rawPatterns.map { TextMateRule(json: $0, grammar: grammar, repository: repository) }
        children = made
        return made
    }

    /// The rules that can match inside this one, in order: every include
    /// followed, every plain list of patterns opened, to rules that match or
    /// begin. `base` is the grammar the document is in, for `$base`.
    func candidates(base: TextMateGrammar?) -> [TextMateRule] {
        let key = base.map(ObjectIdentifier.init)
        lock.lock()
        if let known = flattened[key] { lock.unlock(); return known }
        lock.unlock()
        var out: [TextMateRule] = []
        var seen = Set<ObjectIdentifier>()
        Self.collect(patterns(), base: base, into: &out, seen: &seen, depth: 0)
        lock.lock()
        flattened[key] = out
        lock.unlock()
        return out
    }

    /// The patterns a capture applies to the text it captured, as a rule of
    /// their own, seeing this rule's repository.
    func captureRule(_ capture: Capture, key: String) -> TextMateRule? {
        guard !capture.patterns.isEmpty, let grammar, let repository else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let known = captureRules[key] { return known }
        let rule = TextMateRule(json: ["patterns": capture.patterns], grammar: grammar, repository: repository)
        captureRules[key] = rule
        return rule
    }

    private static func collect(_ rules: [TextMateRule], base: TextMateGrammar?, into out: inout [TextMateRule],
                                seen: inout Set<ObjectIdentifier>, depth: Int) {
        guard depth < 40 else { return }
        for rule in rules {
            if let include = rule.include {
                guard let target = rule.resolve(include, base: base) else { continue }
                // A rule reached twice the same way would only match the same.
                guard seen.insert(ObjectIdentifier(target)).inserted else { continue }
                if target.match != nil || target.begin != nil {
                    out.append(target)
                } else {
                    collect(target.patterns(), base: base, into: &out, seen: &seen, depth: depth + 1)
                }
            } else if rule.match != nil || rule.begin != nil {
                out.append(rule)
            } else {
                collect(rule.patterns(), base: base, into: &out, seen: &seen, depth: depth + 1)
            }
        }
    }

    /// The rule an `include` names: `#name` in the repositories seen from
    /// here, `$self` and `$base`, another grammar by its scope, or
    /// `scope#name` in that grammar's repository.
    func resolve(_ include: String, base: TextMateGrammar?) -> TextMateRule? {
        if include.hasPrefix("#") {
            guard let grammar else { return nil }
            return repository?.rule(String(include.dropFirst()), grammar: grammar)
        }
        if include == "$self" { return grammar?.root }
        if include == "$base" { return (base ?? grammar)?.root }
        let parts = include.split(separator: "#", maxSplits: 1).map(String.init)
        guard let other = grammar?.registry?.grammar(scope: parts[0]) else { return nil }
        return parts.count == 2 ? other.repositoryRule(parts[1]) : other.root
    }
}

/// The grammars Diptych ships (`make-grammars.sh`), and which one a file is
/// coloured with: by its name, its extension, or its first line.
nonisolated final class TextMateRegistry: @unchecked Sendable {

    static let shared = TextMateRegistry(bundle: .main)

    struct Language: Sendable {
        let id: String
        let name: String
        let extensions: [String]
        let filenames: [String]
        let firstLine: NSRegularExpression?
        let scope: String
    }

    private(set) var languages: [Language] = []
    private var byExtension: [String: Language] = [:]
    private var byFilename: [String: Language] = [:]
    private var scopes: Set<String> = []
    private var loaded: [String: TextMateGrammar] = [:]
    private let lock = NSLock()
    private let load: (String) -> Data?

    /// From a folder holding `Grammars.json` and the grammars beside it.
    init(manifest: Data?, load: @escaping (String) -> Data?) {
        self.load = load
        guard let manifest, let json = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any] else { return }
        let grammars = json["grammars"] as? [[String: Any]] ?? []
        var scopeOf: [String: String] = [:]
        for grammar in grammars {
            guard let scope = grammar["scope"] as? String else { continue }
            scopes.insert(scope)
            if let language = grammar["language"] as? String, scopeOf[language] == nil { scopeOf[language] = scope }
        }
        for entry in json["languages"] as? [[String: Any]] ?? [] {
            guard let id = entry["id"] as? String, let scope = scopeOf[id] else { continue }
            let language = Language(
                id: id, name: (entry["names"] as? [String])?.first ?? id,
                extensions: entry["extensions"] as? [String] ?? [],
                filenames: entry["filenames"] as? [String] ?? [],
                firstLine: (entry["firstLine"] as? String).flatMap { try? NSRegularExpression(pattern: TextMateRegex.translate($0)) },
                scope: scope)
            languages.append(language)
            for ext in language.extensions where byExtension[ext] == nil { byExtension[ext] = language }
            for name in language.filenames where byFilename[name] == nil { byFilename[name] = language }
        }
    }

    convenience init(bundle: Bundle) {
        self.init(manifest: bundle.url(forResource: "Grammars", withExtension: "json").flatMap { try? Data(contentsOf: $0) },
                  load: { scope in bundle.url(forResource: scope, withExtension: "json").flatMap { try? Data(contentsOf: $0) } })
    }

    var isEmpty: Bool { languages.isEmpty }

    /// The language of a file: its whole name (`Makefile`, `Dockerfile`),
    /// then its extension -- the longest that is known, so `d.ts` before
    /// `ts` -- then its first line (`#!/usr/bin/env python3`).
    func language(for url: URL, firstLine: String? = nil) -> Language? {
        let name = url.lastPathComponent
        if let known = byFilename[name] { return known }
        let lower = name.lowercased()
        var dot = lower.firstIndex(of: ".")
        while let at = dot {
            let ext = String(lower[lower.index(after: at)...])
            if let known = byExtension[ext] { return known }
            dot = lower[lower.index(after: at)...].firstIndex(of: ".")
        }
        if let firstLine {
            let range = NSRange(firstLine.startIndex..., in: firstLine)
            for language in languages where language.firstLine?.firstMatch(in: firstLine, range: range) != nil {
                return language
            }
        }
        return nil
    }

    func language(id: String) -> Language? { languages.first { $0.id == id } }

    func grammar(scope: String) -> TextMateGrammar? {
        lock.lock()
        if let known = loaded[scope] { lock.unlock(); return known }
        lock.unlock()
        guard scopes.contains(scope), let data = load(scope),
              let grammar = TextMateGrammar(data: data, registry: self) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let raced = loaded[scope] { return raced }
        loaded[scope] = grammar
        return grammar
    }
}
