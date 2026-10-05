import CryptoKit
import Foundation

/// The argument lines a program has been run with, for Run ▸ in the
/// right-click menu.
///
/// One small JSON file per program, in `~/.diptych/run-history/`, named by the
/// MD5 of the program's real path -- not one file for every program: someone
/// with hundreds of scripts should not have Diptych read and rewrite all of
/// their histories to run one of them. The full path is inside the file too,
/// so `grep` finds the one to edit by hand. What may be set by hand:
///
///     "limit": 5          this program's own limit, over the one in Settings
///     "unlimited": true   no limit for this program
///     "fixed": true       a list running never changes: no reordering, no
///                         new lines, no trimming -- for the order muscle
///                         memory has learned. Deleting still works.
///
/// The program carries the key in an extended attribute, which is how its
/// history follows it. Moved, it finds its old file by the attribute, and the
/// history moves to the new key; copied -- the old path still there -- the
/// copy takes its own copy of the history once, and from then on the two go
/// their separate ways. Without the attribute -- a volume that keeps none, or
/// it was removed -- a moved program simply starts a new history.
///
/// Reading never writes: opening a menu changes nothing, on disk or on the
/// program. The move or copy is carried out the first time the program is run.
struct RunHistory {

    struct File: Codable, Equatable {
        /// The layout of this file. Absent means the first one; it is written
        /// only once the layout changes, as 2.
        var version: Int?
        var path: String
        var fixed: Bool?
        var limit: Int?
        var unlimited: Bool?
        var entries: [Entry]

        struct Entry: Codable, Equatable {
            var arguments: String
            /// Variables the program was given, in the order written.
            var environment: [Variable]?
            /// Kept as a starting point: choosing it opens the arguments
            /// window filled in, rather than running at once. Never rolled off
            /// by the limit.
            var template: Bool?
            var lastRun: Date?

            struct Variable: Codable, Equatable, Hashable {
                var name: String
                var value: String
            }

            var variables: [Variable] { environment ?? [] }
            var isTemplate: Bool { template == true }

            /// The same run: arguments, variables and being a template alike.
            /// Two entries can show the same arguments and differ only in
            /// their variables.
            func isSameRun(as other: Entry) -> Bool {
                arguments == other.arguments && variables == other.variables
                    && isTemplate == other.isTemplate
            }
        }
    }

    static let xattrName = "dev.verhas.diptych.run-history"

    /// Where the files are.
    let directory: URL
    /// From Settings: how many lines a program keeps, nil for no limit. A
    /// program's own file can say otherwise.
    let defaultLimit: Int?

    // MARK: - Keys

