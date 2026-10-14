import Foundation

/// Syncing both ways: neither folder is the master, and each change goes
/// whichever way it was made.
///
/// What changed is told against the record of the last sync, `SyncBaseline`.
/// A path changed on one side only is carried to the other -- a deletion as
/// much as an edit. A path changed on both, or one the record cannot speak
/// for, is a conflict, and is left for the user to decide: this way, that
/// way, keep both, or leave it.
extension DirectorySync {

    enum Choice: String, Sendable, Equatable, CaseIterable {
        /// Make the right side like the left.
        case toRight
        /// Make the left side like the right.
        case toLeft
        /// Keep both files: the older one under a new name, on both sides.
        case keepBoth
        /// Leave both sides as they are.
        case skip
    }

    /// One path, with what each choice would do to it.
    struct Item: Identifiable, Sendable, Equatable {
        let relativePath: String
        let isDirectory: Bool
        /// The two files, when there are two to open side by side.
        var comparable: DiffPair?
        /// The two sides, whatever they are, when both are there -- for two
        /// folders or links, whose properties are all there is to compare.
        var sides: DiffPair?
        /// What happened since the last sync, in a few words.
        let reason: String
        let toRight: [Step]
        let toLeft: [Step]
        /// Only for two files.
        let keepBoth: [Step]?
        /// What happens unless the user says otherwise. Nil for a conflict.
        let suggested: Choice?
        /// The choice "newer wins" makes; nil when neither is newer.
        let newer: Choice?

        var id: String { relativePath }
        var isConflict: Bool { suggested == nil }

        /// The name the older file gets beside the newer on a keep both.
        var keptAside: String? {
            keepBoth?.first { $0.kind == .move }?.destination?.lastPathComponent
        }

        var choices: [Choice] {
            keepBoth == nil ? [.toRight, .toLeft, .skip] : [.toRight, .toLeft, .keepBoth, .skip]
        }

        func steps(_ choice: Choice) -> [Step] {
            switch choice {
            case .toRight: toRight
            case .toLeft: toLeft
            case .keepBoth: keepBoth ?? []
            case .skip: []
            }
        }
    }

    struct TwoWayPlan: Identifiable, Sendable, Equatable {
        let id = UUID()
        let left: URL
        let right: URL
        /// In path order. A folder copied or deleted whole stands for
        /// everything in it.
        let items: [Item]
        /// No record of an earlier sync: nothing can be told to be a
        /// deletion, so whatever is on one side only is copied to the other.
        let isFirst: Bool
        /// Files the comparison matched by content under two different
        /// paths, left then right: a copy and a delete between them become a
        /// rename.
        let renames: [Rename]

        struct Rename: Sendable, Equatable {
            let left: String
            let right: String
            /// Whether the folder the left file is in is there on the right,
            /// to rename into -- and the other way round.
            let leftFolderOnRight: Bool
            let rightFolderOnLeft: Bool
        }

        var isEmpty: Bool { items.isEmpty }
        var conflicts: Int { items.filter(\.isConflict).count }

        /// The steps the choices make, in the order they run. A choice left
        /// out is the suggestion; a conflict left out is skipped.
        func resolve(_ choices: [String: Choice]) -> Plan {
            var steps: [Step] = []
            for item in items {
                guard let choice = choices[item.id] ?? item.suggested else { continue }
                steps += item.steps(choice)
            }
            steps = withRenames(steps)
            let order: [Step.Kind] = [.move, .delete, .copy, .replace, .metadata]
            let ordered = order.flatMap { kind in steps.filter { $0.kind == kind } }
            return Plan(direction: .both, left: left, right: right, steps: ordered)
        }

        /// A file copied across where the other side's copy of the same
        /// bytes is deleted is the same file renamed: renamed there instead,
        /// with nothing copied. Not when the folder it goes into is not
        /// there to rename into.
        private func withRenames(_ steps: [Step]) -> [Step] {
            var steps = steps
            for rename in renames {
                for (fromLeft, path, other, folderThere) in
                    [(true, rename.left, rename.right, rename.leftFolderOnRight),
                     (false, rename.right, rename.left, rename.rightFolderOnLeft)] {
                    let sourceRoot = fromLeft ? left : right
                    let targetRoot = fromLeft ? right : left
                    let source = sourceRoot.appendingPathComponent(path)
                    let landing = targetRoot.appendingPathComponent(path)
                    let old = targetRoot.appendingPathComponent(other)
                    guard let copy = steps.firstIndex(where: {
                              $0.kind == .copy && $0.source?.path == source.path
                                  && $0.target.path == landing.path
                          }),
                          let delete = steps.firstIndex(where: {
                              $0.kind == .delete && $0.target.path == old.path
                          }),
                          folderThere,
                          !steps.contains(where: {
                              $0.kind == .delete && FileOperations.isDescendant(
                                  landing.deletingLastPathComponent(), of: $0.target)
                          })
                    else { continue }
                    steps[copy] = Step(kind: .move, source: source, target: old,
                                       destination: landing, relativePath: path,
                                       isDirectory: false)
                    steps.remove(at: delete)
                }
            }
            return steps
        }
    }

