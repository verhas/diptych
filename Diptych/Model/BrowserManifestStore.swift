import Foundation
import Darwin
import SQLite3

/// Where the listings of opened archives and server shadows are kept: in
/// `LocalDatabase.cache`, not beside the files. A manifest file in every folder
/// went wherever the folder went -- into a copy dragged to Finder, into an
/// app whose signature then no longer held -- and had to be told apart from
/// an archive's own file of the same name.
///
/// Three tables. A *source* is one opened archive or one server's shadow,
/// found by its root: the local tree a pane navigates. A *folder* is one
/// directory of it that has been listed, by its path relative to the root --
/// a folder with no row has never been listed, which for a server means it
/// is fetched when opened. A *node* is one child of a listed folder, its
/// well-known attributes in columns of their own.
///
/// A folder's row is good only for the directory it was written for: its
/// inode is kept with it, and a directory deleted and made again under the
/// same name -- by anything, Diptych or not -- reads as never listed.
///
/// Readers ask by directory URL, from any thread; writers too.
nonisolated enum BrowserManifestStore {

    /// Posted on the main queue when a folder's listing changed, with the
    /// folder's `canonical` path as `path` in the user info: a pane showing it
    /// lists it again, as a pane did when the manifest file was rewritten.
    static let changed = Notification.Name("BrowserManifestStore.changed")

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - Sources

    /// Records a source rooted at `root`, which must exist. Registered again,
    /// a source keeps the folders it has listed: a server connected again
    /// keeps its shadow.
    static func register(root: URL, kind: String, holder: URL? = nil, originPath: String? = nil,
                         sha256: String? = nil, writable: Bool = false) {
        let path = canonical(root.path)
        // Read first, so the roots already recorded are not taken for none.
        // The roots' lock is never taken inside the database's, only around it.
        _ = knownRoots()
        let id = database.access { connection -> Int64? in
            connection.run("""
                INSERT INTO browser_source(kind, root, holder, origin_path, origin_sha256, writable, opened_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(root) DO UPDATE SET kind = excluded.kind, holder = excluded.holder,
                  origin_path = excluded.origin_path, origin_sha256 = excluded.origin_sha256,
                  writable = excluded.writable
                """, .text(kind), .text(path), .optional(holder.map { canonical($0.path) }),
                .optional(originPath), .optional(sha256), .int(writable ? 1 : 0),
                .real(Date().timeIntervalSince1970))
            return connection.rows("SELECT id FROM browser_source WHERE root = ?", .text(path),
                                   read: { $0.int(0) }).first ?? nil
        }
        if let id { roots.withLock { $0[path] = id } }
    }

    /// Whether `directory` is inside a registered source. Cheap when there
    /// is none, which is most of the time: an ordinary folder pays nothing.
    static func isManaged(_ directory: URL) -> Bool {
        guard !knownRoots().isEmpty else { return false }
        return source(containing: canonical(directory.path)) != nil
    }

    /// Everything recorded at or under `url`: whole sources rooted there, and
    /// the folders of a source `url` is inside. For a tree that was removed.
    static func forget(under url: URL) {
        let path = canonical(url.path)
        let known = knownRoots()
        guard !known.isEmpty else { return }
        let gone = known.filter { within($0.key, path) }
        let inside = gone.isEmpty ? source(containing: path) : nil
        database.access { connection in
            for id in gone.values {
                connection.run("DELETE FROM browser_source WHERE id = ?", .int(id))
            }
            guard let (id, root) = inside else { return }
            let relative = Self.relative(path, to: root)
            if relative.isEmpty {
                connection.run("DELETE FROM browser_folder WHERE source_id = ?", .int(id))
            } else {
                connection.run("""
                    DELETE FROM browser_folder WHERE source_id = ?
                      AND (path = ? OR substr(path, 1, length(?) + 1) = ? || '/')
                    """, .int(id), .text(relative), .text(relative), .text(relative))
            }
        }
        roots.withLock { state in
            for root in gone.keys { _ = state.removeValue(forKey: root) }
        }
    }

    // MARK: - Reading

    /// The listing recorded for `directory`, nil when it has none -- never
    /// listed, outside every source, or since replaced on disk.
    static func read(in directory: URL) -> BrowserManifest? {
        let path = canonical(directory.path)
        guard let (id, root) = source(containing: path), let inode = inode(of: path) else { return nil }
        return database.access { connection -> BrowserManifest? in
            guard let source = connection.rows("""
                    SELECT kind, holder, origin_path, origin_sha256, writable FROM browser_source WHERE id = ?
                    """, .int(id), read: { row in
                        (kind: row.text(0) ?? "", holder: row.text(1), origin: row.text(2),
                         sha: row.text(3), writable: row.int(4) == 1)
                    }).first,
                  let folder = folder(in: connection, source: id, path: relative(path, to: root)),
                  folder.inode == inode else { return nil }
            var origin: [String: String] = [:]
            origin["path"] = source.origin
            origin["sha256"] = source.sha
            origin["holder"] = source.holder
            return BrowserManifest(source: source.kind, origin: origin,
                                   capabilities: .init(writable: source.writable),
                                   nodes: nodes(in: connection, folder: folder.id))
        }
    }

    /// One child of `directory` as listed, by name.
    static func node(named name: String, in directory: URL) -> BrowserManifest.Node? {
        read(in: directory)?.nodes.first { $0.name == name }
    }

    /// The listed node for a file or folder at `url`.
    static func node(at url: URL) -> BrowserManifest.Node? {
        node(named: url.lastPathComponent, in: url.deletingLastPathComponent())
    }

    // MARK: - Writing

    /// Records `manifest` as `directory`'s listing, replacing what was there.
    /// A directory outside every source becomes a source of its own, from
    /// what the manifest says it is. Returns whether anything changed: the
    /// same listing written again is not a change, and nobody is told.
    @discardableResult
    static func write(_ manifest: BrowserManifest, in directory: URL) throws -> Bool {
        let changed = try write([(directory, manifest)], comparing: true)
        if changed { announce(canonical(directory.path)) }
        return changed
    }

    /// Many folders at once, in one transaction, without comparing or
    /// announcing: a source being built, which nobody is showing yet.
    static func write(_ listings: [(directory: URL, manifest: BrowserManifest)]) throws {
        _ = try write(listings, comparing: false)
    }

    private static func write(_ listings: [(directory: URL, manifest: BrowserManifest)],
                              comparing: Bool) throws -> Bool {
        let prepared = try listings.map { directory, manifest in
            let path = canonical(directory.path)
            guard let inode = inode(of: path) else {
                throw Failure(description: "\(directory.lastPathComponent) is not there to be listed.")
            }
            if source(containing: path) == nil {
                register(root: URL(fileURLWithPath: path), kind: manifest.source,
                         holder: manifest.origin["holder"].map { URL(fileURLWithPath: $0) },
                         originPath: manifest.origin["path"], sha256: manifest.origin["sha256"],
                         writable: manifest.capabilities.writable)
            }
            guard let (id, root) = source(containing: path) else {
                throw Failure(description: "The cache could not be written.")
            }
            return (source: id, path: relative(path, to: root), inode: inode,
                    rows: manifest.nodes.map(values(of:)))
        }
        return try database.transaction { connection in
            var any = false
            for listing in prepared {
                let existing = folder(in: connection, source: listing.source, path: listing.path)
                if comparing, let existing, existing.inode == listing.inode,
                   rows(in: connection, folder: existing.id) == listing.rows { continue }
                any = true
                connection.run("""
                    INSERT INTO browser_folder(source_id, path, inode, listed_at) VALUES (?, ?, ?, ?)
                    ON CONFLICT(source_id, path) DO UPDATE SET inode = excluded.inode,
                      listed_at = excluded.listed_at
                    """, .int(listing.source), .text(listing.path), .int(listing.inode),
                    .real(Date().timeIntervalSince1970))
                guard let folder = folder(in: connection, source: listing.source, path: listing.path) else {
                    throw Failure(description: "The cache could not be written.")
                }
                connection.run("DELETE FROM browser_node WHERE folder_id = ?", .int(folder.id))
                guard insert(listing.rows, startingAt: 0, into: folder.id, connection) else {
                    throw Failure(description: "The cache could not be written.")
                }
            }
            return any
        }
    }

    /// Changes one child of a listed `directory` in place. A child not
    /// listed is added as `creating`, when given. Returns false when the
    /// directory has no listing, or no such child and nothing to create.
    @discardableResult
    static func update(in directory: URL, name: String, creating: BrowserManifest.Node? = nil,
                       _ change: (inout BrowserManifest.Node) -> Void) -> Bool {
        let path = canonical(directory.path)
        guard let (id, root) = source(containing: path), let inode = inode(of: path) else { return false }
        let outcome = try? database.transaction { connection -> (found: Bool, changed: Bool) in
            guard let folder = folder(in: connection, source: id, path: relative(path, to: root)),
                  folder.inode == inode else { return (false, false) }
            let current = connection.rows("""
                SELECT \(columns), position FROM browser_node WHERE folder_id = ? AND name = ?
                """, .int(folder.id), .text(name)) { row in
                    (values: row.values(count: columnCount), position: row.int(Int32(columnCount)) ?? 0)
                }.first
            var node: BrowserManifest.Node
            let position: Int64
            if let current {
                node = Self.node(from: current.values)
                position = current.position
            } else if let creating {
                node = creating
                position = (connection.rows("SELECT max(position) FROM browser_node WHERE folder_id = ?",
                                            .int(folder.id)) { $0.int(0) }.first ?? nil).map { $0 + 1 } ?? 0
            } else {
                return (false, false)
            }
            change(&node)
            let after = values(of: node)
            if let current, current.values == after { return (true, false) }
            if node.name != name {
                connection.run("DELETE FROM browser_node WHERE folder_id = ? AND name = ?",
                               .int(folder.id), .text(name))
            }
            guard insert([after], startingAt: position, into: folder.id, connection) else {
                throw Failure(description: "The cache could not be written.")
            }
            return (true, true)
        }
        if outcome?.changed == true { announce(path) }
        return outcome?.found ?? false
    }

    // MARK: - Paths

    /// `path` as the kernel has it -- `/private/var` for `/var`, links
    /// followed -- for its longest part that exists, and the rest as it is.
    /// Both spellings of a folder then find one row.
    static func canonical(_ path: String) -> String {
        var existing = (path as NSString).standardizingPath
        var rest: [String] = []
        while !existing.isEmpty {
            if let real = realpath(existing, nil) {
                var result = String(cString: real)
                free(real)
                for component in rest.reversed() {
                    result = (result as NSString).appendingPathComponent(component)
                }
                return result
            }
            if existing == "/" { break }
            rest.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
        }
        return path
    }

    private static func within(_ path: String, _ ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
    }

    private static func relative(_ path: String, to root: String) -> String {
        path == root ? "" : String(path.dropFirst(root.count + (root.hasSuffix("/") ? 0 : 1)))
    }

    private static func inode(of path: String) -> Int64? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return Int64(bitPattern: UInt64(info.st_ino))
    }

    // MARK: - Internals

    private static var database: LocalDatabase { .cache }

    /// Registered roots by canonical path, read from the cache once: only a
    /// path under one of them is ever looked up.
    private static let roots = LockedRoots()

    private static func knownRoots() -> [String: Int64] {
        roots.withLock { cached in
            if let loaded = cached.loaded { return loaded }
            // What an earlier run left whose tree is gone -- a crash, or the
            // caches emptied -- is dropped now.
            let all = database.access { connection in
                connection.rows("SELECT id, root FROM browser_source") { ($0.int(0) ?? 0, $0.text(1) ?? "") }
            }
            var found: [String: Int64] = [:]
            for (id, root) in all {
                if FileManager.default.fileExists(atPath: root) {
                    found[root] = id
                } else {
                    database.access { $0.run("DELETE FROM browser_source WHERE id = ?", .int(id)) }
                }
            }
            cached.loaded = found
            return found
        }
    }

    /// The deepest source whose root holds `path`.
    private static func source(containing path: String) -> (id: Int64, root: String)? {
        knownRoots().filter { within(path, $0.key) }
            .max { $0.key.count < $1.key.count }
            .map { ($0.value, $0.key) }
    }

    private static func folder(in connection: LocalDatabase.Connection, source: Int64,
                               path: String) -> (id: Int64, inode: Int64)? {
        connection.rows("SELECT id, inode FROM browser_folder WHERE source_id = ? AND path = ?",
                        .int(source), .text(path)) { ($0.int(0) ?? 0, $0.int(1) ?? 0) }.first
    }

    private static func announce(_ path: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: changed, object: nil, userInfo: ["path": path])
        }
    }

    // MARK: - Nodes as rows

    private static let columns = """
        name, node_id, kind, size, mode, uid, gid, owner, grp, mtime, btime, link_target, \
        backing, backing_path, sha256, local_mtime, server_changed
        """
    private static let columnCount = 17

    private static func rows(in connection: LocalDatabase.Connection,
                             folder: Int64) -> [[LocalDatabase.Value]] {
        connection.rows("SELECT \(columns) FROM browser_node WHERE folder_id = ? ORDER BY position",
                        .int(folder)) { $0.values(count: columnCount) }
    }

    private static func nodes(in connection: LocalDatabase.Connection,
                              folder: Int64) -> [BrowserManifest.Node] {
        rows(in: connection, folder: folder).map(node(from:))
    }

    private static func insert(_ rows: [[LocalDatabase.Value]], startingAt first: Int64, into folder: Int64,
                               _ connection: LocalDatabase.Connection) -> Bool {
        connection.runEach("""
            INSERT OR REPLACE INTO browser_node(folder_id, position, \(columns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, rows.enumerated().map { offset, values in
                [.int(folder), .int(first + Int64(offset))] + values
            })
    }

    /// The columns of a node, in `columns` order. Attributes other than the
    /// well-known ones have no column and are not kept: no source makes any.
    private static func values(of node: BrowserManifest.Node) -> [LocalDatabase.Value] {
        typealias A = BrowserManifest.Attribute
        func int(_ key: String) -> LocalDatabase.Value { .optional(node.attribute(key)?.intValue) }
        func text(_ key: String) -> LocalDatabase.Value { .optional(node.attribute(key)?.stringValue) }
        func date(_ key: String) -> LocalDatabase.Value {
            if case .date(let seconds)? = node.attribute(key) { return .real(seconds) }
            return .null
        }
        let backing: (String, String?) = switch node.backing {
        case .file(let path): ("file", path)
        case .report: ("report", nil)
        case .none: ("none", nil)
        }
        return [.text(node.name), .text(node.id), .text(node.kind.rawValue),
                int(A.size), int(A.mode), int(A.uid), int(A.gid),
                text(A.ownerName), text(A.groupName),
                date(A.modified), date(A.created),
                .optional(node.linkTarget),
                .text(backing.0), .optional(backing.1),
                text(A.checksum), date(A.localModified),
                .int(node.attribute(A.serverChanged)?.boolValue == true ? 1 : 0)]
    }

    private static func node(from values: [LocalDatabase.Value]) -> BrowserManifest.Node {
        typealias A = BrowserManifest.Attribute
        func text(_ i: Int) -> String? { if case .text(let v) = values[i] { return v }; return nil }
        func int(_ i: Int) -> Int64? { if case .int(let v) = values[i] { return v }; return nil }
        func real(_ i: Int) -> Double? {
            switch values[i] {
            case .real(let v): v
            case .int(let v): Double(v)
            default: nil
            }
        }
        var node = BrowserManifest.Node(id: text(1) ?? "", kind: BrowserManifest.Kind(rawValue: text(2) ?? "") ?? .other,
                                        name: text(0) ?? "")
        var attributes: [String: AttributeValue] = [:]
        attributes[A.size] = int(3).map(AttributeValue.int)
        attributes[A.mode] = int(4).map(AttributeValue.int)
        attributes[A.uid] = int(5).map(AttributeValue.int)
        attributes[A.gid] = int(6).map(AttributeValue.int)
        attributes[A.ownerName] = text(7).map(AttributeValue.string)
        attributes[A.groupName] = text(8).map(AttributeValue.string)
        attributes[A.modified] = real(9).map(AttributeValue.date)
        attributes[A.created] = real(10).map(AttributeValue.date)
        attributes[A.checksum] = text(14).map(AttributeValue.string)
        attributes[A.localModified] = real(15).map(AttributeValue.date)
        if int(16) == 1 { attributes[A.serverChanged] = .bool(true) }
        node.attributes = attributes
        node.linkTarget = text(11)
        node.backing = switch text(12) {
        case "file": .file(text(13) ?? "")
        case "report": .report
        default: .none
        }
        return node
    }
}

/// The roots, and whether they have been read from the cache yet.
nonisolated private final class LockedRoots: @unchecked Sendable {
    struct State {
        var loaded: [String: Int64]?
        subscript(root: String) -> Int64? {
            get { loaded?[root] }
            set {
                if loaded == nil { loaded = [:] }
                loaded?[root] = newValue
            }
        }
        mutating func removeValue(forKey root: String) -> Int64? { loaded?.removeValue(forKey: root) }
    }

    private let lock = NSRecursiveLock()
    private var state = State()

    func withLock<T>(_ work: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work(&state)
    }
}

extension LocalDatabase.Row {
    /// The first `count` columns as they are stored.
    nonisolated func values(count: Int) -> [LocalDatabase.Value] {
        (0..<Int32(count)).map { column in
            switch sqlite3_column_type(statement, column) {
            case SQLITE_INTEGER: .int(sqlite3_column_int64(statement, column))
            case SQLITE_FLOAT: .real(sqlite3_column_double(statement, column))
            case SQLITE_TEXT: .text(text(column) ?? "")
            default: .null
            }
        }
    }
}
