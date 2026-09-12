import Foundation
import Observation

/// One run of one script: what was asked for, what came back, and how it ended.
@MainActor
@Observable
final class ScriptRun {

    let script: ScriptDefinition
    let command: [String]
    /// Shown above the output. The single moment the user sees exactly what is
    /// about to run, which is a safeguard rather than a convenience.
    var commandLine: String { command.joined(separator: " ") }

    private(set) var output = ""
    private(set) var isRunning = true
    /// Nil until it finishes. Anything but zero is a failure, however plausible
    /// the output looks.
    private(set) var status: Int32?
    private(set) var trouble: String?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var temporary: URL?

    init(script: ScriptDefinition, targets: [ScriptTarget], left: URL, right: URL,
         active: URL, other: URL) {
        self.script = script
        // A copy in the per-user temporary folder, not /tmp: nothing else can
        // put a different file in its place between writing it and running it.
        // Written from the bytes that were approved, so what runs is what was
        // agreed to.
        let copy = ScriptRun.copyOfScript(script)
        self.temporary = copy
        self.command = script.command(for: targets, script: copy ?? script.url)

        start(left: left, right: right, active: active, other: other)
    }

    private static func copyOfScript(_ script: ScriptDefinition) -> URL? {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diptych-script-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])) != nil else { return nil }

        let copy = folder.appendingPathComponent(script.url.lastPathComponent)
        guard (try? script.contents.write(to: copy, atomically: true, encoding: .utf8)) != nil
        else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: copy.path)
        return copy
    }

    private func start(left: URL, right: URL, active: URL, other: URL) {
        guard let program = command.first else {
            finish(with: nil, trouble: "There is nothing to run.")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: program)
        task.arguments = Array(command.dropFirst())
        // The home folder, as agreed: a script that wants a pane says so, with
        // `cd "$DIPTYCH_ACTIVE"`, and one that does not is somewhere harmless.
        task.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        var environment = ProcessInfo.processInfo.environment
        // Whole words, and no two of them a letter apart. Four variables whose
        // names differed only in their last letter would turn a typo into
        // another valid variable -- and in a two-pane file manager that means
        // running against the wrong files and finding out afterwards.
        environment["DIPTYCH_LEFT"] = left.path
        environment["DIPTYCH_RIGHT"] = right.path
        environment["DIPTYCH_ACTIVE"] = active.path
        environment["DIPTYCH_OTHER"] = other.path
        // The original, not the copy that is running: a script looking for
        // something beside itself has to be told where it really lives.
        environment["DIPTYCH_SCRIPT"] = script.url.path
        task.environment = environment

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        // Both streams into one pipe, and read as it arrives: a script that
        // prints for a minute should be readable for that minute, and one that
        // never finishes must not leave a window that can only wait.
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in self?.output += text }
        }

        task.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            let code = finished.terminationStatus
            let signalled = finished.terminationReason == .uncaughtSignal
            Task { @MainActor [weak self] in
                self?.finish(with: code,
                             trouble: signalled ? "The script was stopped." : nil)
            }
        }

        do {
            try task.run()
            process = task
        } catch {
            finish(with: nil,
                   trouble: "\u{201C}\(program)\u{201D} could not be run. "
                          + error.localizedDescription)
        }
    }

    func stop() {
        process?.terminate()
    }

    private func finish(with code: Int32?, trouble: String?) {
        status = code
        self.trouble = trouble
        isRunning = false
        process = nil
        if let temporary {
            try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent())
            self.temporary = nil
        }
    }
}
