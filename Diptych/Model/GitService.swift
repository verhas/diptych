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

    /// Posted when the Git program, or whether it is used at all, has changed.
    /// Panes listen, because a pane that was drawn before Git was available has
    /// no colours and nothing else would ever tell it to look again.
    static let availabilityChanged = Notification.Name("dev.verhas.Diptych.gitAvailability")

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
    /// The last *Check for Changes* per repository. Not cleared by `invalidate`
    /// -- that fires on every save in a watched folder, and editing a file here
    /// does not make what the server holds any less true.
    @ObservationIgnored var checks: [String: GitService.Check] = [:]

    var isEnabled: Bool { ConfigStore.shared.configuration.gitEnabled && tool != nil }

    private init() {}

    // MARK: - The tool

    /// Re-resolved at launch and whenever the settings change, so a Git that
    /// has been moved or uninstalled turns the feature off with an explanation
    /// rather than failing at every call.
    /// Resolved once at startup, and again whenever the setting or the path
    /// changes. Without the startup call the first window drew with no colours
    /// and only picked them up if the user happened to open Settings.
    func locateIfNeeded() async {
        guard ConfigStore.shared.configuration.gitEnabled else { return }
        guard tool == nil, toolError == nil else { return }
        await locate()
    }

    /// Asynchronous because finding Git means running up to three programs --
    /// `xcode-select`, `git --version`, `codesign` -- and doing that on the
    /// main actor during launch delayed the first window by however long they
    /// took. It also hung the test host long enough that the runner gave up
    /// before it could connect.
    func locate() async {
        let override = ConfigStore.shared.configuration.gitPath
        let found = await BlockingWork.run {
            GitTool.locate(override: override.isEmpty ? nil : override)
        }
        tool = found
        toolError = found == nil
            ? (override.isEmpty
               ? "No Git program was found on this Mac."
               : "There is no usable Git program at \(override).")
            : nil
        forgetEverything()
        NotificationCenter.default.post(name: Self.availabilityChanged, object: nil)
    }

    func forgetEverything() {
        roots.removeAll()
        statuses.removeAll()
        checks.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    /// After anything that changes the repository, or when a watched directory
    /// fires.
    func invalidate(_ root: URL) {
        statuses.removeValue(forKey: root.path)
    }

    /// Record what we now know about the shared copy.
    ///
    /// Called from every operation that fetches, not only from *Check for
    /// Changes* -- a send that was refused has just worked out exactly which
    /// files are contested, and throwing that away only to make the user press
    /// Check would be silly. It also keeps the age on screen honest: the stamp
    /// means "when Diptych last spoke to the server", which is precisely what
    /// this records.
    func noteCheck(_ root: URL, contested: Set<String>, behind: Int) {
        if checks.count >= Self.checksRemembered, checks[root.path] == nil,
           let oldest = checks.min(by: { $0.value.at < $1.value.at })?.key {
            checks.removeValue(forKey: oldest)
        }
        checks[root.path] = Check(contested: contested, behind: behind, at: Date())
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
