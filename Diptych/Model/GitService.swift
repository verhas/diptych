import Foundation
import Observation

/// Everything the panes ask about Git.
///
/// One repository-wide `status` per repository, cached. Measured: a status call
/// costs 46-67 ms of which 23 ms is process spawn, so the rule is fewer, bigger
/// calls -- one for the whole repository rather than one per directory, and
/// certainly not one per file.
@MainActor
@Observable
final class GitService {

    static let shared = GitService()

    /// A status that takes longer than this is a repository Diptych should not
    /// be holding up a pane for. No colours is an acceptable outcome; a stalled
    /// listing is not.
    nonisolated static let timeout: TimeInterval = 10

    private(set) var tool: GitTool.Found?
    private(set) var toolError: String?

    /// Repository root for a directory, or nil for "not in a repository".
    /// Cached both ways: the answer for somewhere outside a repository is worth
    /// remembering too, since navigating around a home folder asks constantly.
    @ObservationIgnored private var roots: [String: URL?] = [:]
    @ObservationIgnored private var statuses: [String: GitStatus] = [:]
    /// One command in flight per repository. Git takes index.lock, and two
    /// concurrent commands in one repository fail.
    @ObservationIgnored private var inFlight: [String: Task<GitStatus?, Never>] = [:]

    var isEnabled: Bool { ConfigStore.shared.configuration.gitEnabled && tool != nil }

    private init() {}

    // MARK: - The tool

    /// Re-resolved at launch and whenever the settings change, so a Git that
    /// has been moved or uninstalled turns the feature off with an explanation
    /// rather than failing at every call.
    func locate() {
        let override = ConfigStore.shared.configuration.gitPath
        let found = GitTool.locate(override: override.isEmpty ? nil : override)
        tool = found
        toolError = found == nil
            ? (override.isEmpty
               ? "No Git program was found on this Mac."
               : "There is no usable Git program at \(override).")
            : nil
        forgetEverything()
    }

    func forgetEverything() {
        roots.removeAll()
        statuses.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    /// After anything that changes the repository, or when a watched directory
    /// fires.
    func invalidate(_ root: URL) {
        statuses.removeValue(forKey: root.path)
    }

    // MARK: - Asking

    func root(for directory: URL) async -> URL? {
        if let known = roots[directory.path] { return known }
        guard let git = tool else { return nil }

        let found = await BlockingWork.run {
            guard case .ok(let text) = GitTool.run(["rev-parse", "--show-toplevel"],
                                                   executable: git.url, in: directory,
                                                   timeout: Self.timeout)
            else { return URL?.none }
            let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : URL(fileURLWithPath: path)
        }
        roots[directory.path] = found
        return found
    }

    /// The repository's status, from cache when there is one.
    func status(forRepository root: URL) async -> GitStatus? {
        if let cached = statuses[root.path] { return cached }
        if let running = inFlight[root.path] { return await running.value }
        guard let git = tool else { return nil }

        let task = Task<GitStatus?, Never> {
            await BlockingWork.run {
                // One call answers everything: branch, upstream, how far ahead
                // and behind, and every file's state. --ignored is deliberately
                // not asked for -- ignored files are drawn normally, so their
                // names would be paid for and thrown away.
                let outcome = GitTool.run(["status", "--porcelain=v2", "-z", "--branch",
                                           "--untracked-files=all"],
                                          executable: git.url, in: root, timeout: Self.timeout)
                guard case .ok(let text) = outcome else { return GitStatus?.none }
                return GitStatus.parse(text)
            }
        }
        inFlight[root.path] = task
        let status = await task.value
        inFlight.removeValue(forKey: root.path)
        if let status { statuses[root.path] = status }
        return status
    }

    /// Root and status together, which is what a pane wants.
    func status(for directory: URL) async -> (root: URL, status: GitStatus)? {
        guard isEnabled, let root = await root(for: directory),
              let status = await status(forRepository: root) else { return nil }
        return (root, status)
    }

    // MARK: - Setup checklist

    struct Setup: Sendable {
        var root: URL?
        var name: String?
        var email: String?
        var remote: String?
        var upstream: String?

        var isReady: Bool {
            root != nil && name != nil && email != nil && remote != nil && upstream != nil
        }
    }

    /// Answered in plain words rather than by failing at the first send. Each
    /// line is one cheap command.
    func setup(for directory: URL) async -> Setup? {
        guard isEnabled, let git = tool, let root = await root(for: directory) else { return nil }

        return await BlockingWork.run {
            func ask(_ arguments: [String]) -> String? {
                guard case .ok(let text) = GitTool.run(arguments, executable: git.url,
                                                       in: root, timeout: Self.timeout)
                else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return Setup(root: root,
                         name: ask(["config", "user.name"]),
                         email: ask(["config", "user.email"]),
                         remote: ask(["remote", "get-url", "origin"]),
                         upstream: ask(["rev-parse", "--abbrev-ref", "@{u}"]))
        }
    }

    /// Everything a helper would need, in one paste.
    func diagnostics(for directory: URL) async -> String {
        var lines = ["Diptych Git diagnostics", ""]
        lines.append("git program : \(tool?.url.path ?? "none found")")
        lines.append("version     : \(tool?.version ?? "-")")
        lines.append("signature   : \(tool?.signature ?? "-")")
        if let toolError { lines.append("problem     : \(toolError)") }

        if let setup = await setup(for: directory) {
            lines.append("repository  : \(setup.root?.path ?? "-")")
            lines.append("name        : \(setup.name ?? "not set")")
            lines.append("email       : \(setup.email ?? "not set")")
            lines.append("shared copy : \(setup.remote ?? "none")")
            lines.append("linked to   : \(setup.upstream ?? "not linked")")
        } else {
            lines.append("repository  : this folder is not in a repository")
        }
        return lines.joined(separator: "\n")
    }
}
