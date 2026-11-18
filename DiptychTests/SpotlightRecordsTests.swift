import CoreSpotlight
import UniformTypeIdentifiers
import XCTest
@testable import Diptych

/// Diptych's records in Spotlight: what a file's record says, and what is
/// never recorded.
@MainActor
final class SpotlightRecordsTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotlightRecordsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func snapshot(_ url: URL, tags: [String] = []) -> SpotlightRecords.Snapshot {
        SpotlightRecords.Snapshot(url: url, name: url.lastPathComponent, isDirectory: false,
                                  size: 1, modified: Date(), created: Date(), tags: tags)
    }

    func testAPictureSaysTheTownItWasTakenNearAndTheCamera() throws {
        let url = root.appendingPathComponent("photo.jpg")
        try MediaFileTests.picture(at: url, type: .jpeg, width: 40, height: 20, properties: [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2023:05:06 07:08:09",
                kCGImagePropertyExifLensModel: "Test Lens 50mm",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Testcam", kCGImagePropertyTIFFModel: "Testcam One",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 47.4979, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 19.0402, kCGImagePropertyGPSLongitudeRef: "E",
            ],
        ])
        let item = SpotlightRecords.item(for: snapshot(url, tags: ["Holiday"]))
        let set = item.attributeSet

        XCTAssertEqual(item.uniqueIdentifier, "file:" + url.path)
        XCTAssertEqual(item.domainIdentifier, SpotlightRecords.filesDomain)
        XCTAssertEqual(set.city, "Budapest")
        XCTAssertEqual(set.country, "Hungary")
        XCTAssertEqual(set.acquisitionModel, "Testcam One")
        XCTAssertEqual(set.lensModel, "Test Lens 50mm")
        XCTAssertEqual(set.latitude?.doubleValue ?? 0, 47.4979, accuracy: 0.0001)
        XCTAssertEqual(set.contentURL, url)
        let keywords = Set(set.keywords ?? [])
        XCTAssertTrue(keywords.isSuperset(of: ["Budapest", "Hungary", "HU", "Testcam One", "Holiday"]),
                      "\(keywords)")
        let said = try XCTUnwrap(set.contentDescription)
        XCTAssertTrue(said.hasPrefix("Taken near Budapest"), said)
        XCTAssertTrue(said.contains("Tagged Holiday"), said)
        XCTAssertGreaterThan(item.expirationDate, Date().addingTimeInterval(10 * 365 * 86_400),
                             "not Spotlight's 30 days")
    }

    func testAPlainFileSaysWhereItIsAndItsTags() throws {
        let url = root.appendingPathComponent("notes.txt")
        try Data("text".utf8).write(to: url)
        let set = SpotlightRecords.item(for: snapshot(url, tags: ["Red"])).attributeSet
        XCTAssertNil(set.city)
        XCTAssertEqual(set.keywords, ["Red"])
        XCTAssertEqual(set.title, "notes.txt")
        XCTAssertTrue(set.contentDescription?.contains("In ") == true)
    }

    func testAJournalEntryExpiresWhenTheJournalWouldPurgeIt() {
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = Journal.Entry(id: 42, time: time, kind: "Move", category: .change, origin: .agent,
                                  told: "\"a\" was moved to ~/b.", folder: "/Users/x/b", count: 1,
                                  outcome: "done")
        let item = SpotlightRecords.item(for: entry, keptDays: 90)
        XCTAssertEqual(item.uniqueIdentifier, "journal:42")
        XCTAssertEqual(item.domainIdentifier, SpotlightRecords.journalDomain)
        XCTAssertEqual(item.attributeSet.contentDescription, "\"a\" was moved to ~/b.")
        XCTAssertTrue(item.attributeSet.keywords?.contains("Agent (MCP)") == true)
        XCTAssertEqual(item.expirationDate, time.addingTimeInterval(90 * 86_400))
        XCTAssertGreaterThan(SpotlightRecords.item(for: entry, keptDays: 0).expirationDate,
                             time.addingTimeInterval(100 * 365 * 86_400))
    }

    func testNeverTheTrashOrDiptychsOwnFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertFalse(SpotlightRecords.isIndexable(home.appendingPathComponent(".Trash/x.jpg")))
        XCTAssertFalse(SpotlightRecords.isIndexable(home.appendingPathComponent(".diptych/journal.sqlite")))
        XCTAssertFalse(SpotlightRecords.isIndexable(URL(fileURLWithPath: "/Volumes/USB/.Trashes/501/x")))
        XCTAssertTrue(SpotlightRecords.isIndexable(home.appendingPathComponent("Pictures/x.jpg")))
    }

    func testWhatWasIndexedIsRememberedByFolder() {
        let store = IndexedFiles(url: root.appendingPathComponent("spotlight.sqlite"))
        let a = snapshot(root.appendingPathComponent("a.jpg"))
        let b = snapshot(root.appendingPathComponent("sub/b.jpg"))
        store.save([a, b])
        XCTAssertEqual(Set(store.indexed(in: root.path).keys), [a.url.path])
        XCTAssertEqual(store.indexed(in: root.path)[a.url.path]?.size, 1)
        store.remove([a.url.path])
        XCTAssertTrue(store.indexed(in: root.path).isEmpty)
        store.removeAll()
        XCTAssertTrue(store.indexed(in: root.appendingPathComponent("sub").path).isEmpty)
    }
}
