import Observation
import XCTest
@testable import Diptych

/// The settings tell what reads them about a change only when there is one.
/// Writing them unchanged -- as the column widths were, on every relayout --
/// made the menus rebuild several times a second while one was open.
@MainActor
final class ConfigStoreObservationTests: XCTestCase {

    private func changes(_ write: () -> Void) -> Bool {
        final class Flag: @unchecked Sendable { var raised = false }
        let flag = Flag()
        withObservationTracking { _ = ConfigStore.shared.configuration } onChange: { flag.raised = true }
        write()
        return flag.raised
    }

    func testTheSameSettingsWrittenAgainAreNoChange() {
        let saved = ConfigStore.shared.configuration
        defer { ConfigStore.shared.configuration = saved }

        let widths = ConfigStore.shared.configuration.columnWidths
        XCTAssertFalse(changes { ConfigStore.shared.configuration.columnWidths = widths })
        XCTAssertFalse(changes { ConfigStore.shared.configuration = ConfigStore.shared.configuration })
    }

    func testARealChangeIsOne() {
        let saved = ConfigStore.shared.configuration
        defer { ConfigStore.shared.configuration = saved }

        var widths = ConfigStore.shared.configuration.columnWidths
        widths["name"] = (widths["name"] ?? 200) + 1
        XCTAssertTrue(changes { ConfigStore.shared.configuration.columnWidths = widths })
    }
}
