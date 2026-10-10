import Foundation

/// Flat view expressions saved under a name, to use instead of an
/// expression or as part of one: `images and size > 1MB`.
///
/// One JSON file each, in `~/.diptych/filters`, holding the expression and
/// every version it had before, newest first -- so an older one can be put
/// back by editing the file, and Undo puts back the one before a save.
/// Names are read without regard to case, as keywords are.
nonisolated final class FlatFilterStore: @unchecked Sendable {

    static let shared = FlatFilterStore(directory: FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent(".diptych/filters"))

    struct Version: Codable, Equatable, Sendable {
        var expression: String
        var saved: Date
    }

    struct Saved: Codable, Equatable, Sendable {
        var name: String
        var expression: String
        var saved: Date
        /// What it was before, newest first.
        var history: [Version] = []
    }

    /// Saved expressions have gone -- deleted, or a first save undone --
    /// and others used them. User info: `gone` and `broken`, names.
    static let lost = Notification.Name("diptych.savedExpressionsLost")

    /// A file in the folder that is not used: its name is not one an
    /// expression can use -- a word the language took for itself since it
    /// was saved, say -- or it is not a saved expression at all.
    struct Ignored: Equatable, Sendable {
        /// Nil for a file that could not be read as one.
        let name: String?
        let path: String
        let reason: String
    }

    /// Files found ignored that `takeIgnored()` has not handed out yet.
    static let ignoredFound = Notification.Name("diptych.savedExpressionsIgnored")

    let directory: URL
    private let lock = NSLock()
    private var cache: [String: Saved] = [:]
    private var readAt = Date.distantPast
    /// Read at least once: until then nothing can have gone.
    private var known = false
    private var watcher: DispatchSourceFileSystemObject?
    /// Each ignored file is told about once while Diptych runs -- again
    /// only after it is mended and broken anew.
    private var told: Set<String> = []
    private var untold: [Ignored] = []

    init(directory: URL) {
        self.directory = directory
    }

    /// Every saved expression, by name in lower case. Read from the disk
    /// again at most once a second, so a file edited by hand counts soon.
    func expressions() -> [String: String] {
        all().mapValues(\.expression)
    }

    func names() -> [String] {
        all().values.map(\.name).sorted { $0.lowercased() < $1.lowercased() }
    }

    func saved(_ name: String) -> Saved? {
        all()[name.lowercased()]
    }

    private func all() -> [String: Saved] {
        lock.lock()
        var gone: [String] = []
        var newlyIgnored = false
        if Date().timeIntervalSince(readAt) > 1 {
            let (fresh, ignored) = Self.read(directory)
            let keys = Set(ignored.map { $0.path + "\u{0}" + ($0.name ?? "") })
            for item in ignored where !told.contains(item.path + "\u{0}" + (item.name ?? "")) {
                untold.append(item)
                newlyIgnored = true
            }
            told = keys
            if known {
                gone = cache.filter { fresh[$0.key] == nil }.map(\.value.name).sorted()
            }
            cache = fresh
            readAt = Date()
            known = true
        }
        let current = cache
        lock.unlock()
        if !gone.isEmpty { tell(gone: gone, current) }
        if newlyIgnored {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.ignoredFound, object: nil)
            }
        }
        return current
    }

    /// The files found ignored since last asked, read afresh first.
    func takeIgnored() -> [Ignored] {
        forget()
        _ = all()
        lock.lock()
        defer { lock.unlock() }
        let taken = untold
        untold = []
        return taken
    }

    /// Which of the rest no longer work for it, said to whoever listens.
    private func tell(gone: [String], _ current: [String: Saved]) {
        let broken = Self.broken(current)
        guard !broken.isEmpty else { return }
        let info: [String: [String]] = ["gone": gone, "broken": broken]
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.lost, object: nil, userInfo: info)
        }
    }

    /// The saved expressions that use one no longer saved, directly or
    /// through another.
    static func broken(_ saved: [String: Saved]) -> [String] {
        let expressions = saved.mapValues(\.expression)
        return saved.values.filter { item in
            // By its name, as a use of it would be: what it uses is then
            // known to have been saved once.
            if case .failure(let problem) = FlatQuery.parse(item.name, saved: expressions) {
                return problem.missing != nil
            }
            return false
        }.map(\.name).sorted { $0.lowercased() < $1.lowercased() }
    }

    /// The saved expressions that use `name` -- directly, or through
    /// another that does -- which a change to it changes too.
    func users(of name: String) -> [String] {
        let saved = all()
        let words = saved.mapValues { item -> Set<String> in
            guard case .success(let tokens) = FlatQuery.tokenize(item.expression) else { return [] }
            return Set(tokens.filter { $0.kind == .word }.map(\.lower))
        }
        var found: Set<String> = []
        var looking: [String] = [name.lowercased()]
        while let next = looking.popLast() {
            for (key, used) in words where used.contains(next) && !found.contains(key)
                && key != name.lowercased() {
                found.insert(key)
                looking.append(key)
            }
        }
        return found.compactMap { saved[$0]?.name }.sorted { $0.lowercased() < $1.lowercased() }
    }

    /// The folder watched, so a file deleted from it is noticed at once and
    /// not when an expression next asks. Once, for the shared store.
    func watch() {
        lock.lock()
        defer { lock.unlock() }
        guard watcher == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .global())
        source.setEventHandler { [weak self] in
            self?.forget()
            _ = self?.all()
        }
        source.setCancelHandler { close(fd) }
        watcher = source
        source.resume()
        // What is there now is what a later loss is measured against.
        readAt = .distantPast
    }

    static func read(_ directory: URL) -> (found: [String: Saved], ignored: [Ignored]) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        var found: [String: Saved] = [:]
        var ignored: [Ignored] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files.sorted(by: { $0.path < $1.path }) where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let saved = try? decoder.decode(Saved.self, from: data) else {
                ignored.append(Ignored(name: nil, path: file.path,
                                       reason: "It cannot be read as a saved expression"))
                continue
            }
            if let problem = problem(with: saved.name) {
                ignored.append(Ignored(name: saved.name, path: file.path, reason: problem))
                continue
            }
            found[saved.name.lowercased()] = saved
        }
        return (found, ignored)
    }

    /// Where a name's file is: its own name, or the one already saved under
    /// it in other letters.
    func file(for name: String) -> URL {
        let existing = saved(name)?.name ?? name
        return directory.appendingPathComponent(existing + ".json")
    }

    /// Saved under `name`, the old expression kept as the newest of the
    /// older versions. What the file held before -- nil when there was none
    /// -- for Undo.
    @discardableResult
    func save(_ expression: String, as name: String, at now: Date = Date()) throws -> Data? {
        let url = file(for: name)
        let before = try? Data(contentsOf: url)
        var saved = Saved(name: name, expression: expression, saved: now)
        if let old = self.saved(name) {
            saved.name = old.name
            saved.history = [Version(expression: old.expression, saved: old.saved)] + old.history
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encode(saved).write(to: url, options: .atomic)
        forget()
        return before
    }

    /// Puts a file back as it was -- or away, for nil -- and says what it
    /// held, for the way back again.
    @discardableResult
    func putBack(_ data: Data?, at url: URL) throws -> Data? {
        let now = try? Data(contentsOf: url)
        if let data {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } else if now != nil {
            try FileManager.default.removeItem(at: url)
        }
        forget()
        return now
    }

    func forget() {
        lock.lock()
        readAt = .distantPast
        lock.unlock()
    }

    static func encode(_ saved: Saved) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(saved)
    }

    // MARK: - Names

    /// A name an expression can use as a word: a letter, then letters,
    /// digits, `_` or `-`, and not one of the language's own words.
    static func isUsable(_ name: String) -> Bool {
        problem(with: name) == nil
    }

    static func problem(with name: String) -> String? {
        guard let first = name.first else { return "A name is needed" }
        guard first.isASCII, first.isLetter,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_"
                                               || $0 == "-") }) else {
            return "A name is a letter, then letters, digits, _ or -"
        }
        guard !FlatQuery.reservedWords.contains(name.lowercased()) else {
            return "\u{201C}\(name)\u{201D} is a word of the expression language itself"
        }
        return nil
    }
}
