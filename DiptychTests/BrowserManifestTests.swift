import XCTest
@testable import Diptych

/// The manifest format: it round-trips, it keeps a value whose type a future
/// version adds, and the __（n)DIPTYCH.json naming escalates past a clash.
final class BrowserManifestTests: XCTestCase {

    private func roundTrip(_ manifest: BrowserManifest) throws -> BrowserManifest {
        let data = try JSONEncoder().encode(manifest)
        return try JSONDecoder().decode(BrowserManifest.self, from: data)
    }

    func testAListingRoundTrips() throws {
        var file = BrowserManifest.Node(id: "2024/a.pdf", kind: .file, name: "a.pdf")
        file.attributes = [
            BrowserManifest.Attribute.size: .size(2048),
            BrowserManifest.Attribute.mode: .mode(0o644),
            BrowserManifest.Attribute.uid: .user(501),
            BrowserManifest.Attribute.modified: .date(Date(timeIntervalSince1970: 1_000_000)),
        ]
        file.backing = .file("store/7/a.pdf")
        let link = BrowserManifest.Node(id: "latest", kind: .symlink, name: "latest",
                                        linkTarget: "2024/a.pdf")
        var manifest = BrowserManifest(source: "archive", nodes: [file, link])
        manifest.origin = ["path": "/x/p.zip", "sha256": "abc"]

        let back = try roundTrip(manifest)
        XCTAssertEqual(back, manifest)
        XCTAssertEqual(back.nodes[0].backing, .file("store/7/a.pdf"))
        XCTAssertEqual(back.nodes[0].attribute(BrowserManifest.Attribute.size)?.intValue, 2048)
        XCTAssertEqual(back.nodes[1].linkTarget, "2024/a.pdf")
        XCTAssertFalse(back.capabilities.writable)
    }

    func testAnUnknownAttributeTypeSurvives() throws {
        // As if a later version wrote a type this one does not know.
        let json = """
        {"schema":1,"source":"process","nodes":[{"id":"42","kind":"other","name":"loginwindow",
        "attributes":{"cpu":{"t":"percent","v":"12.5"}},"backing":{"t":"none"}}]}
        """
        let manifest = try JSONDecoder().decode(BrowserManifest.self, from: Data(json.utf8))
        guard case .unknown(let type, let raw) = manifest.nodes[0].attributes["cpu"] else {
            return XCTFail("the unknown value was not kept")
        }
        XCTAssertEqual(type, "percent")
        XCTAssertEqual(raw, "12.5")
        // And it is written back unchanged.
        let again = try JSONDecoder().decode(BrowserManifest.self,
                                             from: try JSONEncoder().encode(manifest))
        XCTAssertEqual(again.nodes[0].attributes["cpu"], manifest.nodes[0].attributes["cpu"])
    }

    func testTheManifestNameEscalatesPastAClash() {
        XCTAssertEqual(BrowserManifestStore.name(0), "__DIPTYCH.json")
        XCTAssertEqual(BrowserManifestStore.name(2), "__2DIPTYCH.json")
        XCTAssertEqual(BrowserManifestStore.number(of: "__DIPTYCH.json"), 0)
        XCTAssertEqual(BrowserManifestStore.number(of: "__3DIPTYCH.json"), 3)
        XCTAssertNil(BrowserManifestStore.number(of: "notes.txt"))

        XCTAssertEqual(BrowserManifestStore.chooseName(avoiding: []), "__DIPTYCH.json")
        XCTAssertEqual(BrowserManifestStore.chooseName(avoiding: ["__DIPTYCH.json"]), "__1DIPTYCH.json")
        XCTAssertEqual(BrowserManifestStore.chooseName(avoiding: ["__DIPTYCH.json", "__1DIPTYCH.json"]),
                       "__2DIPTYCH.json")
    }

    func testTheReaderTakesTheLargestNumbered() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychManifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A shadowed base and the real escalated one.
        try BrowserManifestStore.write(BrowserManifest(source: "a", nodes: []),
                                       named: "__DIPTYCH.json", in: dir)
        try BrowserManifestStore.write(
            BrowserManifest(source: "b", nodes: [.init(id: "x", kind: .file, name: "x")]),
            named: "__1DIPTYCH.json", in: dir)
        XCTAssertEqual(BrowserManifestStore.read(in: dir)?.source, "b")
        XCTAssertEqual(BrowserManifestStore.read(in: dir)?.nodes.count, 1)
    }
}
