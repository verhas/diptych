import Foundation
import SQLite3

/// A SQLite database opened to be looked at, never written to.
///
/// The file itself is not opened. A database is often in use -- Mail's,
/// Photos', Safari's -- and SQLite opening it even read-only takes part in
/// its locking, and may need its `-shm` file. Opened with `immutable=1` it
/// touches nothing, but misses whatever is still in the write-ahead log. So
/// the database and its `-wal` are cloned into a folder of their own --
/// instant on APFS, and nothing shared with the original -- and the clone is
/// what is opened: everything committed, the app using it undisturbed. Where
/// there is no clone to be had (another volume), a copy, if it is not large;
/// otherwise the original, immutable, saying what may be missing.
///
/// Used from one thread at a time, behind its own lock.
nonisolated final class SQLiteDatabase: @unchecked Sendable {

    static let extensions: Set<String> = ["sqlite", "sqlite3", "db", "db3", "sqlitedb", "sdb", "s3db"]
    static let header = Data("SQLite format 3\u{0}".utf8)

    /// Whether the file starts as every SQLite database does.
    static func looksLikeSQLite(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 16)) == header
    }

    enum Failure: Error, CustomStringConvertible {
        case notADatabase
        case encrypted
        case cannotOpen(String)
        case query(String)

        var description: String {
            switch self {
            case .notADatabase: "It is not a SQLite database: it does not start the way one does."
            case .encrypted: "SQLite cannot read it: it is encrypted (SQLCipher and the like), damaged, or not a database at all."
            case .cannotOpen(let why): "It could not be opened: \(why)"
            case .query(let why): why
            }
        }
    }

    enum Value: Sendable, Hashable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
    }

    struct Object: Sendable, Hashable, Identifiable {
        enum Kind: String, Sendable { case table, view, index, trigger }
        var kind: Kind
        var name: String
        /// The table an index or trigger belongs to.
        var table: String
        var sql: String?
        var id: String { kind.rawValue + ":" + name }
        /// Kept by SQLite itself: `sqlite_sequence`, `sqlite_stat1`.
        var isInternal: Bool { name.hasPrefix("sqlite_") }
    }

    struct Column: Sendable, Hashable {
        var name: String
        var type: String
        var primaryKey: Bool
        var notNull: Bool
    }

    struct Page: Sendable {
        var columns: [String]
        var rows: [[Value]]
    }

    let url: URL
    /// What may be missing, said once: the original was read as it is.
    private(set) var note: String?
    private var db: OpaquePointer?
    private var snapshot: URL?
    private let lock = NSRecursiveLock()

    /// Copied rather than cloned up to this size, when cloning is not possible.
    static let largestCopy: UInt64 = 1 << 30

    init(url: URL) throws(Failure) {
        self.url = url
        guard Self.looksLikeSQLite(url) else {
            throw Self.extensions.contains(url.pathExtension.lowercased()) ? .encrypted : .notADatabase
        }
        try open()
    }

    deinit {
        sqlite3_close_v2(db)
        if let snapshot { try? FileManager.default.removeItem(at: snapshot) }
    }

    private func open() throws(Failure) {
        let manager = FileManager.default
        let wal = URL(fileURLWithPath: url.path + "-wal")
        let hasWAL = manager.fileExists(atPath: wal.path)
        let folder = manager.temporaryDirectory.appendingPathComponent("diptych-sqlite-\(UUID().uuidString)")
        var target: URL?
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let copy = folder.appendingPathComponent(url.lastPathComponent)
            var cloned = clonefile(url.path, copy.path, 0) == 0
            if cloned, hasWAL { cloned = clonefile(wal.path, copy.path + "-wal", 0) == 0 }
            if !cloned {
                try? manager.removeItem(at: copy)
                try? manager.removeItem(atPath: copy.path + "-wal")
                let size = ((try? manager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? .max
                let walSize = hasWAL ? ((try? manager.attributesOfItem(atPath: wal.path)[.size]) as? NSNumber)?.uint64Value ?? 0 : 0
                if size + walSize <= Self.largestCopy {
                    try manager.copyItem(at: url, to: copy)
                    if hasWAL { try manager.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal")) }
                    cloned = true
                }
            }
            if cloned {
                target = copy
                snapshot = folder
            } else {
                try? manager.removeItem(at: folder)
            }
        } catch {
            try? manager.removeItem(at: folder)
        }

        let flags: Int32
        let path: String
        if let target {
            // The snapshot is Diptych's own: SQLite may fold the log into it.
            path = target.path
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        } else {
            var components = URLComponents()
            components.scheme = "file"
            components.path = url.path
            components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
            path = components.string ?? url.path
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
            if hasWAL {
                note = "Read as the file is, too large to copy: changes the app using it has not yet folded in may be missing."
            }
        }
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let why = db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite gave no reason"
            sqlite3_close_v2(db)
            db = nil
            throw .cannotOpen(why)
        }
        sqlite3_busy_timeout(db, 2000)
        exec("PRAGMA query_only = ON")
        // A key-protected or damaged file passes the header test and fails here.
        do { _ = try rows("SELECT count(*) FROM sqlite_master", [], limit: 1) }
        catch { throw .encrypted }
    }

    // MARK: - Schema

    func objects() -> [Object] {
        let found = (try? rows("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name", [], limit: 100_000)) ?? []
        return found.compactMap { row in
            guard case .text(let type) = row[0], let kind = Object.Kind(rawValue: type),
                  case .text(let name) = row[1] else { return nil }
            var table = name
            if case .text(let value) = row[2] { table = value }
            var sql: String?
            if case .text(let value) = row[3] { sql = value }
            return Object(kind: kind, name: name, table: table, sql: sql)
        }
    }

    func columns(of table: String) -> [Column] {
        let found = (try? rows("SELECT name, type, pk, \"notnull\" FROM pragma_table_info(?)", [.text(table)], limit: 10_000)) ?? []
        return found.map { row in
            func text(_ value: Value) -> String { if case .text(let t) = value { return t }; return "" }
            func int(_ value: Value) -> Int64 { if case .integer(let i) = value { return i }; return 0 }
            return Column(name: text(row[0]), type: text(row[1]), primaryKey: int(row[2]) > 0, notNull: int(row[3]) != 0)
        }
    }

    /// Rows in a table or view, counting no further than `cap`.
    func count(of table: String, filter: Filter = Filter(), cap: Int = 1_000_000) throws(Failure) -> (count: Int, capped: Bool) {
        let (clause, values) = try filter.clause(columns: columns(of: table).map(\.name))
        let sql = "SELECT count(*) FROM (SELECT 1 FROM \(Self.quoted(table))\(clause) LIMIT \(cap + 1))"
        let found = try rows(sql, values, limit: 1)
        guard case .integer(let n)? = found.first?.first else { return (0, false) }
        return (min(Int(n), cap), Int(n) > cap)
    }

    // MARK: - Browsing

    /// What narrows a table's rows: text found in any column, and a condition
    /// typed as SQL.
    struct Filter: Sendable, Equatable {
        var text = ""
        var condition = ""

        func clause(columns: [String]) throws(Failure) -> (String, [Value]) {
            var parts: [String] = []
            var values: [Value] = []
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !columns.isEmpty {
                parts.append("(" + columns.map { "CAST(\(SQLiteDatabase.quoted($0)) AS TEXT) LIKE ? ESCAPE '\\'" }
                    .joined(separator: " OR ") + ")")
                let pattern = "%" + trimmed.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
                values += Array(repeating: .text(pattern), count: columns.count)
            }
            let condition = self.condition.trimmingCharacters(in: .whitespacesAndNewlines)
            if !condition.isEmpty {
                // One expression, not a statement: nothing after it.
                guard !condition.contains(";") else { throw .query("A condition is one expression, without “;”.") }
                parts.append("(\(condition))")
            }
            return (parts.isEmpty ? "" : " WHERE " + parts.joined(separator: " AND "), values)
        }
    }

    struct Order: Sendable, Equatable {
        var column: String
        var ascending: Bool
    }

    func browse(_ table: String, filter: Filter = Filter(), order: Order? = nil,
                limit: Int, offset: Int) throws(Failure) -> Page {
        let names = columns(of: table).map(\.name)
        let (clause, values) = try filter.clause(columns: names)
        var sql = "SELECT * FROM \(Self.quoted(table))\(clause)"
        if let order { sql += " ORDER BY \(Self.quoted(order.column)) \(order.ascending ? "ASC" : "DESC")" }
        sql += " LIMIT \(limit) OFFSET \(offset)"
        return try page(sql, values, limit: limit)
    }

    /// A query of the person's own, a page of it at a time. Only what reads:
    /// the connection refuses anything else.
    func run(_ query: String, order: Order? = nil, limit: Int, offset: Int) throws(Failure) -> Page {
        var trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(";") { trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !trimmed.isEmpty else { return Page(columns: [], rows: []) }
        let first = trimmed.prefix { $0.isLetter }.uppercased()
        guard ["SELECT", "WITH", "VALUES"].contains(first) else {
            if first == "PRAGMA" || first == "EXPLAIN" { return try page(trimmed, [], limit: limit) }
            throw .query("Only queries that read run here: SELECT, WITH, VALUES, PRAGMA or EXPLAIN. Nothing is ever changed.")
        }
        let sorted = order.map { " ORDER BY \(Self.quoted($0.column)) \($0.ascending ? "ASC" : "DESC")" } ?? ""
        return try page("SELECT * FROM (\(trimmed))\(sorted) LIMIT \(limit) OFFSET \(offset)", [], limit: limit)
    }

    // MARK: - SQLite

    static func quoted(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func exec(_ sql: String) {
        lock.lock(); defer { lock.unlock() }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func rows(_ sql: String, _ values: [Value], limit: Int) throws(Failure) -> [[Value]] {
        try page(sql, values, limit: limit).rows
    }

    private func page(_ sql: String, _ values: [Value], limit: Int) throws(Failure) -> Page {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw .cannotOpen("it is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let why = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(statement)
            throw .query(why)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, index)
            case .integer(let v): sqlite3_bind_int64(statement, index, v)
            case .real(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, transient)
            case .blob(let v): _ = v.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            }
        }
        let count = sqlite3_column_count(statement)
        let columns = (0..<count).map { String(cString: sqlite3_column_name(statement, $0)) }
        var rows: [[Value]] = []
        while rows.count < limit {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw .query(String(cString: sqlite3_errmsg(db))) }
            rows.append((0..<count).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: .text(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "")
                case SQLITE_BLOB:
                    .blob(sqlite3_column_blob(statement, column).map {
                        Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, column)))
                    } ?? Data())
                default: .null
                }
            })
        }
        return Page(columns: columns, rows: rows)
    }
}

