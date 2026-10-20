import Foundation
import AppKit
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

    private(set) var directory: URL {
        didSet { manualOrder = nil }
    }
    private(set) var items: [FileItem] = []
    private(set) var isLoading = false
    /// Set while a *different* directory is being read, as opposed to the
    /// current one being refreshed in place.
    ///
    /// The two are not the same thing at all. A refresh can leave the rows on
    /// screen; a navigation must not. Keeping the old listing visible while a
    /// slow volume spun up meant the pane was showing one directory, saying it
    /// was in another, and accepting double-clicks against the rows of the
    /// first -- which then opened whatever happened to sit at that row index in
    /// the second.
    private(set) var loadingDirectory: URL?
    /// Where this directory's repository is, and how far it is from the shared
    /// copy. nil when the folder is not in a repository, or Git is off.
    private(set) var gitRoot: URL?
    private(set) var gitBranch: String?
    private(set) var gitAhead = 0
    private(set) var gitBehind = 0
    /// When *Check for Changes* last ran here, or nil if it has not (or the
    /// answer has gone too old to show). Drawn next to the counts, because a
    /// number about the server means nothing without its age.
    private(set) var gitCheckedAt: Date?
    @ObservationIgnored private var gitTask: Task<Void, Never>?
    /// Where cancelling goes back to.
    @ObservationIgnored private var directoryBeforeLoad: URL?

    var isNavigating: Bool { loadingDirectory != nil }
    /// How many entries of the folder being opened have been read so far:
    /// what a slow server shows while it is being listed.
    private(set) var loadedCount = 0
    /// Set while the rows are the ones a server's folder had when it was
    /// last listed -- shown at once, and replaced when it has been read again.
    private(set) var listedEarlier: Date?
    private(set) var errorText: String?
    /// An archive being unpacked to be shown here.
    var openingArchive: OpeningArchive?
    /// Set when the failure was TCC refusing access rather than the folder
    /// being missing or broken -- Time Machine volumes are the common case.
    private(set) var errorIsPermission = false

    @ObservationIgnored private var isCorrectingSelection = false

    var selection: Set<FileItem.ID> = [] {
        didSet {
            // A greyed-out row is not selectable. Correcting here catches every
            // route into the selection -- clicking, arrow keys, Select All.
            //
            // Next turn of the run loop, never from inside this `didSet`:
            // writing the selection back while SwiftUI is delivering a change
            // to it left the table and the model disagreeing from then on.
            // AppKit went on highlighting whatever was clicked while the model
            // held nothing, so the status line said no selection, F5 and F6
            // had nothing to act on, and the only way out was to click the
            // other pane. Deferring keeps the correction and loses the fight.
            if !isCorrectingSelection, hasFilter, filterIsValid, !filterHidesOthers {
                let allowed = rows.filter { selection.contains($0.id) && matchesFilter($0) }
                    .map(\.id)
                if allowed.count != selection.count {
                    let wanted = Set(allowed)
                    Task { @MainActor [weak self] in
                        guard let self, self.selection != wanted else { return }
                        self.isCorrectingSelection = true
                        self.selection = wanted
                        self.isCorrectingSelection = false
                    }
                    return
                }
            }
            // Keep an open Quick Look panel in step with the cursor, so arrowing
            // through a directory previews each file as Finder does.
            //
            // `selectedRows`, not `selectedItems`: the latter leaves out `..`,
            // so arrowing onto it emptied the panel and shut it. `..` is a
            // folder like any other, and Diptych previews a folder by listing
            // it -- which is exactly what somebody about to go up wants to see.
            guard QuickLookController.shared.isVisible else { return }
            // Only the pane the panel follows: the other one, reloaded after
            // a change made here, took the panel to its own selection.
            if let owner, owner.active !== self { return }
            QuickLookController.shared.update(selectedRows.map(\.url))
        }
    }
    var sortOrder: [FileComparator] = [FileComparator(column: .name)] {
        didSet { owner?.persist() }
    }
    /// The order made with Shift-Command-Up and -Down, in place of the sort
    /// until a column header is clicked or the pane goes to another folder.
    /// Not saved: it is for the moment, not for the folder.
    private(set) var manualOrder: ManualOrder<FileItem.ID>?
    var showHidden = false {
        didSet {
            // In a flat view, hidden folders change what is walked: the tree
            // again, or the walk remembered with them shown or not.
            if let flat {
                enter(flat, recordingHistory: false, rescan: false)
            } else {
                reload()
            }
        }
    }

    /// The row currently being renamed in place, and the text being edited.
    var renamingID: FileItem.ID?
    var renameText = ""

    /// The cell whose value is being edited in place -- a date, a picture's
    /// EXIF, a video's metadata -- the text typed, and what it was before.
    var valueEdit: CellEdit.Spot?
    var valueEditText = ""
    var valueEditStart = ""

    /// Rows to select and scroll to once the next load finishes. Set before
    /// `reload()`: after a rename or a move the files may sort somewhere else
    /// entirely, and selecting them before the new listing arrives would land on
    /// stale indexes.
    var pendingSelection: Set<FileItem.ID> = []
    /// Once the selection above is in place, open it as Return would: a file
    /// path typed into the path bar means "that file", not only its folder.
    var openAfterLoading = false

    // MARK: - Filter

    /// Plain text finds a fragment anywhere in the name: `inv` lists every
    /// invoice. A pattern with `*`, `?` or `[` in it is a glob instead, matched
    /// by fnmatch, the same routine the shell uses -- so `*.txt` and `inv*`
    /// mean what they always did. With `filterIsRegex` on it is a regular
    /// expression, matched against the whole name.
    ///
    /// Typing two stars around every word was the common case and the fiddly
    /// one, which is the wrong way round: the plain thing people type should be
    /// the thing they mean.
    var filterText = "" { didSet { rebuildFilter() } }
    var filterIsRegex = false { didSet { rebuildFilter() } }
    /// Off: non-matching rows are greyed out and cannot be selected.
    /// On: they are not listed at all.
    var filterHidesOthers = false { didSet { correctSelectionForFilter() } }

    private(set) var filterIsValid = true
    @ObservationIgnored private var filterRegex: NSRegularExpression?

    /// Never in a flat view, which has its expression instead.
    var hasFilter: Bool { !isFlat && !filterText.trimmingCharacters(in: .whitespaces).isEmpty }

    private func rebuildFilter() {
        let pattern = filterText.trimmingCharacters(in: .whitespaces)
        filterRegex = nil
        filterIsValid = true

        defer { correctSelectionForFilter() }

        guard !pattern.isEmpty else { return }
        guard filterIsRegex else { return }

        // Anchored, so a regex filters the way a glob does: `.*\.txt` matches
        // the whole name rather than finding "txt" anywhere in it.
        filterRegex = try? NSRegularExpression(pattern: "^(?:\(pattern))$",
                                               options: [.caseInsensitive])
        filterIsValid = filterRegex != nil
    }

    /// Drop anything the filter now excludes.
    ///
    /// Changing the filter used to leave an already-selected file selected
    /// while greying it out, and copy, move, chmod and Trash all still acted on
    /// it -- the opposite of what the greying says.
    private func correctSelectionForFilter() {
        guard !isCorrectingSelection, hasFilter, filterIsValid else { return }

        let allowed = rows.filter { selection.contains($0.id) && matchesFilter($0) }.map(\.id)
        guard allowed.count != selection.count else { return }

        // Deferred for the same reason as the correction in `selection`'s own
        // `didSet`: this runs while the filter text is being set, which is
        // also while SwiftUI is reading it.
        let wanted = Set(allowed)
        Task { @MainActor [weak self] in
            guard let self, self.selection != wanted else { return }
            self.isCorrectingSelection = true
            self.selection = wanted
            self.isCorrectingSelection = false
        }
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
        guard Self.isGlob(pattern) else {
            return item.name.range(of: pattern, options: [.caseInsensitive]) != nil
        }
        return fnmatch(pattern, item.name, FNM_CASEFOLD) == 0
    }

    /// Whether to read the filter as a shell pattern rather than as a fragment
    /// of a name. `[` counts because that is fnmatch's character class, and a
    /// name with a bracket in it is rare next to somebody meaning one.
    static func isGlob(_ pattern: String) -> Bool {
        pattern.contains(where: { $0 == "*" || $0 == "?" || $0 == "[" })
    }

    // MARK: - History

    /// Where the pane has been: a folder, or a flat view of one.
    enum Place: Equatable {
        case folder(URL)
        case flat(FlatView)

        var url: URL {
            switch self {
            case .folder(let url): url
            case .flat(let view):  view.root
            }
        }
    }

    /// Where the pane is now.
    var place: Place { flat.map(Place.flat) ?? .folder(directory) }

    @ObservationIgnored private var history: [Place] = []
    @ObservationIgnored private var historyIndex = -1

    private(set) var canGoBack = false
    private(set) var canGoForward = false

    func goBack() {
        guard let target = step(-1) else { return }
        go(to: target)
    }

    func goForward() {
        guard let target = step(1) else { return }
        go(to: target)
    }

    /// Somewhere from the history, which is not recorded again.
    private func go(to target: Place) {
        switch target {
        case .folder(let url):
            navigate(to: url, recordingHistory: false)
        case .flat(let view):
            // Back out of a folder opened from the flat view: the cursor is
            // put back on it.
            if case .folder(let from) = place { pendingSelection = [from] }
            enter(view, recordingHistory: false, rescan: false)
        }
    }

    /// Move through the history in one direction, stepping over anything that
    /// is no longer there and forgetting it on the way past.
    ///
    /// Reported: go into A/B, come back out, delete A/B, and everything before
    /// A/B became unreachable. Back landed on the deleted folder, the failure
    /// sent the pane to the nearest folder that still existed, and *that* was
    /// recorded as a fresh arrival -- which put the cursor back at the end of
    /// the trail. Every further press repeated the same three steps.
    ///
    /// So a folder that has gone is not somewhere to try and fail to go; it is
    /// removed, and the walk carries on in the same direction. What is left is
    /// a history of places that are still there.
    private func step(_ direction: Int) -> Place? {
        while true {
            let next = historyIndex + direction
            guard next >= 0, next < history.count else {
                updateHistoryFlags()
                return nil
            }
            if FileManager.default.fileExists(atPath: history[next].url.path) {
                historyIndex = next
                updateHistoryFlags()
                return history[next]
            }
            history.remove(at: next)
            // Going back, everything above the hole moves down, and the place
            // we are standing is one of them. Going forward, it does not.
            if direction < 0 { historyIndex -= 1 }
            collapse()
            updateHistoryFlags()
        }
    }

    private func record(_ place: Place) {
        // Moving somewhere new after going back discards the forward trail,
        // exactly as a browser does.
        if historyIndex >= 0 && historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        if history.last != place {
            history.append(place)
            if history.count > 200 { history.removeFirst() }
        }
        historyIndex = history.count - 1
        updateHistoryFlags()
    }

    /// Take a place that is gone out of the trail, keeping the cursor pointing
    /// at whatever it was pointing at.
    private func forget(_ url: URL) {
        while let index = history.firstIndex(where: { $0.url == url }) {
            history.remove(at: index)
            if index <= historyIndex { historyIndex -= 1 }
        }
        historyIndex = max(historyIndex, -1)
        collapse()
        updateHistoryFlags()
    }

    /// Join up the seam left by a removal.
    ///
    /// A folder may honestly appear in the trail more than once -- A, B, A, C
    /// is four journeys -- but not twice in a row, because going back from a
    /// place to the same place is a press that does nothing. Taking B out of
    /// that trail leaves exactly that, so the two are made one.
    private func collapse() {
        var index = 1
        while index < history.count {
            if history[index] == history[index - 1] {
                history.remove(at: index)
                if index <= historyIndex { historyIndex -= 1 }
            } else {
                index += 1
            }
        }
        historyIndex = min(max(historyIndex, history.isEmpty ? -1 : 0), history.count - 1)
    }

    // MARK: - Recent folders

    /// Every folder this pane has been in, most recent first, each once --
    /// for the circle between Back and Forward. Not the history: going back
    /// and then somewhere new drops the forward trail from that, as a browser
    /// does, and a folder dropped that way is still here.
    private(set) var recent: [URL] = []

    nonisolated static let recentLimit = 30

    /// `url` moved to the front, its older visit taken out.
    nonisolated static func remembering(_ url: URL, in recent: [URL]) -> [URL] {
        let key = url.standardizedFileURL.path
        return Array(([url] + recent.filter { $0.standardizedFileURL.path != key })
            .prefix(recentLimit))
    }

    /// What the circle offers: the recent folders that are not this one and
    /// are still there.
    var recentElsewhere: [URL] {
        recent.filter { $0.standardizedFileURL.path != directory.standardizedFileURL.path
            && FileManager.default.fileExists(atPath: $0.path) }
    }

    private func updateHistoryFlags() {
        // Somewhere *else*, not merely somewhere. After a deletion the trail
        // can hold the folder you are standing in on both sides of the hole,
        // and a button that offers to take you where you already are is a
        // button that does nothing.
        let here = place
        canGoBack = history[..<max(historyIndex, 0)].contains { $0 != here }
        canGoForward = history.count > historyIndex + 1
            && history[(historyIndex + 1)...].contains { $0 != here }
    }

    /// True while the path bar is an open text field. The pane must not
    /// relocate itself underneath a path being typed.
    var isEditingPath = false

    /// The row whose permissions cell is being edited, and the nine characters
    /// being edited. The edit applies to the whole selection, not just this row.
    var permissionEditAnchor: FileItem.ID?
    var permissionMode: mode_t = 0


    private var loadTask: Task<Void, Never>?

    /// Live refresh. A kqueue watch on the directory's own descriptor: the
    /// kernel tells us when entries appear or vanish, so a file removed by
    /// Finder or `rm` stops showing up here as a stale row.
    /// The window model, so a pane change can trigger a save.
    @ObservationIgnored weak var owner: AppModel?

    /// What the folder is on: this Mac's own disk, or a server -- where it
    /// is never told of changes made elsewhere, and where some servers let
    /// nothing be written.
    private(set) var volume = VolumeFacts.local

    /// The server this folder is on, when it is not connected: the pane
    /// waits here, offering to connect, rather than going elsewhere.
    private(set) var awaitingServer: KnownServer?
    /// The folder last listed. A server's folder that vanishes from under it
    /// was disconnected on purpose, more often than not -- Finder's eject --
    /// and is not mounted again unasked; one arrived at is.
    @ObservationIgnored private var listed: URL?
    /// The servers known; the tests give it one of their own.
    @ObservationIgnored var servers = ServerStore.shared

    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var watchedPath: String?
    /// On a server, a look every few seconds for what changed there.
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// On a server, pictures' details read after the rows are shown.
    @ObservationIgnored private var mediaTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(directory: URL) {
        self.directory = directory
        history = [.folder(directory)]
        historyIndex = 0
    }

    /// Rows as displayed: sorted by the column the user clicked, but with `..`
    /// and directories always pinned above files. Sorting a mixed list purely by
    /// name is what separates a file *list* from a file *manager*.
    var rows: [FileItem] {
        let ordered = arranged
        guard hasFilter && filterHidesOthers && filterIsValid else { return ordered }
        return ordered.filter { matchesFilter($0) }
    }

    /// Every row, the filter aside, in the order shown.
    private var arranged: [FileItem] {
        var all = items
        // By Size, a folder goes by its total as worked out so far -- read
        // once, so one sort sees one set of numbers -- and the rows are
        // sorted again as the totals change.
        if sortOrder.contains(where: { $0.column == .size }), !DirectorySizes.shared.isEmpty {
            let folders = all.indices.filter { all[$0].isDirectory && !all[$0].isParent }
            let sizes = DirectorySizes.shared.store.sizes(folders.map { all[$0].url.path })
            for index in folders { all[index].folderTotal = sizes[all[index].url.path] }
        }
        let sorted = all.sorted(using: sortOrder)

        // `..` stays on top either way: it is navigation, not content, and a
        // row that moved around by size or date would be a trap.
        let parent = sorted.filter(\.isParent)
        let content = ConfigStore.shared.configuration.foldersFirst
            ? sorted.filter { !$0.isParent && $0.isEnterable } + sorted.filter { !$0.isEnterable }
            : sorted.filter { !$0.isParent }
        guard let manualOrder else { return parent + content }
        let byID = Dictionary(content.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return parent + manualOrder.arrange(content.map(\.id)).compactMap { byID[$0] }
    }

    /// Back to the order of the columns: a header clicked.
    func sort(by order: [FileComparator]) {
        manualOrder = nil
        sortOrder = order
    }

    /// Moves the selected rows one place up or down, past the row next to
    /// them, and keeps that order in place of the sort. Folders stay above
    /// files while Settings keeps them first, and `..` stays on top. False
    /// when nothing can move -- nothing selected, or the first row already
    /// at the edge.
    func moveSelectionManually(up: Bool) -> Bool {
        var shown = rows.filter { !$0.isParent }
        let chosen = Set(shown.map(\.id)).intersection(selection)
        guard !chosen.isEmpty else { return false }
        let foldersFirst = ConfigStore.shared.configuration.foldersFirst

        // The swaps worked out on the rows on screen, then made in the whole
        // listing: a row the filter hides is stepped over, not swapped with.
        var swaps: [(FileItem.ID, FileItem.ID)] = []
        let indices = Array(shown.indices.filter { chosen.contains(shown[$0].id) })
        for index in up ? indices : indices.reversed() {
            let other = up ? index - 1 : index + 1
            guard shown.indices.contains(other), !chosen.contains(shown[other].id),
                  !foldersFirst || shown[other].isEnterable == shown[index].isEnterable
            else { return false }
            swaps.append((shown[index].id, shown[other].id))
            shown.swapAt(index, other)
        }
        var order = arranged.filter { !$0.isParent }.map(\.id)
        for (one, two) in swaps {
            guard let first = order.firstIndex(of: one), let second = order.firstIndex(of: two)
            else { continue }
            order.swapAt(first, second)
        }
        manualOrder = ManualOrder(order: order, moved: (manualOrder?.moved ?? []).union(chosen))
        return true
    }

    /// Every selected row, `..` included -- what *navigation* acts on.
    ///
    /// Filtered-out rows are excluded here as well as being unselectable, so a
    /// selection that somehow outlives a filter change still cannot be operated
    /// on. The guard in `selection` keeps the UI honest; this keeps the file
    /// operations honest.
    var selectedRows: [FileItem] {
        rows.filter { selection.contains($0.id) && matchesFilter($0) }
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
        let previous = directory
        // Any navigation leaves a flat view: it is of one folder, and this
        // is going to a folder.
        let wasFlat = flat != nil
        if wasFlat { leaveFlatState() }
        if url != directory { awaitingServer = nil }
        directory = url
        selection = []
        renamingID = nil
        if recordingHistory { record(.folder(url)) } else { updateHistoryFlags() }
        recent = Self.remembering(url, in: recent)
        // From a flat view to its own folder is still a different listing:
        // the flat rows must not stand in for it while it loads.
        reload(navigatingFrom: previous == url && !wasFlat ? nil : previous)
        owner?.persist()
    }

    /// Abandons a navigation and goes back where it came from.
    ///
    /// The previous directory is warm -- it was on screen a moment ago -- so
    /// this is as fast as it looks. Not recorded in history: an abandoned
    /// journey is not somewhere you have been.
    func cancelLoad() {
        guard let back = directoryBeforeLoad, let abandoned = loadingDirectory else { return }
        loadTask?.cancel()
        loadingDirectory = nil
        directoryBeforeLoad = nil
        isLoading = false
        errorText = nil

        // Take the abandoned directory back out of the history. It was recorded
        // when the navigation began, and leaving it there would make Back walk
        // past where you actually are into somewhere you never arrived.
        if history.last == .folder(abandoned), history.count > 1 {
            history.removeLast()
            historyIndex = min(historyIndex, history.count - 1)
        }
        owner?.flash("Stopped loading. Back in \u{201C}\(back.lastPathComponent)\u{201D}.",
                     error: false)
        navigate(to: back, recordingHistory: false)
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

    /// An opened archive is gone when Diptych is next started: the pane is
    /// saved as next to it.
    var snapshot: PaneState {
        PaneState(directory: (ArchiveBrowsing.opened(containing: directory)?.archive
                                .deletingLastPathComponent() ?? directory).path,
                  sortField: (sortOrder.first?.column ?? .name).rawValue,
                  sortAscending: (sortOrder.first?.order ?? .forward) == .forward,
                  recent: recent.filter { !ArchiveBrowsing.isInside($0) }.map(\.path),
                  flatDraft: flatDraft,
                  flatExpression: ArchiveBrowsing.isInside(directory) ? nil : flat?.expression)
    }

    func restore(_ state: PaneState) {
        directory = URL(fileURLWithPath: state.directory)
        flatDraft = state.flatDraft
        // A flat view comes back flat; the next reload walks the tree again.
        if let expression = state.flatExpression {
            flat = FlatView(root: directory, expression: expression)
            flatQuery = try? FlatQuery.parse(expression).get()
        }
        history = [place]
        historyIndex = 0
        updateHistoryFlags()
        recent = Self.remembering(directory, in: state.recent.map { URL(fileURLWithPath: $0) })
        sortOrder = [FileComparator(column: FileColumn(rawValue: state.sortField) ?? .name,
                                    order: state.sortAscending ? .forward : .reverse)]
    }

    func goUp() {
        guard directory.pathComponents.count > 1 else { return }
        let leaving = directory

        // Out of the top of an opened archive: beside it, on it. Matched by
        // resolved path, not URL equality -- going up from a subfolder arrives
        // here with a trailing slash, which an absolute-string compare misses,
        // so Up would overshoot into the caches folder instead of leaving.
        if let opened = ArchiveBrowsing.openedRoot(at: directory) {
            navigate(to: opened.archive.deletingLastPathComponent())
            pendingSelection = [opened.archive]
            return
        }

        // Through navigate(), not by assigning `directory`: going up is a
        // navigation like any other and belongs in the history and in the saved
        // state. Setting the property directly skipped both.
        navigate(to: directory.deletingLastPathComponent())

        // Land the cursor on the directory we just came out of, which is what
        // every keyboard-driven file manager does.
        pendingSelection = [leaving]
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

        if !item.isEnterable, let owner, owner.opensInPane(item.url) {
            owner.openAsFolder(item.url, in: self)
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

    // MARK: - Flat view

    /// A folder and everything under it, as one list, filtered by an
    /// expression: what the history keeps for a flat view.
    struct FlatView: Equatable, Hashable {
        let root: URL
        let expression: String
    }

    /// Set while the pane is a flat view. It has no one folder then: nothing
    /// can be copied, moved or made into it.
    private(set) var flat: FlatView? {
        didSet { manualOrder = nil }
    }
    @ObservationIgnored private var flatQuery: FlatQuery?
    var isFlat: Bool { flat != nil }

    /// What is typed in the expression field, run or not.
    var flatDraft = ""

    /// How the walk is going, while it is.
    struct FlatProgress: Equatable {
        var found: Int
        var walk: FlatScanner.Progress
    }

    private(set) var flatProgress: FlatProgress?
    /// The walk was stopped: the rows are what it had found by then.
    private(set) var flatStopped = false
    /// Folders the walk could not read.
    private(set) var flatUnreadable: [URL] = []
    /// Something listed was changed -- renamed, its permissions set -- and
    /// no longer passes the expression. It stays listed: the view does not
    /// shift under the hand changing it. Only running the expression again
    /// makes the list fresh.
    private(set) var flatStale = false
    @ObservationIgnored private var flatTask: Task<Void, Never>?

    /// Walked trees, so Back to a flat view -- after opening a folder from
    /// it by mistake, say -- shows it at once. The last few, per pane.
    @ObservationIgnored private var flatCache: [(key: FlatCacheKey, rows: [FileItem],
                                                 stale: Bool)] = []
    nonisolated static let flatCacheLimit = 6

    private struct FlatCacheKey: Equatable {
        let view: FlatView
        let showHidden: Bool
    }

    /// The flat view button and View ▸ Flat View: into the flat view of this
    /// folder, or back out to the folder.
    func toggleFlat() {
        if let flat {
            navigate(to: flat.root)
        } else {
            enter(FlatView(root: directory, expression: flatDraft), recordingHistory: true,
                  rescan: false)
        }
    }

    /// The expression's button, or Return in it: the tree walked again with
    /// what is typed now. A changed expression is a new place in the history.
    func runFlat() {
        guard case .success = FlatQuery.parse(flatDraft) else { return }
        let view = FlatView(root: flat?.root ?? directory, expression: flatDraft)
        if view == flat {
            scanFlat()
        } else {
            enter(view, recordingHistory: true, rescan: true)
        }
    }

    /// A flat view of `root` with `expression`, walked afresh -- for an
    /// agent, which names both. False when the expression does not parse.
    @discardableResult
    func showFlat(of root: URL, expression: String) -> Bool {
        guard case .success = FlatQuery.parse(expression) else { return false }
        let view = FlatView(root: root, expression: expression)
        if view == flat {
            flatDraft = expression
            scanFlat()
        } else {
            enter(view, recordingHistory: true, rescan: true)
        }
        return true
    }

    /// The walk stopped where it is; what it found stays.
    func stopFlatScan() {
        guard flatProgress != nil else { return }
        flatTask?.cancel()
        flatTask = nil
        flatProgress = nil
        isLoading = false
        flatStopped = true
    }

    private func enter(_ view: FlatView, recordingHistory: Bool, rescan: Bool) {
        loadTask?.cancel()
        flatTask?.cancel()
        // Nothing to watch: the tree is not one folder, and a change in the
        // top one says nothing about the rest. Refresh re-reads the rows.
        watcher?.cancel()
        watcher = nil
        watchedPath = nil

        flat = view
        flatQuery = try? FlatQuery.parse(view.expression).get()
        flatDraft = view.expression
        directory = view.root
        renamingID = nil
        errorText = nil
        loadingDirectory = nil
        directoryBeforeLoad = nil
        flatStopped = false
        flatUnreadable = []
        flatStale = false
        if recordingHistory { record(.flat(view)) } else { updateHistoryFlags() }

        let key = FlatCacheKey(view: view, showHidden: showHidden)
        if !rescan, let cached = flatCache.first(where: { $0.key == key }) {
            items = cached.rows
            flatStale = cached.stale
            selection = []
            isLoading = false
            flatProgress = nil
            if !applyPendingSelection(in: items) { landOnSomethingToPreview() }
        } else {
            scanFlat()
        }
        owner?.persist()
    }

    /// Out of the flat view, to wherever the navigation goes.
    private func leaveFlatState() {
        flatTask?.cancel()
        flatTask = nil
        flatProgress = nil
        flat = nil
        flatQuery = nil
        flatStopped = false
        flatUnreadable = []
        flatStale = false
    }

    /// The tree walked, the rows arriving as they are found.
    private func scanFlat() {
        guard let view = flat else { return }
        if volume.isNetwork {
            owner?.flash("On a server: the flat view reads every folder below this one over "
                         + "the network. Stop ends it.", error: false)
        }
        flatTask?.cancel()
        loadTask?.cancel()
        items = []
        selection = []
        flatStopped = false
        flatUnreadable = []
        flatStale = false
        // An expression that does not parse lists nothing until it is put
        // right; the field says what is wrong.
        guard let query = flatQuery else {
            flatProgress = nil
            isLoading = false
            return
        }
        isLoading = true
        flatProgress = FlatProgress(found: 0, walk: .init(current: view.root))
        let key = FlatCacheKey(view: view, showHidden: showHidden)
        let stream = FlatScanner.scan(root: view.root, query: query, showHidden: showHidden,
                                      columns: ConfigStore.shared.configuration.columns)
        flatTask = Task { [weak self] in
            for await event in stream {
                guard let self, self.flat == view, !Task.isCancelled else { return }
                switch event {
                case .found(let batch, let walk):
                    self.items.append(contentsOf: batch)
                    self.flatProgress = FlatProgress(found: self.items.count, walk: walk)
                case .finished(let unreadable):
                    self.flatUnreadable = unreadable
                    self.flatProgress = nil
                    self.isLoading = false
                    self.remember(self.items, for: key)
                    self.applyPendingSelection(in: self.items)
                    self.decorateWithGit(for: view.root)
                }
            }
        }
    }

    private func remember(_ rows: [FileItem], for key: FlatCacheKey) {
        flatCache.removeAll { $0.key == key }
        flatCache.insert((key, rows, flatStale), at: 0)
        if flatCache.count > Self.flatCacheLimit { flatCache.removeLast() }
    }

    /// Refresh in a flat view: each row read again -- gone ones dropped --
    /// and the files an operation has just made added. Nothing is left out
    /// for no longer passing the expression: that only makes the view
    /// stale. The tree is not walked again; the expression's button does
    /// that.
    private func refreshFlat() {
        guard let view = flat, flatProgress == nil else { return }
        guard let query = flatQuery else { return }
        let key = FlatCacheKey(view: view, showHidden: showHidden)
        // Restored at launch, or with nothing found yet: walk it.
        if items.isEmpty, !flatStopped, !flatCache.contains(where: { $0.key == key }) {
            scanFlat()
            return
        }
        let current = items
        let wanted = pendingSelection
        let columns = ConfigStore.shared.configuration.columns
        let stopped = flatStopped
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let fresh = await BlockingWork.run { () -> (rows: [FileItem], stale: Bool) in
                var stale = false
                var rows: [FileItem] = []
                for item in current {
                    guard let row = FlatScanner.reread(item, columns: columns) else { continue }
                    // Only what changed is asked again: `contains` reads the
                    // whole file.
                    if Self.changed(item, row), !query.decide(FlatSubject(row)).list {
                        stale = true
                    }
                    rows.append(row)
                }
                let known = Set(rows.map(\.id.path))
                for url in wanted where !known.contains(url.path) {
                    if let row = FlatScanner.row(for: url, under: view.root, columns: columns) {
                        if !query.decide(FlatSubject(row)).list { stale = true }
                        rows.append(row)
                    }
                }
                return (rows, stale)
            }
            guard let self, !Task.isCancelled, self.flat == view else { return }
            self.items = fresh.rows
            if fresh.stale { self.flatStale = true }
            if !stopped { self.remember(fresh.rows, for: key) }
            if !self.applyPendingSelection(in: fresh.rows) {
                self.selection = self.selection.filter { id in fresh.rows.contains { $0.id == id } }
            }
            self.decorateWithGit(for: view.root)
        }
    }

    /// Some rows changed by Diptych itself -- their permissions set, one
    /// renamed, with everything under it if it is a folder -- shown as they
    /// are now, and only they: in a flat view nothing else is read again,
    /// and nothing leaves the list for no longer passing the expression. In
    /// an ordinary listing, the folder is read again.
    func refreshRows(_ urls: [URL], renamed: [(from: URL, to: URL)] = []) {
        guard let view = flat, let query = flatQuery else {
            reload()
            return
        }
        let current = items
        let columns = ConfigStore.shared.configuration.columns
        let touched = Set(urls.map(FlatScanner.canonicalPath))
        Task { [weak self] in
            let changes = await BlockingWork.run { () -> (rows: [URL: FileItem?], stale: Bool) in
                var rows: [URL: FileItem?] = [:]
                var stale = false
                for item in current {
                    let path = FlatScanner.canonicalPath(item.url)
                    let row: FileItem?
                    let moved = RenameManyModel.following(renamed, item.url)
                    if FlatScanner.canonicalPath(moved) != path {
                        row = FlatScanner.row(for: moved, under: view.root, columns: columns)
                    } else if touched.contains(path) {
                        row = FlatScanner.reread(item, columns: columns)
                    } else {
                        continue
                    }
                    if let row, !query.decide(FlatSubject(row)).list { stale = true }
                    rows[item.id] = row
                }
                return (rows, stale)
            }
            guard let self, self.flat == view, !changes.rows.isEmpty else { return }
            // Merged into the rows as they are now, not as they were: another
            // change may have landed meanwhile.
            self.items = self.items.compactMap { item in
                guard let change = changes.rows[item.id] else { return item }
                return change
            }
            if changes.stale { self.flatStale = true }
            if !self.flatStopped { self.remember(self.items, for: FlatCacheKey(view: view,
                                                                               showHidden: self.showHidden)) }
            if !self.applyPendingSelection(in: self.items) {
                self.selection = self.selection.filter { id in self.items.contains { $0.id == id } }
            }
            self.decorateWithGit(for: view.root)
        }
    }

    /// What the expression can ask about has changed.
    nonisolated private static func changed(_ old: FileItem, _ new: FileItem) -> Bool {
        old.name != new.name || old.mode != new.mode || old.owner != new.owner
            || old.group != new.group || old.byteSize != new.byteSize
            || old.modified != new.modified || old.created != new.created
            || old.isDirectory != new.isDirectory
    }

    // MARK: - Loading

    deinit {
        watcher?.cancel()
        pollTask?.cancel()
    }

    /// Watch `directory`, replacing any previous watch. Cheap to call often --
    /// it is a no-op when the path has not changed.
    /// Sets up the kqueue watch on the pane's directory.
    ///
    /// The `open` happens **off the main actor**. It looks like a cheap call and
    /// is not: opening a directory on a disk that has spun down blocks until the
    /// disk answers, and this runs during launch, before any window exists. A
    /// session that had been left pointing at a sleeping USB volume therefore
    /// started an app that never drew anything -- and, under the test harness,
    /// a host that never connected.
    private func watchDirectory() {
        let path = directory.path
        guard path != watchedPath else { return }

        watcher?.cancel()
        watcher = nil
        watchedPath = nil

        Task { [weak self] in
            let (fd, facts) = await BlockingWork.run {
                (Darwin.open(path, O_EVTONLY), VolumeFacts.of(URL(fileURLWithPath: path)))
            }
            // The pane may have moved on while the disk was waking up.
            guard let self, self.directory.path == path else {
                if fd >= 0 { Darwin.close(fd) }
                return
            }
            if self.volume != facts { self.volume = facts }
            self.pollServer(facts.isNetwork)
            guard fd >= 0 else { return }
            self.installWatch(fd: fd, path: path)
        }
    }

    private func installWatch(fd: Int32, path: String) {
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

        watcher?.cancel()
        watcher = source
        watchedPath = path
        source.resume()
    }

    /// The kernel reports what this Mac changes, never what another machine
    /// changes on a server. So a pane on a server looks at the folder's
    /// modification date every few seconds while Diptych is in front, and
    /// lists it again when that moves -- and every time Diptych comes to the
    /// front, since a WebDAV server need not move it at all.
    private func pollServer(_ on: Bool) {
        pollTask?.cancel()
        pollTask = nil
        guard on else { return }
        let path = directory.path
        pollTask = Task { [weak self] in
            var seen: Date?
            var wasActive = NSApp?.isActive ?? true
            while !Task.isCancelled {
                // Read each time round, so a change in Settings takes at once.
                let interval = Self.serverPollSeconds
                try? await Task.sleep(for: .seconds(interval > 0 ? Double(interval) : 2))
                guard !Task.isCancelled, let self, self.directory.path == path else { return }
                let active = NSApp?.isActive ?? true
                defer { wasActive = active }
                guard interval > 0, active, !self.isFlat, !self.isLoading else { continue }
                let modified = await BlockingWork.run {
                    (try? URL(fileURLWithPath: path)
                        .resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate
                }
                guard !Task.isCancelled, self.directory.path == path else { return }
                let changed = seen != nil && modified != seen
                seen = modified
                if changed || !wasActive { self.reload() }
            }
        }
    }

    /// Settings ▸ Behaviour ▸ File Servers; 0 is never.
    static var serverPollSeconds: Int {
        max(0, ConfigStore.shared.configuration.serverRefreshSeconds)
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
        if isFlat {
            refreshFlat()
            return
        }
        reload(navigatingFrom: nil)
    }

    /// Reload, and wait for the rows to actually be there.
    ///
    /// A transfer chain runs one operation after another; without waiting, the
    /// listing that shows a moved item finally gone was queued behind the next
    /// transfer and only landed when *that* finished.
    func reloadAndWait() async {
        reload()
        await loadTask?.value
    }

    private func reload(navigatingFrom previous: URL?) {
        watchDirectory()
        // The cached status describes a repository that has just changed
        // underneath us, so it is dropped rather than redrawn from memory.
        if let root = gitRoot { GitService.shared.invalidate(root) }
        // Cancel any listing still in flight. Without this, walking quickly
        // through directories lets a slow network volume deliver its rows after
        // you have already moved on, and the pane shows the wrong folder.
        loadTask?.cancel()

        let target = directory
        let hidden = showHidden
        let columns = ConfigStore.shared.configuration.columns
        isLoading = true
        errorText = nil
        loadedCount = 0

        if let previous {
            // Cleared, not left standing. Nothing can be selected, opened,
            // previewed or dragged out of a listing that no longer describes
            // where the pane says it is.
            directoryBeforeLoad = previous
            loadingDirectory = target
            items = []
            selection = []
            listedEarlier = nil
            // A folder on a server listed before in this run: its rows as
            // they were, at once, while it is read again behind them. They
            // are this folder's rows, so they may be used meanwhile.
            if let earlier = ListingCache.shared.rows(of: target, showHidden: hidden) {
                directoryBeforeLoad = nil
                loadingDirectory = nil
                items = earlier.rows
                listedEarlier = earlier.at
                if !applyPendingSelection(in: items) { landOnSomethingToPreview() }
            }
        }

        loadTask = Task { [weak self] in
            do {
                // Asked of the folder itself: the pane's facts are still
                // those of where it came from, on arriving at a server.
                let onServer = await BlockingWork.run { VolumeFacts.of(target).isNetwork }
                guard !Task.isCancelled else { return }
                var loaded = try await DirectoryLoader.load(
                    directory: target, showHidden: hidden, columns: columns,
                    deferMedia: onServer,
                    counted: { [weak pane = self] count in
                        Task { @MainActor in
                            guard let pane, pane.directory == target else { return }
                            pane.loadedCount = count
                        }
                    })
                guard !Task.isCancelled else { return }
                // A server's folder is listed again every time it changes:
                // what an unchanged file said is kept, not read again, so the
                // columns do not go blank and fill up each time.
                if onServer, let previous = self?.items {
                    let known = Dictionary(previous.map { ($0.url, $0) },
                                           uniquingKeysWith: { a, _ in a })
                    for index in loaded.indices {
                        if let old = known[loaded[index].url],
                           old.modified == loaded[index].modified {
                            loaded[index].media = old.media
                        }
                    }
                }
                self?.finish(loaded, for: target)
                if onServer {
                    ListingCache.shared.keep(loaded, of: target, showHidden: hidden)
                    self?.readMedia(for: target, columns: columns)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error, for: target)
            }
        }
    }

    /// Git state arrives *after* the rows are on screen, never before them.
    /// A status call is tens of milliseconds on a small repository and can be
    /// seconds on a large or networked one; the listing must not wait for it.
    /// Drop a check that has gone too old to vouch for, and redraw without it.
    ///
    /// Costs one `git status` at most once per check -- half an hour apart --
    /// and only in a tracked folder that has actually been checked.
    func retireStaleGitCheck() {
        guard let at = gitCheckedAt, let root = gitRoot else { return }
        guard Date().timeIntervalSince(at) >= GitService.checkGoesStaleAfter else { return }
        GitService.shared.checks.removeValue(forKey: root.path)
        gitCheckedAt = nil
        decorateWithGit(for: directory)
    }

    private func decorateWithGit(for target: URL) {
        gitTask?.cancel()
        // Not on a server: `git status` reads every file of the repository,
        // and over the network that is minutes, not milliseconds.
        guard GitService.shared.isEnabled, !volume.isNetwork else {
            gitRoot = nil
            gitBranch = nil
            gitAhead = 0
            gitBehind = 0
            gitCheckedAt = nil
            return
        }

        gitTask = Task { [weak self] in
            guard let answer = await GitService.shared.status(for: target) else {
                guard let self, target == self.directory else { return }
                self.gitRoot = nil
                self.gitBranch = nil
                self.gitAhead = 0
                self.gitBehind = 0
                self.gitCheckedAt = nil
                return
            }
            guard !Task.isCancelled, let self, target == self.directory else { return }

            self.gitRoot = answer.root
            self.gitBranch = answer.status.branch
            self.gitAhead = answer.status.ahead
            self.gitBehind = answer.status.behind

            // What the last check found, laid over what the working tree says.
            // Kept as an overlay rather than merged into GitStatus because the
            // two have different provenance: `git status` describes this disk
            // and is always true, while this describes a comparison with the
            // server made at a known moment. Writing it on top here means the
            // existing folder roll-up applies to it for free.
            var status = answer.status
            let check = GitService.shared.check(for: answer.root)
            self.gitCheckedAt = check?.at
            for path in check?.stale ?? [] {
                status.states[path] = .stale
            }
            // After stale, never before: a file changed on both sides is
            // contested, and that is the stronger thing to say about it.
            for path in check?.contested ?? [] {
                status.states[path] = .contested
            }

            for index in self.items.indices where !self.items[index].isParent {
                let found = status.states(for: self.items[index].url, root: answer.root)
                self.items[index].gitStates = found
                self.items[index].gitState = found.first ?? .clean
            }

            // Rows are drawn by now, so this never delays them. One check
            // covers the whole repository -- `conflictingPaths` compares every
            // path, not only this folder's -- so walking into a subfolder
            // afterwards is coloured from the cache with nothing more asked of
            // the network. Silent by design: no dialog, no progress panel, only
            // the colours and the stamp changing.
            if GitService.shared.claimAutomaticCheck(for: answer.root, status: answer.status) {
                Task { _ = await GitService.shared.checkForChanges(inRepository: answer.root) }
            }
        }
    }

    /// What pictures and videos say about themselves, read after the rows
    /// are on screen when the folder is on a server: a few files at a time,
    /// each batch shown as it comes.
    private func readMedia(for target: URL, columns: [FileColumn]) {
        guard DirectoryLoader.keys(for: columns).contains(DirectoryLoader.mediaKey) else { return }
        let wanted = items.filter { !$0.isParent && !$0.isDirectory && $0.media == nil }.map(\.url)
        guard !wanted.isEmpty else { return }
        mediaTask?.cancel()
        mediaTask = Task { [weak self] in
            for start in stride(from: 0, to: wanted.count, by: 24) {
                let batch = Array(wanted[start..<min(start + 24, wanted.count)])
                let found = await BlockingWork.run {
                    batch.map { ($0, MediaCache.shared.info(for: $0)) }
                }
                guard !Task.isCancelled, let self, self.directory == target, !self.isFlat else {
                    return
                }
                let byURL = Dictionary(found.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
                for index in self.items.indices {
                    if let media = byURL[self.items[index].url] { self.items[index].media = media }
                }
            }
        }
    }

    private func finish(_ loaded: [FileItem], for target: URL) {
        // A newer navigation won -- or the pane went flat meanwhile.
        guard target == directory, !isFlat else { return }
        awaitingServer = nil
        listed = target
        listedEarlier = nil
        items = loaded
        decorateWithGit(for: target)
        isLoading = false
        loadingDirectory = nil
        directoryBeforeLoad = nil
        errorIsPermission = false

        if applyPendingSelection(in: loaded) { return }
        openAfterLoading = false
        selection = selection.filter { id in loaded.contains { $0.id == id } }
        landOnSomethingToPreview()
    }

    /// The rows asked for before the listing came, selected and scrolled to
    /// -- and opened, for a file typed into the path bar. True when that
    /// settled the selection.
    @discardableResult
    private func applyPendingSelection(in loaded: [FileItem]) -> Bool {
        if !pendingSelection.isEmpty {
            // Matched by path, not by URL. A row's URL comes from the directory
            // listing, which puts a trailing slash on a folder; a URL built by
            // the caller only gets one if the folder already existed when it
            // was built -- `appendingPathComponent` stats the disk to decide.
            // So the URL a rename or a New Folder hands back never carried it,
            // never equalled the row, and the new folder was silently left
            // unselected. Files were unaffected, which is why it looked like a
            // folders-only bug. `path` has no trailing slash either way.
            let wanted = Set(pendingSelection.map(\.path))
            pendingSelection = []
            let present = Set(loaded.filter { wanted.contains($0.id.path) }.map(\.id))
            if !present.isEmpty {
                selection = present
                owner?.scrollSelectionIntoView()
                if openAfterLoading, present.count == 1,
                   let item = loaded.first(where: { present.contains($0.id) }) {
                    openAfterLoading = false
                    open(item)
                }
                openAfterLoading = false
                return true
            }
        }
        return false
    }

    /// With the preview open, a folder that arrives with nothing selected puts
    /// the cursor on its first item.
    ///
    /// Otherwise walking into a folder emptied the panel: the preview is meant
    /// to follow you through the tree, not stop at the door. Only while the
    /// panel is open -- selecting a row by itself is not something navigation
    /// should do behind the user's back.
    private func landOnSomethingToPreview() {
        guard QuickLookController.shared.isVisible, selection.isEmpty else { return }
        let first = rows.first { !$0.isParent } ?? rows.first
        guard let first else { return }
        selection = [first.id]
        owner?.scrollSelectionIntoView()
    }

    private func fail(_ error: Error, for target: URL) {
        guard target == directory else { return }
        listedEarlier = nil
        ListingCache.shared.forget(target)

        // On a server that has gone -- after sleep, or since the last run.
        // Not a folder that was deleted: its server is simply not there.
        if !FileManager.default.fileExists(atPath: target.path),
           let (server, mountPoint) = servers.server(mountedAbove: target.path),
           !FileManager.default.fileExists(atPath: mountPoint) {
            let arriving = awaitingServer?.id != server.id && listed != target
            items = []
            isLoading = false
            loadingDirectory = nil
            directoryBeforeLoad = nil
            errorIsPermission = false
            awaitingServer = server
            errorText = "\(server.title) is not connected."
            // Once on arriving -- at startup, or from the history -- and not
            // on every look: otherwise it is the button, or waking up.
            if arriving { owner?.reconnect(self) }
            return
        }

        // The directory itself is gone -- deleted from under us, or renamed.
        if !FileManager.default.fileExists(atPath: target.path) {
            // ...but not while a path is being typed. Yanking the pane
            // elsewhere mid-edit throws away what the user was doing; this is
            // settled when they finish or press Escape.
            guard !isEditingPath else {
                items = []
                isLoading = false
                loadingDirectory = nil
                errorText = "This folder is no longer there"
                return
            }
            owner?.flash("\u{201C}\(target.lastPathComponent)\u{201D} is no longer there")
            // Out of the history as well, or Back walks into it again. It can
            // still be reached this way when a folder is deleted between the
            // moment the trail is checked and the moment it is read.
            forget(target)
            navigate(to: Self.nearestExistingAncestor(of: target))
            return
        }

        items = directory.pathComponents.count > 1 ? [FileItem.parent(of: directory)] : []
        isLoading = false
        loadingDirectory = nil
        directoryBeforeLoad = nil

        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        errorIsPermission = nsError.code == NSFileReadNoPermissionError
            || underlying?.code == Int(EPERM)
            || underlying?.code == Int(EACCES)
        errorText = error.localizedDescription
        // NFS asks no password: the server decides by the user's number,
        // which has to be the same on both machines.
        if errorIsPermission, volume.typeName == "nfs" {
            errorText = (errorText ?? "") + " On NFS the server goes by your user number, "
                + "\(getuid()) on this Mac; it has to be yours on the server too."
        }
    }
}

/// Folders on servers as they were last listed in this run, so going back
/// into one shows its rows at once rather than after the network has
/// answered. Never on disk, and only the last few.
@MainActor
final class ListingCache {

    static let shared = ListingCache()
    nonisolated static let limit = 40

    private struct Key: Hashable {
        let path: String
        let showHidden: Bool
    }
    private var entries: [(key: Key, rows: [FileItem], at: Date)] = []

    func rows(of folder: URL, showHidden: Bool) -> (rows: [FileItem], at: Date)? {
        let key = Key(path: folder.standardizedFileURL.path, showHidden: showHidden)
        return entries.first { $0.key == key }.map { ($0.rows, $0.at) }
    }

    func keep(_ rows: [FileItem], of folder: URL, showHidden: Bool) {
        let key = Key(path: folder.standardizedFileURL.path, showHidden: showHidden)
        entries.removeAll { $0.key == key }
        entries.insert((key, rows, Date()), at: 0)
        if entries.count > Self.limit { entries.removeLast() }
    }

    func forget(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        entries.removeAll { $0.key.path == path }
    }
}
