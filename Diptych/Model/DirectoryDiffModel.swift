import Foundation

/// One directory-comparison window: two folders and the pairs they come apart
/// into.
@MainActor
@Observable
final class DirectoryDiffModel {

    let left: URL
    let right: URL

    private(set) var pairs: [DirectoryComparison.Pair] = []
    private(set) var isLoading = false
    private(set) var failure: String?

    /// No multiple selection: a comparison is opened for one pair at a time.
    var selection: DirectoryComparison.Pair.ID? {
        didSet { if !isCorrectingSelection { correctSelectionForFilter() } }
    }
    @ObservationIgnored private var isCorrectingSelection = false

    /// What the checkboxes on the window currently say. Starts from the
    /// application's defaults, but from here on belongs to this window alone.
    var options: DirectoryComparison.Options
    /// What the pairs on screen were actually compared with. Differs from
    /// `options` exactly when a checkbox has been changed since the last
    /// comparison -- which is what tells the window to offer a refresh rather
    /// than silently keep showing a stale answer.
    private(set) var appliedOptions: DirectoryComparison.Options
    var needsRefresh: Bool { options != appliedOptions }

    // MARK: - Showing less than everything

    var onlyShowDifferences = false {
        didSet { correctSelectionForFilter() }
    }
    /// Hides a pair that exists on only one side. Independent of
    /// `onlyShowDifferences`: a pair missing its partner is not "the same",
    /// so the two checkboxes would otherwise disagree about it.
    var ignoreMissing = false {
        didSet { correctSelectionForFilter() }
    }

    /// Plain text finds a fragment anywhere in the name: `inv` lists every
    /// invoice. With `filterIsRegex` on it is a regular expression instead,
    /// matched against the whole name -- the same rule a pane's own filter
    /// follows, so it means the same thing here.
    var filterText = "" {
        didSet { rebuildFilter() }
    }
    var filterIsRegex = false {
        didSet { rebuildFilter() }
    }
    /// Off: non-matching rows are shown dimmed. On: they are left out of the
    /// list entirely.
    var filterHidesOthers = false {
        didSet { correctSelectionForFilter() }
    }
    private(set) var filterIsValid = true
    @ObservationIgnored private var filterRegex: NSRegularExpression?

    var hasFilter: Bool { !filterText.trimmingCharacters(in: .whitespaces).isEmpty }

    private func rebuildFilter() {
        let pattern = filterText.trimmingCharacters(in: .whitespaces)
        filterRegex = nil
        filterIsValid = true
        defer { correctSelectionForFilter() }

        guard !pattern.isEmpty, filterIsRegex else { return }
        filterRegex = try? NSRegularExpression(pattern: "^(?:\(pattern))$",
                                               options: [.caseInsensitive])
        filterIsValid = filterRegex != nil
    }

    /// A pair matches when either side's name does -- a rename's two names
    /// are rarely the same, and a search for either one should still find it.
    func matchesFilter(_ pair: DirectoryComparison.Pair) -> Bool {
        guard hasFilter, filterIsValid else { return true }
        return [pair.left, pair.right].contains { entry in
            guard let name = entry?.name else { return false }
            if let filterRegex {
                let range = NSRange(name.startIndex..., in: name)
                return filterRegex.firstMatch(in: name, options: [], range: range) != nil
            }
            let pattern = filterText.trimmingCharacters(in: .whitespaces)
            guard PaneModel.isGlob(pattern) else {
                return name.range(of: pattern, options: [.caseInsensitive]) != nil
            }
            return fnmatch(pattern, name, FNM_CASEFOLD) == 0
        }
    }

    private func passesHardFilters(_ pair: DirectoryComparison.Pair) -> Bool {
        if onlyShowDifferences, pair.status == .same { return false }
        if ignoreMissing, pair.status == .onlyLeft || pair.status == .onlyRight { return false }
        if filterHidesOthers, !matchesFilter(pair) { return false }
        return true
    }

    /// What the list actually shows, in order.
    var displayedPairs: [DirectoryComparison.Pair] {
        pairs.filter(passesHardFilters)
    }

    /// Drop a selection the list no longer shows, the same reason a pane's
    /// filter does it: acting on a row that vanished out from under a keypress
    /// is worse than acting on nothing.
    private func correctSelectionForFilter() {
        guard !isCorrectingSelection, let selection,
              let pair = pairs.first(where: { $0.id == selection }),
              !passesHardFilters(pair) else { return }
        isCorrectingSelection = true
        self.selection = nil
        isCorrectingSelection = false
    }

    // MARK: - Loading

    init(left: URL, right: URL) {
        self.left = left
        self.right = right
        let settings = ConfigStore.shared.configuration
        var defaults = DirectoryComparison.Options(
            comparePermissions: settings.directoryDiffComparePermissions,
            compareAttributes: settings.directoryDiffCompareAttributes,
            compareACL: settings.directoryDiffCompareACL,
            compareModificationDate: settings.directoryDiffCompareModificationDate,
            compareCreationDate: settings.directoryDiffCompareCreationDate,
            compareOwnership: settings.directoryDiffCompareOwnership,
            recurseHiddenDirectories: settings.directoryDiffRecurseHiddenDirectories)
        // A comparison of two dot-folders -- two `.git`s, say -- is a
        // comparison of hidden folders on purpose, whatever the setting says:
        // the setting is about not wading into `.git` while comparing an
        // ordinary project folder, which is a different question from one
        // asked about `.git` directly. Still just a starting point -- the
        // checkbox on the window can turn it off again.
        if left.lastPathComponent.hasPrefix(".") || right.lastPathComponent.hasPrefix(".") {
            defaults.recurseHiddenDirectories = true
        }
        options = defaults
        appliedOptions = defaults
    }

    func load() async {
        isLoading = true
        failure = nil
        let left = left
        let right = right
        let options = options
        do {
            pairs = try await BlockingWork.run {
                try DirectoryComparison.compare(left: left, right: right, options: options)
            }
            appliedOptions = options
            // A refresh can change which pairs exist at all -- turning content
            // off, say, can turn a rename into two unrelated singles, under
            // different ids. A selection that no longer names anything real is
            // worse than none.
            if let selection, !pairs.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
        } catch {
            pairs = []
            failure = "These folders could not be compared: \(error.localizedDescription)"
        }
        isLoading = false
    }

    var selectedPair: DirectoryComparison.Pair? {
        guard let selection else { return nil }
        return pairs.first { $0.id == selection }
    }

    var summary: String {
        if isLoading { return "Comparing\u{2026}" }
        if let failure { return failure }
        guard !pairs.isEmpty else { return "Both folders are empty." }

        let differing = pairs.filter { $0.status == .differs }.count
        let onlyLeft = pairs.filter { $0.status == .onlyLeft }.count
        let onlyRight = pairs.filter { $0.status == .onlyRight }.count
        guard differing != 0 || onlyLeft != 0 || onlyRight != 0 else {
            return "These two folders are the same."
        }

        var parts: [String] = []
        if differing > 0 { parts.append("\(differing) differ\(differing == 1 ? "s" : "")") }
        if onlyLeft > 0 { parts.append("\(onlyLeft) only on the left") }
        if onlyRight > 0 { parts.append("\(onlyRight) only on the right") }
        return parts.joined(separator: ", ")
    }
}
