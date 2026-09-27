import XCTest
@testable import Diptych

/// The one piece of `UpdateChecker` that is pure enough to test directly:
/// deciding whether a version string from GitHub is actually newer than
/// this build's own, numerically rather than as strings -- "1.3.10" reads as
/// *older* than "1.3.9" by string comparison alone.
@MainActor
final class UpdateCheckerTests: XCTestCase {

    func testAHigherPatchIsNewer() {
        XCTAssertTrue(UpdateChecker.isNewer("1.3.3", than: "1.3.2"))
        XCTAssertFalse(UpdateChecker.isNewer("1.3.2", than: "1.3.3"))
    }

    func testEqualVersionsAreNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("1.3.2", than: "1.3.2"))
    }

    func testDoubleDigitsCompareNumericallyNotLexically() {
        XCTAssertTrue(UpdateChecker.isNewer("1.3.10", than: "1.3.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.3.9", than: "1.3.10"))
    }

    func testAHigherMinorOutranksALowerPatch() {
        XCTAssertTrue(UpdateChecker.isNewer("1.4.0", than: "1.3.99"))
    }

    func testAMissingComponentCountsAsZero() {
        XCTAssertTrue(UpdateChecker.isNewer("2.0", than: "1.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.9", than: "1.9.1"))
    }
}
