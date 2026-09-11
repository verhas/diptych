import Foundation

/// The operations that change a repository.
///
/// Read-only work lives in `GitService`; this is everything that writes. All of
/// it runs off the main actor through `BlockingWork`, and all of it reports
/// Git's own words on failure -- a friendly summary that swallows
/// "Permission denied (publickey)" makes the problem unfixable.
extension GitService {

    /// One line of the send dialog.
    struct Change: Identifiable, Sendable, Hashable {
        let path: String
        let state: GitState
        var id: String { path }

        /// "changed", "removed", "new" -- what the user needs to know, in the
        /// past tense of what they did rather than Git's vocabulary.
        var describes: String {
            switch state {
            case .untracked:  "new"
            case .added:      "new, tracked"
            case .changed:    "changed"
            case .deleted:    "removed"
            case .contested:  "also changed elsewhere"
            case .conflicted: "unfinished merge"
            case .clean:      ""
            }
        }
    }

    struct Changes: Sendable {
        /// Tracked changes and files already marked: always offered, ticked.
        var sending: [Change] = []
        /// New files Git does not know about: offered unticked.
        var new: [Change] = []
        /// Half-finished merges: listed, but not sendable at all.
        var unresolved: [Change] = []
        var isEmpty: Bool { sending.isEmpty && new.isEmpty && unresolved.isEmpty }
    }

    /// What the send dialog lists, split into the groups it shows.
    func changes(inRepository root: URL) async -> Changes {
        guard let status = await status(forRepository: root) else { return Changes() }
        var changes = Changes()
        for (path, state) in status.states.sorted(by: { $0.key < $1.key }) {
            switch state {
            case .untracked:            changes.new.append(Change(path: path, state: state))
            case .added, .changed, .deleted,
                 .contested:            changes.sending.append(Change(path: path, state: state))
            // Never offered. `git add` on a half-finished merge marks it
            // resolved and stages the file *with the conflict markers in it* --
            // committing the one thing the rest of this design exists to
            // prevent. It is listed so it does not simply vanish.
            case .conflicted:           changes.unresolved.append(Change(path: path, state: state))
            case .clean:                break
            }
        }
        return changes
    }

    // MARK: - Checking what other people have sent

    /// The result of one check, and when it was made.
    ///
    /// Held in memory only, deliberately. An extended attribute or a dotfile
    /// would outlive the truth: a week-old "also changed" would look exactly as
    /// authoritative as one from ten seconds ago, and it would mean writing to
    /// the user's own files to store Diptych's UI state. Here forgetting is the
    /// correct behaviour, so the store that forgets by itself is the right one.
    struct Check: Sendable {
        var contested: Set<String>
        var behind: Int
        var at: Date
    }

    /// How long a check is worth showing. Long enough to cover a work session,
    /// short enough that red cannot quietly persist into a world that has moved
    /// on -- the colour is only honest while its age is still defensible.
    static let checkGoesStaleAfter: TimeInterval = 30 * 60

    /// Bounded so that browsing through many repositories cannot grow without
    /// limit. Tiny either way: a set of short strings per repository.
    static let checksRemembered = 16

    /// The last check for a repository, or nil if there is none worth showing.
    func check(for root: URL) -> Check? {
        guard let check = checks[root.path] else { return nil }
        guard Date().timeIntervalSince(check.at) < Self.checkGoesStaleAfter else {
            checks.removeValue(forKey: root.path)
            return nil
        }
        return check
    }

    /// Ask the server what it has. The only operation that reaches the network
    /// without the user having asked for something else, which is why it is
    /// never on a timer: the user presses it, and the age of the answer is
    /// shown next to the answer.
    ///
    /// `fetch` is read-only -- it updates what this Mac knows about the shared
    /// copy and touches no file in the folder.
    func checkForChanges(inRepository root: URL) async -> CheckResult {
        switch await command(["fetch"], in: root, timeout: 120) {
        case .ok:
            break
        case .failed(_, let text), .couldNotRun(let text):
            return .failed(details: text)
        case .timedOut:
            return .failed(details: "The check took too long and was stopped.")
        }

        invalidate(root)
        let contested = Set(await conflictingPaths(inRepository: root))
        let behind = await status(forRepository: root)?.behind ?? 0

        noteCheck(root, contested: contested, behind: behind)
        NotificationCenter.default.post(name: Self.checkCompleted, object: nil)
        return .checked(behind: behind, contested: contested.sorted())
    }

