import XCTest
@testable import Diptych

/// The pane font and its zoom commands.
@MainActor
final class PaneFontTests: XCTestCase {

    private var original = Configuration()

    override func setUp() {
        original = ConfigStore.shared.configuration
    }

    override func tearDown() {
        ConfigStore.shared.configuration = original
    }

    func testZoomingStopsAtTheEnds() {
        // Without a clamp, holding the shortcut walks the size to something no
        // pane can show and there is no way back except editing config.json.
        PaneFont.set(Configuration.fontSizes.upperBound)
        PaneFont.zoom(by: 5)
        XCTAssertEqual(ConfigStore.shared.configuration.fontSize,
                       Configuration.fontSizes.upperBound)

        PaneFont.set(Configuration.fontSizes.lowerBound)
        PaneFont.zoom(by: -5)
        XCTAssertEqual(ConfigStore.shared.configuration.fontSize,
                       Configuration.fontSizes.lowerBound)
    }

    func testZoomingStepsAndResets() {
        PaneFont.set(11)
        PaneFont.zoom(by: 1)
        XCTAssertEqual(ConfigStore.shared.configuration.fontSize, 12)
        PaneFont.zoom(by: -1)
        XCTAssertEqual(ConfigStore.shared.configuration.fontSize, 11)

        PaneFont.set(20)
        PaneFont.reset()
        XCTAssertEqual(ConfigStore.shared.configuration.fontSize,
                       Configuration.defaultFontSize)
    }

    func testAHandEditedSizeIsClampedOnTheWayIn() throws {
        // config.json is meant to be editable by hand, so a nonsense value must
        // not be able to render the app unusable.
        for written in [0.0, -3, 4000] {
            let json = Data(#"{"fontSize": \#(written)}"#.utf8)
            let decoded = try JSONDecoder().decode(Configuration.self, from: json)
            XCTAssertTrue(Configuration.fontSizes.contains(decoded.fontSize),
                          "\(written) decoded to \(decoded.fontSize)")
        }
    }

    func testAMissingFontFallsBackToTheSystemOne() {
        // A config carried to another Mac can name a font that is not installed.
        ConfigStore.shared.configuration.fontName = "No Such Font At All"
        XCTAssertNil(PaneFont.name)

        ConfigStore.shared.configuration.fontName = ""
        XCTAssertNil(PaneFont.name, "empty means the system font")
    }

    func testOnlyInstalledFamiliesAreOffered() {
        for name in PaneFont.availableNames {
            XCTAssertNotNil(NSFont(name: name, size: 12), "\(name) is not installed")
        }
    }

    func testRowsAndIconsGrowWithTheText() {
        // The measured failure this exists for: SwiftUI keeps every row at 24
        // points whatever the content, so the height has to be computed and
        // pushed to AppKit -- and it has to leave room for the icon.
        PaneFont.set(11)
        let small = (row: PaneFont.rowHeight, icon: PaneFont.iconSize)
        PaneFont.set(22)
        let large = (row: PaneFont.rowHeight, icon: PaneFont.iconSize)

        XCTAssertGreaterThan(large.row, small.row)
        XCTAssertGreaterThan(large.icon, small.icon)
        XCTAssertGreaterThan(small.row, small.icon, "a row must fit its icon")
        XCTAssertGreaterThan(large.row, large.icon)
    }
}
