import Foundation
import SQLite3

/// What Diptych did, kept for months: every file operation, every undo and
/// redo, every run -- in `~/.diptych/journal.sqlite`, the person's alone
/// (0600), searchable by any word of what was done or of a path touched.
///
/// Not the undo history. That lives in memory and ends when Diptych quits;
/// this outlives it, and so never offers to reverse anything -- weeks later
/// the files have moved on. A row can show where things were and went.
///
/// One row per operation, one more per file it touched: a 500-file copy is
/// one entry that opens up to its files. Written on a queue of its own, so
/// recording never holds up the window that did the work.
nonisolated final class Journal: @unchecked Sendable {

    /// A test run writes to a journal of its own, never the person's.
    static let shared = Journal(url: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        ? Journal.url
        : FileManager.default.temporaryDirectory
            .appendingPathComponent("diptych-test-journal-\(ProcessInfo.processInfo.processIdentifier).sqlite"))
    /// `StateStore.directory`'s, spelled out: that one belongs to the main actor.
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".diptych/journal.sqlite")

    /// Who an operation was done for. A task-local, so a batch an agent
    /// proposed is credited to the agent all the way down to the
    /// `FileHistory` call it ends in, whatever else runs meanwhile.
    enum Origin: String, Sendable, CaseIterable, Codable {
        case you, agent, shortcuts, undo, redo, run

        var title: String {
            switch self {
            case .you: "You"
            case .agent: "Agent (MCP)"
            case .shortcuts: "Siri/Shortcuts"
            case .undo: "Undo"
            case .redo: "Redo"
            case .run: "Run"
            }
        }
    }

    @TaskLocal static var origin: Origin = .you

    /// What sort of thing an entry records. Each can be left out of the
    /// journal in Settings; none is by default.
    enum Category: String, Sendable, CaseIterable, Codable {
        /// Files made, changed, moved, renamed, deleted -- here or on a server.
        case change
        /// A file's contents read: opened, looked at in Quick Look, copied.
        case content
        /// Names and details read: a folder listed, files selected, Info.
        case attributes
        /// How the files are shown: a view, a sort, a filter, a pane, a tab.
        case navigation
        /// A setting changed.
        case settings
        /// A window opened or closed.
        case window
        /// A script or a command run.
        case run
        /// Diptych started or quit.
        case app
        /// An agent or Siri/Shortcuts asked Diptych for something.
        case request

        var title: String {
            switch self {
            case .change: "File Changes"
            case .content: "Contents Read"
            case .attributes: "Names and Details Read"
            case .navigation: "Navigation"
            case .settings: "Settings"
            case .window: "Windows"
            case .run: "Runs"
            case .app: "Diptych Started or Quit"
            case .request: "Agent and Shortcuts Requests"
            }
        }

        /// What each held before categories were kept, by kind.
        static func of(kind: String) -> Category {
            switch kind {
            case "Open", "Quick Look": .content
            case "Open Folder", "Select": .attributes
            case "Run": .run
            default: .change
            }
        }
    }

    /// One file of an entry: where it was and where it is. A file made has
    /// no `before`; a file changed in place has both the same.
    struct File: Sendable, Equatable, Codable {
        var before: String?
        var after: String?

        var path: String { after ?? before ?? "" }
    }

    struct Entry: Sendable, Identifiable, Equatable, Codable {
        var id: Int64
        var time: Date
        /// "Copy", "Move", "Undo Move", "Run" -- the menu's word for it.
        var kind: String
        var category: Category
        var origin: Origin
        /// The sentence Undo would ask about: "draft.txt" was renamed to
        /// "final.txt" in "~/Documents".
        var told: String
        /// The folder most of it happened in, as a path.
        var folder: String?
        var count: Int
        /// done, failed, partly.
        var outcome: String
    }

    struct Stats: Sendable, Equatable, Codable {
        struct Count: Sendable, Equatable, Codable {
            var name: String
            var entries: Int
            var files: Int
        }
        var entries = 0
        var files = 0
        var first: Date?
        var last: Date?
        var byKind: [Count] = []
        var byCategory: [Count] = []
        var byOrigin: [Count] = []
        var byDay: [Count] = []
        var folders: [Count] = []
    }

    struct Query: Sendable, Equatable {
        /// Words, each found as the start of a word in the sentence, the
        /// kind or any path. Empty: everything.
        var text = ""
        var from: Date?
        var to: Date?
        var kinds: [String] = []
        var categories: [Category] = []
        var origins: [Origin] = []
        /// Entries that touched something inside this folder.
        var folder: String?
        var limit = 200
    }

    private let queue = DispatchQueue(label: "Diptych.Journal")
    private var db: OpaquePointer?
    let location: URL

    /// Told about each entry once it is written -- what Spotlight mirrors.
    /// Called on the journal's queue.
    var onRecord: (@Sendable (Entry, [File]) -> Void)?
    /// Told about entries purged or deleted, by id; nil for all of them.
    var onDelete: (@Sendable ([Int64]?) -> Void)?

    init(url: URL = Journal.url) {
        location = url
        queue.sync { open() }
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Recording

    /// From the main actor, where every operation ends. Off in Settings, or
    /// its category left out: nothing is written.
    @MainActor
    func record(kind: String, category: Category = .change, told: String, files: [File] = [],
                origin: Origin = Journal.origin, outcome: String = "done", folder: String? = nil,
                at time: Date = Date()) {
        guard Self.isRecording(category) else { return }
        write(kind: kind, category: category, told: told, files: files, origin: origin,
              outcome: outcome, folder: folder, at: time)
    }

    /// Whether entries of this category are being written now.
    @MainActor
    static func isRecording(_ category: Category) -> Bool {
        let configuration = ConfigStore.shared.configuration
        return configuration.journalEnabled && !configuration.journalLeftOut.contains(category.rawValue)
    }

    /// Unconditional, for tests and for `record`.
    func write(kind: String, category: Category = .change, told: String, files: [File],
               origin: Origin, outcome: String = "done", folder: String? = nil,
               at time: Date = Date()) {
        let folder = folder ?? Self.folder(of: files)
        queue.async { [self] in
            guard let db else { return }
            sqlite3_exec(db, "BEGIN", nil, nil, nil)
            let id = insertEntry(time: time, kind: kind, category: category, origin: origin, told: told,
                                 folder: folder, count: files.count, outcome: outcome)
            guard id > 0 else { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); return }
            for file in files { insertFile(id, file) }
            let paths = files.flatMap { [$0.before, $0.after].compactMap { $0 } }
            run("INSERT INTO search(rowid, told, kind, paths) VALUES (?, ?, ?, ?)",
                .int(id), .text(told), .text(kind), .text(Set(paths).sorted().joined(separator: "\n")))
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
            onRecord?(Entry(id: id, time: time, kind: kind, category: category, origin: origin, told: told,
                            folder: folder, count: files.count, outcome: outcome), files)
            Self.changed()
        }
    }

    /// Waits for every write sent so far -- for tests, and before reading
    /// what was just recorded.
    func flush() { queue.sync {} }

    /// Posted on the main thread after anything is written or deleted.
    static let didChange = Notification.Name("DiptychJournalDidChange")

    private static func changed() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    // MARK: - Reading

    func search(_ query: Query) -> [Entry] {
        queue.sync {
            var clauses: [String] = []
            var values: [Value] = []
            if let match = Self.match(query.text) {
                clauses.append("e.id IN (SELECT rowid FROM search WHERE search MATCH ?)")
                values.append(.text(match))
            }
            if let from = query.from {
                clauses.append("e.time >= ?")
                values.append(.real(from.timeIntervalSince1970))
            }
            if let to = query.to {
                clauses.append("e.time < ?")
                values.append(.real(to.timeIntervalSince1970))
            }
            if !query.kinds.isEmpty {
                clauses.append("e.kind IN (\(query.kinds.map { _ in "?" }.joined(separator: ", ")))")
                values += query.kinds.map { .text($0) }
            }
            if !query.categories.isEmpty {
                clauses.append("e.category IN (\(query.categories.map { _ in "?" }.joined(separator: ", ")))")
                values += query.categories.map { .text($0.rawValue) }
            }
            if !query.origins.isEmpty {
                clauses.append("e.origin IN (\(query.origins.map { _ in "?" }.joined(separator: ", ")))")
                values += query.origins.map { .text($0.rawValue) }
            }
            if let folder = query.folder.map(Self.withoutSlash) {
                clauses.append("""
                    (e.folder = ? OR e.folder LIKE ? ESCAPE '\\' OR e.id IN (SELECT entry FROM files
                     WHERE before = ? OR after = ? OR before LIKE ? ESCAPE '\\'
                     OR after LIKE ? ESCAPE '\\'))
                    """)
                let under = Self.like(folder) + "/%"
                values += [.text(folder), .text(under), .text(folder), .text(folder),
                           .text(under), .text(under)]
            }
            let sql = "SELECT e.id, e.time, e.kind, e.origin, e.told, e.folder, e.count, e.outcome, e.category "
                + "FROM entries e"
                + (clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND "))
                + " ORDER BY e.time DESC, e.id DESC LIMIT \(max(1, query.limit))"
            return rows(sql, values) { statement in
                Entry(id: sqlite3_column_int64(statement, 0),
                      time: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                      kind: Self.text(statement, 2) ?? "",
                      category: Category(rawValue: Self.text(statement, 8) ?? "") ?? .change,
                      origin: Origin(rawValue: Self.text(statement, 3) ?? "") ?? .you,
                      told: Self.text(statement, 4) ?? "",
                      folder: Self.text(statement, 5),
                      count: Int(sqlite3_column_int64(statement, 6)),
                      outcome: Self.text(statement, 7) ?? "done")
            }
        }
    }

    func files(of id: Int64) -> [File] {
        queue.sync {
            rows("SELECT before, after FROM files WHERE entry = ? ORDER BY rowid", [.int(id)]) {
                File(before: Self.text($0, 0), after: Self.text($0, 1))
            }
        }
    }

    /// The kinds recorded so far, for the window's filter.
    func kinds() -> [String] {
        queue.sync {
            rows("SELECT DISTINCT kind FROM entries ORDER BY kind", []) { Self.text($0, 0) ?? "" }
        }
    }

    func stats(from: Date? = nil, to: Date? = nil, folders limit: Int = 10) -> Stats {
        queue.sync {
            var clauses: [String] = []
            var values: [Value] = []
            if let from { clauses.append("time >= ?"); values.append(.real(from.timeIntervalSince1970)) }
            if let to { clauses.append("time < ?"); values.append(.real(to.timeIntervalSince1970)) }
            let filter = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
            var stats = Stats()
            _ = rows("SELECT COUNT(*), COALESCE(SUM(count), 0), MIN(time), MAX(time) FROM entries"
                     + filter, values) { statement in
                stats.entries = Int(sqlite3_column_int64(statement, 0))
                stats.files = Int(sqlite3_column_int64(statement, 1))
                if sqlite3_column_type(statement, 2) != SQLITE_NULL {
                    stats.first = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                    stats.last = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                }
            }
            func counts(_ column: String, order: String, limit: Int? = nil) -> [Stats.Count] {
                rows("SELECT \(column) AS name, COUNT(*), COALESCE(SUM(count), 0) FROM entries"
                     + filter + (filter.isEmpty ? " WHERE " : " AND ") + "\(column) IS NOT NULL"
                     + " GROUP BY name ORDER BY \(order)" + (limit.map { " LIMIT \($0)" } ?? ""),
                     values) {
                    Stats.Count(name: Self.text($0, 0) ?? "", entries: Int(sqlite3_column_int64($0, 1)),
                                files: Int(sqlite3_column_int64($0, 2)))
                }
            }
            stats.byKind = counts("kind", order: "2 DESC, name")
            stats.byCategory = counts("category", order: "2 DESC, name")
            stats.byOrigin = counts("origin", order: "2 DESC, name")
            stats.byDay = counts("date(time, 'unixepoch', 'localtime')", order: "name")
            stats.folders = counts("folder", order: "2 DESC, name", limit: limit)
            return stats
        }
    }

    // MARK: - Purging

    /// Older than the days kept: gone, with their files.
    func purge(keepingDays days: Int, now: Date = Date()) {
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        delete(where: "time < ?", [.real(cutoff)])
    }

    @MainActor
    func purge() {
        purge(keepingDays: ConfigStore.shared.configuration.journalKeepDays)
    }

    /// At launch, and every hour after: what is past its days goes.
    @MainActor
    static func startKeeping() {
        shared.purge()
        keeper = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { Journal.shared.purge() }
        }
    }

    @MainActor private static var keeper: Timer?

    func deleteAll() {
        queue.async { [self] in
            run("DELETE FROM files")
            run("DELETE FROM entries")
            run("DELETE FROM search")
            sqlite3_exec(db, "VACUUM", nil, nil, nil)
            onDelete?(nil)
            Self.changed()
        }
    }

    /// Everything about one folder: what happened in it and every entry
    /// that touched anything inside it.
    func delete(about folder: String) {
        let folder = Self.withoutSlash(folder)
        let under = Self.like(folder) + "/%"
        delete(where: """
            folder = ? OR folder LIKE ? ESCAPE '\\' OR id IN (SELECT entry FROM files
             WHERE before = ? OR after = ? OR before LIKE ? ESCAPE '\\' OR after LIKE ? ESCAPE '\\')
            """, [.text(folder), .text(under), .text(folder), .text(folder), .text(under), .text(under)])
    }

    private func delete(where condition: String, _ values: [Value]) {
        queue.async { [self] in
            let ids = rows("SELECT id FROM entries WHERE " + condition, values) {
                sqlite3_column_int64($0, 0)
            }
            guard !ids.isEmpty else { return }
            sqlite3_exec(db, "BEGIN", nil, nil, nil)
            for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
                let list = chunk.map(String.init).joined(separator: ",")
                run("DELETE FROM files WHERE entry IN (\(list))")
                run("DELETE FROM search WHERE rowid IN (\(list))")
                run("DELETE FROM entries WHERE id IN (\(list))")
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
            onDelete?(ids)
            Self.changed()
        }
    }

    // MARK: - From the undo history

    /// The files an undo history action touched, read from the action that
    /// undoes it: a relocation's `to` is where the file was, its `from`
    /// where it is now.
    static func files(of action: FileHistory.Action) -> [File] {
        switch action {
        case .relocate(let moves):
            return moves.map { File(before: $0.to.path, after: $0.from.path) }
        case .trash(let removals):
            return removals.map { File(before: nil, after: $0.url.path) }
        case .permissions(let changes):
            return changes.map { File(before: $0.url.path, after: $0.url.path) }
        case .ownership(let changes):
            return changes.map { File(before: $0.url.path, after: $0.url.path) }
        case .attributes(let changes):
            return unique(changes.map(\.url))
        case .contents(let changes):
            return unique(changes.map(\.url))
        case .savedExpressions(let changes):
            return unique(changes.map(\.url))
        case .dates(let changes):
            return unique(changes.map(\.url))
        case .acls(let changes):
            return unique(changes.map(\.url))
        case .icons(let placement):
            return [File(before: placement.folder.path, after: placement.folder.path)]
        case .several(let actions):
            var seen = Set<String>()
            return actions.flatMap(files(of:)).filter { seen.insert("\($0.before ?? "")\n\($0.after ?? "")").inserted }
        }
    }

    /// For an undo or redo: the step carried out runs the other way from
    /// the one recorded, so `before` and `after` change places.
    static func reversed(_ files: [File]) -> [File] {
        files.map { File(before: $0.after, after: $0.before) }
    }

    private static func unique(_ urls: [URL]) -> [File] {
        var seen = Set<String>()
        return urls.map(\.path).filter { seen.insert($0).inserted }.map { File(before: $0, after: $0) }
    }

    // MARK: - Helpers

    /// The folder most of the files are in.
    static func folder(of files: [File]) -> String? {
        let parents = files.map { ($0.path as NSString).deletingLastPathComponent }.filter { !$0.isEmpty }
        let counts = Dictionary(parents.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }

    /// The words typed, as an FTS5 query: each word the start of a word,
    /// all of them needed. Quoted, so nothing typed is taken as syntax.
    static func match(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    private static func like(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func withoutSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    // MARK: - SQLite

    private enum Value {
        case int(Int64), real(Double), text(String), null
    }

    private func open() {
        try? FileManager.default.createDirectory(
            at: location.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard sqlite3_open(location.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            return
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location.path)
        sqlite3_busy_timeout(db, 2000)
        sqlite3_exec(db, """
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;
            CREATE TABLE IF NOT EXISTS entries (
              id INTEGER PRIMARY KEY, time REAL NOT NULL, kind TEXT NOT NULL,
              origin TEXT NOT NULL, told TEXT NOT NULL, folder TEXT,
              count INTEGER NOT NULL, outcome TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS entries_time ON entries(time);
            CREATE INDEX IF NOT EXISTS entries_folder ON entries(folder);
            CREATE TABLE IF NOT EXISTS files (
              entry INTEGER NOT NULL, before TEXT, after TEXT);
            CREATE INDEX IF NOT EXISTS files_entry ON files(entry);
            CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(
              told, kind, paths, tokenize = "unicode61 remove_diacritics 2 tokenchars '._-'");
            """, nil, nil, nil)
        // A journal from before categories: each entry gets the one its kind
        // had then.
        let columns = rows("PRAGMA table_info(entries)", []) { Self.text($0, 1) ?? "" }
        if !columns.contains("category") {
            sqlite3_exec(db, "BEGIN", nil, nil, nil)
            run("ALTER TABLE entries ADD COLUMN category TEXT NOT NULL DEFAULT 'change'")
            for kind in rows("SELECT DISTINCT kind FROM entries", [], { Self.text($0, 0) ?? "" }) {
                let category = Category.of(kind: kind)
                if category != .change {
                    run("UPDATE entries SET category = ? WHERE kind = ?", .text(category.rawValue), .text(kind))
                }
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS entries_category ON entries(category)", nil, nil, nil)
    }

    private func insertEntry(time: Date, kind: String, category: Category, origin: Origin, told: String,
                             folder: String?, count: Int, outcome: String) -> Int64 {
        guard run("""
            INSERT INTO entries(time, kind, category, origin, told, folder, count, outcome)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, .real(time.timeIntervalSince1970), .text(kind), .text(category.rawValue),
                  .text(origin.rawValue),
                  .text(told), folder.map { .text($0) } ?? .null, .int(Int64(count)), .text(outcome))
        else { return 0 }
        return sqlite3_last_insert_rowid(db)
    }

    private func insertFile(_ id: Int64, _ file: File) {
        run("INSERT INTO files(entry, before, after) VALUES (?, ?, ?)",
            .int(id), file.before.map { .text($0) } ?? .null, file.after.map { .text($0) } ?? .null)
    }

    @discardableResult
    private func run(_ sql: String, _ values: Value...) -> Bool {
        guard let statement = prepare(sql, values) else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func rows<T>(_ sql: String, _ values: [Value], _ read: (OpaquePointer) -> T) -> [T] {
        guard let statement = prepare(sql, values) else { return [] }
        defer { sqlite3_finalize(statement) }
        var found: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { found.append(read(statement)) }
        return found
    }

    private func prepare(_ sql: String, _ values: [Value]) -> OpaquePointer? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        // SQLITE_TRANSIENT: SQLite copies the text before the Swift string goes.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let number): sqlite3_bind_int64(statement, index, number)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