    enum CheckResult: Sendable {
        case checked(behind: Int, contested: [String])
        case failed(details: String)
    }

    // MARK: - Tracking

    func track(_ paths: [String], inRepository root: URL) async -> GitTool.Outcome {
        await command(["add", "--"] + paths, in: root)
    }

    /// Appends to `.gitignore`, which is a tracked file and therefore a change
    /// like any other -- it will show up in the next send, which is correct:
    /// everyone should get the same rules.
    func neverTrack(_ paths: [String], inRepository root: URL) async -> GitTool.Outcome {
        let file = root.appendingPathComponent(".gitignore")
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        var lines = existing.isEmpty ? [] : existing.split(separator: "\n").map(String.init)

        for path in paths where !lines.contains(path) { lines.append(path) }
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true,
                                                             encoding: .utf8)
        } catch {
            return .couldNotRun(error.localizedDescription)
        }
        invalidate(root)
        return .ok("")
    }

    // MARK: - Sending

    enum SendResult: Sendable {
        /// `kept` names copies set aside because restoring an unsent change on
        /// top of the newly arrived version genuinely clashed.
        case sent(count: Int, kept: [String])
        case nothingSelected
        /// Committed and pushed by someone else first, or offline. The commit
        /// has been undone; the files are exactly as they were.
        ///
        /// `conflicts` is what the two sides have both changed -- empty when
        /// the shared copy has merely moved on, which is the common case and
        /// the one that needs no decision from anybody.
        case notSent(reason: String, details: String, conflicts: [String])
        /// The push failed but the commit did reach the shared copy after all,
        /// so it was left in place. Undoing it would delete something other
        /// people can already see.
        case sentDespiteError(details: String)
    }

    /// Commit and push, as one action.
    ///
    /// "Saved here but not shared" is a state with no place in the user's
    /// model, and it is exactly where people believe they have shared when they
    /// have not -- so if the push fails, the commit is undone and the pane
    /// looks precisely as it did before the button was pressed.
    ///
    /// That undo is history rewriting, which is otherwise excluded. It is safe
    /// here for one reason, and only that reason: **the commit provably never
    /// left this Mac.** Which is why the failure path checks before undoing.
    func send(paths: [String], newPaths: [String], message: String,
              inRepository root: URL) async -> SendResult {
        let all = paths + newPaths
        guard !all.isEmpty else { return .nothingSelected }

        guard case .ok(let headText) = await command(["rev-parse", "HEAD"], in: root) else {
            return .notSent(reason: "This folder has no saved versions yet.",
                            details: "git rev-parse HEAD failed", conflicts: [])
        }
        let previousHead = headText.trimmingCharacters(in: .whitespacesAndNewlines)

        // What was already tracked before any of this began. Tracking a file is
        // a separate decision the user made earlier, and undoing the send must
        // not undo it -- `reset --mixed` unstages everything indiscriminately,
        // so a file marked green by hand went brown again when the push failed.
        var alreadyTracked: [String] = []
        if case .ok(let staged) = await command(["diff", "--name-only", "--cached", "HEAD"],
                                                in: root) {
            alreadyTracked = staged.split(separator: "\n").map(String.init)
        }

        // New files have to be tracked before a commit can name them.
        if !newPaths.isEmpty {
            if case .failed(_, let text) = await track(newPaths, inRepository: root) {
                return .notSent(reason: "Those files could not be included.",
                                details: text, conflicts: [])
            }
        }
        // Staging modifications too, so a deletion is recorded as one.
        if case .failed(_, let text) = await command(["add", "--"] + all, in: root) {
            return .notSent(reason: "Your changes could not be prepared.",
                            details: text, conflicts: [])
        }

        let commit = await command(["commit", "-m", message, "--"] + all, in: root)
        if case .failed(_, let text) = commit {
            return .notSent(reason: "Your work could not be saved.",
                            details: text, conflicts: [])
        }

        // Ticking a new file in the dialog means "include it, now and from now
        // on", so those stay tracked too: the send is undone, the decisions
        // that led to it are not.
        let keepTracked = alreadyTracked + newPaths

        switch await command(["push"], in: root, timeout: 120) {
        case .ok:
            invalidate(root)
            noteCheck(root, contested: [], behind: 0)
            return .sent(count: all.count, kept: [])

        case .timedOut:
            return await afterFailedPush(count: all.count, previousHead: previousHead,
                                         keepTracked: keepTracked, root: root,
                                         details: "The push took too long and was stopped.")

        case .failed(_, let text), .couldNotRun(let text):
            // A connection that dies *after* the server accepted means the
            // outcome is unknown. Undoing then would delete a commit other
            // people can already see, so ask before assuming.
            return await afterFailedPush(count: all.count, previousHead: previousHead,
                                         keepTracked: keepTracked, root: root, details: text)
        }
    }

    /// Catch up with the shared copy and send again, without touching anything
    /// the user did not choose to send.
    ///
    /// This is what other Git clients do and what Diptych refused to for far
    /// too long: a file changed here and also changed by someone else does not
    /// stop an *unrelated* file being sent. The commit already exists and holds
    /// only the chosen files; replaying it on top of what arrived is a rebase,
    /// safe because the commit has provably never left this Mac.
    ///
    /// `rebase.autoStash` puts the unsent working changes aside for the
    /// duration and brings them back afterwards. Most come back cleanly --
    /// two people editing different parts of one file is not a conflict, only
    /// a coincidence -- and the ones that do not are set aside by name.
    private func catchUpAndSendAgain(count: Int, previousHead: String,
                                     keepTracked: [String], root: URL,
                                     details: String) async -> SendResult {
        // An untracked file here that also arrives in the update would stop the
        // rebase before it started. Autostash does not cover those.
        let blocking = await untrackedFilesArrivingInUpdate(root: root)
        let movedAside = moveAside(blocking, inRepository: root)

        let rebase = await command(["-c", "rebase.autoStash=true", "rebase", "@{u}"],
                                   in: root, timeout: 120)
        if case .failed(_, let text) = rebase {
            // A file we *did* choose to send is contested, which is a real
            // decision for the user rather than something to paper over.
            _ = await command(["rebase", "--abort"], in: root)
            // Nothing arrived after all, so the files moved out of the way go
            // back under their own names rather than leaving the user with
            // renamed copies from an attempt that changed nothing.
            for (original, copy) in movedAside {
                try? FileManager.default.moveItem(at: copy, to: root.appendingPathComponent(original))
            }
            return await undoTheCommit(previousHead: previousHead, keepTracked: keepTracked,
                                       root: root, details: text.isEmpty ? details : text)
        }
        var kept = movedAside.map { $0.copy.lastPathComponent }
        if !kept.isEmpty { excludeLocally(pattern: "*(my version)*", inRepository: root) }

        switch await command(["push"], in: root, timeout: 120) {
        case .ok:
            break
        case .failed(_, let text), .couldNotRun(let text):
            invalidate(root)
            return .notSent(reason: "Your changes were not sent.", details: text, conflicts: [])
        case .timedOut:
            invalidate(root)
            return .notSent(reason: "Your changes were not sent.",
                            details: "The push took too long and was stopped.", conflicts: [])
        }

        // Whatever the autostash could not put back cleanly is still in the
        // stash, with conflict markers in the file. Take the user's version out
        // by name and leave the folder clean rather than leaving them to stare
        // at <<<<<<< in a document.
        kept += await rescueFailedAutostash(root: root)
        invalidate(root)
        noteCheck(root, contested: [], behind: 0)
        return .sent(count: count, kept: kept)
    }

    /// Untracked files here that the update is about to bring in.
    private func untrackedFilesArrivingInUpdate(root: URL) async -> [String] {
        guard case .ok(let incomingText) = await command(["diff", "--name-only", "HEAD", "@{u}"],
                                                         in: root) else { return [] }
        let incoming = Set(incomingText.split(separator: "\n").map(String.init))
        guard case .ok(let untrackedText) = await command(["ls-files", "--others",
                                                           "--exclude-standard"], in: root)
        else { return [] }
        return untrackedText.split(separator: "\n").map(String.init)
            .filter { incoming.contains($0) }
    }

    /// Renames each file out of the way so the arriving version has somewhere
    /// to land, remembering enough to put it back if the attempt is abandoned.
    private func moveAside(_ paths: [String],
                           inRepository root: URL) -> [(original: String, copy: URL)] {
        var moved: [(original: String, copy: URL)] = []
        for path in paths {
            let source = root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let target = FileOperations.uniqueURL(for: root.appendingPathComponent(myVersion(of: path)))
            guard (try? FileManager.default.moveItem(at: source, to: target)) != nil else { continue }
            moved.append((path, target))
        }
        return moved
    }

    /// The autostash conflicted: the user's version is in the stash and the
    /// file on disk has conflict markers in it.
    private func rescueFailedAutostash(root: URL) async -> [String] {
        guard case .ok(let list) = await command(["stash", "list"], in: root),
              !list.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        guard case .ok(let conflicted) = await command(["diff", "--name-only",
                                                        "--diff-filter=U"], in: root)
        else { return [] }
        let paths = conflicted.split(separator: "\n").map(String.init)

        var kept: [String] = []
        for path in paths {
            guard case .ok(let mine) = await command(["show", "stash@{0}:\(path)"], in: root)
            else { continue }
            let target = FileOperations.uniqueURL(for: root.appendingPathComponent(myVersion(of: path)))
            guard (try? mine.write(to: target, atomically: true, encoding: .utf8)) != nil
            else { continue }
            kept.append(target.lastPathComponent)
            _ = await command(["checkout", "HEAD", "--", path], in: root)
        }
        if !kept.isEmpty { excludeLocally(pattern: "*(my version)*", inRepository: root) }
        _ = await command(["stash", "drop"], in: root)
        return kept
    }

    private func myVersion(of path: String) -> String {
        let stem = (path as NSString).deletingPathExtension
        let suffix = (path as NSString).pathExtension
        return suffix.isEmpty ? "\(stem) (my version)" : "\(stem) (my version).\(suffix)"
    }

    /// Undo the commit -- but only after establishing that it really did not
    /// reach the shared copy. A push that failed after the server accepted it
    /// would otherwise have its commit deleted from under everyone who can
    /// already see it.
    private func afterFailedPush(count: Int, previousHead: String, keepTracked: [String],
                                 root: URL, details: String) async -> SendResult {
        _ = await command(["fetch"], in: root, timeout: 120)
        if case .ok = await command(["merge-base", "--is-ancestor", "HEAD", "@{u}"], in: root) {
            invalidate(root)
            return .sentDespiteError(details: details)
        }

        // Refused because the shared copy has moved on, which is the ordinary
        // case and not something to hand back to the user.
        if case .ok = await command(["rev-parse", "--verify", "@{u}"], in: root) {
            return await catchUpAndSendAgain(count: count, previousHead: previousHead,
                                             keepTracked: keepTracked, root: root,
                                             details: details)
        }

        return await undoTheCommit(previousHead: previousHead, keepTracked: keepTracked,
                                   root: root, details: details)
    }

    private func undoTheCommit(previousHead: String, keepTracked: [String], root: URL,
                               details: String) async -> SendResult {
        _ = await command(["reset", "--mixed", previousHead], in: root)
        // Put back what was tracked before the send, which the reset has just
        // swept away along with everything else.
        let clashing = await conflictingPaths(inRepository: root)
        let surviving = keepTracked.filter {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
        if !surviving.isEmpty {
            _ = await command(["add", "--"] + surviving, in: root)
        }
        invalidate(root)
        // The fetch above and this comparison are seconds old, so the pane can
        // go red now without the user having to ask a second time.
        noteCheck(root, contested: Set(clashing),
                  behind: await status(forRepository: root)?.behind ?? 0)
        // Says what happened, not what the user already knows. That their work
        // is still on their own Mac is not news; that it did not reach anyone
        // else is the whole point of the message.
        return .notSent(reason: clashing.isEmpty
                            ? "Your changes were not sent."
                            : "Your changes were not sent \u{2014} someone else has changed "
                              + "some of the same files.",
                        details: details, conflicts: clashing)
    }

    // MARK: - Getting the latest

    enum GetResult: Sendable {
        case upToDate
        case updated(count: Int)
        /// Both sides changed the same files. `paths` is computed exactly, not
        /// approximated as "everything that differs".
        case conflicting(paths: [String], hasOwnVersions: Bool)
        /// Updated, having set these copies of the user's versions aside.
        case keptCopies(names: [String])
        case failed(reason: String, details: String)
    }

    /// Fetch, then fast-forward. Never a plain `pull`, which can start a merge
    /// and leave a half-merged tree -- precisely where non-experts lose work.
    func getLatest(inRepository root: URL) async -> GetResult {
        switch await command(["fetch"], in: root, timeout: 120) {
        case .failed(_, let text), .couldNotRun(let text):
            return .failed(reason: "The shared copy could not be reached.", details: text)
        case .timedOut:
            return .failed(reason: "The shared copy could not be reached.",
                           details: "The connection took too long and was stopped.")
        case .ok: break
        }
        invalidate(root)

        guard let status = await status(forRepository: root) else {
            return .failed(reason: "This folder could not be read.", details: "")
        }
        guard status.upstream != nil else {
            return .failed(reason: "This folder is not linked to a shared copy.",
                           details: "no upstream branch")
        }
        if status.behind == 0 {
            noteCheck(root, contested: [], behind: 0)
            return .upToDate
        }

        if case .ok = await command(["merge", "--ff-only", "@{u}"], in: root) {
            invalidate(root)
            noteCheck(root, contested: [], behind: 0)
            return .updated(count: status.behind)
        }

        let clashing = await conflictingPaths(inRepository: root)
        noteCheck(root, contested: Set(clashing), behind: status.behind)
        return .conflicting(paths: clashing, hasOwnVersions: status.ahead > 0)
    }

    /// Files changed on both sides since the point they last agreed.
    ///
    /// Computed as an intersection rather than "everything that differs":
    /// someone who is fifty commits behind has hundreds of differing files and
    /// only two of them are their problem.
    func conflictingPaths(inRepository root: URL) async -> [String] {
        guard case .ok(let baseText) = await command(["merge-base", "HEAD", "@{u}"], in: root)
        else { return [] }
        let base = baseText.trimmingCharacters(in: .whitespacesAndNewlines)

        func names(_ arguments: [String]) async -> Set<String> {
            guard case .ok(let text) = await command(arguments, in: root) else { return [] }
            return Set(text.split(separator: "\n").map(String.init))
        }

        var mine = await names(["diff", "--name-only", base, "HEAD"])
        mine.formUnion(await names(["diff", "--name-only", "HEAD"]))
        mine.formUnion(await names(["diff", "--name-only", "--cached", "HEAD"]))
        // Untracked files count. `git diff` never sees them, so a file created
        // here that also arrived in the shared copy was missing from the list
        // entirely -- the dialog offered to keep copies of nothing, and the
        // update then failed on the very file it had not mentioned.
        mine.formUnion(await names(["ls-files", "--others", "--exclude-standard"]))
        let theirs = await names(["diff", "--name-only", base, "@{u}"])

        return mine.intersection(theirs).sorted()
    }

    /// Keep a copy of each conflicting file, then take the shared version.
    ///
    /// The copies go beside the originals so both panes and the diff viewer can
    /// be used on them at once, and the pattern goes into `.git/info/exclude`
    /// rather than `.gitignore`: local-only, never pushed, no tracked file
    /// touched -- so they cannot be sent by accident and no collaborator ever
    /// sees the rule.
    func keepCopiesAndTakeShared(paths: [String], inRepository root: URL) async -> GetResult {
        // What decides how each file is put back is whether it exists in the
        // current commit -- not whether Git has heard of it.
        //
        // "Untracked" was the wrong test. A file staged but never committed is
        // *tracked* and still absent from HEAD, so restoring it with
        // `checkout --` brought it back from the index and left it exactly
        // where it was, and the fast-forward refused again. That is what
        // happens to a file the user tracked by hand before a send that failed.
        var inHead: Set<String> = []
        for path in paths {
            if case .ok = await command(["cat-file", "-e", "HEAD:\(path)"], in: root) {
                inHead.insert(path)
            }
        }
        var kept: [String] = []

        for path in paths {
            let source = root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let stem = (path as NSString).deletingPathExtension
            let extension_ = (path as NSString).pathExtension
            let name = extension_.isEmpty ? "\(stem) (my version)"
                                          : "\(stem) (my version).\(extension_)"
            let target = FileOperations.uniqueURL(for: root.appendingPathComponent(name))
            do {
                try FileManager.default.copyItem(at: source, to: target)
                kept.append(target.lastPathComponent)
                // Copied, so the original is safe to get out of the way. Git
                // will not overwrite a file it has no committed version of,
                // and there is nothing to restore it from either.
                if !inHead.contains(path) {
                    _ = await command(["reset", "--", path], in: root)   // unstage
                    try FileManager.default.removeItem(at: source)
                }
            } catch {
                return .failed(reason: "A copy of your version could not be made.",
                               details: error.localizedDescription)
            }
        }
        excludeLocally(pattern: "*(my version)*", inRepository: root)

        // Whether the changes were saved as versions or not, the goal is the
        // same -- make the folder match the shared copy -- and only the command
        // differs.
        guard let status = await status(forRepository: root) else {
            return .failed(reason: "This folder could not be read.", details: "")
        }
        if status.ahead > 0 {
            // A bookmark, never a branch anyone works on, so the dropped
            // commits stay reachable instead of relying on the reflog, which
            // expires unreachable objects in about thirty days.
            let stamp = ISO8601DateFormatter.string(from: .now, timeZone: .current,
                                                    formatOptions: [.withYear, .withMonth,
                                                                    .withDay, .withDashSeparatorInDate])
            _ = await command(["branch", "diptych-kept-\(stamp)"], in: root)
            if case .failed(_, let text) = await command(["reset", "--hard", "@{u}"], in: root) {
                return .failed(reason: "The folder could not be updated.", details: text)
            }
        } else {
            // Only the ones with a committed version to come back to. The
            // rest have been removed above.
            let restorable = paths.filter { inHead.contains($0) }
            if !restorable.isEmpty {
                _ = await command(["checkout", "--"] + restorable, in: root)
            }
            if case .failed(_, let text) = await command(["merge", "--ff-only", "@{u}"], in: root) {
                return .failed(reason: "The folder could not be updated.", details: text)
            }
        }
        invalidate(root)
        return .keptCopies(names: kept)
    }

    private func excludeLocally(pattern: String, inRepository root: URL) {
        let file = root.appendingPathComponent(".git/info/exclude")
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        guard !existing.contains(pattern) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? (existing + (existing.hasSuffix("\n") || existing.isEmpty ? "" : "\n")
              + "# copies Diptych kept of your versions\n" + pattern + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - Running

    func command(_ arguments: [String], in root: URL,
                 timeout: TimeInterval = GitService.timeout) async -> GitTool.Outcome {
        guard let git = tool else { return .couldNotRun("No Git program is available.") }
        return await BlockingWork.run {
            GitTool.run(arguments, executable: git.url, in: root, timeout: timeout)
        }
    }
}
