import XCTest
@testable import Diptych

/// The path bar's Tab, on a server: the server's own path, completed from the
/// listing kept for it here.
final class ServerPathCompletionTests: XCTestCase {

    private func shadow() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("completion-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("peter"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("paul"),
                                                withIntermediateDirectories: true)
        BrowserManifestStore.register(root: root, kind: "sftp")
        try BrowserManifestStore.write(BrowserManifest(source: "sftp", nodes: []), in: home)
        return root
    }

    func testAServerPathCompletesFromItsListedFolder() throws {
        let root = try shadow()
        XCTAssertEqual(PathCompletion.complete("/home/pe", base: "/", root: root.path), "/home/peter/")
        XCTAssertEqual(PathCompletion.complete("pe", base: "/home", root: root.path), "peter/")
        XCTAssertTrue(PathCompletion.exists("/home/paul", base: "/", root: root.path))
    }
}
