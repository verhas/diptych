import XCTest
@testable import Diptych

/// Single-pane mode hides the other pane, and nothing two-pane may reach into
/// it: no copy or move to it, and `otherPaneFolder` -- what every "to the other
/// pane" command keys its enablement off -- goes away.
@MainActor
final class SinglePaneTests: XCTestCase {

    override func setUp() { LiveSettings.protect() }
    override func tearDown() { LiveSettings.putBack() }

    func testOtherPaneFolderAndVisibilityTrackSinglePane() {
        let model = AppModel()

        model.isSinglePane = false
        XCTAssertTrue(model.twoPanesVisible)
        XCTAssertNotNil(model.otherPaneFolder, "with both panes shown there is an other pane")

        model.isSinglePane = true
        XCTAssertFalse(model.twoPanesVisible)
        XCTAssertNil(model.otherPaneFolder, "the hidden pane is not a target in single-pane mode")
    }
}
