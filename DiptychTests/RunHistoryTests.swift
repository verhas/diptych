import XCTest
@testable import Diptych
import SwiftTerm

/// The argument lines Run ▸ remembers, one JSON file per program, and how
/// they follow a program that is moved or copied.
final class RunHistoryTests: XCTestCase {

    private var folder: URL!
    private var program: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        program = folder.appendingPathComponent("build.sh")
        try "#!/bin/sh\necho hi\n".write(to: program, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func store(limit: Int? = 10) -> RunHistory {
        RunHistory(directory: folder.appendingPathComponent("history"), defaultLimit: limit)
    }

    func testTheMostRecentComesFirstAndARepeatMovesUp() {
        let history = store()
        history.record("run", for: program)
        history.record("dmg", for: program)
        history.record("run", for: program)
        XCTAssertEqual(history.entries(for: program).map(\.arguments), ["run", "dmg"])
    }

    func testNoArgumentsIsNotHistory() {
        let history = store()
        history.record("   ", for: program)
        XCTAssertEqual(history.entries(for: program).map(\.arguments), [])
    }

    func testTheLimitRollsTheOldestOff() {
        let history = store(limit: 2)
        for line in ["a", "b", "c"] { history.record(line, for: program) }
        XCTAssertEqual(history.entries(for: program).map(\.arguments), ["c", "b"])
    }

    func testNoLimitKeepsEverything() {
        let history = store(limit: nil)
        for n in 1...30 { history.record("arg\(n)", for: program) }
        XCTAssertEqual(history.entries(for: program).count, 30)
    }

    func testAProgramsOwnLimitAndFixedListAreHonoured() throws {
        let history = store()
        history.record("run", for: program)
        let file = history.ensureFile(for: program)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: file)) as? [String: Any])
        json["fixed"] = true
        try JSONSerialization.data(withJSONObject: json).write(to: file)

        history.record("dmg", for: program)
        XCTAssertEqual(history.entries(for: program).map(\.arguments), ["run"], "a fixed list does not grow")
        history.delete(arguments: "run", for: program)
        XCTAssertEqual(history.entries(for: program).map(\.arguments), [], "but deleting still works")
    }

    func testTheFileNamesItsProgramForGrep() throws {
        let history = store()
        history.record("dmg", for: program)
        let key = RunHistory.key(forPath: RunHistory.canonicalPath(of: program))
        let text = try String(contentsOf: history.fileURL(forKey: key), encoding: .utf8)
        XCTAssertTrue(text.contains(RunHistory.canonicalPath(of: program)))
    }

    func testAMovedProgramTakesItsHistoryAlong() throws {
        let history = store()
        history.record("publish", for: program)
        let oldKey = RunHistory.key(forPath: RunHistory.canonicalPath(of: program))
        let moved = folder.appendingPathComponent("release.sh")
        try FileManager.default.moveItem(at: program, to: moved)

        XCTAssertEqual(history.entries(for: moved).map(\.arguments), ["publish"], "found by its attribute")
        history.record("dmg", for: moved)
        XCTAssertEqual(history.entries(for: moved).map(\.arguments), ["dmg", "publish"])
        XCTAssertNil(history.read(key: oldKey), "the old file goes, its program is gone")
    }

    func testACopyInheritsOnceAndThenGoesItsOwnWay() throws {
        let history = store()
        history.record("run", for: program)
        let copy = folder.appendingPathComponent("build-copy.sh")
        try FileManager.default.copyItem(at: program, to: copy)

        XCTAssertEqual(history.entries(for: copy).map(\.arguments), ["run"])
        history.record("dmg", for: copy)
        history.record("release", for: program)
        XCTAssertEqual(history.entries(for: copy).map(\.arguments), ["dmg", "run"])
        XCTAssertEqual(history.entries(for: program).map(\.arguments), ["release", "run"])
    }
}

/// A run, start to end: the arguments as the shell reads them, the output, and
/// the exit code.
@MainActor
final class CommandRunTests: XCTestCase {

    private func finished(_ run: CommandRun) async {
        for _ in 0..<100 where run.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
    }

