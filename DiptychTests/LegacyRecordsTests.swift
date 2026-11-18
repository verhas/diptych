import XCTest
@testable import Diptych

/// What 1.x kept in JSON files is brought into the records database at
/// start, and the files go; the records database itself is never thrown away.
@MainActor
final class LegacyRecordsTests: XCTestCase {

    private var folder: URL!
    private let fm = FileManager.default

    override func setUp() async throws {
        folder = fm.temporaryDirectory.appendingPathComponent("LegacyRecordsTests-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: folder)
    }

    private func write(_ name: String, _ json: String) throws {
        try Data(json.utf8).write(to: folder.appendingPathComponent(name))
    }

    private func exists(_ name: String) -> Bool {
        fm.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    /// The four files as 1.13 wrote them.
    func testEachFileIsBroughtInAndThenDeleted() throws {
        let trashed = folder.appendingPathComponent("in-the-trash.txt")
        try Data("x".utf8).write(to: trashed)
        try write("trash-origins.json", """
            {"\(trashed.path)": "/Users/me/Desktop/in-the-trash.txt",
             "/nowhere/emptied.txt": "/Users/me/emptied.txt"}
            """)
        try write("servers.json", """
            [{"address": "sftp://pi@raspberry/home", "saved": true, "openAtLogin": false,
              "lastUsed": "2026-11-01T10:00:00Z", "keepAliveSeconds": 30, "hashCommand": "sha256sum"},
             {"address": "smb://nas/photos", "lastUsed": "2026-11-02T10:00:00Z", "mountPoint": "/Volumes/photos"}]
            """)
        try write("script-timings.json", """
            {"explain.sh": {"runs": 2, "shortest": 1, "longest": 3, "total": 4, "runsWithFiles": 2,
                            "shortestPerFile": 1, "longestPerFile": 3, "totalPerFile": 4}}
            """)
        try write("scripts-approved.json", #"["abc123", "def456"]"#)
        try write("config.json", #"{"kept": true}"#)

        let database = LocalDatabase.records(at: folder.appendingPathComponent("diptych.sqlite"))
        let imported = LegacyRecords.importFiles(in: folder, into: database)

        XCTAssertEqual(imported, ["trash-origins.json": 1, "servers.json": 2,
                                  "script-timings.json": 1, "scripts-approved.json": 2])
        for name in ["trash-origins.json", "servers.json", "script-timings.json", "scripts-approved.json"] {
            XCTAssertFalse(exists(name), "\(name) deleted once in")
        }
        XCTAssertTrue(exists("config.json"), "the configuration stays a file")

        let origins = TrashOriginals(database: database)
        XCTAssertEqual(origins.original(of: trashed), "/Users/me/Desktop/in-the-trash.txt")

        let servers = ServerStore(database: database)
        XCTAssertEqual(servers.servers.map(\.address), ["sftp://pi@raspberry/home", "smb://nas/photos"])
        let pi = servers.server(for: URL(string: "sftp://pi@raspberry/home")!)
        XCTAssertEqual(pi?.saved, true)
        XCTAssertEqual(pi?.keepAliveSeconds, 30)
        XCTAssertEqual(pi?.hashCommand, "sha256sum")
        XCTAssertEqual(servers.servers.last?.mountPoint, "/Volumes/photos")

        let timings = ScriptTimings(database: database)
        XCTAssertEqual(timings.entry(for: "explain.sh")?.runs, 2)
        XCTAssertEqual(timings.estimate(for: "explain.sh", files: 1), 2)

        let approvals = database.access { connection in
            connection.rows("SELECT fingerprint FROM script_approval ORDER BY fingerprint") { $0.text(0) ?? "" }
        }
        XCTAssertEqual(approvals, ["abc123", "def456"])
    }

    func testTheWindowsAreBroughtInWithTheirPanes() throws {
        try write("state.json", """
            {"windows": [{"frame": "{{100, 200}, {1100, 680}}", "activeSide": "right", "singlePane": true,
              "left": {"directory": "/Users/me", "recent": ["/a", "/b"], "viewStyle": "icons"},
              "right": {"directory": "/tmp", "sortField": "size", "sortAscending": false,
                        "flatExpression": "size > 1M"}},
             {"left": {"directory": "/x"}, "right": {"directory": "/y"}}]}
            """)
        let database = LocalDatabase.records(at: folder.appendingPathComponent("diptych.sqlite"))
        XCTAssertEqual(LegacyRecords.importFiles(in: folder, into: database)["state.json"], 2)
        XCTAssertFalse(exists("state.json"))

        let state = StateStore.read(from: database)
        XCTAssertEqual(state.windows.count, 2)
        let first = state.windows[0]
        XCTAssertEqual(first.frame, "{{100, 200}, {1100, 680}}")
        XCTAssertEqual(first.activeSide, "right")
        XCTAssertTrue(first.singlePane)
        XCTAssertEqual(first.left.recent, ["/a", "/b"], "in their order")
        XCTAssertEqual(first.left.viewStyle, "icons")
        XCTAssertEqual(first.right.sortField, "size")
        XCTAssertFalse(first.right.sortAscending)
        XCTAssertEqual(first.right.flatExpression, "size > 1M")
        XCTAssertEqual(state.windows[1].right.directory, "/y")
    }

    func testTheStateTablesGiveBackWhatWasWritten() throws {
        let database = LocalDatabase.records(at: folder.appendingPathComponent("diptych.sqlite"))
        var pane = PaneState(directory: "/p", recent: ["/r1", "/r2", "/r3"], flatDraft: "name ~ x")
        pane.iconArrangement = "finder"
        let state = DiptychState(windows: [
            WindowState(frame: nil, left: pane, right: PaneState(directory: "/q"), sidebarVisible: true,
                        showHidden: true)])
        _ = try database.transaction { StateStore.write(state, in: $0) }
        XCTAssertEqual(StateStore.read(from: database), state)
        // Written again with fewer: nothing of the old one is left over.
        let fewer = DiptychState(windows: [])
        _ = try database.transaction { StateStore.write(fewer, in: $0) }
        XCTAssertEqual(StateStore.read(from: database), fewer)
        XCTAssertEqual(database.access { $0.rows("SELECT COUNT(*) FROM pane_recent") { $0.int(0) } }, [0])
    }

    func testTheOldestLayoutAFileNotAFolderIsLiftedIntoOne() throws {
        let home = folder.appendingPathComponent(".diptych")
        try Data(#"{"windows": []}"#.utf8).write(to: home)
        LegacyRecords.liftPlainFile(at: home)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: home.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("state.json"), encoding: .utf8),
                       #"{"windows": []}"#)
        LegacyRecords.liftPlainFile(at: home)
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent("state.json").path), "a folder is left alone")
    }

    func testAFileThatCannotBeReadIsLeftAlone() throws {
        try write("servers.json", "not JSON at all")
        try write("scripts-approved.json", #"["abc"]"#)
        let database = LocalDatabase.records(at: folder.appendingPathComponent("diptych.sqlite"))
        let imported = LegacyRecords.importFiles(in: folder, into: database)
        XCTAssertEqual(imported, ["scripts-approved.json": 1])
        XCTAssertTrue(exists("servers.json"), "kept, to be tried again, rather than lost")
    }

    func testAFileWrittenAgainByAnOlderVersionWins() throws {
        let database = LocalDatabase.records(at: folder.appendingPathComponent("diptych.sqlite"))
        try write("script-timings.json", Self.timing(runs: 1))
        LegacyRecords.importFiles(in: folder, into: database)
        try write("script-timings.json", Self.timing(runs: 5))
        LegacyRecords.importFiles(in: folder, into: database)
        XCTAssertEqual(ScriptTimings(database: database).entry(for: "a.sh")?.runs, 5)
    }

    private static func timing(runs: Int) -> String {
        """
        {"a.sh": {"runs": \(runs), "shortest": 1, "longest": 1, "total": \(runs), "runsWithFiles": 0,
                  "shortestPerFile": 0, "longestPerFile": 0, "totalPerFile": 0}}
        """
    }

    func testADamagedRecordsFileIsSetAsideNotDeleted() throws {
        let url = folder.appendingPathComponent("diptych.sqlite")
        try Data(repeating: 0x41, count: 4096).write(to: url)
        let database = LocalDatabase.records(at: url)
        XCTAssertTrue(database.access { $0.run("INSERT INTO script_approval VALUES ('x', 0)") },
                      "a new one was made")
        let names = try fm.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("diptych.sqlite.damaged-") }, "\(names)")
    }

    func testTheCacheKeepsAVersionOneFileAndGivesItFolderSizes() throws {
        let url = folder.appendingPathComponent("cache.sqlite")
        // A cache from before folder sizes: version 1, with a listing in it.
        var database: LocalDatabase? = LocalDatabase.cache(at: url)
        database?.access { connection in
            connection.run("INSERT INTO browser_source (kind, root, opened_at) VALUES ('sftp', '/r', 0)")
            connection.exec("DROP TABLE folder_size; PRAGMA user_version = 1;")
        }
        database = nil
        let reopened = LocalDatabase.cache(at: url)
        let sources = reopened.access { $0.rows("SELECT root FROM browser_source") { $0.text(0) ?? "" } }
        XCTAssertEqual(sources, ["/r"], "listings kept: emptying them empties a server's fetched files")
        XCTAssertTrue(reopened.access {
            $0.run("INSERT INTO folder_size VALUES ('/a', '/', 1, 0, 1)")
        })
    }
}
