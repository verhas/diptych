import AppKit
import Observation
@preconcurrency import SwiftTerm

/// One run of a command-line program, from Run ▸ in the right-click menu,
/// shown as a tab of the Runs window.
///
/// A real terminal, so a program that draws progress, uses colour or asks a
/// question behaves as it does in Terminal.app. The arguments are given to
/// the login shell exactly as typed -- quotes, `~`, `$VARIABLES`, globs and
/// pipes all work as at a prompt -- after the program's own path, which
/// Diptych quotes. Input reaches the program while it runs; once it has
/// ended the terminal takes none.
@MainActor
@Observable
final class CommandRun: NSObject, Identifiable {

    let id = UUID()
    let program: URL
    let arguments: String
    /// Variables given to this run, on top of the login shell's.
    let environment: [RunHistory.File.Entry.Variable]
    let directory: URL

    private(set) var isRunning = true
    /// Nil until it ends, and nil too when it was ended by a signal.
    private(set) var exitCode: Int32?
    /// Stop was pressed: whatever the exit code says, it did not end by itself.
    private(set) var wasStopped = false
    let startedAt = Date()
    private(set) var endedAt: Date?
    /// User and system time, the program's children included -- what `time`
    /// reports. Nil while it runs, and when the shell could not say.
    private(set) var cpu: (user: TimeInterval, system: TimeInterval)?
    /// Whether its tab is still open. A closed run lives on in `RunLog`.
    var windowIsOpen = true
    /// Called once, when the program has ended and everything about it is known.
    @ObservationIgnored var onFinish: ((CommandRun) -> Void)?

    /// Set when this is one of the scripts in `~/.diptych/scripts`, run from
    /// Scripts ▸ rather than Run ▸.
    let script: Script?

    /// A Diptych script, which runs differently from a program run by hand:
    /// its argument list goes to it as it is, with no shell reading it -- a
    /// file name with spaces or quotes in it arrives in one piece -- from a
    /// private copy of the script, with the panes in `DIPTYCH_*` variables.
    struct Script {
        let name: String
        /// Exactly what is run, the private copy first.
        let command: [String]
        let variables: [String: String]
        /// The folder holding the private copy, removed when the run ends.
        let copyFolder: URL?
        /// What is shown: the command with the script's own path in place of
        /// the copy's.
        let shownCommand: String
    }

    @ObservationIgnored let view: DiptychTerminalView
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    /// Where the wrapper writes `times` when the program ends.
    @ObservationIgnored private let timesFile = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("diptych-run-\(UUID().uuidString).times")

    convenience init(program: URL, arguments: String,
                     environment: [RunHistory.File.Entry.Variable] = [], directory: URL) {
        self.init(program: program, arguments: arguments, environment: environment,
                  directory: directory, script: nil)
    }

