import XCTest
@testable import Diptych

/// What two files differ in besides their bytes -- the thing a folder
/// comparison or a sync says, and comparing the text cannot show.
final class PropertyComparisonTests: XCTestCase {

    private var folder: URL!
    private var left: URL!
    private var right: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychProperties-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        left = folder.appendingPathComponent("left.txt")
        right = folder.appendingPathComponent("right.txt")
        for url in [left!, right!] {
            try Data("same\n".utf8).write(to: url)
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000),
                                       .creationDate: Date(timeIntervalSince1970: 1_600_000_000),
                                       .posixPermissions: 0o644],
                                      ofItemAtPath: url.path)
        }
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: folder)
    }

    private func differing() -> [String] {
        PropertyComparison.of(left, right).differing.map(\.name)
    }

    func testTwoCopiesDifferInNothing() {
        let properties = PropertyComparison.of(left, right, comparingBytes: true)
        XCTAssertEqual(properties.differing.map(\.name), [])
        XCTAssertEqual(properties.bytesAreSame, true)
        XCTAssertTrue(properties.rows.contains { $0.name == "Permissions" && $0.left == "rw-r--r--" })
    }

    func testPermissionsAndAnAttributeOnOneSideAreNamed() {
        chmod(right.path, 0o600)
        XCTAssertNil(ExtendedAttributes.set(Data("hello".utf8), name: "dev.test.note", on: left.path))

        let properties = PropertyComparison.of(left, right)
        XCTAssertEqual(properties.differing.map(\.name), ["Permissions", "Attribute dev.test.note"])
        let note = properties.differing[1]
        XCTAssertEqual(note.left, "hello")
        XCTAssertNil(note.right, "not there at all")
        XCTAssertEqual(properties.summary, "permissions, dev.test.note")
    }

    func testDatesDifferingByLessThanASecondAreShownToTheNanosecond() throws {
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000.5)],
                                  ofItemAtPath: right.path)
        let row = try XCTUnwrap(PropertyComparison.of(left, right).differing.first)
        XCTAssertEqual(row.name, "Modified")
        XCTAssertEqual(row.right?.hasSuffix(".500000000"), true, row.right ?? "")
        XCTAssertEqual(row.left?.contains("."), false)
    }

    func testTheSameLengthAndOtherBytesIsSaid() throws {
        try Data("same\r".utf8).write(to: right)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                                  ofItemAtPath: right.path)
        let properties = PropertyComparison.of(left, right, comparingBytes: true)
        XCTAssertEqual(properties.bytesAreSame, false)
        XCTAssertEqual(properties.differing.map(\.name), [])
    }

    func testABinaryPropertyListAttributeIsReadAsWhatItHolds() throws {
        let tags = try PropertyListSerialization.data(fromPropertyList: ["Red\n6", "Work"],
                                                      format: .binary, options: 0)
        XCTAssertNil(ExtendedAttributes.set(tags, name: "com.apple.metadata:_kMDItemUserTags",
                                            on: left.path))
        let row = try XCTUnwrap(PropertyComparison.of(left, right).differing.first)
        XCTAssertEqual(row.left, "[Red\n6, Work]")
    }
}
