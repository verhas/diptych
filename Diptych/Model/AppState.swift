import Foundation
import AppKit

/// What one pane remembers across launches.
///
/// This is the extension point the persistence design turns on: add a property
/// here, a line in `PaneModel.snapshot` / `restore`, a column of `pane_state`
/// -- with `ALTER TABLE` in `LocalDatabase.records`, as the table is already
/// in people's files -- and its place in `StateStore.write` / `read`, and it
/// is saved, reloaded and carried across a pane swap. The window code needs
/// no change. Decoding stays, for 1.x's `state.json`.
struct PaneState: Codable, Equatable {
    var directory: String
    var sortField: String = "name"
    var sortAscending: Bool = true
    /// The folders it has been in, most recent first, each once.
    var recent: [String] = []
    /// What was typed in the flat view's expression field.
    var flatDraft: String = ""
    /// The expression of the flat view the pane is showing; nil when it is
    /// an ordinary folder.
    var flatExpression: String?
    /// "list" or "icons", and in the icon view "byName" or "finder".
    var viewStyle: String = "list"
    var iconArrangement: String = "byName"

    init(directory: String, sortField: String = "name", sortAscending: Bool = true,
         recent: [String] = [], flatDraft: String = "", flatExpression: String? = nil,
         viewStyle: String = "list", iconArrangement: String = "byName") {
        self.directory = directory
        self.sortField = sortField
        self.sortAscending = sortAscending
        self.recent = recent
        self.flatDraft = flatDraft
        self.flatExpression = flatExpression
        self.viewStyle = viewStyle
        self.iconArrangement = iconArrangement
    }

    /// Tolerant, like Configuration's: the synthesized decoder throws on a
    /// missing key, so adding a field would discard the whole saved session.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        directory = (try? container.decode(String.self, forKey: .directory)) ?? ""
        sortField = (try? container.decode(String.self, forKey: .sortField)) ?? "name"
        sortAscending = (try? container.decode(Bool.self, forKey: .sortAscending)) ?? true
        recent = (try? container.decode([String].self, forKey: .recent)) ?? []
        flatDraft = (try? container.decode(String.self, forKey: .flatDraft)) ?? ""
        flatExpression = try? container.decode(String.self, forKey: .flatExpression)
        viewStyle = (try? container.decode(String.self, forKey: .viewStyle)) ?? "list"
        iconArrangement = (try? container.decode(String.self, forKey: .iconArrangement)) ?? "byName"
    }
}

/// What one window remembers.
struct WindowState: Codable, Equatable {
    /// NSStringFromRect form, e.g. "{{100, 200}, {1100, 680}}".
    var frame: String?
    var left: PaneState
    var right: PaneState
    var activeSide: String = "left"
    var singlePane: Bool = false
    var sidebarVisible: Bool = false
    var showHidden: Bool = false

    init(frame: String?, left: PaneState, right: PaneState, activeSide: String = "left",
         singlePane: Bool = false, sidebarVisible: Bool = false, showHidden: Bool = false) {
        self.frame = frame
        self.left = left
        self.right = right
        self.activeSide = activeSide
        self.singlePane = singlePane
        self.sidebarVisible = sidebarVisible
        self.showHidden = showHidden
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        frame = try? container.decode(String.self, forKey: .frame)
        left = (try? container.decode(PaneState.self, forKey: .left)) ?? PaneState(directory: home)
        right = (try? container.decode(PaneState.self, forKey: .right)) ?? PaneState(directory: home)
        activeSide = (try? container.decode(String.self, forKey: .activeSide)) ?? "left"
        singlePane = (try? container.decode(Bool.self, forKey: .singlePane)) ?? false
        sidebarVisible = (try? container.decode(Bool.self, forKey: .sidebarVisible)) ?? false
        showHidden = (try? container.decode(Bool.self, forKey: .showHidden)) ?? false
    }
}

struct DiptychState: Codable, Equatable {
    var windows: [WindowState] = []
}

/// The windows and panes as they were left, in the `window_state`,
/// `pane_state` and `pane_recent` tables of `LocalDatabase.records`.
///
/// 1.x kept this in `~/.diptych/state.json` -- and the earliest versions in
/// the file `~/.diptych` itself -- which `LegacyRecords` brings in.
@MainActor
final class StateStore {

    static let shared = StateStore()

