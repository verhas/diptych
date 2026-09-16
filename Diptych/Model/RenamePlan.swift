import Foundation

/// A folder's worth of renames, worked out completely before any of them
/// happens.
///
/// Renaming many files one at a time is where a bulk rename goes wrong: the
/// third rename fails because the second took its name, and the folder is left
/// half done. So the whole thing is decided first -- what each file would be
/// called, what would collide, and in which order the renames have to run --
/// and nothing is touched unless all of it can be done.
///
/// Three rules, in the order they matter:
///
/// * **No two files may end up with the same name.** Reported, naming both.
/// * **No file may take a name that is already in the folder** unless that
///   file is itself being renamed out of the way.
/// * **A chain is ordered, not refused.** `A` to `B` while `B` to `C` is
///   perfectly sensible: `B` moves first. That is a topological sort over "my
///   new name is somebody's old name".
///
/// A *cycle* -- `A` to `B` and `B` to `A` -- cannot be ordered, so one file
/// steps aside under a temporary name and comes back at the end. That is the
/// only case where a file is briefly called something nobody asked for, and it
/// is invisible unless the application is killed mid-rename.
struct RenamePlan: Equatable, Sendable {

    struct Step: Equatable, Sendable {
        let from: String
        let to: String
        /// A move out of the way, to break a cycle. Its counterpart comes later.
        var isTemporary = false
    }

    /// In the order they must run.
    var steps: [Step] = []
    /// Why this cannot be done. Nothing runs while there is anything here.
    var problems: [String] = []
    /// What the search matched, whether or not it changes the name.
    var matched = 0
    /// Files whose new name is the name they already have.
    var unchanged = 0

    /// The name a file steps aside under, to break a cycle.
    static let temporaryPrefix = ".diptych-rename-"

    var isEmpty: Bool { steps.isEmpty }
    /// How many files end up with a name somebody asked for.
    ///
    /// Counted by where each step lands, not by how many steps there are: in a
    /// swap, two files are renamed by three steps, because one of them goes
    /// aside and comes back.
    var renames: Int { steps.filter { !$0.to.hasPrefix(Self.temporaryPrefix) }.count }

    // MARK: - Working it out

    /// `names` is everything in the folder, `search` must match a whole name.
    static func plan(names: [String], search: NSRegularExpression,
                     replacement: String) -> RenamePlan {
        var plan = RenamePlan()
        var pairs: [(from: String, to: String)] = []

        for name in names.sorted() {
            let range = NSRange(name.startIndex..., in: name)
            guard let match = search.firstMatch(in: name, options: [], range: range),
                  match.range == range else { continue }
            plan.matched += 1

            let new = search.stringByReplacingMatches(in: name, options: [], range: range,
                                                      withTemplate: replacement)
            if new == name {
                plan.unchanged += 1
                continue
            }
            guard isUsable(new) else {
                plan.problems.append("\u{201C}\(name)\u{201D} would become "
                                     + "\u{201C}\(new)\u{201D}, which cannot be a file name.")
                continue
            }
            pairs.append((name, new))
        }

        plan.problems += clashes(pairs, among: names)
        guard plan.problems.isEmpty else { return plan }

        plan.steps = order(pairs)
        return plan
    }

    /// A name the file system will take. Empty, a slash, a colon -- which
    /// Finder still shows as a slash -- and the two navigation names are out.
    static func isUsable(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains(":")
            && name != "." && name != ".."
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Two files fighting over one name, or a name already taken by a file that
    /// is staying put.
    ///
    /// Folded for comparison, because this disk does not tell `Notes` from
    /// `notes`: two renames landing on those two names are a collision even
    /// though the strings differ.
    static func clashes(_ pairs: [(from: String, to: String)],
                        among names: [String]) -> [String] {
        var problems: [String] = []
        var takenBy: [String: String] = [:]
        for pair in pairs {
            let folded = pair.to.lowercased()
            if let other = takenBy[folded] {
                problems.append("\u{201C}\(other)\u{201D} and \u{201C}\(pair.from)\u{201D} "
                                + "would both be called \u{201C}\(pair.to)\u{201D}.")
            } else {
                takenBy[folded] = pair.from
            }
        }

        let moving = Set(pairs.map { $0.from.lowercased() })
        for pair in pairs {
            let folded = pair.to.lowercased()
            // Its own name in different letters is not a clash with itself.
            guard folded != pair.from.lowercased() else { continue }
            guard let standing = names.first(where: { $0.lowercased() == folded }),
                  !moving.contains(folded) else { continue }
            problems.append("\u{201C}\(pair.from)\u{201D} would be called "
                            + "\u{201C}\(pair.to)\u{201D}, and \u{201C}\(standing)\u{201D} is "
                            + "already here and is not being renamed.")
        }
        return problems
    }

    /// The order to run them in: anything whose new name is still occupied by
    /// another file waits for that file to move.
    static func order(_ pairs: [(from: String, to: String)]) -> [Step] {
        var waiting = pairs
        var steps: [Step] = []
        // Where a file that stepped aside has to end up.
        var parked: [(temporary: String, to: String)] = []

        while !waiting.isEmpty {
            let occupied = Set(waiting.map { $0.from.lowercased() })
            // Free now: nothing still waiting is called what this wants to be.
            let free = waiting.firstIndex { pair in
                let folded = pair.to.lowercased()
                return folded == pair.from.lowercased() || !occupied.contains(folded)
            }

            if let index = free {
                let pair = waiting.remove(at: index)
                steps.append(Step(from: pair.from, to: pair.to))
                continue
            }

            // Every remaining rename is blocked by another: a cycle. One file
            // steps aside under a name nothing can be called by accident.
            let pair = waiting.removeFirst()
            let temporary = temporaryPrefix + UUID().uuidString
            steps.append(Step(from: pair.from, to: temporary, isTemporary: true))
            parked.append((temporary, pair.to))
        }

        // And back, once the names they want are free.
        for park in parked {
            steps.append(Step(from: park.temporary, to: park.to, isTemporary: true))
        }
        return steps
    }
}
