import XCTest
@testable import Diptych

/// The two switches for what a colour tag does to the listing.
final class TagColourSettingsTests: XCTestCase {

    func testBothAreOnByDefault() {
        let config = Configuration()
        XCTAssertTrue(config.tagColourRows)
        XCTAssertTrue(config.tagColourFolderIcons)
    }

    func testAConfigFromBeforeTheSwitchesKeepsBothOn() throws {
        let config = try JSONDecoder().decode(Configuration.self, from: Data("{}".utf8))
        XCTAssertTrue(config.tagColourRows)
        XCTAssertTrue(config.tagColourFolderIcons)
    }

    func testEachIsSavedOnItsOwn() throws {
        var config = Configuration()
        config.tagColourRows = false
        let back = try JSONDecoder().decode(Configuration.self,
                                            from: JSONEncoder().encode(config))
        XCTAssertFalse(back.tagColourRows)
        XCTAssertTrue(back.tagColourFolderIcons)

        config.tagColourRows = true
        config.tagColourFolderIcons = false
        let again = try JSONDecoder().decode(Configuration.self,
                                             from: JSONEncoder().encode(config))
        XCTAssertTrue(again.tagColourRows)
        XCTAssertFalse(again.tagColourFolderIcons)
    }
}
