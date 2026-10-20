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
