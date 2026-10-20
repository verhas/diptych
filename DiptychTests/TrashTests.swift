import XCTest
@testable import Diptych

/// The sidebar's Open Trash and the Trash listing's Original Location column:
/// where a volume's Trash is, what counts as a Trash folder, and Diptych's
/// record of what it moved there.
final class TrashTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychTrash-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    // MARK: - Where the Trash is

    func testTheStartupVolumeUsesTheHomeTrash() {
        XCTAssertEqual(Trash.url(forVolumeAt: URL(fileURLWithPath: "/")).path, Trash.home.path)
    }

    func testAnotherVolumeUsesItsOwnTrashesByUID() {
        let mount = URL(fileURLWithPath: "/Volumes/BACKUP")
        XCTAssertEqual(Trash.url(forVolumeAt: mount).path,
                       "/Volumes/BACKUP/.Trashes/\(getuid())")
    }

    // MARK: - What is a Trash folder

    func testIsTrashRecognisesHomeAndVolumeTrashes() {
        XCTAssertTrue(Trash.isTrash(Trash.home))
        XCTAssertTrue(Trash.isTrash(URL(fileURLWithPath: "/Volumes/BACKUP/.Trashes/501")))
        XCTAssertFalse(Trash.isTrash(URL(fileURLWithPath: "/Volumes/BACKUP/.Trashes")))
        XCTAssertFalse(Trash.isTrash(URL(fileURLWithPath: "/Volumes/BACKUP/.Trashes/notauid")))
        XCTAssertFalse(Trash.isTrash(URL(fileURLWithPath: "/Users/someone/Documents")))
    }

    // MARK: - Diptych's record of originals

    @MainActor
    func testRecordAndLookUpAnOriginalLocation() throws {
        let store = root.appendingPathComponent("origins.json")
        let originals = TrashOriginals(store: store)

        // The trashed file has to exist, since loading forgets ones that are gone.
        let trashed = root.appendingPathComponent("note.txt")
        try Data("x".utf8).write(to: trashed)
        let original = URL(fileURLWithPath: "/Users/me/Desktop/note.txt")

        originals.record([(original: original, trashed: trashed)])
        XCTAssertEqual(originals.original(of: trashed), original.path)
        XCTAssertNil(originals.original(of: root.appendingPathComponent("other.txt")))
    }

    @MainActor
    func testOriginalsPersistAndForgetWhatIsGone() throws {
        let store = root.appendingPathComponent("origins.json")
        let present = root.appendingPathComponent("present.txt")
        try Data("x".utf8).write(to: present)
        let gone = root.appendingPathComponent("gone.txt")   // never created

        TrashOriginals(store: store).record([
            (original: URL(fileURLWithPath: "/a/present.txt"), trashed: present),
            (original: URL(fileURLWithPath: "/a/gone.txt"), trashed: gone),
        ])

        // A fresh instance reads the file back, keeping the present one and
        // forgetting the one whose trashed file is not there.
        let reloaded = TrashOriginals(store: store)
        XCTAssertEqual(reloaded.original(of: present), "/a/present.txt")
        XCTAssertNil(reloaded.original(of: gone))
    }
}
