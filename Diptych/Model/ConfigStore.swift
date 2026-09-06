import Foundation
import Observation

/// Reads and writes `~/.diptych/config.json`.
///
/// Separate from `StateStore` on purpose: state is written by the app and read
/// by nobody, configuration is meant to be read and edited by a person. When
/// this grows a format that takes comments, only this file changes.
@MainActor
@Observable
final class ConfigStore {

    static let shared = ConfigStore()

    static let url = StateStore.directory.appendingPathComponent("config.json")

    var configuration: Configuration {
        didSet {
            guard configuration != oldValue else { return }
            scheduleSave()
        }
    }

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private init() {
        var loaded = (try? Data(contentsOf: Self.url))
            .flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) }
            ?? Configuration()
        loaded.normalise()
        configuration = loaded
    }

    // MARK: - Editing

    func setEnabled(_ column: FileColumn, _ enabled: Bool) {
        guard column.isRemovable else { return }
        if enabled {
            configuration.enabledColumns.insert(column)
        } else {
            configuration.enabledColumns.remove(column)
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        var order = configuration.columnOrder
        order.move(fromOffsets: source, toOffset: destination)
        configuration.columnOrder = order
        configuration.normalise()   // keeps Name first whatever the drag did
    }

    /// Reorder favourites by dragging them in the sidebar.
    func moveFavourites(from source: IndexSet, to destination: Int) {
        var list = configuration.favourites
        list.move(fromOffsets: source, toOffset: destination)
        configuration.favourites = list
    }

    func resetToDefaults() {
        configuration = Configuration()
    }

    // MARK: - Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(configuration) else { return }
        try? FileManager.default.createDirectory(at: StateStore.directory,
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }
}
