import Foundation
import AppKit

/// What one pane remembers across launches.
///
/// This is the extension point the persistence design turns on: add a property
/// here plus a line in `PaneModel.snapshot` / `restore`, and it is saved,
/// reloaded and carried across a pane swap. Nothing else has to change --
/// not the store, not the window code, not the JSON handling.
struct PaneState: Codable, Equatable {
    var directory: String
    var sortField: String = "name"
    var sortAscending: Bool = true
}

/// What one window remembers.
struct WindowState: Codable, Equatable {
    /// NSStringFromRect form, e.g. "{{100, 200}, {1100, 680}}".
    var frame: String?
    var left: PaneState
    var right: PaneState
    var activeSide: String = "left"
    var singlePane: Bool = false
    var showHidden: Bool = false
}

struct DiptychState: Codable, Equatable {
    var windows: [WindowState] = []
}

/// Reads and writes `~/.diptych`.
///
/// JSON, pretty-printed, keys sorted, slashes unescaped -- so the file is
/// genuinely hand-editable rather than merely text.
@MainActor
final class StateStore {

    static let shared = StateStore()

    /// A directory, not a file. State lives in state.json; configuration will
    /// get its own files alongside it -- in a format that takes comments, which
    /// is exactly what JSON cannot do.
    static let directory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".diptych")

    static let stateURL = directory.appendingPathComponent("state.json")

    private(set) var state = DiptychState()
    private var saveTask: Task<Void, Never>?

    private init() {
        load()
        // A debounced save can still be pending when the app quits.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { StateStore.shared.saveNow() }
        }
    }

    private func load() {
        prepareDirectory()
        guard let data = try? Data(contentsOf: Self.stateURL) else { return }
        // A hand-edited file can be malformed; falling back to defaults beats
        // refusing to launch.
        state = (try? JSONDecoder().decode(DiptychState.self, from: data)) ?? DiptychState()
    }

    /// Create ~/.diptych, converting the old plain-file layout if it is there.
    private func prepareDirectory() {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false

        if fm.fileExists(atPath: Self.directory.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else { return }
            // Earlier versions wrote the state as ~/.diptych itself. Lift it
            // into the new layout rather than discarding the user's session.
            let legacy = try? Data(contentsOf: Self.directory)
            try? fm.removeItem(at: Self.directory)
            try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            if let legacy { try? legacy.write(to: Self.stateURL) }
            return
        }

        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
    }

    func window(_ index: Int) -> WindowState? {
        state.windows.indices.contains(index) ? state.windows[index] : nil
    }

    func update(_ index: Int, _ windowState: WindowState) {
        if state.windows.indices.contains(index) {
            // Nothing changed: skip the write rather than rewriting the file on
            // every notification.
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(state) else { return }
        prepareDirectory()
        try? data.write(to: Self.stateURL, options: .atomic)
    }
}
