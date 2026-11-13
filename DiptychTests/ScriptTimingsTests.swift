import XCTest
@testable import Diptych

/// How long scripts take, summed up per script, and the estimate drawn from it.
@MainActor
final class ScriptTimingsTests: XCTestCase {

    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptTimingsTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func store() -> ScriptTimings {
        ScriptTimings(url: folder.appendingPathComponent("script-timings.json"))
    }

    func testCountShortestLongestAndAverage() throws {
        let timings = store()
        timings.record("a.sh", seconds: 10, files: 1)
        timings.record("a.sh", seconds: 40, files: 4)
        timings.record("a.sh", seconds: 4, files: 2)
        let entry = try XCTUnwrap(timings.entry(for: "a.sh"))
        XCTAssertEqual(entry.runs, 3)
        XCTAssertEqual(entry.shortest, 4)
        XCTAssertEqual(entry.longest, 40)
        XCTAssertEqual(try XCTUnwrap(entry.average), 18, accuracy: 1e-9)
    }

    func testPerFileFigures() throws {
        let timings = store()
        timings.record("a.sh", seconds: 10, files: 1)   // 10 a file
        timings.record("a.sh", seconds: 40, files: 4)   // 10 a file
        timings.record("a.sh", seconds: 4, files: 2)    //  2 a file
        let entry = try XCTUnwrap(timings.entry(for: "a.sh"))
        XCTAssertEqual(entry.shortestPerFile, 2)
        XCTAssertEqual(entry.longestPerFile, 10)
        XCTAssertEqual(try XCTUnwrap(entry.averagePerFile), 22.0 / 3, accuracy: 1e-9)
    }

    func testARunOnNoFilesCountsButNotPerFile() throws {
        let timings = store()
        timings.record("a.sh", seconds: 5, files: 0)
        let entry = try XCTUnwrap(timings.entry(for: "a.sh"))
        XCTAssertEqual(entry.runs, 1)
        XCTAssertEqual(entry.runsWithFiles, 0)
        XCTAssertNil(entry.averagePerFile)
    }

    func testTheEstimateScalesWithTheFiles() {
        let timings = store()
        XCTAssertNil(timings.estimate(for: "a.sh", files: 3))
        timings.record("a.sh", seconds: 10, files: 2)
        XCTAssertEqual(timings.estimate(for: "a.sh", files: 6), 30)
        // Run on nothing: the plain average.
        XCTAssertEqual(timings.estimate(for: "a.sh", files: 0), 10)
    }

    func testWithoutPerFileFiguresTheEstimateIsTheAverage() {
        let timings = store()
        timings.record("a.sh", seconds: 8, files: 0)
        XCTAssertEqual(timings.estimate(for: "a.sh", files: 5), 8)
    }

    func testScriptsAreKeptApart() {
        let timings = store()
        timings.record("a.sh", seconds: 1, files: 1)
        timings.record("b.sh", seconds: 2, files: 1)
        XCTAssertEqual(timings.entry(for: "a.sh")?.runs, 1)
        XCTAssertEqual(timings.entry(for: "b.sh")?.runs, 1)
    }

    func testResetForgetsOnlyThatScript() {
        let timings = store()
        timings.record("a.sh", seconds: 1, files: 1)
        timings.record("b.sh", seconds: 2, files: 1)
        timings.reset("a.sh")
        XCTAssertNil(timings.entry(for: "a.sh"))
        XCTAssertNotNil(timings.entry(for: "b.sh"))
        XCTAssertNil(store().entry(for: "a.sh"), "the reset is on disk too")
    }

    func testFiguresSurviveARestartAndAreThePersonsAlone() throws {
        let timings = store()
        timings.record("a.sh", seconds: 3, files: 1)
        XCTAssertEqual(store().entry(for: "a.sh"), timings.entry(for: "a.sh"))
        let attributes = try FileManager.default.attributesOfItem(atPath: timings.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testNonsenseTimesAreNotRecorded() {
        let timings = store()
        timings.record("a.sh", seconds: -1, files: 1)
        timings.record("a.sh", seconds: .nan, files: 1)
        XCTAssertNil(timings.entry(for: "a.sh"))
    }

    func testDurations() {
        XCTAssertEqual(ScriptTimings.duration(0.84), "0.8s")
        XCTAssertEqual(ScriptTimings.duration(42.4), "42s")
        XCTAssertEqual(ScriptTimings.duration(185), "3m 05s")
        XCTAssertEqual(ScriptTimings.duration(3720), "1h 02m")
    }
}