    func testArgumentsReachTheProgramAsTheShellReadsThem() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandRunTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("show args.sh")
        try "#!/bin/sh\nfor a in \"$@\"; do echo \"<$a>\"; done\nexit 3\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let run = CommandRun(program: script, arguments: "one 'two words' $HOME",
                             directory: folder)
        await finished(run)
        XCTAssertFalse(run.isRunning)
        XCTAssertEqual(run.exitCode, 3)
        let output = run.outputText
        XCTAssertTrue(output.contains("<one>"), output)
        XCTAssertTrue(output.contains("<two words>"), output)
        XCTAssertTrue(output.contains("<\(NSHomeDirectory())>"), output)
        XCTAssertEqual(run.commandLine, "'./show args.sh' one 'two words' $HOME")
        XCTAssertNotNil(run.cpu, "the wrapper reported times")
        XCTAssertTrue(run.timingLine.hasPrefix("real 0m"), run.timingLine)
        XCTAssertEqual(run.state, "failed")
    }

    func testTimesOutputIsReadLikeTimeReportsIt() {
        let parsed = CommandRun.childTimes(fromTimesOutput: "0m0.001s 0m0.002s\n1m12.403s 0m8.102s\n")
        XCTAssertEqual(parsed?.user ?? 0, 72.403, accuracy: 0.0005)
        XCTAssertEqual(parsed?.system ?? 0, 8.102, accuracy: 0.0005)
        XCTAssertEqual(CommandRun.formatted(72.403), "1m12.403s")
        XCTAssertEqual(CommandRun.formatted(0.5), "0m00.500s")
    }
}

/// The last day's runs on disk: kept after the tab closes, and after a
/// restart; purged after a day.
@MainActor
final class RunLogTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func script(_ body: String) throws -> URL {
        let url = folder.appendingPathComponent("tool.sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testAFinishedRunAndItsOutputSurviveARestart() async throws {
        let logFolder = folder.appendingPathComponent("runs")
        let log = RunLog(directory: logFolder)
        let run = CommandRun(program: try script("echo hello from the run; exit 2"),
                             arguments: "", directory: folder)
        log.started(run)
        for _ in 0..<100 where run.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        log.finished(run)

        let reopened = RunLog(directory: logFolder)
        let record = try XCTUnwrap(reopened.record(run.id))
        XCTAssertEqual(record.state, "failed")
        XCTAssertEqual(record.exitCode, 2)
        XCTAssertEqual(record.diptychPID, getpid())
        XCTAssertTrue(record.isThisSession, "started by the Diptych running now")
        XCTAssertLessThan(DiptychProcess.startedAt, Date(), "the process's own start time")
        XCTAssertTrue(reopened.savedOutput(run.id)?.contains("hello from the run") ?? false)
        let mode = try FileManager.default.attributesOfItem(
            atPath: logFolder.appendingPathComponent("\(run.id.uuidString).log").path)[.posixPermissions]
        XCTAssertEqual((mode as? NSNumber)?.intValue, 0o600, "output is private")
    }

    func testARunStillGoingWhenDiptychQuitIsInterrupted() throws {
        let logFolder = folder.appendingPathComponent("runs")
        let log = RunLog(directory: logFolder)
        let run = CommandRun(program: try script("sleep 30"), arguments: "", directory: folder)
        log.started(run)
        let reopened = RunLog(directory: logFolder)
        XCTAssertEqual(reopened.record(run.id)?.state, "interrupted")
        run.stop()
    }

    func testRunsOlderThanADayArePurged() async throws {
        let logFolder = folder.appendingPathComponent("runs")
        let log = RunLog(directory: logFolder)
        let run = CommandRun(program: try script("true"), arguments: "", directory: folder)
        log.started(run)
        for _ in 0..<100 where run.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        log.finished(run)
        log.purge(now: Date().addingTimeInterval(24 * 3600 + 60), keptFor: 24 * 3600)
        XCTAssertNil(log.record(run.id))
        XCTAssertNil(log.savedOutput(run.id))
    }
}

final class RunHistoryDefaultsTests: XCTestCase {
    func testANewFileSpellsOutItsSettings() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunHistoryDefaults-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let program = folder.appendingPathComponent("tool.sh")
        try "#!/bin/sh\n".write(to: program, atomically: true, encoding: .utf8)
        let history = RunHistory(directory: folder.appendingPathComponent("h"), defaultLimit: 7)
        let text = try String(contentsOf: history.ensureFile(for: program), encoding: .utf8)
        XCTAssertTrue(text.contains("\"fixed\" : false"), text)
        XCTAssertTrue(text.contains("\"limit\" : 7"), text)
        XCTAssertTrue(text.contains("\"unlimited\" : false"), text)
    }
}

/// What the terminals put on the clipboard.
@MainActor
final class TerminalCopyTests: XCTestCase {

    /// A gap the cursor jumped over comes back as spaces -- checked, because
    /// a paste that came out empty was first blamed on NULs here; it was not.
    func testGapsInALineComeBackAsSpaces() {
        let view = DiptychTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.feed(text: "ab\u{1b}[6Gcd")          // "ab", jump to column 6, "cd"
        let terminal = view.getTerminal()
        let raw = terminal.getText(start: Position(col: 0, row: 0), end: Position(col: 10, row: 0))
        XCTAssertFalse(raw.contains("\u{0}"))
        XCTAssertEqual(DiptychTerminalView.cleanedForPasting(raw), "ab   cd")
    }

