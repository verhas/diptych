import XCTest
@testable import Diptych

/// The `$…` placeholders the Rename Many replacement understands on top of the
/// regex's own `$1`.
final class RenamePlaceholdersTests: XCTestCase {

    func testSerialOwnerAndGroup() {
        var values = RenamePlaceholders.Values()
        values.serial = 3
        values.owner = "peter"
        values.group = "staff"
        XCTAssertEqual(RenamePlaceholders.expand("$n-$owner-$group", with: values),
                       "3-peter-staff")
    }

    func testRegexBackreferencesAreLeftForTheEngine() {
        var values = RenamePlaceholders.Values()
        values.serial = 1
        XCTAssertEqual(RenamePlaceholders.expand("$1 $n $2", with: values), "$1 1 $2")
    }

    func testAnUnknownOrPartialNameIsLeftAlone() {
        let values = RenamePlaceholders.Values()
        XCTAssertEqual(RenamePlaceholders.expand("$foo", with: values), "$foo")
        // $owner, not the start of $ownership.
        XCTAssertEqual(RenamePlaceholders.expand("$ownership", with: values), "$ownership")
    }

    func testDatesUseEverydayLetters() {
        var values = RenamePlaceholders.Values()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        values.created = date
        // YYYY-MM-DD is turned into the formatter's yyyy-MM-dd.
        let same = DateFormatter()
        same.locale = Locale(identifier: "en_US_POSIX")
        same.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(RenamePlaceholders.expand("$cdate{YYYY-MM-DD}", with: values),
                       same.string(from: date))
    }

    func testAMissingExifValueIsEmpty() {
        var values = RenamePlaceholders.Values()
        values.exif = ["DateTimeOriginal": "2008:02:28 19:28:19"]
        XCTAssertEqual(RenamePlaceholders.expand("$exif{Make}|$exif{DateTimeOriginal}", with: values),
                       "|2008:02:28 19:28:19")
    }

    func testASubstitutedValueGoesInLiterally() throws {
        // A value that contains $1 must not become a backreference.
        var values = RenamePlaceholders.Values()
        values.owner = "a$1b"
        let filled = RenamePlaceholders.expand("$owner", with: values)

        let regex = try NSRegularExpression(pattern: "^(.*)$")
        let name = "x"
        let replaced = regex.stringByReplacingMatches(
            in: name, options: [], range: NSRange(name.startIndex..., in: name),
            withTemplate: filled)
        XCTAssertEqual(replaced, "a$1b", "the owner's text is literal, not group 1")
    }

    func testEmptyFormatAndTrailingDollar() {
        let values = RenamePlaceholders.Values()
        XCTAssertEqual(RenamePlaceholders.expand("end$", with: values), "end$")
    }
}
