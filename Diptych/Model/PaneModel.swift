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

    @ObservationIgnored private var isCorrectingSelection = false

    var selection: Set<FileItem.ID> = [] {
        didSet {
            // A greyed-out row is not selectable. Correcting here catches every
            // route into the selection -- clicking, arrow keys, Select All.
            if !isCorrectingSelection, hasFilter, filterIsValid, !filterHidesOthers {
                let allowed = rows.filter { selection.contains($0.id) && matchesFilter($0) }
                    .map(\.id)
                if allowed.count != selection.count {
                    isCorrectingSelection = true
                    selection = Set(allowed)
                    isCorrectingSelection = false
                    return
                }
            }
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

    /// Rows to select and scroll to once the next load finishes. Set before
    /// `reload()`: after a rename or a move the files may sort somewhere else
    /// entirely, and selecting them before the new listing arrives would land on
    /// stale indexes.
    var pendingSelection: Set<FileItem.ID> = []

    // MARK: - Filter

    /// A glob by default -- `*.txt`, matched by fnmatch, the same routine the
    /// shell uses -- or a regular expression when `filterIsRegex` is on, where
    /// the equivalent is `.*\.txt`. Matching is case-insensitive, because the
    /// file system is.
    var filterText = "" { didSet { rebuildFilter() } }
    var filterIsRegex = false { didSet { rebuildFilter() } }
    /// Off: non-matching rows are greyed out and cannot be selected.
    /// On: they are not listed at all.
    var filterHidesOthers = false

    private(set) var filterIsValid = true
    @ObservationIgnored private var filterRegex: NSRegularExpression?

    var hasFilter: Bool { !filterText.trimmingCharacters(in: .whitespaces).isEmpty }

    private func rebuildFilter() {
        let pattern = filterText.trimmingCharacters(in: .whitespaces)
        filterRegex = nil
        filterIsValid = true

        guard !pattern.isEmpty else { return }
        guard filterIsRegex else { return }

        // Anchored, so a regex filters the way a glob does: `.*\.txt` matches
        // the whole name rather than finding "txt" anywhere in it.
        filterRegex = try? NSRegularExpression(pattern: "^(?:\(pattern))$",
                                               options: [.caseInsensitive])
        filterIsValid = filterRegex != nil
    }

    /// `..` always matches: it is navigation, not content.
    func matchesFilter(_ item: FileItem) -> Bool {
        guard hasFilter, filterIsValid else { return true }
        if item.isParent { return true }

        if let regex = filterRegex {
            let range = NSRange(item.name.startIndex..., in: item.name)
            return regex.firstMatch(in: item.name, options: [], range: range) != nil
        }

        let pattern = filterText.trimmingCharacters(in: .whitespaces)
        return fnmatch(pattern, item.name, FNM_CASEFOLD) == 0
    }

    // MARK: - History

    @ObservationIgnored private var history: [URL] = []
    @ObservationIgnored private var historyIndex = -1

    private(set) var canGoBack = false
    private(set) var canGoForward = false

    func goBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        navigate(to: history[historyIndex], recordingHistory: false)
    }

    func goForward() {
        guard historyIndex + 1 < history.count else { return }
        historyIndex += 1
        navigate(to: history[historyIndex], recordingHistory: false)
    }

    private func record(_ url: URL) {
        // Moving somewhere new after going back discards the forward trail,
        // exactly as a browser does.
        if historyIndex >= 0 && historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        if history.last != url {
            history.append(url)
            if history.count > 200 { history.removeFirst() }
        }
        historyIndex = history.count - 1
        updateHistoryFlags()
    }

    private func updateHistoryFlags() {
        canGoBack = historyIndex > 0
        canGoForward = historyIndex + 1 < history.count
    }

    /// True while the path bar is an open text field. The pane must not
    /// relocate itself underneath a path being typed.
    var isEditingPath = false

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
        history = [directory]
        historyIndex = 0
    }

    /// Rows as displayed: sorted by the column the user clicked, but with `..`
    /// and directories always pinned above files. Sorting a mixed list purely by
    /// name is what separates a file *list* from a file *manager*.
    var rows: [FileItem] {
        let visible = (hasFilter && filterHidesOthers && filterIsValid)
            ? items.filter { matchesFilter($0) }
            : items
        let sorted = visible.sorted(using: sortOrder)
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

    func navigate(to url: URL, recordingHistory: Bool = true) {
        directory = url
        selection = []
        renamingID = nil
        if recordingHistory { record(url) } else { updateHistoryFlags() }
        reload()
        owner?.persist()
    }

    /// The closest folder above `url` that still exists -- much less jarring
    /// than jumping to the home directory from somewhere deep.
    static func nearestExistingAncestor(of url: URL) -> URL {
        let fm = FileManager.default
        var candidate = url.deletingLastPathComponent()

        while candidate.pathComponents.count > 1 {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }
        return fm.homeDirectoryForCurrentUser
    }

    // MARK: - Persistence

    var snapshot: PaneState {
        PaneState(directory: directory.path,
                  sortField: (sortOrder.first?.column ?? .name).rawValue,
                  sortAscending: (sortOrder.first?.order ?? .forward) == .forward)
    }

    func restore(_ state: PaneState) {
        directory = URL(fileURLWithPath: state.directory)
        history = [directory]
        historyIndex = 0
        updateHistoryFlags()
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

        if !pendingSelection.isEmpty {
            let wanted = pendingSelection
            pendingSelection = []
            let present = wanted.filter { id in loaded.contains { $0.id == id } }
            if !present.isEmpty {
                selection = present
                owner?.scrollSelectionIntoView()
                return
            }
        }
        selection = selection.filter { id in loaded.contains { $0.id == id } }
    }

    private func fail(_ error: Error, for target: URL) {
        guard target == directory else { return }

        // The directory itself is gone -- deleted from under us, or renamed.
        if !FileManager.default.fileExists(atPath: target.path) {
            // ...but not while a path is being typed. Yanking the pane
            // elsewhere mid-edit throws away what the user was doing; this is
            // settled when they finish or press Escape.
            guard !isEditingPath else {
                items = []
                isLoading = false
                errorText = "This folder is no longer there"
                return
            }
            owner?.flash("\u{201C}\(target.lastPathComponent)\u{201D} is no longer there")
            navigate(to: Self.nearestExistingAncestor(of: target))
            return
        }

        items = directory.pathComponents.count > 1 ? [FileItem.parent(of: directory)] : []
        isLoading = false
        errorText = error.localizedDescription
    }
}