    /// A real drag and release, in an off-screen window: the text is copied
    /// and nothing is left selected. The person's clipboard is put back.
    func testADragAndReleaseCopiesAndClearsTheSelection() {
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = DiptychTerminalView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        window.contentView = view
        view.feed(text: "hello selection world")
        var copied: String?
        view.onCopied = { copied = $0 }
        func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 110), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // The first drag event only marks where a selection starts; a real
        // drag sends many.
        view.mouseDown(with: event(.leftMouseDown, x: 3))
        view.mouseDragged(with: event(.leftMouseDragged, x: 60))
        view.mouseDragged(with: event(.leftMouseDragged, x: 120))
        XCTAssertFalse((view.getSelection() ?? "").isEmpty)
        view.mouseUp(with: event(.leftMouseUp, x: 120))
        XCTAssertNotNil(copied)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), copied)
        XCTAssertNil(view.getSelection(), "the selection is cleared once it is copied")
    }

    /// A selection with nothing in it to copy is still cleared.
    func testAnEmptySelectionIsClearedToo() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = DiptychTerminalView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        window.contentView = view
        func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 110), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, x: 3))
        view.mouseDragged(with: event(.leftMouseDragged, x: 120))
        view.mouseUp(with: event(.leftMouseUp, x: 120))
        XCTAssertNil(view.getSelection())
    }

    func testPaddingIsTrimmedAndEmptyIsNothing() {
        XCTAssertEqual(DiptychTerminalView.cleanedForPasting("one   \ntwo\u{0}\u{0}\n\n"), "one\ntwo")
        XCTAssertNil(DiptychTerminalView.cleanedForPasting("  \u{0} \n"))
    }
}

/// Environment variables and templates.
final class RunTemplateTests: XCTestCase {

    private var folder: URL!
    private var program: URL!
    typealias Variable = RunHistory.File.Entry.Variable

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunTemplateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        program = folder.appendingPathComponent("build.sh")
        try "#!/bin/sh\n".write(to: program, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testTheSameArgumentsWithOtherVariablesAreAnotherEntry() {
        let history = RunHistory(directory: folder.appendingPathComponent("h"), defaultLimit: 10)
        history.record("dmg", for: program)
        history.record("dmg", environment: [Variable(name: "CONFIG", value: "Debug")], for: program)
        history.record("dmg", for: program)
        let entries = history.entries(for: program)
        XCTAssertEqual(entries.map(\.arguments), ["dmg", "dmg"])
        XCTAssertEqual(entries.map(\.variables.count), [0, 1])
    }

    func testTemplatesAreNotRolledOff() {
        let history = RunHistory(directory: folder.appendingPathComponent("h"), defaultLimit: 2)
        history.record("release", asTemplate: true, for: program)
        for line in ["a", "b", "c"] { history.record(line, for: program) }
        let entries = history.entries(for: program)
        XCTAssertEqual(entries.filter(\.isTemplate).map(\.arguments), ["release"])
        XCTAssertEqual(entries.filter { !$0.isTemplate }.map(\.arguments), ["c", "b"])
    }

    func testVariablesWithoutArgumentsAreHistory() {
        let history = RunHistory(directory: folder.appendingPathComponent("h"), defaultLimit: 10)
        history.record("", environment: [Variable(name: "DEBUG", value: "1")], for: program)
        XCTAssertEqual(history.entries(for: program).count, 1)
    }

    func testNamesAreCheckedTheWayAShellReadsThem() {
        XCTAssertTrue(RunArgumentsView.isValidName("CONFIG"))
        XCTAssertTrue(RunArgumentsView.isValidName("_private_2"))
        XCTAssertFalse(RunArgumentsView.isValidName("2FAST"))
        XCTAssertFalse(RunArgumentsView.isValidName("A-B"))
        XCTAssertFalse(RunArgumentsView.isValidName("A B"))
    }
}

@MainActor
final class RunEnvironmentTests: XCTestCase {
    func testVariablesReachTheProgram() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunEnvironmentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("show.sh")
        try "#!/bin/sh\necho \"<$GREETING>\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let run = CommandRun(program: script, arguments: "",
                             environment: [.init(name: "GREETING", value: "hello there")],
                             directory: folder)
        for _ in 0..<100 where run.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(run.exitCode, 0)
        XCTAssertTrue(run.outputText.contains("<hello there>"), run.outputText)
        XCTAssertEqual(run.commandLine, "GREETING='hello there' ./show.sh")
    }
}
