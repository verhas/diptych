import Foundation

// Changing what only root may change on a server -- the owner of a file -- by
// running that one command through sudo. The SFTP session itself always runs as
// the user who signed in: only the single command is raised, and only when the
// server has refused it to that user.

/// What sudo did with a command.
nonisolated enum SudoOutcome: Equatable, Sendable {
    case done
    /// sudo wants a password, and none was given.
    case needsPassword
    /// The password given was not accepted.
    case wrongPassword
    /// The user may not run this through sudo at all.
    case notAllowed(String)
    /// sudo ran it, and it failed, with what it said.
    case failed(String)

    /// What sudo's error output means.
    static func reading(_ errors: String) -> SudoOutcome {
        let text = errors.lowercased()
        let said = errors.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("a password is required") || text.contains("no password was provided")
            || text.contains("a terminal is required") {
            return .needsPassword
        }
        if text.contains("incorrect password") || text.contains("sorry, try again") {
            return .wrongPassword
        }
        if text.contains("not in the sudoers") || text.contains("is not allowed to run")
            || text.contains("may not run sudo") {
            return .notAllowed(said)
        }
        return .failed(said.isEmpty ? "It failed, and said nothing." : said)
    }
}

/// How long a sudo password is kept, as the person chose.
nonisolated enum SudoKeep: String, CaseIterable, Identifiable, Sendable {
    case once, fiveMinutes, tenMinutes, hour, untilDisconnected

    var id: String { rawValue }

    var label: String {
        switch self {
        case .once: "Use it, then forget it"
        case .fiveMinutes: "Keep it for 5 minutes"
        case .tenMinutes: "Keep it for 10 minutes"
        case .hour: "Keep it for an hour"
        case .untilDisconnected: "Keep it until the server is disconnected"
        }
    }

    /// How long it is kept; nil until the server is disconnected.
    var duration: TimeInterval? {
        switch self {
        case .once: 0
        case .fiveMinutes: 5 * 60
        case .tenMinutes: 10 * 60
        case .hour: 60 * 60
        case .untilDisconnected: nil
        }
    }
}

/// The person's answer to the sudo question.
nonisolated struct SudoAnswer: Sendable {
    let password: String
    let keep: SudoKeep
}

/// The sudo passwords kept, by server, in memory only: never written anywhere,
/// gone at their time, when their server is disconnected, and when Diptych quits.
nonisolated final class SudoPasswords: @unchecked Sendable {

    static let shared = SudoPasswords()

    private let lock = NSLock()
    private var kept: [String: (password: String, until: Date?)] = [:]

    /// The password kept for a server, while it is still to be kept.
    func password(for server: String, now: Date = Date()) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = kept[server] else { return nil }
        if let until = entry.until, until <= now {
            kept[server] = nil
            return nil
        }
        return entry.password
    }

    /// Keeps a password as the person chose; `once` keeps nothing.
    func keep(_ password: String, for server: String, _ keep: SudoKeep, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        switch keep.duration {
        case 0?: kept[server] = nil
        case let seconds?: kept[server] = (password, now.addingTimeInterval(seconds))
        case nil: kept[server] = (password, nil)
        }
    }

    func forget(_ server: String) {
        lock.lock()
        kept[server] = nil
        lock.unlock()
    }

    func forgetAll() {
        lock.lock()
        kept = [:]
        lock.unlock()
    }
}

/// Quotes a word for a POSIX shell: in single quotes, which nothing inside
/// can break out of.
nonisolated func shellQuoted(_ word: String) -> String {
    "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Asks the person for the sudo password, in the frontmost browser window.
@MainActor
enum SudoPrompter {

    static func ask(host: String, user: String, wasWrong: Bool) async -> SudoAnswer? {
        let models = KeyRouter.shared.allModels
        guard let model = models.first(where: { $0.window?.isKeyWindow == true }) ?? models.first
        else { return nil }
        return await model.askSudoPassword(host: host, user: user, wasWrong: wasWrong)
    }
}
