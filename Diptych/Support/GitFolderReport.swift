import Foundation

/// The Git part of a folder's preview: which branch, how it stands with the
/// shared copy, what is changed and not sent, and the last few commits --
/// in the words the panes use (see `git-integration.md`), not Git's.
///
/// Three read-only commands, run as the panes run theirs: never prompting,
/// never taking the index lock.
nonisolated enum GitFolderReport {

    struct Commit: Sendable, Equatable {
        var hash: String
        var author: String
        var date: Date
        var subject: String
    }

    struct Facts: Sendable {
        var root: URL
        var status: GitStatus
        /// Not clean, under the folder shown, by path relative to it.
        var changes: [(path: String, state: GitState)]
        /// The last commits that touched the folder.
        var commits: [Commit]
        var isRoot: Bool
    }

    static let commitsShown = 5
    static let changesShown = 200

    /// Nil when the folder is not in a repository, or Git does not answer in time.
    static func read(_ folder: URL, git: URL, timeout: TimeInterval = 5) -> Facts? {
        guard case .ok(let top) = GitTool.run(["rev-parse", "--show-toplevel"], executable: git,
                                              in: folder, timeout: timeout) else { return nil }
        let rootPath = top.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootPath.isEmpty else { return nil }
        let root = URL(fileURLWithPath: rootPath)
        guard case .ok(let text) = GitTool.run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"],
                                               executable: git, in: root, timeout: timeout) else { return nil }
        let status = GitStatus.parse(text)

        let here = GitStatus.relativePath(of: folder, under: root) ?? ""
        let prefix = here.isEmpty ? "" : here + "/"
        var changes: [(path: String, state: GitState)] = []
        for (path, state) in status.states where state != .clean && path.hasPrefix(prefix) {
            changes.append((String(path.dropFirst(prefix.count)), state))
        }
        changes.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        let isRoot = folder.standardizedFileURL.resolvingSymlinksInPath().path
            == root.standardizedFileURL.resolvingSymlinksInPath().path
        var commits: [Commit] = []
        // The folder's own history below the root; at the root every commit,
        // those that changed no file included. A repository with no commits
        // yet answers with an error: none.
        let log = ["log", "-\(commitsShown)", "--format=%h%x1f%an%x1f%at%x1f%s%x1e"] + (isRoot ? [] : ["--", "."])
        if case .ok(let log) = GitTool.run(log, executable: git, in: folder, timeout: timeout) {
            commits = log.split(separator: "\u{1E}").compactMap { record in
                let parts = record.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 4, let seconds = TimeInterval(parts[2]) else { return nil }
                return Commit(hash: parts[0], author: parts[1], date: Date(timeIntervalSince1970: seconds),
                              subject: parts[3])
            }
        }
        return Facts(root: root, status: status, changes: changes, commits: commits, isRoot: isRoot)
    }

    // MARK: - The section

    static func section(_ facts: Facts, now: Date = Date()) -> String {
        let status = facts.status
        var html = "<div class=git><h2>Git</h2><table class=facts>"
        if !facts.isRoot {
            html += row("Repository", escape(facts.root.lastPathComponent)
                        + " <span class=via>\(escape(facts.root.path))</span>")
        }
        switch status.branch {
        case nil, "(detached)"?:
            html += row("Branch", "<span class=bad>none</span> <span class=via>— a past commit is checked out; "
                        + "work done here belongs to no branch</span>")
        case let branch?:
            html += row("Branch", "<b>\(escape(branch))</b>")
        }
        if let upstream = status.upstream {
            var parts: [String] = []
            if status.ahead > 0 { parts.append("\(status.ahead) commit\(status.ahead == 1 ? "" : "s") of yours not sent") }
            if status.behind > 0 { parts.append("\(status.behind) newer there to get") }
            html += row("Shared copy", escape(upstream) + " <span class=via>— "
                        + (parts.isEmpty ? "even, as of the last check" : parts.joined(separator: "; ") + ", as of the last check")
                        + "</span>")
        } else if status.branch != nil, status.branch != "(detached)" {
            html += row("Shared copy", "<span class=via>not linked: nothing is sent from this branch</span>")
        }

        let counts = Dictionary(grouping: facts.changes, by: \.state).mapValues(\.count)
        if facts.changes.isEmpty {
            html += row(facts.isRoot ? "Changes" : "Changes here", "none — everything is as last committed")
        } else {
            let order: [GitState] = [.conflicted, .contested, .changed, .added, .renamed, .deleted,
                                     .untracking, .untracked, .stale, .keptCopy]
            let words = order.compactMap { state in counts[state].map { "\($0) \(state.title)" } }
            let label = facts.isRoot ? "Changes" : "Changes here"
            html += row(label, (counts[.conflicted] != nil ? "<span class=bad>" : "")
                        + escape(words.joined(separator: ", ")) + (counts[.conflicted] != nil ? "</span>" : ""))
        }
        html += "</table>"

        if !facts.changes.isEmpty {
            html += "<details><summary>\(facts.changes.count) changed item\(facts.changes.count == 1 ? "" : "s")</summary><table>"
            for change in facts.changes.prefix(changesShown) {
                html += "<tr><td class=name>\(escape(change.path))</td><td class=state>\(escape(change.state.title))</td></tr>"
            }
            html += "</table>"
            if facts.changes.count > changesShown {
                html += "<p class=footnote>And \(facts.changes.count - changesShown) more.</p>"
            }
            html += "</details>"
        }

        if !facts.commits.isEmpty {
            html += "<h3>Last commits\(facts.isRoot ? "" : " here")</h3><table>"
            for commit in facts.commits {
                html += "<tr><td class=hash>\(escape(commit.hash))</td><td class=name>\(escape(commit.subject))</td>"
                    + "<td class=when>\(escape(commit.author)), \(escape(ago(commit.date, now: now)))</td></tr>"
            }
            html += "</table>"
        } else {
            html += "<p class=empty>No commits yet\(facts.isRoot ? "" : " touch this folder").</p>"
        }
        return html + "</div>"
    }

    static let style = """
        <style>
        .git { margin: 14px 0 6px; padding-top: 6px; border-top: 1px solid var(--rule); }
        .git h2 { font-size: 13px; margin: 4px 0; }
        .git h3 { font-size: 12px; margin: 10px 0 0; color: var(--dim); font-weight: 600; }
        .git table.facts td:first-child { width: 110px; color: var(--dim); font-size: 11px; }
        .git .hash { width: 70px; font: 11px ui-monospace, Menlo, monospace; color: var(--dim); }
        .git .state { width: 130px; color: var(--dim); font-size: 11px; }
        .git details { margin-top: 6px; }
        .git summary { color: var(--dim); font-size: 11px; cursor: default; }
        </style>
        """

    private static func row(_ label: String, _ value: String) -> String {
        "<tr><td>\(escape(label))</td><td>\(value)</td></tr>"
    }

    private static func escape(_ text: String) -> String { ListingReport.escape(text) }

    private static func ago(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
