import XCTest
@testable import Diptych

/// What may be a sidebar favourite: a folder, as always, and now a disk image,
/// which mounts to a folder when it is opened.
@MainActor
final class FavouriteTests: XCTestCase {

    override func setUp() { LiveSettings.protect() }
    override func tearDown() { LiveSettings.putBack() }

    func testADiskImageIsEligibleButAPlainFileIsNot() {
        let model = AppModel()
        ConfigStore.shared.configuration.favourites = []

        let base = "/tmp/DiptychFavouriteTest"
        model.addFavourites([URL(fileURLWithPath: "\(base)/photos.dmg"),
                             URL(fileURLWithPath: "\(base)/disk.iso"),
                             URL(fileURLWithPath: "\(base)/notes.txt")])

        let paths = ConfigStore.shared.configuration.favourites
        XCTAssertTrue(paths.contains("\(base)/photos.dmg"), "a .dmg can be a favourite")
        XCTAssertTrue(paths.contains("\(base)/disk.iso"), "an .iso can be a favourite")
        XCTAssertFalse(paths.contains("\(base)/notes.txt"), "a plain file cannot")

        // It shows in the sidebar list as a favourite, named after the image.
        XCTAssertTrue(model.favourites.contains { $0.url.lastPathComponent == "photos.dmg" })
    }

    func testNoneOfTheDroppedItemsQualify() {
        let model = AppModel()
        ConfigStore.shared.configuration.favourites = []
        model.addFavourites([URL(fileURLWithPath: "/tmp/DiptychFavouriteTest/a.txt")])
        XCTAssertTrue(ConfigStore.shared.configuration.favourites.isEmpty)
    }
}
