import XCTest
@testable import Diptych

/// The folders the path bar offers as links while Option is held.
final class PathCrumbsTests: XCTestCase {

    func testEveryFolderFromTheRootDown() {
        let folders = PathCrumbs.folders(of: URL(fileURLWithPath: "/Users/verhasp/github"))
        XCTAssertEqual(folders.map(\.path), ["/", "/Users", "/Users/verhasp", "/Users/verhasp/github"])
    }

    func testTheRootIsOnlyItself() {
        XCTAssertEqual(PathCrumbs.folders(of: URL(fileURLWithPath: "/")).map(\.path), ["/"])
    }

    /// Not shortened to /var: that is a link, and the pane is in /private/var.
    func testThePathIsKeptAsItIs() {
        let folders = PathCrumbs.folders(of: URL(fileURLWithPath: "/private/var/folders"))
        XCTAssertEqual(folders.map(\.path), ["/", "/private", "/private/var", "/private/var/folders"])
    }

    func testATrailingSlashMakesNoExtraStep() {
        let folders = PathCrumbs.folders(of: URL(fileURLWithPath: "/Users/", isDirectory: true))
        XCTAssertEqual(folders.map(\.path), ["/", "/Users"])
    }
}
