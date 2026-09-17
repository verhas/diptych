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
@MainActor
@Observable
final class RenameManyModel {

    static let renamed = Notification.Name("diptych.renamedMany")

    private(set) var folder: URL
    private(set) var entries: [Entry] = []
    private(set) var isLoading = false

    struct Entry: Identifiable, Sendable {
        let name: String
        let isDirectory: Bool
        var id: String { name }
    }

    /// Always a regular expression, always anchored, so there is no box to
    /// tick and no way to replace half a name by accident.
    var search = "" { didSet { rebuild() } }
    var replacement = "" { didSet { rebuild() } }
    /// Off: the files that do not match are dimmed, as the pane filter dims
    /// them. On: they are not listed.
    var hidesOthers = false

    private(set) var searchIsValid = true
    private(set) var plan = RenamePlan()
    /// What each matching file would be called.
    private(set) var newNames: [String: String] = [:]
    private(set) var matching: Set<String> = []

    private(set) var isRenaming = false
    /// What came of the last run, for the window to show.
    private(set) var outcome: String?
    private(set) var wentWrong = false

    @ObservationIgnored private var regex: NSRegularExpression?

    init(folder: URL) {
        self.folder = folder
    }

    // MARK: - The folder

    func load() {
        isLoading = true
        let folder = folder
        Task {
            let found = await BlockingWork.run { Self.read(folder) }
            entries = found
            isLoading = false
            rebuild()
        }
    }

    nonisolated private static func read(_ folder: URL) -> [Entry] {
        let manager = FileManager()
        let urls = (try? manager.contentsOfDirectory(at: folder,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [])) ?? []
        return urls.map { url in
            Entry(name: url.lastPathComponent,
                  isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
                      ?? false)
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased())
                      < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    func navigate(to url: URL) {
        folder = url
        outcome = nil
        wentWrong = false
        load()
    }

    func goUp() {
        let parent = folder.deletingLastPathComponent()
        guard parent.path != folder.path else { return }
        navigate(to: parent)
    }

    var canGoUp: Bool { folder.deletingLastPathComponent().path != folder.path }

    // MARK: - What would happen

    var hasSearch: Bool { !search.isEmpty }

    private func rebuild() {
        regex = nil
        searchIsValid = true
        newNames = [:]
        matching = []
        plan = RenamePlan()
        outcome = nil
        wentWrong = false

        guard !search.isEmpty else { return }
        // Anchored here rather than left to the user: every name must match
        // whole, and a pattern that ends in a group still has to.
        regex = try? NSRegularExpression(pattern: "^(?:\(search))$")
        guard let regex else {
            searchIsValid = false
            return
        }

        let names = entries.map(\.name)
        for name in names {
            let range = NSRange(name.startIndex..., in: name)
            guard let match = regex.firstMatch(in: name, options: [], range: range),
                  match.range == range else { continue }
            matching.insert(name)
            guard !replacement.isEmpty else { continue }
            let new = regex.stringByReplacingMatches(in: name, options: [], range: range,
                                                     withTemplate: replacement)
            if new != name { newNames[name] = new }
        }

        guard !replacement.isEmpty else { return }
        plan = RenamePlan.plan(names: names, search: regex, replacement: replacement)
    }

    func matches(_ entry: Entry) -> Bool {
        !hasSearch || !searchIsValid || matching.contains(entry.name)
    }

    var listed: [Entry] {
        guard hidesOthers, hasSearch, searchIsValid else { return entries }
        return entries.filter { matching.contains($0.name) }
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

        for step in plan.steps {
            let from = folder.appendingPathComponent(step.from)
            do {
                let to = try await FileOperations.shared.rename(from, to: step.to)
                await GitService.shared.followMove(from: from, to: to)
                applied.append((from, to))
            } catch {
                // Stopped here: the steps after this one were ordered on the
                // assumption that this one had happened, and running them
                // anyway is how a folder gets truly muddled.
                failures.append("\u{201C}\(step.from)\u{201D} could not be renamed to "
                                + "\u{201C}\(step.to)\u{201D}: \(error.localizedDescription)")
                break
            }
        }

        // Counted by where each step landed: a swap renames two files with
        // three steps, one of them a hop nobody asked for.
        let done = applied.filter {
            !$0.to.lastPathComponent.hasPrefix(RenamePlan.temporaryPrefix)
        }.count
        FileHistory.shared.recordRenames(applied, in: folder, renames: done)
        NotificationCenter.default.post(name: Self.renamed, object: nil)
        if failures.isEmpty {
            outcome = "\(done) item\(done == 1 ? "" : "s") renamed."
            wentWrong = false
        } else {
            let left = plan.steps.count - applied.count
            outcome = failures.joined(separator: "\n")
                + "\n\(done) renamed; the remaining \(left) "
                + "\(left == 1 ? "step was" : "steps were") not started. Undo puts back what "
                + "was done."
            wentWrong = true
        }

        search = search   // re-reads the folder's names through rebuild()
        load()
    }
}
