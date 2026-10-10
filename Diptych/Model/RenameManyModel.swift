import Foundation

/// One Rename Many window: a folder, a regular expression, a replacement, and
/// the renames they add up to.
///
/// The search always matches a **whole** name -- half a name matched is half a
/// name replaced, which in a bulk rename is a folder full of damage -- and it
/// is always a regular expression, because the replacement needs `$1` to be
/// worth anything.
///
/// Nothing is renamed until the whole plan is sound: `RenamePlan` decides what
/// each file would be called, refuses two files landing on one name or a name
/// that is already taken, and orders a chain so each name is free when it is
/// wanted.
/// What a Rename Many window is opened on: a folder, or a pane's flat view
/// of one -- its rows, as listed, whatever the expression would say now --
/// and what was selected there.
struct RenameManyRequest: Codable, Hashable, Sendable {
    var folder: URL
    var selected: [URL] = []
    /// The flat view's rows; nil for a folder.
    var flatRows: [URL]? = nil
    var flatExpression: String? = nil
}

@MainActor
@Observable
final class RenameManyModel {

    static let renamed = Notification.Name("diptych.renamedMany")
    /// In a `renamed` notification's user info: the renames, in the order
    /// they ran, as two lists of URLs.
    nonisolated static let fromKey = "from"
    nonisolated static let toKey = "to"

    /// The folder, or the folder a flat view is of.
    private(set) var folder: URL
    private(set) var entries: [Entry] = []
    private(set) var isLoading = false
    /// A flat view's rows rather than one folder's names.
    private(set) var flatRows: [URL]?
    let flatExpression: String?
    var isFlat: Bool { flatRows != nil }

    struct Entry: Identifiable, Sendable {
        let name: String
        let isDirectory: Bool
        /// Where it is; in a flat view, each row's own folder.
        var folder: URL
        /// In a flat view, the folder relative to the view's, `src/`; empty
        /// for a folder's own names.
        var prefix = ""
        var id: String { prefix + name }
        var url: URL { folder.appendingPathComponent(name) }
    }

    /// What was selected in the pane, by entry id.
    private(set) var selected: Set<String> = []
    /// Only the selected entries are matched and renamed. On by default
    /// when something was selected.
    var selectionOnly = false { didSet { rebuild() } }
    var hasSelection: Bool { !selected.isEmpty }

    /// Always a regular expression, always anchored, so there is no box to
    /// tick and no way to replace half a name by accident.
    var search = "" { didSet { edited() } }
    var replacement = "" { didSet { edited() } }
    /// Off: the files that do not match are dimmed, as the pane filter dims
    /// them. On: they are not listed.
    var hidesOthers = false

    private(set) var searchIsValid = true
    /// All the folders' plans as one: their problems, their steps, how many.
    private(set) var plan = RenamePlan()
    /// One plan per folder, deepest first: a folder's own name changes last,
    /// after what is in it.
    private(set) var folderPlans: [(folder: URL, prefix: String, plan: RenamePlan)] = []
    /// What each matching entry would be called, by entry id.
    private(set) var newNames: [String: String] = [:]
    private(set) var matching: Set<String> = []

    private(set) var isRenaming = false
    /// What came of the last run, for the window to show.
    private(set) var outcome: String?
    private(set) var wentWrong = false

    /// Every name in each folder involved, whether listed or not: a new name
    /// must not take one of them.
    @ObservationIgnored private var folderNames: [URL: [String]] = [:]
    @ObservationIgnored private var regex: NSRegularExpression?
    @ObservationIgnored private var selectedURLs: [URL]

    init(folder: URL) {
        self.folder = folder
        flatRows = nil
        flatExpression = nil
        selectedURLs = []
    }

    init(_ request: RenameManyRequest) {
        folder = request.folder
        flatRows = request.flatRows
        flatExpression = request.flatExpression
        selectedURLs = request.selected
        selectionOnly = !request.selected.isEmpty
    }

    // MARK: - The folder

    func load() {
        // Loading from now, not from when the task gets going.
        isLoading = true
        Task { await reload() }
    }