extension SQLiteDatabase.Value {
    /// One line of it, as a cell shows it.
    nonisolated func shortText(_ most: Int = 200) -> String {
        switch self {
        case .null: return "NULL"
        case .integer(let v): return String(v)
        case .real(let v): return String(v)
        case .text(let v):
            let line = v.replacingOccurrences(of: "\n", with: " \u{21B5} ")
            return line.count > most ? String(line.prefix(most)) + "\u{2026}" : line
        case .blob(let data):
            let kind = Self.blobKind(data).map { " " + $0 } ?? ""
            return "\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .memory))\(kind) blob"
        }
    }

    /// As text in a CSV or a copy: whole, a blob as hex.
    nonisolated var plainText: String {
        switch self {
        case .null: ""
        case .integer(let v): String(v)
        case .real(let v): String(v)
        case .text(let v): v
        case .blob(let data): data.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// What a blob holds, when its first bytes say: pictures, a property list, compressed data.
    nonisolated static func blobKind(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(16))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "PNG" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "JPEG" }
        if b.starts(with: Array("GIF8".utf8)) { return "GIF" }
        if b.count >= 12, b.starts(with: Array("RIFF".utf8)), Array(b[8..<12]) == Array("WEBP".utf8) { return "WebP" }
        if b.count >= 12, Array(b[4..<8]) == Array("ftyp".utf8) { return "HEIC/MP4" }
        if b.starts(with: Array("bplist".utf8)) { return "property list" }
        if b.starts(with: [0x1F, 0x8B]) { return "gzip" }
        if b.starts(with: Array("PK".utf8)) { return "zip" }
        if b.starts(with: Array("SQLite format 3".utf8)) { return "SQLite" }
        return nil
    }

    nonisolated var isNull: Bool { if case .null = self { return true }; return false }
}
