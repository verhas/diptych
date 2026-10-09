import XCTest
@testable import Diptych

/// Saved flat view expressions: a JSON file each, older versions kept in it,
/// and Undo putting the one before back.
@MainActor
final class FlatFilterStoreTests: XCTestCase {

    private var folder: URL!
    private var store: FlatFilterStore!

    override func setUp() async throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychFilters-\(UUID().uuidString)")
        store = FlatFilterStore(directory: folder)
        FileHistory.shared.forgetEverything()
    }

    override func tearDown() async throws {
        FileHistory.shared.forgetEverything()
        try? FileManager.default.removeItem(at: folder)
    }

    func testSavingKeepsTheOlderVersions() throws {
        XCTAssertNil(try store.save("name = \"*.png\"", as: "Images",
                                    at: Date(timeIntervalSince1970: 1)))
        XCTAssertNotNil(try store.save("name = \"*.jpg\"", as: "images",
                                       at: Date(timeIntervalSince1970: 2)))
        let saved = try XCTUnwrap(store.saved("IMAGES"))
        XCTAssertEqual(saved.name, "Images", "the name as first saved")
        XCTAssertEqual(saved.expression, "name = \"*.jpg\"")
        XCTAssertEqual(saved.history.map(\.expression), ["name = \"*.png\""])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path),
                       ["Images.json"])
        XCTAssertEqual(store.expressions(), ["images": "name = \"*.jpg\""])
    }

    func testAFileEditedByHandCounts() throws {
        try store.save("file", as: "f")
        var saved = try XCTUnwrap(store.saved("f"))
        saved.expression = "directory"
        try FlatFilterStore.encode(saved).write(to: store.file(for: "f"))
        store.forget()
        XCTAssertEqual(store.saved("f")?.expression, "directory")
    }

    func testUndoPutsTheVersionBeforeBack() async throws {
        let url = store.file(for: "big")
        try store.save("size > 1MB", as: "big")
        let before = try store.save("size > 1GB", as: "big")
        FileHistory.shared.recordSavedExpression("big", at: url, before: before)
        XCTAssertEqual(FileHistory.shared.undoName, "Save Expression")

        let undone = await FileHistory.shared.perform(.undo) { _ in true }
        XCTAssertTrue(undone.failures.isEmpty, "\(undone.failures)")
        store.forget()
        XCTAssertEqual(store.saved("big")?.expression, "size > 1MB")

        _ = await FileHistory.shared.perform(.redo) { _ in true }
        store.forget()
        XCTAssertEqual(store.saved("big")?.expression, "size > 1GB")
    }

    func testUndoingTheFirstSaveRemovesIt() async throws {
        let url = store.file(for: "new")
        let before = try store.save("file", as: "new")
        FileHistory.shared.recordSavedExpression("new", at: url, before: before)
        _ = await FileHistory.shared.perform(.undo) { _ in true }
        store.forget()
        XCTAssertNil(store.saved("new"))
    }

    func testNames() {
        XCTAssertNil(FlatFilterStore.problem(with: "images_2-big"))
        XCTAssertNotNil(FlatFilterStore.problem(with: "2images"))
        XCTAssertNotNil(FlatFilterStore.problem(with: "my images"))
        XCTAssertNotNil(FlatFilterStore.problem(with: "Size"), "a keyword")
        XCTAssertNotNil(FlatFilterStore.problem(with: "MiB"), "a unit")
        XCTAssertNotNil(FlatFilterStore.problem(with: ""))
    }

    // MARK: - One that others use, gone

    func testAMissingOneIsSaidAsMissing() {
        guard case .failure(let direct) = FlatQuery.parse(
            "photos", saved: ["photos": "images and size > 1MB"]) else { return XCTFail() }
        XCTAssertEqual(direct.message,
                       "\u{201C}images\u{201D} is no longer saved, and \u{201C}photos\u{201D} uses it")
        XCTAssertEqual(direct.range, NSRange(location: 0, length: 6), "at what was written")
        XCTAssertEqual(direct.missing, "images")

        guard case .failure(let chain) = FlatQuery.parse(
            "file and Big", saved: ["big": "photos and size > 1GB",
                                    "photos": "jpegs or name = \"*.png\""]) else { return XCTFail() }
        XCTAssertEqual(chain.message, "\u{201C}jpegs\u{201D} is no longer saved, and "
                       + "\u{201C}photos\u{201D} uses it, which \u{201C}Big\u{201D} uses")
        XCTAssertEqual(chain.range, NSRange(location: 9, length: 3))

        guard case .failure(let typo) = FlatQuery.parse("imagez", saved: [:]) else {
            return XCTFail()
        }
        XCTAssertNil(typo.missing, "typed, not saved: a word that is not a test")
    }

    func testWhoUsesWhat() throws {
        try store.save("name = \"*.jpg\"", as: "jpegs")
        try store.save("jpegs or name = \"*.png\"", as: "images")
        try store.save("Images and size > 1MB", as: "photos")
        try store.save("file", as: "files")
        XCTAssertEqual(store.users(of: "JPEGS"), ["images", "photos"], "through another too")
        XCTAssertEqual(store.users(of: "files"), [])
    }

    func testLosingOneThatOthersUseIsSaid() throws {
        try store.save("name = \"*.jpg\"", as: "jpegs")
        try store.save("jpegs and size > 1MB", as: "photos")
        try store.save("file", as: "files")
        XCTAssertEqual(store.expressions().count, 3)

        let told = expectation(forNotification: FlatFilterStore.lost, object: nil) { note in
            note.userInfo?["gone"] as? [String] == ["jpegs"]
                && note.userInfo?["broken"] as? [String] == ["photos"]
        }
        try FileManager.default.removeItem(at: store.file(for: "jpegs"))
        store.forget()
        XCTAssertEqual(store.expressions().count, 2)
        wait(for: [told], timeout: 2)
        XCTAssertEqual(FlatFilterStore.broken(["a": .init(name: "a", expression: "b2",
                                                          saved: Date())]), ["a"])
    }

    func testTheWatchNoticesADeletionByItself() throws {
        try store.save("name = \"*.jpg\"", as: "jpegs")
        try store.save("jpegs and size > 1MB", as: "photos")
        store.watch()
        _ = store.expressions()
        let told = expectation(forNotification: FlatFilterStore.lost, object: nil)
        // Past the second the store trusts what it read.
        Thread.sleep(forTimeInterval: 1.1)
        try FileManager.default.removeItem(at: store.file(for: "jpegs"))
        wait(for: [told], timeout: 3)
    }

    func testLosingOneNobodyUsesIsNotSaid() throws {
        try store.save("file", as: "files")
        _ = store.expressions()
        let told = expectation(forNotification: FlatFilterStore.lost, object: nil)
        told.isInverted = true
        try FileManager.default.removeItem(at: store.file(for: "files"))
        store.forget()
        _ = store.expressions()
        wait(for: [told], timeout: 0.5)
    }

    func testTheMessages() {
        XCTAssertEqual(AppModel.lostMessage(gone: ["jpegs"], broken: ["photos"]),
                       "\u{201C}jpegs\u{201D} is no longer saved, so \u{201C}photos\u{201D}, which "
                       + "uses it, does not work until it is back \u{2014} Undo, or the Trash, "
                       + "may have it")
        XCTAssertEqual(AppModel.quotedList(["a", "b", "c"]),
                       "\u{201C}a\u{201D}, \u{201C}b\u{201D} and \u{201C}c\u{201D}")
    }

    // MARK: - Expand

    func testExpandingANameGivesItsExpression() {
        let saved = ["images": "name = \"*.jpg\" or name = \"*.png\"",
                     "big": "size > 1MB",
                     "wrapped": "(file and big)",
                     "pair": "(file) and (big)"]
        XCTAssertEqual(FlatQuery.expansion(of: "Images", saved: saved),
                       "(name = \"*.jpg\" or name = \"*.png\")", "joined: in parentheses")
        XCTAssertEqual(FlatQuery.expansion(of: " big ", saved: saved), "size > 1MB",
                       "one test needs none")
        XCTAssertEqual(FlatQuery.expansion(of: "wrapped", saved: saved), "(file and big)",
                       "already in them")
        XCTAssertEqual(FlatQuery.expansion(of: "pair", saved: saved), "((file) and (big))",
                       "outer parentheses that are not one pair")
        XCTAssertNil(FlatQuery.expansion(of: "size", saved: saved))
        XCTAssertNil(FlatQuery.expansion(of: "images and big", saved: saved))
    }
}
