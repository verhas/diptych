import SQLite3
import XCTest
@testable import Diptych

/// The journal: what goes in, what a search finds, what purging leaves.
@MainActor
final class JournalTests: XCTestCase {

    private var folder: URL!
    private var journal: Journal!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        journal = Journal(url: folder.appendingPathComponent("journal.sqlite"))
    }

    override func tearDown() async throws {
        journal = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ kind: String, _ told: String, _ files: [Journal.File],
                       origin: Journal.Origin = .you, daysAgo: Double = 0) {
        journal.write(kind: kind, told: told, files: files, origin: origin,
                      at: Date().addingTimeInterval(-daysAgo * 86_400))
    }

    func testTheFileIsPrivate() throws {
        journal.flush()
        let mode = try FileManager.default.attributesOfItem(
            atPath: folder.appendingPathComponent("journal.sqlite").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testAWordOfTheSentenceOrOfAPathFindsTheEntry() {
        write("Move", "\"report.pdf\" was moved from ~/Downloads to ~/Taxes.",
              [Journal.File(before: "/Users/x/Downloads/report.pdf", after: "/Users/x/Taxes/report.pdf")])
        write("Copy", "\"cat.jpg\" was copied to ~/Pictures.",
              [Journal.File(before: nil, after: "/Users/x/Pictures/cat.jpg")])
        journal.flush()

        XCTAssertEqual(journal.search(.init(text: "taxes")).map(\.kind), ["Move"])
        XCTAssertEqual(journal.search(.init(text: "rep")).map(\.kind), ["Move"], "the start of a word")
        XCTAssertEqual(journal.search(.init(text: "cat.jpg")).map(\.kind), ["Copy"])
        XCTAssertEqual(journal.search(.init(text: "copied pictures")).map(\.kind), ["Copy"])
        XCTAssertEqual(journal.search(.init(text: "")).count, 2)
        XCTAssertTrue(journal.search(.init(text: "nowhere")).isEmpty)
    }

    func testWhatIsTypedIsNeverTakenAsSearchSyntax() {
        write("Rename", "\"a\" was renamed.", [Journal.File(before: "/a", after: "/b")])
        journal.flush()
        for text in ["\"", "a OR", "NOT", "a*", "(", "a:b", "-x", "^"] {
            _ = journal.search(.init(text: text))  // no crash, no error
        }
        XCTAssertEqual(Journal.match("tax \"2025\""), "\"tax\"* \"2025\"*")
        XCTAssertNil(Journal.match("   "))
    }

    func testNewestFirstAndFilteredByTimeKindAndWho() {
        write("Copy", "old", [Journal.File(before: nil, after: "/x/1")], daysAgo: 10)
        write("Move", "agent's", [Journal.File(before: "/x/2", after: "/y/2")], origin: .agent, daysAgo: 1)
        write("Copy", "new", [Journal.File(before: nil, after: "/x/3")])
        journal.flush()

        XCTAssertEqual(journal.search(.init()).map(\.told), ["new", "agent's", "old"])
        XCTAssertEqual(journal.search(.init(from: Date().addingTimeInterval(-2 * 86_400))).map(\.told),
                       ["new", "agent's"])
        XCTAssertEqual(journal.search(.init(kinds: ["Copy"])).map(\.told), ["new", "old"])
        XCTAssertEqual(journal.search(.init(origins: [.agent])).map(\.told), ["agent's"])
        XCTAssertEqual(journal.search(.init(limit: 1)).map(\.told), ["new"])
    }

    func testAFolderFindsWhatHappenedInsideItButNotInAFolderNamedAlike() {
        write("Move", "into taxes", [Journal.File(before: "/d/report.pdf", after: "/home/taxes/2025/report.pdf")])
        write("Copy", "next door", [Journal.File(before: nil, after: "/home/taxes-old/a.pdf")])
        write("Rename", "the folder itself", [Journal.File(before: "/home/taxes", after: "/home/taxes")])
        journal.flush()
        XCTAssertEqual(Set(journal.search(.init(folder: "/home/taxes")).map(\.told)),
                       ["into taxes", "the folder itself"])
        XCTAssertEqual(journal.search(.init(folder: "/home/taxes/")).count, 2, "a trailing slash")
    }

    func testFilesComeBackInOrderWithTheirBeforeAndAfter() {
        let files = [Journal.File(before: "/a/1", after: "/b/1"), Journal.File(before: nil, after: "/b/2"),
                     Journal.File(before: "/a/3", after: nil)]
        write("Move", "three", files)
        journal.flush()
        let entry = journal.search(.init())[0]
        XCTAssertEqual(entry.count, 3)
        XCTAssertEqual(entry.folder, "/b")
        XCTAssertEqual(journal.files(of: entry.id), files)
    }

    func testStatisticsAddUp() {
        write("Copy", "1", [Journal.File(before: nil, after: "/p/a"), Journal.File(before: nil, after: "/p/b")])
        write("Copy", "2", [Journal.File(before: nil, after: "/p/c")], origin: .agent)
        write("Move", "3", [Journal.File(before: "/q/d", after: "/r/d")], daysAgo: 3)
        journal.flush()

        let all = journal.stats()
        XCTAssertEqual(all.entries, 3)
        XCTAssertEqual(all.files, 4)
        XCTAssertEqual(all.byKind.map(\.name), ["Copy", "Move"])
        XCTAssertEqual(all.byKind.first?.files, 3)
        XCTAssertEqual(all.byOrigin.first { $0.name == "agent" }?.entries, 1)
        XCTAssertEqual(all.byDay.count, 2)
        XCTAssertEqual(all.folders.first?.name, "/p")

        XCTAssertEqual(journal.stats(from: Date().addingTimeInterval(-86_400)).entries, 2)
    }

    func testPurgingTakesWhatIsPastItsDaysWithItsFilesAndItsWords() {
        write("Copy", "ancient words", [Journal.File(before: nil, after: "/old/a")], daysAgo: 100)
        write("Copy", "recent", [Journal.File(before: nil, after: "/new/a")], daysAgo: 1)
        journal.flush()
        let oldID = journal.search(.init(text: "ancient"))[0].id

        journal.purge(keepingDays: 90)
        journal.flush()
        XCTAssertEqual(journal.search(.init()).map(\.told), ["recent"])
        XCTAssertTrue(journal.search(.init(text: "ancient")).isEmpty)
        XCTAssertTrue(journal.files(of: oldID).isEmpty)

        journal.purge(keepingDays: 0)  // kept until deleted
        journal.flush()
        XCTAssertEqual(journal.search(.init()).count, 1)
    }

    func testDeletingAboutAFolderAndDeletingEverything() {
        write("Copy", "private", [Journal.File(before: nil, after: "/secret/a")])
        write("Move", "out of it", [Journal.File(before: "/secret/b", after: "/open/b")])
        write("Copy", "elsewhere", [Journal.File(before: nil, after: "/open/c")])
        journal.flush()

        journal.delete(about: "/secret")
        journal.flush()
        XCTAssertEqual(journal.search(.init()).map(\.told), ["elsewhere"])

        journal.deleteAll()
        journal.flush()
        XCTAssertEqual(journal.stats().entries, 0)
    }

    func testWhoDidItIsCarriedByTheTask() async {
        XCTAssertEqual(Journal.origin, .you)
        await Journal.$origin.withValue(.shortcuts) {
            XCTAssertEqual(Journal.origin, .shortcuts)
        }
        XCTAssertEqual(Journal.origin, .you)
    }

    // MARK: - From the undo history

    func testAMoveIsReadFromTheStepThatUndoesIt() {
        // Undoing a move from /a/f to /b/f moves it from /b/f back to /a/f.
        let undo = FileHistory.Action.relocate([
            FileHistory.Relocation(from: URL(fileURLWithPath: "/b/f"), to: URL(fileURLWithPath: "/a/f"),
                                   identity: nil)])
        XCTAssertEqual(Journal.files(of: undo), [Journal.File(before: "/a/f", after: "/b/f")])
        XCTAssertEqual(Journal.reversed(Journal.files(of: undo)),
                       [Journal.File(before: "/b/f", after: "/a/f")])
    }

    func testACopyIsWhatUndoingItWouldTakeAway() {
        let undo = FileHistory.Action.trash([
            FileHistory.Removal(url: URL(fileURLWithPath: "/b/copy.txt"), identity: nil, modified: nil)])
        XCTAssertEqual(Journal.files(of: undo), [Journal.File(before: nil, after: "/b/copy.txt")])
    }

    func testAChangeInPlaceNamesEachFileOnce() {
        let url = URL(fileURLWithPath: "/a/photo.jpg")
        let undo = FileHistory.Action.several([
            .dates([FileHistory.DateChange(url: url, which: .modified, from: Date(), to: Date())]),
            .dates([FileHistory.DateChange(url: url, which: .created, from: Date(), to: Date())]),
        ])
        XCTAssertEqual(Journal.files(of: undo), [Journal.File(before: "/a/photo.jpg", after: "/a/photo.jpg")])
    }

    func testWhatTheUndoHistoryRecordsGoesIntoTheJournal() {
        let saved = ConfigStore.shared.configuration
        defer { ConfigStore.shared.configuration = saved }
        ConfigStore.shared.configuration.journalEnabled = true

        let marker = "journal-\(UUID().uuidString)"
        let history = FileHistory()
        history.recordRename(from: URL(fileURLWithPath: "/tmp/\(marker)-old"),
                             to: URL(fileURLWithPath: "/tmp/\(marker)-new"))
        Journal.shared.flush()
        let found = Journal.shared.search(.init(text: marker))
        XCTAssertEqual(found.map(\.kind), ["Rename"])
        XCTAssertEqual(found.first?.origin, .you)
        XCTAssertEqual(Journal.shared.files(of: found[0].id),
                       [Journal.File(before: "/tmp/\(marker)-old", after: "/tmp/\(marker)-new")])

        ConfigStore.shared.configuration.journalEnabled = false
        history.recordRename(from: URL(fileURLWithPath: "/tmp/\(marker)-x"),
                             to: URL(fileURLWithPath: "/tmp/\(marker)-y"))
        Journal.shared.flush()
        XCTAssertEqual(Journal.shared.search(.init(text: marker)).count, 1, "switched off: nothing")
    }

    func testTheTestRunNeverWritesThePersonsJournal() {
        XCTAssertNotEqual(Journal.shared.location, Journal.url)
    }

    // MARK: - Categories

    func testEachEntryKeepsItsCategoryAndIsFoundByIt() {
        journal.write(kind: "Copy", told: "a copy", files: [Journal.File(before: nil, after: "/x/1")],
                      origin: .you)
        journal.write(kind: "View", category: .navigation, told: "shown as icons", files: [], origin: .you)
        journal.write(kind: "Setting", category: .settings, told: "a setting", files: [], origin: .you)
        journal.flush()

        XCTAssertEqual(journal.search(.init()).map(\.category), [.settings, .navigation, .change])
        XCTAssertEqual(journal.search(.init(categories: [.navigation])).map(\.told), ["shown as icons"])
        XCTAssertEqual(journal.search(.init(categories: [.change, .settings])).count, 2)
        XCTAssertEqual(Set(journal.stats().byCategory.map(\.name)), ["change", "navigation", "settings"])
    }

    func testAJournalFromBeforeCategoriesGetsThemFromItsKinds() throws {
        let url = folder.appendingPathComponent("old.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        sqlite3_exec(db, """
            CREATE TABLE entries (id INTEGER PRIMARY KEY, time REAL NOT NULL, kind TEXT NOT NULL,
              origin TEXT NOT NULL, told TEXT NOT NULL, folder TEXT, count INTEGER NOT NULL,
              outcome TEXT NOT NULL);
            INSERT INTO entries(time, kind, origin, told, count, outcome) VALUES
              (1, 'Move', 'you', 'moved', 1, 'done'), (2, 'Quick Look', 'you', 'looked', 1, 'done'),
              (3, 'Select', 'you', 'selected', 1, 'done'), (4, 'Run', 'run', 'ran', 1, 'done');
            """, nil, nil, nil)
        sqlite3_close(db)

        let old = Journal(url: url)
        XCTAssertEqual(old.search(.init()).map(\.category), [.run, .attributes, .content, .change])
        old.write(kind: "Quit", category: .app, told: "quit", files: [], origin: .you)
        old.flush()
        XCTAssertEqual(old.search(.init(categories: [.app])).count, 1)
    }

    func testACategoryLeftOutIsNotRecorded() {
        let saved = ConfigStore.shared.configuration
        defer { ConfigStore.shared.configuration = saved }
        ConfigStore.shared.configuration.journalEnabled = true
        ConfigStore.shared.configuration.journalLeftOut = ["navigation"]

        let marker = "category-\(UUID().uuidString)"
        Journal.shared.record(kind: "View", category: .navigation, told: "\(marker) navigation")
        Journal.shared.record(kind: "Open Window", category: .window, told: "\(marker) window")
        Journal.shared.flush()
        XCTAssertEqual(Journal.shared.search(.init(text: marker)).map(\.category), [.window])
    }

    func testTheOldSwitchForWhatWasLookedAtLeavesOutContentsAndDetails() throws {
        let off = try JSONDecoder().decode(Configuration.self, from: Data(#"{"journalViewing": false}"#.utf8))
        XCTAssertEqual(Set(off.journalLeftOut), ["content", "attributes"])
        let on = try JSONDecoder().decode(Configuration.self, from: Data(#"{"journalViewing": true}"#.utf8))
        XCTAssertEqual(on.journalLeftOut, [])
        XCTAssertEqual(Configuration().journalLeftOut, [], "everything is recorded by default")
    }

    func testASettingChangedIsToldFromWhatToWhat() {
        var old = Configuration()
        old.journalKeepDays = 90
        var new = old
        new.journalKeepDays = 30
        new.journalLeftOut = ["window"]
        let differences = JournalActivity.differences(old, new)
        XCTAssertEqual(differences.map(\.0), ["journalKeepDays", "journalLeftOut"])
        XCTAssertEqual(differences.first?.1, "90")
        XCTAssertEqual(differences.first?.2, "30")
        XCTAssertTrue(JournalActivity.differences(old, old).isEmpty)
    }

    func testATableOfSettingsIsToldByTheEntryThatChanged() {
        var old = Configuration()
        old.columnWidths = ["name": 200, "size": 80]
        var new = old
        new.columnWidths["size"] = 95
        let differences = JournalActivity.differences(old, new)
        XCTAssertEqual(differences.map(\.0), ["columnWidths.size"])
        XCTAssertEqual(differences.first?.1, "80")
        XCTAssertEqual(differences.first?.2, "95")
    }

    func testDatesAsAnAgentWritesThem() {
        XCTAssertNotNil(DiptychCommands.journalDate("2026-11-01"))
        XCTAssertNotNil(DiptychCommands.journalDate("2026-11-01T14:30"))
        XCTAssertNotNil(DiptychCommands.journalDate("2026-11-01T14:30:00Z"))
        XCTAssertNil(DiptychCommands.journalDate("last week"))
        XCTAssertNil(DiptychCommands.journalDate(nil))
    }
}
