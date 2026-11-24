import Foundation
import SQLite3

/// A SQLite file of Diptych's in `~/.diptych`, with one connection used under
/// a lock by whichever thread asks; SQLite's own work is quick next to the
/// file system work around it.
///
/// Two of them, which differ in what happens when a file cannot be used:
///
/// - `cache` -- `cache.sqlite`: what Diptych works out and keeps only so as
///   not to work it out again: the listings of opened archives and server
///   shadows, folder sizes. Nothing in it is the person's, so a damaged file,
///   or one whose tables changed shape, is emptied and made again and the
///   work is redone.
/// - `records` -- `diptych.sqlite`: what Diptych remembers for the person and
///   cannot work out again: the windows and panes as they were left, where
///   trashed files came from, the servers connected to, how long scripts
///   take, the scripts approved. Never emptied
///   by Diptych: a damaged file is set aside beside it, and a newer
///   version's tables are used as they are.
///
/// A test run keeps databases of its own, never the person's.
nonisolated final class LocalDatabase: @unchecked Sendable {

    static let cache = LocalDatabase.cache(at: testing
        ? temporary("cache") : home.appendingPathComponent("cache.sqlite"))

    /// The records, with what 1.x kept in JSON files brought in the first
    /// time they are opened (`LegacyRecords`).
    static let records: LocalDatabase = {
        // The oldest layout first: ~/.diptych a file, not a folder.
        if !testing { LegacyRecords.liftPlainFile(at: home) }
        let database = LocalDatabase.records(at: testing
            ? temporary("records") : home.appendingPathComponent("diptych.sqlite"))
        if !testing { LegacyRecords.importFiles(in: home, into: database) }
        return database
    }()

    static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".diptych")

    static var testing: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    private static func temporary(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("diptych-test-\(name)-\(ProcessInfo.processInfo.processIdentifier).sqlite")
    }

    /// What is done with a file that cannot be opened.
    enum WhenDamaged {
        /// Deleted and made again: a cache.
        case remake
        /// Renamed aside, `<name>.damaged-<date>`, and a new one made.
        case setAside
    }

    let url: URL
    private let whenDamaged: WhenDamaged
    /// Makes the tables, given the connection and the version the file had.
    private let setUp: (Connection, Int64) -> Void
    private let lock = NSRecursiveLock()
    private var db: OpaquePointer?

    init(url: URL, whenDamaged: WhenDamaged, setUp: @escaping (Connection, Int64) -> Void) {
        self.url = url
        self.whenDamaged = whenDamaged
        self.setUp = setUp
        open()
    }

    enum Value: Equatable {
        case int(Int64), real(Double), text(String), null

        static func optional(_ value: Int64?) -> Value { value.map { .int($0) } ?? .null }
        static func optional(_ value: Double?) -> Value { value.map { .real($0) } ?? .null }
        static func optional(_ value: String?) -> Value { value.map { .text($0) } ?? .null }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - Using it

    /// Runs `work` with the connection to itself; a nested call from inside
    /// `work` is fine.
    /// Discardable: a statement run for its effect returns whether it ran,
    /// and most callers have nothing to do with that.
    @discardableResult
    func access<T>(_ work: (Connection) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try work(Connection(db: db))
    }

    /// `work` as one transaction: all of it, or -- when it throws -- none.
    func transaction<T>(_ work: (Connection) throws -> T) throws -> T {
        try access { connection in
            guard connection.db != nil else { throw Failure(description: "\(url.lastPathComponent) could not be opened.") }
            connection.exec("BEGIN IMMEDIATE")
            do {
                let result = try work(connection)
                connection.exec("COMMIT")
                return result
            } catch {
                connection.exec("ROLLBACK")
                throw error
            }
        }
    }

    struct Connection {
        let db: OpaquePointer?

        func exec(_ sql: String) {
            sqlite3_exec(db, sql, nil, nil, nil)
        }

        @discardableResult
        func run(_ sql: String, _ values: Value...) -> Bool {
            run(sql, values)
        }

        @discardableResult
        func run(_ sql: String, _ values: [Value]) -> Bool {
            guard let statement = prepare(sql, values) else { return false }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_DONE
        }

        /// Runs `sql` once for each set of values, prepared once.
        @discardableResult
        func runEach(_ sql: String, _ rows: [[Value]]) -> Bool {
            guard let db else { return false }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                sqlite3_finalize(statement)
                return false
            }
            defer { sqlite3_finalize(statement) }
            for values in rows {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(values, to: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { return false }
            }
            return true
        }

        func rows<T>(_ sql: String, _ values: Value..., read: (Row) -> T) -> [T] {
            guard let statement = prepare(sql, values) else { return [] }
            defer { sqlite3_finalize(statement) }
            var found: [T] = []
            while sqlite3_step(statement) == SQLITE_ROW { found.append(read(Row(statement: statement))) }
            return found
        }

        var lastInsertedRow: Int64 { sqlite3_last_insert_rowid(db) }

        private func prepare(_ sql: String, _ values: [Value]) -> OpaquePointer? {
            guard let db else { return nil }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                sqlite3_finalize(statement)
                return nil
            }
            bind(values, to: statement)
            return statement
        }

        private func bind(_ values: [Value], to statement: OpaquePointer) {
            // SQLITE_TRANSIENT: SQLite copies the text before the Swift string goes.
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                switch value {
                case .int(let v): sqlite3_bind_int64(statement, index, v)
                case .real(let v): sqlite3_bind_double(statement, index, v)
                case .text(let v): sqlite3_bind_text(statement, index, v, -1, transient)
                case .null: sqlite3_bind_null(statement, index)
                }
            }
        }
    }

    struct Row {
        let statement: OpaquePointer

        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
        func int(_ column: Int32) -> Int64? { isNull(column) ? nil : sqlite3_column_int64(statement, column) }
        func real(_ column: Int32) -> Double? { isNull(column) ? nil : sqlite3_column_double(statement, column) }
        func text(_ column: Int32) -> String? {
            guard let text = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: text)
        }
    }

    // MARK: - Opening

    private func open() {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard !connect() else { return }
        switch whenDamaged {
        case .remake:
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        case .setAside:
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.moveItem(atPath: url.path + suffix,
                                                  toPath: url.path + ".damaged-\(stamp)" + suffix)
            }
        }
        _ = connect()
    }

    private func connect() -> Bool {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            return false
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        sqlite3_busy_timeout(db, 2000)
        let connection = Connection(db: db)
        // Not SQLite at all, or damaged past reading its header: no version.
        guard let version = connection.rows("PRAGMA user_version", read: { $0.int(0) ?? 0 }).first else {
            sqlite3_close(db)
            db = nil
            return false
        }
        connection.exec("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
        setUp(connection, version)
        return true
    }
}

