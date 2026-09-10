import Foundation

/// What will happen to a file when you send your work.
///
/// Not a mirror of Git's index and worktree states -- deliberately. The colours
/// answer one question, and each case is something the user can act on. An
/// ignored file is `.clean`, because "nothing will happen" is the same answer
/// as for a file that has not changed, and colouring a `build` folder would
/// paint half the pane for no information.
enum GitState: Sendable, Equatable {
    /// New, and Git does not know about it: it will **not** be sent.
    case untracked
    /// New and tracked: it will be sent.
    case added
    /// Tracked and changed -- including deleted: it will be sent.
    case changed
    /// Changed here and on the shared side.
    case conflicted
    /// Nothing to send.
    case clean
}

extension GitState {
    /// What the column says. Plain words: the pane is read by someone who does
    /// not know what an index is.
    var title: String {
        switch self {
        case .untracked:  "not tracked"
        case .added:      "new"
        case .changed:    "changed"
        case .conflicted: "conflict"
        case .clean:      ""
        }
    }

    /// What will happen when you send your work, which is the only question
    /// the colours answer.
    var explanation: String? {
        switch self {
        case .untracked:  "New. This will not be sent unless you track it."
        case .added:      "New, and will be sent."
        case .changed:    "Changed, and will be sent."
        case .conflicted: "Changed here and in the shared copy."
        case .clean:      nil
        }
    }
}

/// One repository's answer, from a single `git status` call.
struct GitStatus: Sendable {
    /// Keyed by path relative to the repository root.
    var states: [String: GitState] = [:]
    var branch: String?
    var upstream: String?
    /// Commits this side has that the shared side does not, and the reverse.
    var ahead = 0
    var behind = 0

    func state(for url: URL, root: URL) -> GitState {
        guard let relative = GitStatus.relativePath(of: url, under: root) else { return .clean }
        if let exact = states[relative] { return exact }

        // A directory takes the strongest state of anything inside it, so a
        // folder is not silently clean while it holds changes -- the pane shows
        // folders, and their contents may never be looked at.
        let prefix = relative + "/"
        var strongest = GitState.clean
        for (path, state) in states where path.hasPrefix(prefix) {
            strongest = GitStatus.stronger(strongest, state)
        }
        return strongest
    }

    /// Conflicts matter most, then anything that will be sent, then anything
    /// that will not.
    static func stronger(_ a: GitState, _ b: GitState) -> GitState {
        let rank: (GitState) -> Int = {
            switch $0 {
            case .conflicted: 4
            case .changed:    3
            case .added:      2
            case .untracked:  1
            case .clean:      0
            }
        }
        return rank(a) >= rank(b) ? a : b
    }

    static func relativePath(of url: URL, under root: URL) -> String? {
        let path = FileOperations.canonicalPath(url)
        let base = FileOperations.canonicalPath(root)
        guard path.hasPrefix(base + "/") else { return path == base ? "" : nil }
        return String(path.dropFirst(base.count + 1))
    }

    // MARK: - Parsing

    /// Reads `git status --porcelain=v2 -z --branch --untracked-files=all`.
    ///
    /// NUL-separated, and one record is not one field: a rename (`2`) is
    /// followed by its original path as a *separate* NUL-terminated field, so a
    /// naive split leaves that path masquerading as a record of its own.
    static func parse(_ output: String) -> GitStatus {
        var status = GitStatus()
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0

        while index < fields.count {
            let field = fields[index]
            index += 1
            guard let kind = field.first else { continue }

            switch kind {
            case "#":
                let parts = field.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count >= 3 else { continue }
                switch parts[1] {
                case "branch.head":     status.branch = parts[2] == "(detached)" ? nil : parts[2]
                case "branch.upstream": status.upstream = parts[2]
                case "branch.ab":
                    // "+1 -0": ahead of the shared side by one, behind by none.
                    for token in parts[2].split(separator: " ") {
                        let value = Int(token.dropFirst()) ?? 0
                        if token.hasPrefix("+") { status.ahead = value }
                        if token.hasPrefix("-") { status.behind = value }
                    }
                default: break
                }

            case "?":
                status.states[String(field.dropFirst(2))] = .untracked

            case "!":
                // Only present if --ignored was asked for, which it is not.
                break

            case "u":
                if let path = pathAfter(fields: 10, in: field) {
                    status.states[path] = .conflicted
                }

            case "1", "2":
                // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
                // 2 adds <X><score> before the path, and eats the next field.
                let columns = kind == "1" ? 8 : 9
                if let path = pathAfter(fields: columns, in: field) {
                    status.states[path] = state(fromXY: field.dropFirst(2).prefix(2))
                }
                if kind == "2" { index += 1 }   // the original path of a rename

            default:
                break
            }
        }
        return status
    }

    /// The path is the remainder after a fixed number of space-separated
    /// columns -- taken this way because a path may itself contain spaces.
    private static func pathAfter(fields count: Int, in record: String) -> String? {
        var remaining = Substring(record)
        for _ in 0 ..< count {
            guard let space = remaining.firstIndex(of: " ") else { return nil }
            remaining = remaining[remaining.index(after: space)...]
        }
        return remaining.isEmpty ? nil : String(remaining)
    }

    /// `X` is what is staged, `Y` what is only in the folder. A staged addition
    /// is the one that means "new and tracked"; everything else that is not
    /// clean will be sent as a change.
    private static func state(fromXY xy: Substring) -> GitState {
        let staged = xy.first ?? "."
        return staged == "A" ? .added : .changed
    }
}
