import Foundation
import Observation

/// State of one pane: which directory it shows, the rows, the selection.
///
/// `@Observable` is Swift's built-in change tracking. SwiftUI reads the
/// properties a view actually touches and re-renders only when those change --
/// no listeners to register, no fireTableDataChanged() to remember.
///
/// `@MainActor` pins the whole class to the main thread. That is the same rule
/// as Swing's event dispatch thread, with one large difference: here the
/// *compiler* enforces it. Calling into this type from a background context
/// without an `await` will not build.
@MainActor
@Observable
final class PaneModel {

    private(set) var directory: URL
    private(set) var items: [FileItem] = []
    private(set) var isLoading = false
    private(set) var errorText: String?

    var selection: Set<FileItem.ID> = [] {
        didSet {
            // Keep an open Quick Look panel in step with the cursor, so arrowing
            // through a directory previews each file as Finder does.
            guard QuickLookController.shared.isVisible else { return }
            QuickLookController.shared.update(selectedItems.map(\.url))
        }
    }
    var sortOrder: [FileComparator] = [FileComparator(column: .name)] {
        didSet { owner?.persist() }
    }
    var showHidden = false { didSet { reload() } }

    /// The row currently being renamed in place, and the text being edited.
    var renamingID: FileItem.ID?
    var renameText = ""

    /// A row to select and scroll to once the next load finishes. Set before
    /// `reload()`: after a rename the file may sort somewhere else entirely, and
    /// selecting it before the new listing arrives would land on the old index.
    var pendingReveal: FileItem.ID?

    /// The row whose permissions cell is being edited, and the nine characters
    /// being edited. The edit applies to the whole selection, not just this row.
    var permissionEditAnchor: FileItem.ID?
    var permissionText = ""


    private var loadTask: Task<Void, Never>?

    /// Live refresh. A kqueue watch on the directory's own descriptor: the
    /// kernel tells us when entries appear or vanish, so a file removed by
    /// Finder or `rm` stops showing up here as a stale row.
    /// The window model, so a pane change can trigger a save.
    @ObservationIgnored weak var owner: AppModel?

    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var watchedPath: String?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(directory: URL) {
        self.directory = directory
    }

    /// Rows as displayed: sorted by the column the user clicked, but with `..`
    /// and directories always pinned above files. Sorting a mixed list purely by
    /// name is what separates a file *list* from a file *manager*.
    var rows: [FileItem] {
        let sorted = items.sorted(using: sortOrder)
        return sorted.filter(\.isParent)
            + sorted.filter { !$0.isParent && $0.isEnterable }
            + sorted.filter { !$0.isEnterable }
    }

    /// Every selected row, `..` included -- what *navigation* acts on.
    var selectedRows: [FileItem] {
        rows.filter { selection.contains($0.id) }
    }

    /// Selected rows without `..` -- what copy / move / rename / trash act on,
    /// so no keystroke can ever target the parent-directory entry.
    ///
    /// Navigation must not use this: filtering `..` out here is what made
    /// Return and Cmd-Down do nothing when the cursor sat on `..`.
    var selectedItems: [FileItem] {
        selectedRows.filter { !$0.isParent }
    }

    // MARK: - Navigation

    func navigate(to url: URL) {
        directory = url
        selection = []
        renamingID = nil
        reload()
        owner?.persist()
    }

    // MARK: - Persistence

    var snapshot: PaneState {
        PaneState(directory: directory.path,
                  sortField: (sortOrder.first?.column ?? .name).rawValue,
                  sortAscending: (sortOrder.first?.order ?? .forward) == .forward)
    }

    func restore(_ state: PaneState) {
        directory = URL(fileURLWithPath: state.directory)
        sortOrder = [FileComparator(column: FileColumn(rawValue: state.sortField) ?? .name,
                                    order: state.sortAscending ? .forward : .reverse)]
    }

    func goUp() {
        guard directory.pathComponents.count > 1 else { return }
        let leaving = directory
        directory = directory.deletingLastPathComponent()
        reload()
        // Land the cursor on the directory we just came out of, which is what
        // every keyboard-driven file manager does.
        selection = [leaving]
    }

    func open(_ item: FileItem) {
        if item.isParent {
            goUp()
            return
        }

        // fileExists follows symlinks, so this is false exactly when the link is
        // broken -- the row is listed, but there is nothing on the other end.
        guard FileManager.default.fileExists(atPath: item.url.path) else {
            owner?.flash("\u{201C}\(item.name)\u{201D} can\u{2019}t be opened \u{2014} the link is broken")
            return
        }

        if item.isEnterable {
            // Follow the link to where it actually points, the way Finder does.
            // Navigating to the link path itself lists the right contents but
            // leaves the path bar and `..` describing the link's location
            // rather than the target's.
            navigate(to: item.isSymlink ? item.url.resolvingSymlinksInPath() : item.url)
        } else {
            NSWorkspaceOpener.open(item.url)
        }
    }

    // MARK: - Loading

    deinit {
        watcher?.cancel()
    }

    /// Watch `directory`, replacing any previous watch. Cheap to call often --
    /// it is a no-op when the path has not changed.
    private func watchDirectory() {
        let path = directory.path
        guard path != watchedPath else { return }

        watcher?.cancel()
        watcher = nil
        watchedPath = nil

        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: .main)

        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.directoryChanged() }
        }
        // The cancel handler owns closing the descriptor; closing it anywhere
        // else races the source and can shut down an unrelated file.
        source.setCancelHandler { Darwin.close(fd) }

        watcher = source
        watchedPath = path
        source.resume()
    }

    private func directoryChanged() {
        // Coalesce: a single `rm -r` or a copy in Finder produces a burst of
        // events, and reloading on each one would thrash the pane.
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    func reload() {
        watchDirectory()
        // Cancel any listing still in flight. Without this, walking quickly
        // through directories lets a slow network volume deliver its rows after
        // you have already moved on, and the pane shows the wrong folder.
        loadTask?.cancel()

        let target = directory
        let hidden = showHidden
        let columns = ConfigStore.shared.configuration.columns
        isLoading = true
        errorText = nil

        loadTask = Task { [weak self] in
            do {
                let loaded = try await DirectoryLoader.shared.load(directory: target,
                                                                   showHidden: hidden,
                                                                   columns: columns)
                guard !Task.isCancelled else { return }
                self?.finish(loaded, for: target)
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error, for: target)
            }
        }
    }

    private func finish(_ loaded: [FileItem], for target: URL) {
        guard target == directory else { return }   // a newer navigation won
        items = loaded
        isLoading = false

        if let reveal = pendingReveal {
            pendingReveal = nil
            if loaded.contains(where: { $0.id == reveal }) {
                selection = [reveal]
                owner?.scrollSelectionIntoView()
                return
            }
        }
        selection = selection.filter { id in loaded.contains { $0.id == id } }
    }

    private func fail(_ error: Error, for target: URL) {
        guard target == directory else { return }
        items = directory.pathComponents.count > 1 ? [FileItem.parent(of: directory)] : []
        isLoading = false
        errorText = error.localizedDescription
    }
}
