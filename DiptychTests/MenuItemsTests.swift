import XCTest
@testable import Diptych

/// Switching right-click menu entries on and off, and the presets.
final class MenuItemsTests: XCTestCase {

    func testEverythingIsOnByDefault() {
        let config = Configuration()
        XCTAssertTrue(config.hiddenMenuItems.isEmpty)
    }

    func testAPresetShowsItsSetAndHidesTheRest() {
        let dev = MenuPreset.developer
        // Hidden is exactly the complement of shown.
        XCTAssertEqual(dev.hidden, Set(MenuItem.allCases.map(\.id)).subtracting(dev.shown.map(\.id)))
        // Developer shows checksums; it does not show the image tools.
        XCTAssertTrue(dev.shown.contains(.checksum))
        XCTAssertFalse(dev.shown.contains(.image))
        XCTAssertTrue(dev.hidden.contains(MenuItem.image.id))
    }

    func testEverythingPresetHidesNothing() {
        XCTAssertTrue(MenuPreset.everything.hidden.isEmpty)
    }

    func testPresetsCoverEveryItem() {
        // Each preset's shown ∪ hidden is the whole set, so no item is orphaned.
        for preset in MenuPreset.all {
            let covered = Set(preset.shown.map(\.id)).union(preset.hidden)
            XCTAssertEqual(covered, Set(MenuItem.allCases.map(\.id)), "\(preset.name) misses an item")
        }
    }

    // The store's toggle/apply helpers are a thin wrapper over the config's
    // `hiddenMenuItems`; exercising that set directly keeps the real
    // ~/.diptych/config.json (which the shared store would persist to) untouched.
    func testHiddenSetDecidesWhatIsShown() {
        var config = Configuration()
        func shown(_ item: MenuItem) -> Bool { !config.hiddenMenuItems.contains(item.id) }

        config.hiddenMenuItems = MenuPreset.contentCreator.hidden
        XCTAssertTrue(shown(.image))
        XCTAssertFalse(shown(.splitJoin))

        config.hiddenMenuItems.remove(MenuItem.splitJoin.id)
        XCTAssertTrue(shown(.splitJoin))

        config.hiddenMenuItems = MenuPreset.everything.hidden
        XCTAssertTrue(MenuItem.allCases.allSatisfy(shown))
    }
}