// MARK: - The two schemas

extension LocalDatabase {

    /// The cache, at `url`. Version 2 added `folder_size` to version 1's
    /// tables, so a version 1 file is kept and given it; any other is emptied.
    static func cache(at url: URL) -> LocalDatabase {
        LocalDatabase(url: url, whenDamaged: .remake) { connection, version in
            if version != 1 && version != 2 {
                connection.exec("""
                    DROP TABLE IF EXISTS browser_node;
                    DROP TABLE IF EXISTS browser_folder;
                    DROP TABLE IF EXISTS browser_source;
                    DROP TABLE IF EXISTS folder_size;
                    """)
            }
            connection.exec("""
                CREATE TABLE IF NOT EXISTS browser_source (
                  id INTEGER PRIMARY KEY,
                  kind TEXT NOT NULL,
                  root TEXT NOT NULL UNIQUE,
                  holder TEXT,
                  origin_path TEXT,
                  origin_sha256 TEXT,
                  writable INTEGER NOT NULL DEFAULT 0,
                  opened_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS browser_folder (
                  id INTEGER PRIMARY KEY,
                  source_id INTEGER NOT NULL REFERENCES browser_source ON DELETE CASCADE,
                  path TEXT NOT NULL,
                  inode INTEGER NOT NULL,
                  listed_at REAL NOT NULL,
                  UNIQUE (source_id, path));
                CREATE TABLE IF NOT EXISTS browser_node (
                  folder_id INTEGER NOT NULL REFERENCES browser_folder ON DELETE CASCADE,
                  name TEXT NOT NULL,
                  position INTEGER NOT NULL,
                  node_id TEXT NOT NULL,
                  kind TEXT NOT NULL,
                  size INTEGER, mode INTEGER, uid INTEGER, gid INTEGER,
                  owner TEXT, grp TEXT,
                  mtime REAL, btime REAL,
                  link_target TEXT,
                  backing TEXT NOT NULL,
                  backing_path TEXT,
                  sha256 TEXT,
                  local_mtime REAL,
                  server_changed INTEGER NOT NULL DEFAULT 0,
                  PRIMARY KEY (folder_id, name)) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS folder_size (
                  path TEXT PRIMARY KEY,
                  parent TEXT NOT NULL,
                  size INTEGER NOT NULL,
                  measured_at REAL NOT NULL,
                  complete INTEGER NOT NULL) WITHOUT ROWID;
                CREATE INDEX IF NOT EXISTS folder_size_parent ON folder_size (parent);
                PRAGMA user_version = 2;
                """)
        }
    }