    /// One of the scripts, on exactly these items. In the home folder, as
    /// agreed: a script that wants a pane says so, with `cd "$DIPTYCH_ACTIVE"`,
    /// and one that does not is somewhere harmless.
    convenience init(script definition: ScriptDefinition, targets: [ScriptTarget],
                     left: URL, right: URL, active: URL, other: URL) {
        // A copy in the per-user temporary folder, not /tmp: nothing else can
        // put a different file in its place between writing it and running
        // it. Written from the bytes that were approved, so what runs is what
        // was agreed to.
        let copy = Self.copyOfScript(definition)
        let command = definition.command(for: targets, script: copy ?? definition.url)
        let shown = command.map { $0 == copy?.path ? definition.url.path : $0 }
        let script = Script(
            name: definition.name, command: command,
            // Whole words, and no two of them a letter apart. Four variables
            // whose names differed only in their last letter would turn a typo
            // into another valid variable -- and in a two-pane file manager
            // that means running against the wrong files.
            variables: ["DIPTYCH_LEFT": left.path, "DIPTYCH_RIGHT": right.path,
                        "DIPTYCH_ACTIVE": active.path, "DIPTYCH_OTHER": other.path,
                        // The original, not the copy that is running: a script
                        // looking for something beside itself has to be told
                        // where it really lives.
                        "DIPTYCH_SCRIPT": definition.url.path],
            copyFolder: copy?.deletingLastPathComponent(),
            shownCommand: shown.map(Shell.argument).joined(separator: " "))
        self.init(program: definition.url,
                  arguments: shown.dropFirst().map(Shell.argument).joined(separator: " "),
                  environment: [], directory: FileManager.default.homeDirectoryForCurrentUser,
                  script: script)
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

    private init(program: URL, arguments: String,
                 environment: [RunHistory.File.Entry.Variable], directory: URL,
                 script: Script?) {
        self.script = script
        self.program = program
        self.arguments = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        self.environment = environment.filter { !$0.name.isEmpty }
        self.directory = directory
        let style = TerminalStyle.current
        view = DiptychTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480),
                                   font: style.font, options: TerminalOptions(scrollback: 50_000))
        super.init()
        view.processDelegate = self
        view.apply(style)
        start()
    }

    /// What is run, as a person would type it: the program's name, relative
    /// to where it runs when it is there, then the arguments.
    var commandLine: String {
        if let script { return script.shownCommand }
        let inPlace = program.deletingLastPathComponent().standardizedFileURL
            == directory.standardizedFileURL
        let name = inPlace ? "./" + program.lastPathComponent : program.path
        return Self.variablesPrefix(environment)
            + Shell.argument(name) + (arguments.isEmpty ? "" : " " + arguments)
    }

    /// "CONFIG=Release TOKEN='a b' " -- as a shell would take it.
    nonisolated static func variablesPrefix(_ variables: [RunHistory.File.Entry.Variable]) -> String {
        variables.map { $0.name + "=" + Shell.argument($0.value) + " " }.joined()
    }

    /// A login shell, so the PATH from `.zprofile` is there -- but not an
    /// interactive one: `.zshrc` would print its greeting into the output.
    ///
    /// The login shell reads the arguments, as typed, and hands them to a
    /// small `/bin/sh` wrapper that runs the program and, when it ends, writes
    /// `times` -- the user and system time of what it waited for, children
    /// included, as `time` reports them -- to a file, then exits with the
    /// program's own status. A shell can only time what it waits for, and the
    /// login shell may be fish, which has no `times`.
    private func start() {
        let shell = TerminalSession.loginShell
        let wrapper = #"out=$1; shift; "$@"; status=$?; times > "$out"; exit $status"#
        if let script {
            startScript(script, wrapper: wrapper)
            return
        }
        // The variables through env(1), after the login shell has read its
        // start-up files -- so a .zprofile cannot quietly override them.
        let variables = environment.map { Shell.argument("\($0.name)=\($0.value)") }
        let setting = variables.isEmpty ? "" : "/usr/bin/env " + variables.joined(separator: " ") + " "
        let script = "exec " + setting + "/bin/sh -c " + Shell.argument(wrapper) + " sh "
            + Shell.argument(timesFile.path) + " " + Shell.argument(program.path)
            + (arguments.isEmpty ? "" : " " + arguments)
        view.startProcess(executable: shell, args: ["-l", "-c", script],
                          environment: TerminalSession.environment,
                          execName: nil, currentDirectory: directory.path)
    }

    /// The same wrapper, but no login shell: the argument list goes to the
    /// script as it is. Diptych's own environment, as a script has always had,
    /// with a terminal's TERM so that colour and progress output work.
    private func startScript(_ script: Script, wrapper: String) {
        guard !script.command.isEmpty else {
            view.feed(text: "There is nothing to run.\r\n")
            processTerminated(source: view, exitCode: nil)
            return
        }
        var variables = ProcessInfo.processInfo.environment
        variables["TERM"] = "xterm-256color"
        variables["COLORTERM"] = "truecolor"
        variables["TERM_PROGRAM"] = "Diptych"
        variables.merge(script.variables) { $1 }
        view.startProcess(executable: "/bin/sh",
                          args: ["-c", wrapper, "sh", timesFile.path] + script.command,
                          environment: variables.map { "\($0.key)=\($0.value)" },
                          execName: nil, currentDirectory: directory.path)
    }

    /// Control-C, as at a prompt; if the program does not end within two
    /// seconds, the terminal is closed under it.
    func stop() {
        guard isRunning else { return }
        wasStopped = true
        view.send(txt: "\u{3}")
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, self.isRunning else { return }
            self.view.terminate()
        }
    }

    /// Everything it printed, scrollback included, as plain text: the colours
    /// and cursor movements are the terminal's, not part of the output.
    var outputText: String {
        let data = view.getTerminal().getBufferAsData(kind: .normal)
        var text = String(decoding: data, as: UTF8.self)
        while text.hasSuffix("\n\n") { text.removeLast() }
        return text
    }
}