    /// `~/.diptych`: Diptych's own folder, made when the records are opened.
    static let directory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".diptych")

    private(set) var state = DiptychState()
    private var saveTask: Task<Void, Never>?
    private let database: LocalDatabase

    private init() {
        database = .records
        state = Self.read(from: database)
        // A debounced save can still be pending when the app quits.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { StateStore.shared.saveNow() }
        }
    }

    func window(_ index: Int) -> WindowState? {
        state.windows.indices.contains(index) ? state.windows[index] : nil
    }

    func update(_ index: Int, _ windowState: WindowState) {
        if state.windows.indices.contains(index) {
            // Nothing changed: skip the write rather than writing on every
            // notification.
            guard state.windows[index] != windowState else { return }
            state.windows[index] = windowState
        } else {
            // Grow to reach this slot. Comparing after appending would find the
            // value already equal to itself and skip the save entirely.
            while state.windows.count < index {
                state.windows.append(windowState)
            }
            state.windows.append(windowState)
        }
        scheduleSave()
    }

    /// Dragging a window emits a stream of move notifications; write once the
    /// dust settles rather than once per pixel.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let state = self.state
        _ = try? database.transaction { Self.write(state, in: $0) }
    }

    // MARK: - The tables

    /// Every window replaced by `state`'s, in one transaction's connection.
    nonisolated static func write(_ state: DiptychState, in connection: LocalDatabase.Connection) {
        // The panes and their recent folders go with their window.
        connection.run("DELETE FROM window_state")
        for (slot, window) in state.windows.enumerated() {
            let slot = Int64(slot)
            connection.run("""
                INSERT INTO window_state (slot, frame, active_side, single_pane, sidebar_visible, show_hidden)
                VALUES (?, ?, ?, ?, ?, ?)
                """, .int(slot), .optional(window.frame), .text(window.activeSide),
                .int(window.singlePane ? 1 : 0), .int(window.sidebarVisible ? 1 : 0), .int(window.showHidden ? 1 : 0))
            for (side, pane) in [("left", window.left), ("right", window.right)] {
                connection.run("""
                    INSERT INTO pane_state (slot, side, directory, sort_field, sort_ascending, flat_draft,
                      flat_expression, view_style, icon_arrangement) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, .int(slot), .text(side), .text(pane.directory), .text(pane.sortField),
                    .int(pane.sortAscending ? 1 : 0), .text(pane.flatDraft), .optional(pane.flatExpression),
                    .text(pane.viewStyle), .text(pane.iconArrangement))
                connection.runEach("INSERT INTO pane_recent (slot, side, position, path) VALUES (?, ?, ?, ?)",
                                   pane.recent.enumerated().map {
                                       [.int(slot), .text(side), .int(Int64($0.offset)), .text($0.element)]
                                   })
            }
        }
    }

    nonisolated static func read(from database: LocalDatabase) -> DiptychState {
        database.access { connection in
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var recents: [String: [String]] = [:]
            for (key, path) in connection.rows(
                "SELECT slot, side, path FROM pane_recent ORDER BY slot, side, position", read: { row in
                    ("\(row.int(0) ?? 0)/\(row.text(1) ?? "")", row.text(2) ?? "")
                }) {
                recents[key, default: []].append(path)
            }
            var panes: [String: PaneState] = [:]
            for (key, pane) in connection.rows("""
                SELECT slot, side, directory, sort_field, sort_ascending, flat_draft, flat_expression,
                  view_style, icon_arrangement FROM pane_state
                """, read: { row -> (String, PaneState) in
                    let key = "\(row.int(0) ?? 0)/\(row.text(1) ?? "")"
                    return (key, PaneState(directory: row.text(2) ?? home, sortField: row.text(3) ?? "name",
                                           sortAscending: row.int(4) != 0, recent: [],
                                           flatDraft: row.text(5) ?? "", flatExpression: row.text(6),
                                           viewStyle: row.text(7) ?? "list",
                                           iconArrangement: row.text(8) ?? "byName"))
                }) {
                var pane = pane
                pane.recent = recents[key] ?? []
                panes[key] = pane
            }
            let windows = connection.rows("""
                SELECT slot, frame, active_side, single_pane, sidebar_visible, show_hidden
                FROM window_state ORDER BY slot
                """, read: { row -> WindowState in
                    let slot = row.int(0) ?? 0
                    return WindowState(frame: row.text(1),
                                       left: panes["\(slot)/left"] ?? PaneState(directory: home),
                                       right: panes["\(slot)/right"] ?? PaneState(directory: home),
                                       activeSide: row.text(2) ?? "left", singlePane: row.int(3) == 1,
                                       sidebarVisible: row.int(4) == 1, showHidden: row.int(5) == 1)
                })
            return DiptychState(windows: windows)
        }
    }
}
