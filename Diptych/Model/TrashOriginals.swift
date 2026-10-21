import Foundation

/// Remembers where files Diptych moved to the Trash came from, so a Trash
/// listing can show an Original Location column.
///
/// macOS keeps Finder's "Put Back" in a private store with no public API, so
/// this is Diptych's own record of what *it* trashed -- honest about what it
/// knows, and blank for anything trashed by Finder or another app.
@MainActor
final class TrashOriginals {

    static let shared = TrashOriginals()

    /// Trashed-file path → the path it came from.
    private var origins: [String: String] = [:]
    private let store: URL?

    /// `store` nil keeps it in memory only -- what the tests and a test run use,
    /// so ~/.diptych is left alone.
    init(store: URL? = TrashOriginals.defaultStore) {
        self.store = store
        load()
    }

    nonisolated static var defaultStore: URL? {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".diptych/trash-origins.json")
    }

    /// Record what a trash moved: each trashed file and where it was.
    func record(_ moved: [(original: URL, trashed: URL)]) {
        guard !moved.isEmpty else { return }
        for move in moved {
            origins[move.trashed.standardizedFileURL.path] = move.original.standardizedFileURL.path
        }
        save()
    }

    /// Where the file now at `trashed` came from, if Diptych knows.
    func original(of trashed: URL) -> String? {
        origins[trashed.standardizedFileURL.path]
    }

    /// Forget a trashed file -- it has been restored or is otherwise gone.
    func forget(_ trashed: URL) {
        if origins.removeValue(forKey: trashed.standardizedFileURL.path) != nil { save() }
    }

    /// A trashed file was renamed in place: carry its origin over to the new
    /// name, so Put Back still knows where it came from. Where it came from
    /// does not change -- only the key the file is now found under.
    func rename(_ old: URL, to new: URL) {
        let key = old.standardizedFileURL.path
        guard let origin = origins.removeValue(forKey: key) else { return }
        origins[new.standardizedFileURL.path] = origin
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let store, let data = try? Data(contentsOf: store),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        // Forget entries whose trashed file is gone -- the Trash was emptied, or
        // the file was put back -- so the record does not grow without bound.
        origins = decoded.filter { FileManager.default.fileExists(atPath: $0.key) }
    }

    private func save() {
        guard let store else { return }
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(origins) { try? data.write(to: store) }
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