extension CommandRun: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// SwiftTerm passes the raw `waitpid` status, not the exit code: exit 3
    /// arrives as 768. Decoded the way `WIFEXITED`/`WEXITSTATUS` do; a
    /// program ended by a signal has no exit code at all.
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
        endedAt = Date()
        self.exitCode = exitCode.flatMap(Self.exitCode(fromWaitStatus:))
        if let text = try? String(contentsOf: timesFile, encoding: .utf8) {
            cpu = Self.childTimes(fromTimesOutput: text)
        }
        try? FileManager.default.removeItem(at: timesFile)
        if let folder = script?.copyFolder { try? FileManager.default.removeItem(at: folder) }
        stopTask?.cancel()
        onFinish?(self)
        onFinish = nil
    }

    /// `times` prints two lines, the shell's own user and system time and then
    /// its children's -- "0m45.201s 0m8.102s". The second is the program's.
    nonisolated static func childTimes(fromTimesOutput text: String)
        -> (user: TimeInterval, system: TimeInterval)? {
        let lines = text.split(separator: "\n").map(String.init)
        guard let children = lines.last else { return nil }
        let values = children.split(separator: " ").compactMap { seconds(String($0)) }
        guard values.count == 2 else { return nil }
        return (values[0], values[1])
    }

    /// "1m12.403s" as seconds.
    nonisolated static func seconds(_ text: String) -> TimeInterval? {
        guard text.hasSuffix("s"), let m = text.firstIndex(of: "m"),
              let minutes = Double(text[..<m]),
              let seconds = Double(text[text.index(after: m)..<text.index(before: text.endIndex)])
        else { return nil }
        return minutes * 60 + seconds
    }

    /// Wall-clock time so far, or in all once it has ended.
    var realTime: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    /// As `time` writes it: "1m12.403s".
    nonisolated static func formatted(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return String(format: "%dm%06.3fs", minutes, seconds - Double(minutes) * 60)
    }

    /// "real 1m12.403s  user 0m45.201s  sys 0m8.102s", or as much as is known.
    var timingLine: String {
        var parts = ["real " + Self.formatted(realTime)]
        if let cpu {
            parts.append("user " + Self.formatted(cpu.user))
            parts.append("sys " + Self.formatted(cpu.system))
        }
        return parts.joined(separator: "  ")
    }

    /// running, finished, failed or stopped -- as the window and MCP say it.
    var state: String {
        if isRunning { return "running" }
        if wasStopped { return "stopped" }
        return exitCode == 0 ? "finished" : (exitCode == nil ? "stopped" : "failed")
    }

    nonisolated static func exitCode(fromWaitStatus status: Int32) -> Int32? {
        status & 0x7f == 0 ? (status >> 8) & 0xff : nil
    }
}

/// The runs whose tabs are open in the Runs window, or that are still running:
/// for the tab strip, and for live output. Once a run has ended and its tab is
/// closed it is dropped here -- its record and output are in `RunLog` by then,
/// and a terminal's scrollback is not worth keeping in memory for nothing.
@MainActor
@Observable
final class CommandRuns {
    static let shared = CommandRuns()
    private var runs: [CommandRun] = []
    private init() {}

    /// The tab shown in the Runs window: "this run", "the open one" -- what
    /// the person most likely means. Nil once the window is closed.
    var focused: UUID?

    func add(_ run: CommandRun) {
        runs.append(run)
        focused = run.id
    }

    func run(_ id: UUID) -> CommandRun? { runs.first { $0.id == id } }
    var all: [CommandRun] { runs }
    var tabs: [CommandRun] { runs.filter(\.windowIsOpen) }

    /// Its tab closed. The neighbour to its left -- or right -- takes its place.
    func closeTab(_ id: UUID) {
        guard let run = run(id) else { return }
        let open = tabs
        if focused == id, let index = open.firstIndex(where: { $0.id == id }) {
            let neighbour = index > 0 ? open[index - 1] : open.dropFirst().first
            focused = neighbour?.id
        }
        run.windowIsOpen = false
        if !run.isRunning { runs.removeAll { $0.id == id } }
    }

    func finished(_ run: CommandRun) {
        if !run.windowIsOpen { runs.removeAll { $0.id == run.id } }
    }
}
