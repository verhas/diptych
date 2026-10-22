import Foundation

/// Runs a set of worked-out `RenamePlan`s, folder by folder, the same way the
/// Rename Many window does: each step a real rename, Git told to follow it, and
/// a stop at the first failure so the steps that were ordered on its having
/// happened do not run into a muddle.
///
/// What is shared between the one-click transforms (lower case, spaces to
/// underscores) and the find-and-replace window -- both of which decide the new
/// names themselves and then need them applied safely and undoably. Recording
/// the undo step and telling the user are left to the caller, which knows the
/// folder and the words for what it did.
enum RenameRunner {

    struct Result: Sendable {
        /// Every rename that ran, in order -- including a cycle's temporary
        /// hops -- which is what Undo is given.
        var applied: [(from: URL, to: URL)] = []
        /// One line per failure; present only when something stopped.
        var failures: [String] = []
        /// How many files ended up with a name that was asked for -- a swap's
        /// temporary hop is not counted.
        var done = 0
        /// Steps that were never started because an earlier one failed.
        var notStarted = 0
    }

    /// `folderPlans` deepest folder first, so a folder's own rename runs after
    /// whatever is inside it.
    static func run(_ folderPlans: [(folder: URL, prefix: String, plan: RenamePlan)]) async -> Result {
        var result = Result()
        let total = folderPlans.reduce(0) { $0 + $1.plan.steps.count }

        run: for part in folderPlans {
            for step in part.plan.steps {
                let from = part.folder.appendingPathComponent(step.from)
                do {
                    let to = try await FileOperations.shared.rename(from, to: step.to)
                    await GitService.shared.followMove(from: from, to: to)
                    result.applied.append((from, to))
                } catch {
                    result.failures.append(
                        "\u{201C}\(part.prefix)\(step.from)\u{201D} could not be renamed to "
                        + "\u{201C}\(step.to)\u{201D}: \(error.localizedDescription)")
                    break run
                }
            }
        }

        result.done = result.applied.filter {
            !$0.to.lastPathComponent.hasPrefix(RenamePlan.temporaryPrefix)
        }.count
        result.notStarted = total - result.applied.count
        return result
    }
}
