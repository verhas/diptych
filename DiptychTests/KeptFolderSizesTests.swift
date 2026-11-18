import XCTest
@testable import Diptych

/// Folder totals kept in the cache: shown again by a later session, measured
/// again from where they were, and gone with the folder or with Clear.
final class KeptFolderSizesTests: XCTestCase {

    private var root: URL!
    private var cacheURL: URL!
    private let fm = FileManager.default

    override func setUp() async throws {
        let made = fm.temporaryDirectory.appendingPathComponent("KeptFolderSizesTests-\(UUID().uuidString)")
        try fm.createDirectory(at: made, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: realpath(made.path, nil).map { String(cString: $0) } ?? made.path)
        cacheURL = root.appendingPathComponent("cache.sqlite")
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: root)
    }

    private func file(_ path: String, _ bytes: Int) throws {
        let url = root.appendingPathComponent("tree").appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func folder(_ path: String) -> String {
        root.appendingPathComponent("tree").appendingPathComponent(path).path
    }

    /// A session of its own, on the same kept totals.
    private func session() -> DirectorySizes.Store {
        DirectorySizes.Store(database: LocalDatabase.cache(at: cacheURL))
    }

    /// Asked, worked out, and written.
    private func calculate(_ store: DirectorySizes.Store, _ paths: String...) async throws {
        store.calculate(paths.map(folder))
        let deadline = Date() + 10
        while store.isWorking {
            guard Date() < deadline else { return XCTFail("never finished") }
            try await Task.sleep(for: .milliseconds(10))
        }
        // Written with the publication that follows, a tenth of a second on.
        try await Task.sleep(for: .milliseconds(400))
    }

    private func tree() throws {
        try file("A/a", 100)
        try file("A/B/b", 200)
        try file("A/B/C/c", 300)
    }

    private func row(_ path: String) -> (size: Int64, measured: Double, complete: Bool)? {
        LocalDatabase.cache(at: cacheURL).access { connection in
            connection.rows("SELECT size, measured_at, complete FROM folder_size WHERE path = ?",
                            .text(folder(path))) { ($0.int(0) ?? -1, $0.real(1) ?? 0, $0.int(2) == 1) }
        }.first
    }

    func testATotalIsKeptWithWhenAndWhetherItWasDone() async throws {
        try tree()
        let before = Date().timeIntervalSince1970
        try await calculate(session(), "A")
        let a = try XCTUnwrap(row("A"))
        XCTAssertEqual(a.size, 600)
        XCTAssertTrue(a.complete)
        XCTAssertGreaterThanOrEqual(a.measured, before - 1)
        XCTAssertEqual(row("A/B/C")?.size, 300, "every folder under it is kept too")
        XCTAssertEqual(row("A/B/C")?.complete, true)
    }

    func testALaterSessionShowsWhatWasKept() async throws {
        try tree()
        try await calculate(session(), "A")
        let later = session()
        XCTAssertEqual(later.shown(folder("A")), .remembered(600, complete: true))
        XCTAssertEqual(later.shown(folder("A/B")), .remembered(500, complete: true))
        XCTAssertNotNil(later.measured(folder("A")))
        XCTAssertEqual(later.sizes([folder("A")]), [folder("A"): 600], "sorting uses it")
        XCTAssertEqual(later.sizes([folder("A")], since: Date() + 60), [:], "but not once too old")
        XCTAssertFalse(later.isEmpty)
    }

    func testAskingAgainMeasuresAgainFromWhatWasKept() async throws {
        try tree()
        try await calculate(session(), "A")
        try file("A/B/C/d", 50)
        let later = session()
        later.calculate([folder("A")])
        // Until it is read again, it is the old total, shown as about to change.
        if case .updating(let size)? = later.shown(folder("A")) { XCTAssertEqual(size, 600) }
        try await calculate(later, "A")
        XCTAssertEqual(later.shown(folder("A")), .done(650))
        XCTAssertEqual(row("A")?.size, 650, "and kept anew")
        XCTAssertEqual(row("A/B/C")?.size, 350)
    }

    func testAFolderThatWentIsForgottenWithAllUnderIt() async throws {
        try tree()
        try await calculate(session(), "A")
        try fm.removeItem(atPath: folder("A/B"))
        try await calculate(session(), "A")
        XCTAssertNil(row("A/B"))
        XCTAssertNil(row("A/B/C"), "what was under it too")
        XCTAssertEqual(row("A")?.size, 100)
        XCTAssertNil(session().shown(folder("A/B")))
    }

    func testClearForgetsWhatWasKept() async throws {
        try tree()
        let store = session()
        try await calculate(store, "A")
        store.clear()
        XCTAssertNil(row("A"))
        XCTAssertTrue(session().isEmpty)
        XCTAssertNil(session().shown(folder("A")))
    }

    func testPurgeTakesOnlyTheOldOnes() async throws {
        try tree()
        try await calculate(session(), "A")
        let store = session()
        store.purge(measuredBefore: Date().addingTimeInterval(-3600))
        XCTAssertNotNil(row("A"), "measured just now")
        store.purge(measuredBefore: Date().addingTimeInterval(60))
        XCTAssertNil(row("A"))
    }

    func testAKeptTotalLooksLikeOneOfThisSession() {
        XCTAssertEqual(DirectorySizes.Shown.remembered(2_000, complete: true).text,
                       ByteCountFormatter.string(fromByteCount: 2_000, countStyle: .file))
        XCTAssertEqual(CellView.colour(of: .remembered(1, complete: true)), .teal)
        XCTAssertEqual(CellView.colour(of: .remembered(1, complete: false)), .orange, "caught part way")
    }
}
