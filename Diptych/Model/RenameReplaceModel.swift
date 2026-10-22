import Foundation

/// What a Replace-in-Names window is opened on: the files that were selected.
/// Unlike Rename Many it is not a folder browser -- it works on exactly these
/// files, wherever they are.
struct RenameReplaceRequest: Codable, Hashable, Sendable {
    var urls: [URL]
}

/// Find text A in the selected names and change it to B -- every occurrence,
/// anywhere in the name, not the whole-name match Rename Many does. Plain text
/// or, with the box ticked, a regular expression, so `\s+` to `-` collapses
/// each run of spaces to one dash across a whole selection.
///
/// The new names are previewed live and nothing runs until the whole plan is
/// sound: the same `RenamePlan`/`RenameRunner` the other renamers use refuses
/// collisions and a name already taken, and the lot is a single Undo step.
@MainActor
@Observable
final class RenameReplaceModel {

    struct Item: Identifiable, Sendable {
        var url: URL
        var name: String { url.lastPathComponent }
        var folder: URL { url.deletingLastPathComponent() }
        var id: URL { url }
    }

    private(set) var items: [Item]
    private(set) var isLoading = true

    var find = "" { didSet { edited() } }
    var replaceWith = "" { didSet { edited() } }
    var useRegex = false { didSet { edited() } }

    private(set) var searchIsValid = true
    /// The new name of each item that would change, by url -- for the preview.
    private(set) var newNames: [URL: String] = [:]
    private(set) var problems: [String] = []
    private(set) var isRenaming = false
    private(set) var outcome: String?
    private(set) var wentWrong = false

    /// Deepest folder first, ready for the runner.
    @ObservationIgnored private var folderPlans: [(folder: URL, prefix: String, plan: RenamePlan)] = []
    /// Every name in each folder involved, so a new name cannot take one.
    @ObservationIgnored private var folderNames: [URL: [String]] = [:]
    @ObservationIgnored private var regex: NSRegularExpression?

    init(_ request: RenameReplaceRequest) {
        items = request.urls.map { Item(url: $0) }
    }

    func load() {
        isLoading = true
        let folders = Set(items.map(\.folder))
        Task {
            let names = await BlockingWork.run {
                var names: [URL: [String]] = [:]
                for folder in folders {
                    names[folder] = (try? FileManager().contentsOfDirectory(atPath: folder.path)) ?? []
                }
                return names
            }
            folderNames = names
            isLoading = false
            rebuild()
        }
    }

    var hasFind: Bool { !find.isEmpty }
    var canApply: Bool { !isRenaming && problems.isEmpty && renames > 0 }
    var renames: Int { folderPlans.reduce(0) { $0 + $1.plan.renames } }

    private func edited() {
        outcome = nil
        wentWrong = false
        rebuild()
    }

    /// The new name for `name`, or nil when the find text is empty or invalid.
    private func replaced(_ name: String) -> String? {
        guard !find.isEmpty else { return nil }
        if useRegex {
            guard let regex else { return nil }
            let range = NSRange(name.startIndex..., in: name)
            return regex.stringByReplacingMatches(in: name, options: [], range: range,
                                                  withTemplate: replaceWith)
        }
        return name.replacingOccurrences(of: find, with: replaceWith)
    }

    private func rebuild() {
        regex = nil
        searchIsValid = true
        newNames = [:]
        problems = []
        folderPlans = []
        guard !find.isEmpty else { return }

        if useRegex {
            regex = try? NSRegularExpression(pattern: find)
            guard regex != nil else { searchIsValid = false; return }
        }

        // Per folder, so the collision check sees every name that is there.
        let byFolder = Dictionary(grouping: items, by: \.folder)
        let folders = byFolder.keys.sorted {
            ($0.pathComponents.count, $0.path) > ($1.pathComponents.count, $1.path)
        }
        for folder in folders {
            let group = byFolder[folder] ?? []
            var pairs: [(from: String, to: String)] = []
            for item in group {
                guard let new = replaced(item.name) else { continue }
                if new != item.name, RenamePlan.isUsable(new) { newNames[item.url] = new }
                pairs.append((from: item.name, to: new))
            }
            let names = folderNames[folder] ?? group.map(\.name)
            let plan = RenamePlan.plan(pairs: pairs, among: names)
            folderPlans.append((folder, "", plan))
            problems += plan.problems
        }
    }

    func apply() async {
        guard canApply else { return }
        isRenaming = true
        defer { isRenaming = false }

        let result = await RenameRunner.run(folderPlans)
        FileHistory.shared.recordRenames(result.applied, renames: result.done, as: "Replace in Names")
        NotificationCenter.default.post(name: RenameManyModel.renamed, object: nil, userInfo: [
            RenameManyModel.fromKey: result.applied.map(\.from),
            RenameManyModel.toKey: result.applied.map(\.to),
        ])

        if result.failures.isEmpty {
            outcome = "\(result.done) item\(result.done == 1 ? "" : "s") renamed."
            wentWrong = false
        } else {
            outcome = result.failures.joined(separator: "\n")
                + "\n\(result.done) renamed; the remaining \(result.notStarted) "
                + "\(result.notStarted == 1 ? "step was" : "steps were") not started. "
                + "Undo puts back what was done."
            wentWrong = true
        }

        // The files keep their place in the window under their new names, and
        // the plan is worked out again on them.
        items = items.map { Item(url: RenameManyModel.following(result.applied, $0.url)) }
        load()
    }
}
