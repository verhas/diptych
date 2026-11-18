import Foundation

/// Remembers where files Diptych moved to the Trash came from, so a Trash
/// listing can show an Original Location column.
///
/// macOS keeps Finder's "Put Back" in a private store with no public API, so
/// this is Diptych's own record of what *it* trashed -- honest about what it
/// knows, and blank for anything trashed by Finder or another app. Kept in
/// the `trash_origin` table of `LocalDatabase.records`; 1.x kept it in
/// `~/.diptych/trash-origins.json`.
@MainActor
final class TrashOriginals {

    static let shared = TrashOriginals()

    /// Trashed-file path → the path it came from.
    private var origins: [String: String] = [:]
    private let database: LocalDatabase?

    /// `database` nil keeps it in memory only -- what a test run uses, so
    /// the person's records are left alone.
    init(database: LocalDatabase? = TrashOriginals.defaultDatabase) {
        self.database = database
        load()
    }

    nonisolated static var defaultDatabase: LocalDatabase? {
        LocalDatabase.testing ? nil : .records
    }

    /// Record what a trash moved: each trashed file and where it was.
    func record(_ moved: [(original: URL, trashed: URL)]) {
        guard !moved.isEmpty else { return }
        var rows: [[LocalDatabase.Value]] = []
        let now = Date().timeIntervalSince1970
        for move in moved {
            let trashed = move.trashed.standardizedFileURL.path
            let original = move.original.standardizedFileURL.path
            origins[trashed] = original
            rows.append([.text(trashed), .text(original), .real(now)])
        }
        _ = try? database?.transaction { connection in
            connection.runEach(Self.insert, rows)
        }
    }

    /// Where the file now at `trashed` came from, if Diptych knows.
    func original(of trashed: URL) -> String? {
        origins[trashed.standardizedFileURL.path]
    }

    /// Forget a trashed file -- it has been restored or is otherwise gone.
    func forget(_ trashed: URL) {
        let key = trashed.standardizedFileURL.path
        guard origins.removeValue(forKey: key) != nil else { return }
        database?.access { $0.run("DELETE FROM trash_origin WHERE trashed = ?", .text(key)) }
    }

    /// A trashed file was renamed in place: carry its origin over to the new
    /// name, so Put Back still knows where it came from. Where it came from
    /// does not change -- only the key the file is now found under.
    func rename(_ old: URL, to new: URL) {
        let key = old.standardizedFileURL.path
        guard let origin = origins.removeValue(forKey: key) else { return }
        let newKey = new.standardizedFileURL.path
        origins[newKey] = origin
        _ = try? database?.transaction { connection in
            connection.run("DELETE FROM trash_origin WHERE trashed = ?", .text(key))
            connection.run(Self.insert, .text(newKey), .text(origin), .real(Date().timeIntervalSince1970))
        }
    }

    nonisolated static let insert = "INSERT OR REPLACE INTO trash_origin (trashed, original, recorded_at) VALUES (?, ?, ?)"

    // MARK: - Persistence

    private func load() {
        guard let database else { return }
        let all = database.access { connection in
            connection.rows("SELECT trashed, original FROM trash_origin") { row in
                (row.text(0) ?? "", row.text(1) ?? "")
            }
        }
        // Forget entries whose trashed file is gone -- the Trash was emptied, or
        // the file was put back -- so the record does not grow without bound.
        var gone: [[LocalDatabase.Value]] = []
        for (trashed, original) in all {
            if FileManager.default.fileExists(atPath: trashed) {
                origins[trashed] = original
            } else {
                gone.append([.text(trashed)])
            }
        }
        if !gone.isEmpty {
            _ = try? database.transaction { $0.runEach("DELETE FROM trash_origin WHERE trashed = ?", gone) }
        }
    }
}

/// Finder's own record of where trashed files came from -- its "Put Back"
/// target -- read straight from the Trash folder's `.DS_Store`.
///
/// macOS has no public API for this and does not store it on the file, so it is
/// reverse-engineered from the `.DS_Store` B-tree: each trashed entry carries a
/// `ptbL` string with the folder it came from and a `ptbN` string with the name
/// it was trashed under. The folder is written *relative to the volume's root*
/// -- `/Users/me/Desktop/` on the startup disk, or `/photos/` on another volume
/// mounted at `/Volumes/BACKUP` -- so the full path is the volume's mount point,
/// then `ptbL`, then `ptbN`.
///
/// Reading it needs Full Disk Access -- which Diptych asks for the moment a
/// Trash is opened -- and is empty without it. This is the honest fallback for
/// files Finder or another app trashed, which [[TrashOriginals]] does not know
/// about because Diptych did not move them.
///
/// The format is private and the most that can go wrong is a blank or, rarely,
/// a wrong location -- never a crash: [[DSStore]] bounds-checks every read, and
/// nothing here is ever written back.
enum TrashPutBack {

    /// Where each file in the Trash at `trash` came from, keyed by the name the
    /// file now has in the Trash. Empty when the `.DS_Store` is absent,
    /// unreadable (no Full Disk Access), or holds no put-back records.
    static func origins(inTrashAt trash: URL) -> [String: String] {
        let dsStore = trash.appendingPathComponent(".DS_Store")
        guard let data = try? Data(contentsOf: dsStore),
              let store = try? DSStore(data: data) else { return [:] }
        // `ptbL` is relative to the root of the volume the Trash is on. The
        // startup volume's root is `/`, so its paths are already absolute.
        let mount = (try? trash.resourceValues(forKeys: [.volumeURLKey]))?
            .volume ?? URL(fileURLWithPath: "/")
        var result: [String: String] = [:]
        for (entry, records) in store.byEntry {
            if let path = originalPath(from: records, onVolumeAt: mount) {
                result[entry] = path
            }
        }
        return result
    }

    /// The original path one entry's records describe: the volume's mount
    /// point, then the volume-relative folder in `ptbL`, then the name in
    /// `ptbN` -- the name the file had before it was trashed, which a Trash
    /// collision may have changed since.
    private static func originalPath(from records: [DSStore.Record],
                                     onVolumeAt mount: URL) -> String? {
        var folder: String?
        var name: String?
        for record in records {
            switch record.key {
            case "ptbL":
                if case let .text(text) = record.value { folder = text }
            case "ptbN":
                if case let .text(text) = record.value { name = text }
            default:
                break
            }
        }
        guard let folder, let name, !name.isEmpty else { return nil }
        return mount.appendingPathComponent(folder)
            .appendingPathComponent(name)
            .standardizedFileURL.path
    }
}
