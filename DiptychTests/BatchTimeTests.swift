import XCTest
@testable import Diptych

/// The times a proposal's set_times row takes.
@MainActor
final class BatchTimeTests: XCTestCase {

    func testNowAndISODatesAreUnderstoodAndAnythingElseIsNot() {
        XCTAssertNotNil(BatchOperationRow.parseTime("now"))
        XCTAssertNotNil(BatchOperationRow.parseTime("2026-01-31T12:00:00"))
        XCTAssertNotNil(BatchOperationRow.parseTime("2026-01-31T12:00:00Z"))
        XCTAssertNotNil(BatchOperationRow.parseTime("2026-01-31"))
        XCTAssertNil(BatchOperationRow.parseTime("yesterday"))
    }

    func testAnISODateWithAZoneIsThatMoment() {
        XCTAssertEqual(BatchOperationRow.parseTime("1970-01-01T00:00:10Z"),
                       Date(timeIntervalSince1970: 10))
    }
}