    /// The records, at `url`. Tables are only ever added, or given columns:
    /// a version newer than this one's is left at its number and used.
    static func records(at url: URL) -> LocalDatabase {
        LocalDatabase(url: url, whenDamaged: .setAside) { connection, version in
            connection.exec("""
                CREATE TABLE IF NOT EXISTS trash_origin (
                  trashed TEXT PRIMARY KEY,
                  original TEXT NOT NULL,
                  recorded_at REAL NOT NULL) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS server (
                  id TEXT PRIMARY KEY,
                  address TEXT NOT NULL,
                  saved INTEGER NOT NULL DEFAULT 0,
                  open_at_login INTEGER NOT NULL DEFAULT 0,
                  last_used REAL NOT NULL,
                  mount_point TEXT,
                  keep_alive_seconds INTEGER,
                  hash_command TEXT) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS script_timing (
                  script TEXT PRIMARY KEY,
                  runs INTEGER NOT NULL,
                  shortest REAL NOT NULL,
                  longest REAL NOT NULL,
                  total REAL NOT NULL,
                  runs_with_files INTEGER NOT NULL,
                  shortest_per_file REAL NOT NULL,
                  longest_per_file REAL NOT NULL,
                  total_per_file REAL NOT NULL) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS script_approval (
                  fingerprint TEXT PRIMARY KEY,
                  approved_at REAL NOT NULL) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS window_state (
                  slot INTEGER PRIMARY KEY,
                  frame TEXT,
                  active_side TEXT NOT NULL,
                  single_pane INTEGER NOT NULL,
                  sidebar_visible INTEGER NOT NULL,
                  show_hidden INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS pane_state (
                  slot INTEGER NOT NULL REFERENCES window_state ON DELETE CASCADE,
                  side TEXT NOT NULL,
                  directory TEXT NOT NULL,
                  sort_field TEXT NOT NULL,
                  sort_ascending INTEGER NOT NULL,
                  flat_draft TEXT NOT NULL,
                  flat_expression TEXT,
                  view_style TEXT NOT NULL,
                  icon_arrangement TEXT NOT NULL,
                  PRIMARY KEY (slot, side)) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS pane_recent (
                  slot INTEGER NOT NULL,
                  side TEXT NOT NULL,
                  position INTEGER NOT NULL,
                  path TEXT NOT NULL,
                  PRIMARY KEY (slot, side, position),
                  FOREIGN KEY (slot, side) REFERENCES pane_state ON DELETE CASCADE) WITHOUT ROWID;
                """)
            if version < 1 { connection.exec("PRAGMA user_version = 1") }
        }
    }
}
