import Foundation

/// Finding and running the user's own `git`.
///
/// Diptych does not bundle Git and does not link libgit2. A subprocess inherits
/// the user's `.gitconfig`, their SSH agent, their credential helper, their
/// hooks and their Git version -- which is the whole reason push and pull work
/// at all for someone whose repository was set up by a colleague. See
/// `git-integration.md` for the argument in full.
enum GitTool {

    struct Found: Sendable, Equatable {
        let url: URL
        /// Whatever `git --version` printed, verbatim.
        let version: String
        /// Who signed the binary, in words: "Apple", a Developer ID name, or
        /// that it is unsigned. More honest than any "is this really Git" test,
        /// because there is no such test.
        let signature: String
    }

    enum Outcome: Sendable {
        case ok(String)
        /// Ran, and said no. `text` is Git's own stderr, kept verbatim: a
        /// friendly summary that swallows "Permission denied (publickey)"
        /// makes the problem unfixable.
        case failed(status: Int32, text: String)
        case timedOut
        case couldNotRun(String)
    }

    /// Searched in this order. **Not** `$PATH`: an app launched from the Finder
    /// gets a minimal PATH rather than the user's shell one, so discovery would
    /// find a different Git depending on how Diptych was started -- and an
    /// environment variable is not something to take executable paths from.
    static let candidates = [
        "/usr/bin/git",
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/usr/local/git/bin/git",
        "/opt/local/bin/git",
    ]

    /// The first candidate that answers like Git, or the override if one is set.
    nonisolated static func locate(override: String?) -> Found? {
        if let override, !override.isEmpty {
            return probe(URL(fileURLWithPath: override))
        }
        for path in candidates {
            // `/usr/bin/git` is a shim to the selected developer directory. On
            // a Mac with no Command Line Tools it raises the installer dialog,
            // so it is only tried once a developer directory is known to exist.
            if path == "/usr/bin/git", !hasDeveloperDirectory { continue }
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            if let found = probe(URL(fileURLWithPath: path)) { return found }
        }
        return nil
    }

    private nonisolated static var hasDeveloperDirectory: Bool {
        let selected = run(["-p"], executable: URL(fileURLWithPath: "/usr/bin/xcode-select"),
                           in: nil, timeout: 5)
        guard case .ok(let path) = selected else { return false }
        return FileManager.default.fileExists(atPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Runs `--version` and reads the code signature. Both are weak tests --
    /// a harmful program can print anything and be named anything -- which is
    /// why the settings pane says so rather than implying a check happened.
    nonisolated static func probe(_ url: URL) -> Found? {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        guard case .ok(let version) = run(["--version"], executable: url, in: nil, timeout: 5),
              version.hasPrefix("git version ") else { return nil }
        return Found(url: url,
                     version: version.trimmingCharacters(in: .whitespacesAndNewlines),
                     signature: signature(of: url))
    }

    private nonisolated static func signature(of url: URL) -> String {
        let described = run(["-dvv", url.path],
                            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                            in: nil, timeout: 5)
        // codesign writes its description to stderr.
        let text: String
        switch described {
        case .ok(let out): text = out
        case .failed(_, let err): text = err
        default: return "could not be checked"
        }

        for line in text.split(separator: "\n") where line.hasPrefix("Authority=") {
            let authority = line.dropFirst("Authority=".count)
            if authority.contains("Software Signing") { return "Apple" }
            return String(authority)
        }
        return text.contains("adhoc") ? "none (ad-hoc signed only)" : "none"
    }

    // MARK: - Running

    nonisolated static func run(_ arguments: [String], executable: URL,
                                in directory: URL?, timeout: TimeInterval) -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }

        var environment = ProcessInfo.processInfo.environment
        // Git must never stop to ask for anything: there is no terminal to ask
        // on, and a blocked process would hold the pane's decoration for ever.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // Read-only commands must not take index.lock or rewrite the index --
        // otherwise a status run by Diptych fights a git the user is running in
        // a terminal, and one of them loses.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        // Porcelain output is unlocalised, but error text is not; C keeps what
        // we show the user's helper in one language.
        environment["LC_ALL"] = "C"
        process.environment = environment

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        let collected = Collected()
        let reading = DispatchGroup()
        let queue = DispatchQueue(label: "dev.verhas.Diptych.git.io", attributes: .concurrent)

        do {
            try process.run()
        } catch {
            return .couldNotRun(error.localizedDescription)
        }

        // Read both pipes while the process runs. A repo-wide status easily
        // exceeds the 64 KB pipe buffer, and reading only after it exits would
        // deadlock: it cannot exit until someone drains the pipe.
        queue.async(group: reading) { collected.out(output.fileHandleForReading.readDataToEndOfFile()) }
        queue.async(group: reading) { collected.err(errors.fileHandleForReading.readDataToEndOfFile()) }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
            reading.wait()
            return .timedOut
        }
        reading.wait()

        let text = collected.outText
        guard process.terminationStatus == 0 else {
            return .failed(status: process.terminationStatus, text: collected.errText)
        }
        return .ok(text)
    }

    /// Two pipes read on two queues need somewhere thread-safe to land.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var outData = Data()
        private var errData = Data()

        func out(_ data: Data) { lock.lock(); outData = data; lock.unlock() }
        func err(_ data: Data) { lock.lock(); errData = data; lock.unlock() }

        var outText: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: outData, as: UTF8.self)
        }
        var errText: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: errData, as: UTF8.self)
        }
    }
}