    /// The path a history is kept under: symlinks resolved, so a link to a
    /// script and the script share one.
    static func canonicalPath(of program: URL) -> String {
        program.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func key(forPath path: String) -> String {
        Insecure.MD5.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func fileURL(forKey key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("json")
    }

    // MARK: - Reading

    func read(key: String) -> File? {
        guard let data = try? Data(contentsOf: fileURL(forKey: key)) else { return nil }
        return try? Self.decoder.decode(File.self, from: data)
    }

    /// The history to show for a program: its own, or -- if it was moved or
    /// copied -- the one its attribute points to. Nothing is written.
    func history(for program: URL) -> File? {
        let path = Self.canonicalPath(of: program)
        if let own = read(key: Self.key(forPath: path)) { return own }
        guard let inherited = inheritedKey(of: program, path: path),
              var file = read(key: inherited) else { return nil }
        file.path = path
        return file
    }

    func entries(for program: URL) -> [File.Entry] {
        history(for: program)?.entries ?? []
    }

    /// The key the program's attribute names, when it is not this path's own
    /// -- the program was moved or copied here.
    private func inheritedKey(of program: URL, path: String) -> String? {
        guard let data = ExtendedAttributes.data(of: program.path, name: Self.xattrName),
              let key = String(data: data, encoding: .utf8),
              key != Self.key(forPath: path),
              key.count == 32, key.allSatisfy(\.isHexDigit) else { return nil }
        return key
    }

    // MARK: - Writing

    /// The program's own file, taking over an inherited history first: moved,
    /// the old file goes; copied, it stays for the original.
    private func adopt(_ program: URL) -> (file: File, key: String) {
        let path = Self.canonicalPath(of: program)
        let key = Self.key(forPath: path)
        if let own = read(key: key) { return (own, key) }
        guard let oldKey = inheritedKey(of: program, path: path),
              var file = read(key: oldKey) else {
            return (File(path: path, entries: []), key)
        }
        let original = file.path
        file.path = path
        if !FileManager.default.fileExists(atPath: original) {
            try? FileManager.default.removeItem(at: fileURL(forKey: oldKey))
        }
        return (file, key)
    }

    /// A run: to the top of the list, or -- in a fixed list -- left out,
    /// unless it is a template, which is made on purpose. A run with neither
    /// arguments nor variables is not history.
    func record(_ arguments: String, environment: [File.Entry.Variable] = [],
                asTemplate: Bool = false, for program: URL, now: Date = Date()) {
        let line = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let variables = environment.filter { !$0.name.isEmpty }
        var (file, key) = adopt(program)
        let worthKeeping = asTemplate || !line.isEmpty || !variables.isEmpty
        if worthKeeping, file.fixed != true || asTemplate {
            let entry = File.Entry(arguments: line, environment: variables.isEmpty ? nil : variables,
                                   template: asTemplate ? true : nil, lastRun: now)
            file.entries.removeAll { $0.isSameRun(as: entry) }
            file.entries.insert(entry, at: 0)
            if let limit = limit(for: file) { file.entries = Self.trimmed(file.entries, to: limit) }
        }
        save(file, key: key, program: program)
    }

    /// The limit counts runs, not templates: a template stays until deleted.
    private static func trimmed(_ entries: [File.Entry], to limit: Int) -> [File.Entry] {
        var runs = 0
        return entries.filter { entry in
            if entry.isTemplate { return true }
            runs += 1
            return runs <= limit
        }
    }

    /// The ⌥-click Delete. Allowed in a fixed list too: it is an edit.
    func delete(_ entry: File.Entry, for program: URL) {
        var (file, key) = adopt(program)
        file.entries.removeAll { $0.isSameRun(as: entry) }
        save(file, key: key, program: program)
    }

    func delete(arguments: String, for program: URL) {
        delete(File.Entry(arguments: arguments), for: program)
    }

    /// The program's file, made if it has none yet, for editing by hand.
    func ensureFile(for program: URL) -> URL {
        let (file, key) = adopt(program)
        save(file, key: key, program: program)
        return fileURL(forKey: key)
    }

    private func limit(for file: File) -> Int? {
        if file.unlimited == true { return nil }
        if let own = file.limit { return own > 0 ? own : nil }
        return defaultLimit
    }

    private func save(_ file: File, key: String, program: URL) {
        // Every setting written out, with its value: someone opening the file
        // to edit it should see that a limit and a fixed order exist, not have
        // to know the names. The limit starts as Settings' at the moment the
        // file is first written; from then on it is this program's own.
        var file = file
        // The first layout is the absence of a version: an old file's "1" goes.
        if file.version == 1 { file.version = nil }
        if file.fixed == nil { file.fixed = false }
        if file.unlimited == nil { file.unlimited = file.limit == nil && defaultLimit == nil }
        if file.limit == nil { file.limit = defaultLimit ?? 10 }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? Self.encoder.encode(file) else { return }
        try? data.write(to: fileURL(forKey: key), options: .atomic)
        // How the history follows the program. Only written when it differs:
        // a change to the program's attributes is a change to the program.
        let current = ExtendedAttributes.data(of: program.path, name: Self.xattrName)
        if current != Data(key.utf8) {
            _ = ExtendedAttributes.set(Data(key.utf8), name: Self.xattrName, on: program.path)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Sorted, so the file's layout does not change from one write to the
        // next -- it is meant to be edited by hand and compared.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension RunHistory {
    /// The one in `~/.diptych`, with the limit Settings give.
    @MainActor
    static var shared: RunHistory {
        let configuration = ConfigStore.shared.configuration
        return RunHistory(
            directory: StateStore.directory.appendingPathComponent("run-history"),
            defaultLimit: configuration.runHistoryUnlimited
                ? nil : max(1, configuration.runHistoryLimit))
    }
}
