import Foundation
import AppKit
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
            // The panes redraw themselves -- they read the font during body --
            // but the row height lives on the NSTableView underneath, which no
            // amount of SwiftUI invalidation reaches.
            if configuration.fontSize != oldValue.fontSize
                || configuration.fontName != oldValue.fontName {
                RowHeights.applyEverywhere()
            }
            if configuration.mcpServerEnabled != oldValue.mcpServerEnabled
                || configuration.mcpServerPort != oldValue.mcpServerPort {
                let enabled = configuration.mcpServerEnabled
                let port = configuration.mcpServerPort
                let token = configuration.mcpServerToken
                Task { await MCPServer.shared.applyConfiguration(
                    enabled: enabled, port: port, token: token) }
            }
            scheduleSave()
        }
    }

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private init() {
        // A debounced save can still be pending when the app quits -- the same
        // observer StateStore has, which configuration was missing.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ConfigStore.shared.saveNow() }
        }

        var loaded: Configuration
        do {
            let data = try Data(contentsOf: Self.url)
            loaded = try JSONDecoder().decode(Configuration.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            loaded = Configuration()
        } catch {
            // Falling back to defaults either way -- a corrupt or
            // incompatible config file must not keep the app from
            // launching -- but silently is how this kind of thing goes
            // unnoticed for a long time.
            NSLog("Diptych: ~/.diptych/config.json failed to decode, using defaults: \(error)")
            loaded = Configuration()
        }
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

    /// Drag a toolbar button up or down. Order within a side follows this one
    /// list, so moving a button and changing which side it is on are separate
    /// decisions rather than one tangled control.
    func moveToolbar(from source: IndexSet, to destination: Int) {
        var slots = configuration.toolbarSlots
        slots.move(fromOffsets: source, toOffset: destination)
        configuration.toolbar = slots
    }

    func setToolbar(_ button: ToolbarButton, shown: Bool? = nil, side: ToolbarSide? = nil) {
        var slots = configuration.toolbarSlots
        guard let index = slots.firstIndex(where: { $0.button == button }) else { return }
        if let shown { slots[index].isShown = shown }
        if let side { slots[index].side = side }
        configuration.toolbar = slots
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

    /// Switches the MCP server on or off, generating and persisting a bearer
    /// token first if one doesn't exist yet -- a config file written before
    /// this feature existed carries no token, and an empty one would be no
    /// token check at all. Generating it in a separate assignment, before
    /// `mcpServerEnabled` changes, means the `didSet` above always sees the
    /// real token on the one assignment that actually starts the server,
    /// rather than racing a second, unobserved change against it.
    func setMCPServerEnabled(_ enabled: Bool) {
        if enabled && configuration.mcpServerToken.isEmpty {
            configuration.mcpServerToken = UUID().uuidString
        }
        configuration.mcpServerEnabled = enabled
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
