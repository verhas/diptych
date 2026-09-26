import XCTest
@testable import Diptych

/// What a double-click or Return does with a row -- walk into it, or hand it
/// to the app that owns it -- and the one exception among packages.
final class FileItemTests: XCTestCase {

    private func item(_ name: String, isDirectory: Bool = true,
                      isPackage: Bool = true) -> FileItem {
        FileItem(isParent: false, url: URL(fileURLWithPath: "/tmp/\(name)"), name: name,
                isDirectory: isDirectory, isPackage: isPackage, isSymlink: false,
                isExecutable: false, byteSize: 0, modified: .now)
    }

    func testAnApplicationIsEnterableUnlikeOtherPackages() {
        let app = item("Image Capture.app")
        XCTAssertTrue(app.isApplication)
        XCTAssertTrue(app.isEnterable, "an application is walked into, not launched, on its own")
    }

    func testTheExtensionMatchIsCaseInsensitive() {
        XCTAssertTrue(item("Weird.APP").isApplication)
    }

    /// A rename or an export can leave a folder merely *named* like an
    /// application without macOS treating it as one -- `isPackage` reflects
    /// what LaunchServices actually thinks, and that is what must gate this,
    /// not the extension by itself.
    func testANameEndingInAppIsNotEnoughWithoutBeingAPackage() {
        let notReally = item("Coincidence.app", isPackage: false)
        XCTAssertFalse(notReally.isApplication)
        XCTAssertTrue(notReally.isEnterable, "an ordinary folder, whatever it is named")
    }

    func testOtherPackagesStayNotEnterable() {
        let document = item("Chapter.rtfd")
        XCTAssertFalse(document.isApplication)
        XCTAssertFalse(document.isEnterable, "a document package still opens in its own app")
    }

    func testAnOrdinaryFolderIsStillEnterable() {
        let folder = item("Projects", isPackage: false)
        XCTAssertTrue(folder.isEnterable)
    }

    func testAnOrdinaryFileIsNotEnterable() {
        let file = item("notes.txt", isDirectory: false, isPackage: false)
        XCTAssertFalse(file.isApplication)
        XCTAssertFalse(file.isEnterable)
    }
}
