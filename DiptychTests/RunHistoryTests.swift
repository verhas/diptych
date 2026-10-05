import XCTest
@testable import Diptych

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
        XCTAssertEqual(history.entries(for: program), ["run", "dmg"])
    }

    func testNoArgumentsIsNotHistory() {
        let history = store()
        history.record("   ", for: program)
        XCTAssertEqual(history.entries(for: program), [])
    }

    func testTheLimitRollsTheOldestOff() {
        let history = store(limit: 2)
        for line in ["a", "b", "c"] { history.record(line, for: program) }
        XCTAssertEqual(history.entries(for: program), ["c", "b"])
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
        XCTAssertEqual(history.entries(for: program), ["run"], "a fixed list does not grow")
        history.delete("run", for: program)
        XCTAssertEqual(history.entries(for: program), [], "but deleting still works")
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

        XCTAssertEqual(history.entries(for: moved), ["publish"], "found by its attribute")
        history.record("dmg", for: moved)
        XCTAssertEqual(history.entries(for: moved), ["dmg", "publish"])
        XCTAssertNil(history.read(key: oldKey), "the old file goes, its program is gone")
    }

    func testACopyInheritsOnceAndThenGoesItsOwnWay() throws {
        let history = store()
        history.record("run", for: program)
        let copy = folder.appendingPathComponent("build-copy.sh")
        try FileManager.default.copyItem(at: program, to: copy)

        XCTAssertEqual(history.entries(for: copy), ["run"])
        history.record("dmg", for: copy)
        history.record("release", for: program)
        XCTAssertEqual(history.entries(for: copy), ["dmg", "run"])
        XCTAssertEqual(history.entries(for: program), ["release", "run"])
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
