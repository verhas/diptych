import Foundation
import SQLite3

/// `~/.diptych/cache.sqlite`: what Diptych works out and keeps only so as not
/// to work it out again -- the listings of opened archives and server shadows
/// now, folder sizes and the like later. Nothing in it is the person's: lost
/// or damaged, the file is made again and the work is redone.
///
/// One connection, used under a lock by whichever thread asks; SQLite's own
/// work is quick next to the file system work around it.
nonisolated final class CacheDatabase: @unchecked Sendable {

    /// A test run keeps a cache of its own, never the person's.
    static let shared = CacheDatabase(url: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".diptych/cache.sqlite")
        : FileManager.default.temporaryDirectory
            .appendingPathComponent("diptych-test-cache-\(ProcessInfo.processInfo.processIdentifier).sqlite"))

    /// Raised when a table changes shape; a cache that is older is emptied
    /// and made again rather than migrated.
    private static let schemaVersion: Int32 = 1

    let url: URL
    private let lock = NSRecursiveLock()
    private var db: OpaquePointer?

    init(url: URL) {
        self.url = url
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
    func access<T>(_ work: (Connection) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try work(Connection(db: db))
    }

    /// `work` as one transaction: all of it, or -- when it throws -- none.
    func transaction<T>(_ work: (Connection) throws -> T) throws -> T {
        try access { connection in
            guard connection.db != nil else { throw Failure(description: "The cache could not be opened.") }
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
        guard connect() else {
            // Damaged, or not SQLite at all: it is only a cache.
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
            _ = connect()
            return
        }
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
        let version = connection.rows("PRAGMA user_version") { $0.int(0) ?? 0 }
        guard let version = version.first else {
            sqlite3_close(db)
            db = nil
            return false
        }
        connection.exec("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
        if version != Int64(Self.schemaVersion) {
            connection.exec("""
                DROP TABLE IF EXISTS browser_node;
                DROP TABLE IF EXISTS browser_folder;
                DROP TABLE IF EXISTS browser_source;
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
            PRAGMA user_version = \(Self.schemaVersion);
            """)
        return true
    }
}