    func reload() async {
        isLoading = true
        let folder = folder
        let rows = flatRows
        let wanted = selectedURLs
        do {
            let found = await BlockingWork.run {
                rows.map { Self.read($0, under: folder) } ?? Self.read(folder)
            }
            entries = found.entries
            folderNames = found.names
            // The selection, as entries: by path, whichever way the URL was
            // made.
            if !wanted.isEmpty {
                let paths = Set(wanted.map(FlatScanner.canonicalPath))
                selected = Set(entries.filter {
                    paths.contains(FlatScanner.canonicalPath($0.url))
                }.map(\.id))
                selectedURLs = []
            }
            isLoading = false
            rebuild()
        }
    }

    nonisolated private static func read(_ folder: URL)
        -> (entries: [Entry], names: [URL: [String]]) {
        let manager = FileManager()
        let urls = (try? manager.contentsOfDirectory(at: folder,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [])) ?? []
        let entries = urls.map { url in
            Entry(name: url.lastPathComponent,
                  isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
                      ?? false,
                  folder: folder)
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased())
                      < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
        return (entries, [folder: entries.map(\.name)])
    }

    /// A flat view's rows, in the order the pane lists them, and every name
    /// in each of their folders.
    nonisolated private static func read(_ rows: [URL], under root: URL)
        -> (entries: [Entry], names: [URL: [String]]) {
        let manager = FileManager()
        let rootPath = FlatScanner.canonicalPath(root)
        var entries: [Entry] = []
        var names: [URL: [String]] = [:]
        for row in rows {
            var url = row.standardizedFileURL
            url.removeAllCachedResourceValues()
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }   // gone since
            let folder = url.deletingLastPathComponent()
            let folderPath = FlatScanner.canonicalPath(folder)
            let relative = folderPath == rootPath ? ""
                : folderPath.hasPrefix(rootPath + "/")
                    ? String(folderPath.dropFirst(rootPath.count + 1)) + "/" : ""
            entries.append(Entry(name: url.lastPathComponent,
                                 isDirectory: (info.st_mode & S_IFMT) == S_IFDIR,
                                 folder: folder, prefix: relative))
            if names[folder] == nil {
                names[folder] = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
            }
        }
        return (entries, names)
    }

    func navigate(to url: URL) {
        guard !isFlat else { return }
        folder = url
        outcome = nil
        wentWrong = false
        // Somewhere else: what was selected was selected there.
        selected = []
        selectionOnly = false
        load()
    }

    func goUp() {
        let parent = folder.deletingLastPathComponent()
        guard parent.path != folder.path else { return }
        navigate(to: parent)
    }

    var canGoUp: Bool { !isFlat && folder.deletingLastPathComponent().path != folder.path }

    // MARK: - What would happen

    var hasSearch: Bool { !search.isEmpty }

    /// What may be renamed: the selection, or everything listed.
    private var candidates: [Entry] {
        selectionOnly ? entries.filter { selected.contains($0.id) } : entries
    }

    /// Typed: what the last run came to is no longer what is in front.
    private func edited() {
        outcome = nil
        wentWrong = false
        rebuild()
    }

    private func rebuild() {
        regex = nil
        searchIsValid = true
        newNames = [:]
        matching = []
        plan = RenamePlan()
        folderPlans = []

        guard !search.isEmpty else { return }
        // Anchored here rather than left to the user: every name must match
        // whole, and a pattern that ends in a group still has to.
        regex = try? NSRegularExpression(pattern: "^(?:\(search))$")
        guard let regex else {
            searchIsValid = false
            return
        }

        let candidates = candidates
        for entry in candidates {
            let name = entry.name
            let range = NSRange(name.startIndex..., in: name)
            guard let match = regex.firstMatch(in: name, options: [], range: range),
                  match.range == range else { continue }
            matching.insert(entry.id)
            guard !replacement.isEmpty else { continue }
            let new = regex.stringByReplacingMatches(in: name, options: [], range: range,
                                                     withTemplate: replacement)
            if new != name { newNames[entry.id] = new }
        }

        guard !replacement.isEmpty else { return }
        let byFolder = Dictionary(grouping: candidates, by: \.folder)
        let folders = byFolder.keys.sorted {
            ($0.pathComponents.count, $0.path) > ($1.pathComponents.count, $1.path)
        }
        for folder in folders {
            let group = byFolder[folder] ?? []
            let names = folderNames[folder] ?? group.map(\.name)
            let only = selectionOnly || isFlat ? Set(group.map(\.name)) : nil
            let part = RenamePlan.plan(names: names, search: regex, replacement: replacement,
                                       only: only)
            let prefix = group.first?.prefix ?? ""
            folderPlans.append((folder, prefix, part))
            plan.steps += part.steps
            plan.problems += part.problems.map { prefix.isEmpty ? $0 : "In \(prefix): \($0)" }
            plan.matched += part.matched
            plan.unchanged += part.unchanged
        }
    }

    func matches(_ entry: Entry) -> Bool {
        if selectionOnly, !selected.contains(entry.id) { return false }
        return !hasSearch || !searchIsValid || matching.contains(entry.id)
    }

    var listed: [Entry] {
        guard hidesOthers else { return entries }
        if hasSearch, searchIsValid { return entries.filter { matching.contains($0.id) } }
        return selectionOnly ? entries.filter { selected.contains($0.id) } : entries
    }

    /// What the button says, and whether it can be pressed.
    var canRename: Bool {
        !isRenaming && plan.problems.isEmpty && plan.renames > 0
    }

    // MARK: - Doing it

    func rename() async {
        guard canRename else { return }
        isRenaming = true
        defer { isRenaming = false }

        var applied: [(from: URL, to: URL)] = []
        var failures: [String] = []
        let total = plan.steps.count

        run: for part in folderPlans {
            for step in part.plan.steps {
                let from = part.folder.appendingPathComponent(step.from)
                do {
                    let to = try await FileOperations.shared.rename(from, to: step.to)
                    await GitService.shared.followMove(from: from, to: to)
                    applied.append((from, to))
                } catch {
                    // Stopped here: the steps after this one were ordered on
                    // the assumption that this one had happened, and running
                    // them anyway is how a folder gets truly muddled.
                    failures.append("\u{201C}\(part.prefix)\(step.from)\u{201D} could not be "
                                    + "renamed to \u{201C}\(step.to)\u{201D}: "
                                    + error.localizedDescription)
                    break run
                }
            }
        }

        // Counted by where each step landed: a swap renames two files with
        // three steps, one of them a hop nobody asked for.
        let done = applied.filter {
            !$0.to.lastPathComponent.hasPrefix(RenamePlan.temporaryPrefix)
        }.count
        FileHistory.shared.recordRenames(applied, in: folder, renames: done)
        NotificationCenter.default.post(name: Self.renamed, object: nil, userInfo: [
            Self.fromKey: applied.map(\.from), Self.toKey: applied.map(\.to),
        ])
        if failures.isEmpty {
            outcome = "\(done) item\(done == 1 ? "" : "s") renamed."
            wentWrong = false
        } else {
            let left = total - applied.count
            outcome = failures.joined(separator: "\n")
                + "\n\(done) renamed; the remaining \(left) "
                + "\(left == 1 ? "step was" : "steps were") not started. Undo puts back what "
                + "was done."
            wentWrong = true
        }

        // What was renamed is still what is listed and selected, under its
        // new name.
        let renamedSelection = entries.filter { selected.contains($0.id) }.map {
            Self.following(applied, $0.url)
        }
        if let rows = flatRows {
            flatRows = rows.map { Self.following(applied, $0) }
        }
        selectedURLs = renamedSelection
        await reload()   // and the plan worked out again on the new names
    }

    /// Where a URL is after the renames, run in order: a folder's rename
    /// takes what is in it along.
    nonisolated static func following(_ renames: [(from: URL, to: URL)], _ url: URL) -> URL {
        var path = FlatScanner.canonicalPath(url)
        for rename in renames {
            let from = FlatScanner.canonicalPath(rename.from)
            if path == from || path.hasPrefix(from + "/") {
                path = FlatScanner.canonicalPath(rename.to) + path.dropFirst(from.count)
            }
        }
        return URL(fileURLWithPath: path)
    }
}