    /// What has happened to one side of one path since the last sync.
    private enum Change {
        case absent, new, same, changed, deleted
    }

    private static func change(_ entry: DirectoryComparison.Entry?,
                               was: SyncBaseline.State?) -> Change {
        switch (entry, was) {
        case (nil, nil): .absent
        case (nil, _?): .deleted
        case (_?, nil): .new
        case let (entry?, was?): was.isUnchanged(SyncBaseline.State(entry)) ? .same : .changed
        }
    }

    /// The items a sync both ways is made of, each with a suggestion or, for
    /// a conflict, without one.
    static func twoWay(_ pairs: [DirectoryComparison.Pair], baseline: SyncBaseline?,
                       left: URL, right: URL,
                       options: DirectoryComparison.Options) -> TwoWayPlan {
        var leftEntries: [String: DirectoryComparison.Entry] = [:]
        var rightEntries: [String: DirectoryComparison.Entry] = [:]
        var byPath: [String: DirectoryComparison.Pair] = [:]
        var renames: [TwoWayPlan.Rename] = []
        for pair in pairs {
            if let l = pair.left { leftEntries[l.relativePath] = l }
            if let r = pair.right { rightEntries[r.relativePath] = r }
            if pair.isRename, let l = pair.left, let r = pair.right {
                renames.append(TwoWayPlan.Rename(
                    left: l.relativePath, right: r.relativePath,
                    leftFolderOnRight: isFolder(right, (l.relativePath as NSString)
                        .deletingLastPathComponent),
                    rightFolderOnLeft: isFolder(left, (r.relativePath as NSString)
                        .deletingLastPathComponent)))
            } else if let l = pair.left, pair.right != nil {
                byPath[l.relativePath] = pair
            }
        }

        // Folders before what is in them, so a folder copied or deleted whole
        // is decided before anything inside it would be.
        let paths = Set(leftEntries.keys).union(rightEntries.keys).sorted {
            let a = $0.split(separator: "/").count, b = $1.split(separator: "/").count
            return a != b ? a < b : $0 < $1
        }

        /// Everything under a folder on one side is unchanged since the last
        /// sync, the folder included -- what deleting it on that side needs.
        func untouched(_ path: String, _ entries: [String: DirectoryComparison.Entry],
                       onLeft: Bool) -> Bool {
            func was(_ p: String) -> SyncBaseline.State? {
                baseline?.entries[p].map { onLeft ? $0.left : $0.right }
            }
            guard let entry = entries[path],
                  change(entry, was: was(path)) == .same else { return false }
            guard entry.isDirectory else { return true }
            // Not looked into, so not known to be unchanged.
            if !options.recurseHiddenDirectories, entry.name.hasPrefix(".") { return false }
            let prefix = path + "/"
            return entries.allSatisfy { p, e in
                !p.hasPrefix(prefix) || change(e, was: was(p)) == .same
            }
        }

        var covered: Set<String> = []
        var items: [Item] = []

        for path in paths where !hasAncestor(path, in: covered) {
            let l = leftEntries[path]
            let r = rightEntries[path]
            let was = baseline?.entries[path]
            let lc = change(l, was: was?.left)
            let rc = change(r, was: was?.right)
            let pair = byPath[path]
            let toRight = mirrorSteps(source: l, target: r, pair: pair, path: path,
                                      targetRoot: right)
            let toLeft = mirrorSteps(source: r, target: l, pair: pair, path: path,
                                     targetRoot: left)
            let isDirectory = (l ?? r)?.isDirectory ?? false

            var suggested: Choice?
            var newer: Choice?
            var reason: String
            var keepBoth: [Step]?

            if let l, let r {
                guard let pair, pair.status != .same else { continue }
                if pair.differences.contains(.kind) { covered.insert(path) }
                newer = l.modified == r.modified ? nil : (l.modified > r.modified ? .toRight : .toLeft)
                if pair.isDirectory, pair.differences.isSubset(of: [.modified, .created]) {
                    // A folder's dates follow what happens inside it; never a
                    // question worth asking.
                    reason = "folder dates differ"
                    suggested = pair.newerSide == .right ? .toLeft : .toRight
                } else {
                    switch (lc, rc) {
                    case (.changed, .same): reason = "changed on the left"; suggested = .toRight
                    case (.same, .changed): reason = "changed on the right"; suggested = .toLeft
                    case (.changed, .changed): reason = "changed on both sides"
                    case (.new, .new), (.new, _), (_, .new):
                        reason = baseline == nil ? "different on the two sides"
                            : "made on both sides since the last sync"
                    default: reason = "differs, though neither side changed since the last sync"
                    }
                }
                if !l.isDirectory, !r.isDirectory, !l.isSymlink, !r.isSymlink {
                    keepBoth = keepBothSteps(path, l, r, leftEntries: leftEntries,
                                             rightEntries: rightEntries, left: left, right: right)
                }
            } else if let only = l ?? r {
                let onLeft = l != nil
                let otherChange = onLeft ? rc : lc
                let copyAcross: Choice = onLeft ? .toRight : .toLeft
                let removeHere: Choice = onLeft ? .toLeft : .toRight
                let here = onLeft ? "left" : "right"
                let there = onLeft ? "right" : "left"
                if only.isDirectory { covered.insert(path) }
                if otherChange == .deleted {
                    if untouched(path, onLeft ? leftEntries : rightEntries, onLeft: onLeft) {
                        reason = "deleted on the \(there)"
                        suggested = removeHere
                    } else {
                        reason = "deleted on the \(there), changed on the \(here)"
                    }
                    // The changed one is the one worth keeping.
                    newer = copyAcross
                } else {
                    reason = "new on the \(here)"
                    suggested = copyAcross
                    newer = copyAcross
                }
            } else {
                continue
            }

            var comparable: DiffPair?
            var sides: DiffPair?
            if let l, let r {
                sides = DiffPair(left: l.url, right: r.url)
                if !l.isDirectory, !r.isDirectory, !l.isSymlink, !r.isSymlink {
                    comparable = sides
                }
            }
            items.append(Item(relativePath: path, isDirectory: isDirectory,
                              comparable: comparable, sides: sides, reason: reason,
                              toRight: toRight, toLeft: toLeft, keepBoth: keepBoth,
                              suggested: suggested, newer: newer))
        }

        items.sort {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        return TwoWayPlan(left: left, right: right, items: items, isFirst: baseline == nil,
                          renames: renames)
    }

    private static func isFolder(_ root: URL, _ path: String) -> Bool {
        var isFolder: ObjCBool = false
        let url = path.isEmpty ? root : root.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
            && isFolder.boolValue
    }

    /// What makes the target side of one path like the source side -- the
    /// same steps a one-way sync makes for it.
    private static func mirrorSteps(source: DirectoryComparison.Entry?,
                                    target: DirectoryComparison.Entry?,
                                    pair: DirectoryComparison.Pair?, path: String,
                                    targetRoot: URL) -> [Step] {
        switch (source, target) {
        case (nil, nil):
            return []
        case let (nil, t?):
            return [Step(kind: .delete, source: nil, target: t.url, destination: nil,
                         relativePath: path, isDirectory: t.isDirectory)]
        case let (s?, nil):
            return [Step(kind: .copy, source: s.url,
                         target: targetRoot.appendingPathComponent(path), destination: nil,
                         relativePath: path, isDirectory: s.isDirectory)]
        case let (s?, t?):
            let differences = pair?.differences ?? []
            if differences.contains(.kind) || s.isSymlink || t.isSymlink {
                return [Step(kind: .delete, source: nil, target: t.url, destination: nil,
                             relativePath: path, isDirectory: t.isDirectory),
                        Step(kind: .copy, source: s.url, target: t.url, destination: nil,
                             relativePath: path, isDirectory: s.isDirectory)]
            }
            if !s.isDirectory, !differences.isDisjoint(with: [.content, .size]) {
                return [Step(kind: .replace, source: s.url, target: t.url, destination: nil,
                             relativePath: path, isDirectory: false)]
            }
            guard !differences.isEmpty else { return [] }
            return [Step(kind: .metadata, source: s.url, target: t.url, destination: nil,
                         relativePath: path, isDirectory: s.isDirectory)]
        }
    }

    /// The older of two files renamed out of the way -- "report (right
    /// copy).txt" -- and copied to the other side; the newer one copied into
    /// its place. Both sides end up with both.
    private static func keepBothSteps(_ path: String, _ l: DirectoryComparison.Entry,
                                      _ r: DirectoryComparison.Entry,
                                      leftEntries: [String: DirectoryComparison.Entry],
                                      rightEntries: [String: DirectoryComparison.Entry],
                                      left: URL, right: URL) -> [Step] {
        let olderOnLeft = l.modified < r.modified
        let older = olderOnLeft ? l : r
        let newer = olderOnLeft ? r : l
        let olderRoot = olderOnLeft ? left : right
        let newerRoot = olderOnLeft ? right : left
        let side = olderOnLeft ? "left" : "right"

        let folder = (path as NSString).deletingLastPathComponent
        let stem = (l.name as NSString).deletingPathExtension
        let ext = (l.name as NSString).pathExtension
        var aside = ""
        for n in 1... {
            let name = stem + " (\(side) copy\(n == 1 ? "" : " \(n)"))" + (ext.isEmpty ? "" : "." + ext)
            aside = folder.isEmpty ? name : folder + "/" + name
            let taken = leftEntries[aside] != nil || rightEntries[aside] != nil
                || FileOperations.exists(left.appendingPathComponent(aside))
                || FileOperations.exists(right.appendingPathComponent(aside))
            if !taken { break }
        }

        return [
            Step(kind: .move, source: nil, target: older.url,
                 destination: olderRoot.appendingPathComponent(aside), relativePath: aside,
                 isDirectory: false),
            Step(kind: .copy, source: olderRoot.appendingPathComponent(aside),
                 target: newerRoot.appendingPathComponent(aside), destination: nil,
                 relativePath: aside, isDirectory: false),
            Step(kind: .copy, source: newer.url, target: older.url, destination: nil,
                 relativePath: path, isDirectory: false),
        ]
    }
}
