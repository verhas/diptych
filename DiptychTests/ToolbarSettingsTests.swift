import XCTest
@testable import Diptych

/// Which toolbar buttons are shown, where, and in what order.
@MainActor
final class ToolbarSettingsTests: XCTestCase {

    private var original: [ToolbarSlot] = []

    override func setUp() {
        original = ConfigStore.shared.configuration.toolbar
    }

    override func tearDown() {
        ConfigStore.shared.configuration.toolbar = original
    }

    func testTheDefaultsAreASmallSetOfEverythingAvailable() {
        // Everything is offered; only a few are on. Twenty-six buttons is not
        // a toolbar, it is a wall.
        ConfigStore.shared.configuration.toolbar = Configuration.defaultToolbar
        let shown = ToolbarSide.allCases
            .flatMap { ConfigStore.shared.configuration.toolbarButtons(on: $0) }

        XCTAssertEqual(ConfigStore.shared.configuration.toolbarSlots.count,
                       ToolbarButton.allCases.count, "all of them are configurable")
        XCTAssertLessThan(shown.count, ToolbarButton.allCases.count / 2,
                          "and most start switched off")
        XCTAssertEqual(ConfigStore.shared.configuration.toolbarButtons(on: .left),
                       [.singlePane, .refresh, .swapPanes, .sameFolder, .hiddenFiles])
        XCTAssertEqual(ConfigStore.shared.configuration.toolbarButtons(on: .right),
                       [.sendWork, .getLatest])
    }

    func testEveryButtonHasAnIconAndAnExplanation() {
        // A toolbar is read at a glance, so a missing or duplicated glyph is a
        // real defect rather than a cosmetic one.
        var symbols: Set<String> = []
        for button in ToolbarButton.allCases {
            XCTAssertFalse(button.title.isEmpty, "\(button)")
            XCTAssertFalse(button.explanation.isEmpty, "\(button)")
            XCTAssertNotNil(NSImage(systemSymbolName: button.symbol,
                                    accessibilityDescription: nil),
                            "\(button) has no icon named \(button.symbol)")
            XCTAssertTrue(symbols.insert(button.symbol).inserted,
                          "\(button) shares its icon with another button")
        }
    }

    func testAButtonAddedInALaterVersionIsAppendedRatherThanLost() {
        // A config written by an older build knows nothing about a new button.
        // Without repair it would be silently missing, which reads as the
        // feature not existing.
        ConfigStore.shared.configuration.toolbar = [
            ToolbarSlot(button: .refresh, isShown: true, side: .left),
        ]
        let slots = ConfigStore.shared.configuration.toolbarSlots

        XCTAssertEqual(slots.count, ToolbarButton.allCases.count)
        XCTAssertEqual(slots.first?.button, .refresh, "and what was saved keeps its place")
        XCTAssertTrue(slots.contains { $0.button == .sendWork })
    }

    func testHidingBothOfASideLeavesItEmpty() {
        for button in ToolbarButton.allCases {
            ConfigStore.shared.setToolbar(button, shown: false)
        }
        for side in ToolbarSide.allCases {
            XCTAssertTrue(ConfigStore.shared.configuration.toolbarButtons(on: side).isEmpty)
        }
    }

    func testMovingAButtonToAnotherSideKeepsItShown() {
        ConfigStore.shared.configuration.toolbar = Configuration.defaultToolbar
        ConfigStore.shared.setToolbar(.refresh, side: .right)

        XCTAssertFalse(ConfigStore.shared.configuration.toolbarButtons(on: .left)
            .contains(.refresh))
        XCTAssertTrue(ConfigStore.shared.configuration.toolbarButtons(on: .right)
            .contains(.refresh))
    }

    func testOrderWithinASideFollowsTheOneList() {
        ConfigStore.shared.configuration.toolbar = Configuration.defaultToolbar
        // Move Refresh (index 1) to the front.
        ConfigStore.shared.moveToolbar(from: IndexSet(integer: 1), to: 0)

        XCTAssertEqual(ConfigStore.shared.configuration.toolbarButtons(on: .left).first,
                       .refresh)
    }

    func testTheGitButtonsKnowTheyNeedARepository() {
        // They are left out rather than greyed out: a permanently disabled
        // button in an untracked folder teaches nobody anything.
        XCTAssertTrue(ToolbarButton.sendWork.needsRepository)
        XCTAssertTrue(ToolbarButton.getLatest.needsRepository)
        XCTAssertFalse(ToolbarButton.refresh.needsRepository)
    }

    func testAnArrangementSurvivesBeingSavedAndRead() throws {
        ConfigStore.shared.setToolbar(.swapPanes, shown: false)
        ConfigStore.shared.setToolbar(.hiddenFiles, side: .middle)

        let data = try JSONEncoder().encode(ConfigStore.shared.configuration)
        let read = try JSONDecoder().decode(Configuration.self, from: data)

        XCTAssertFalse(read.toolbarButtons(on: .left).contains(.swapPanes))
        XCTAssertTrue(read.toolbarButtons(on: .middle).contains(.hiddenFiles))
    }
}
