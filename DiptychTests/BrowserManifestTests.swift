import XCTest
@testable import Diptych

/// The manifest format: it round-trips, it keeps a value whose type a future
/// version adds; and the cache it is kept in.
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

    // MARK: - The store

    private func folder(_ name: String = "DiptychManifest-\(UUID().uuidString)") throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
            BrowserManifestStore.forget(under: dir)
        }
        return dir
    }

    private func sample() -> BrowserManifest.Node {
        var file = BrowserManifest.Node(id: "2024/a.pdf", kind: .file, name: "a.pdf")
        file.attributes = [
            BrowserManifest.Attribute.size: .size(2048),
            BrowserManifest.Attribute.mode: .mode(0o4755),
            BrowserManifest.Attribute.uid: .user(501),
            BrowserManifest.Attribute.gid: .user(20),
            BrowserManifest.Attribute.ownerName: .string("peter"),
            BrowserManifest.Attribute.groupName: .string("staff"),
            BrowserManifest.Attribute.modified: .date(1_000_000.123456),
            BrowserManifest.Attribute.created: .date(999_999.5),
            BrowserManifest.Attribute.checksum: .string("abc"),
            BrowserManifest.Attribute.localModified: .date(1_000_001.000001),
            BrowserManifest.Attribute.serverChanged: .bool(true),
        ]
        file.backing = .file("2024/a.pdf")
        return file
    }

    func testAListingRoundTripsThroughTheCache() throws {
        let root = try folder()
        let sub = root.appendingPathComponent("2024")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        BrowserManifestStore.register(root: root, kind: "archive", holder: root,
                                      originPath: "/x/p.zip", sha256: "f00")
        let link = BrowserManifest.Node(id: "latest", kind: .symlink, name: "latest",
                                        linkTarget: "2024/a.pdf", backing: .file("latest"))
        let dir = BrowserManifest.Node(id: "2024", kind: .directory, name: "2024")
        // In the order given, not sorted: a server's listing keeps its order.
        try BrowserManifestStore.write([(root, BrowserManifest(source: "archive", nodes: [link, dir])),
                                        (sub, BrowserManifest(source: "archive", nodes: [sample()]))])

        let top = try XCTUnwrap(BrowserManifestStore.read(in: root))
        XCTAssertEqual(top.nodes, [link, dir])
        XCTAssertEqual(top.source, "archive")
        XCTAssertEqual(top.origin["path"], "/x/p.zip")
        XCTAssertEqual(top.origin["sha256"], "f00")
        XCTAssertEqual(BrowserManifestStore.read(in: sub)?.nodes, [sample()], "every column comes back")
    }

    func testEitherSpellingOfAPathFindsTheListing() throws {
        // NSTemporaryDirectory is under /var, which is /private/var.
        let root = try folder()
        try BrowserManifestStore.write(BrowserManifest(source: "a", nodes: [sample()]), in: root)
        let other = root.path.hasPrefix("/private/") ? String(root.path.dropFirst("/private".count))
                                                     : "/private" + root.path
        XCTAssertEqual(BrowserManifestStore.read(in: URL(fileURLWithPath: other))?.nodes.count, 1)
    }

    func testAFolderNeverListedHasNoListing() throws {
        let root = try folder()
        BrowserManifestStore.register(root: root, kind: "sftp")
        let sub = root.appendingPathComponent("unlisted")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertTrue(BrowserManifestStore.isManaged(sub))
        XCTAssertNil(BrowserManifestStore.read(in: sub), "listed empty and never listed differ")
        try BrowserManifestStore.write(BrowserManifest(source: "sftp", nodes: []), in: sub)
        XCTAssertEqual(BrowserManifestStore.read(in: sub)?.nodes, [])
    }

    func testAnOrdinaryFolderIsNotManaged() throws {
        XCTAssertFalse(BrowserManifestStore.isManaged(try folder()))
    }

    func testAFolderMadeAgainUnderTheSameNameIsNotListed() throws {
        // Removed by anything -- Finder, rm -- and made again: the old row
        // must not describe the new folder.
        let root = try folder()
        BrowserManifestStore.register(root: root, kind: "sftp")
        let sub = root.appendingPathComponent("d")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try BrowserManifestStore.write(BrowserManifest(source: "sftp", nodes: [sample()]), in: sub)
        try FileManager.default.removeItem(at: sub)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertNil(BrowserManifestStore.read(in: sub))
    }

    func testWritingTheSameListingIsNoChange() throws {
        let root = try folder()
        let manifest = BrowserManifest(source: "sftp", nodes: [sample()])
        XCTAssertTrue(try BrowserManifestStore.write(manifest, in: root))
        XCTAssertFalse(try BrowserManifestStore.write(manifest, in: root))
        var changed = manifest
        changed.nodes[0].attributes[BrowserManifest.Attribute.size] = .size(1)
        XCTAssertTrue(try BrowserManifestStore.write(changed, in: root))
    }

    func testAChangeIsAnnouncedForItsFolder() throws {
        let root = try folder()
        let told = expectation(forNotification: BrowserManifestStore.changed, object: nil) { note in
            (note.userInfo?["path"] as? String) == BrowserManifestStore.canonical(root.path)
        }
        try BrowserManifestStore.write(BrowserManifest(source: "sftp", nodes: [sample()]), in: root)
        wait(for: [told], timeout: 2)
    }

    func testUpdateChangesOneNodeAndCanAddOne() throws {
        let root = try folder()
        let other = BrowserManifest.Node(id: "b", kind: .file, name: "b")
        try BrowserManifestStore.write(BrowserManifest(source: "sftp", nodes: [sample(), other]), in: root)

        XCTAssertTrue(BrowserManifestStore.update(in: root, name: "a.pdf") {
            $0.attributes[BrowserManifest.Attribute.serverChanged] = nil
        })
        let a = BrowserManifestStore.node(named: "a.pdf", in: root)
        XCTAssertNil(a?.attribute(BrowserManifest.Attribute.serverChanged))
        XCTAssertEqual(a?.attribute(BrowserManifest.Attribute.size)?.intValue, 2048, "the rest stays")

        XCTAssertFalse(BrowserManifestStore.update(in: root, name: "c") { _ in }, "no such child")
        XCTAssertTrue(BrowserManifestStore.update(in: root, name: "c",
                                                  creating: .init(id: "c", kind: .file, name: "c")) { _ in })
        XCTAssertEqual(BrowserManifestStore.read(in: root)?.nodes.map(\.name), ["a.pdf", "b", "c"],
                       "added at the end, the order kept")
    }

    func testForgettingATreeTakesItsListings() throws {
        let root = try folder()
        BrowserManifestStore.register(root: root, kind: "sftp")
        let sub = root.appendingPathComponent("d")
        let deeper = sub.appendingPathComponent("e")
        let sibling = root.appendingPathComponent("dd")
        for url in [deeper, sibling] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        for url in [root, sub, deeper, sibling] {
            try BrowserManifestStore.write(BrowserManifest(source: "sftp", nodes: []), in: url)
        }

        BrowserManifestStore.forget(under: sub)
        XCTAssertNil(BrowserManifestStore.read(in: sub))
        XCTAssertNil(BrowserManifestStore.read(in: deeper))
        XCTAssertNotNil(BrowserManifestStore.read(in: sibling), "a name that only starts the same stays")
        XCTAssertNotNil(BrowserManifestStore.read(in: root))

        BrowserManifestStore.forget(under: root)
        XCTAssertFalse(BrowserManifestStore.isManaged(root), "the source itself goes")
    }
}
