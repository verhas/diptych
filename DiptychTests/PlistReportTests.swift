import XCTest
@testable import Diptych

/// Property lists rendered for Quick Look: XML in its own key order, binary
/// read as well, and a file that is no plist said to be one.
final class PlistReportTests: XCTestCase {

    private let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Zebra</key><string>a &lt;b&gt;</string>
          <key>Apple</key><array><integer>1</integer><true/></array>
          <key>Blob</key><data>AAEC</data>
        </dict></plist>
        """

    func testXMLKeepsFileOrder() throws {
        let (root, format) = try XCTUnwrap(PlistReport.tree(of: Data(xml.utf8)))
        XCTAssertEqual(format, .xml)
        XCTAssertEqual(root.children.map(\.key), ["Zebra", "Apple", "Blob"])
    }

    func testBinaryIsRead() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["b": 2, "a": ["x": true]], format: .binary, options: 0)
        let (root, format) = try XCTUnwrap(PlistReport.tree(of: data))
        XCTAssertEqual(format, .binary)
        XCTAssertEqual(Set(root.children.compactMap(\.key)), ["a", "b"])
    }

    func testPageShowsTypesAndEscapes() {
        let page = PlistReport.html(for: Data(xml.utf8), name: "x.plist", path: "/tmp")
        XCTAssertTrue(page.contains("a &lt;b&gt;"))
        XCTAssertTrue(page.contains("<b>Apple</b>"))
        XCTAssertTrue(page.contains("2 items"))
        XCTAssertTrue(page.contains("YES"))
        XCTAssertTrue(page.contains("00 01 02"))
    }

    func testNotAPlist() {
        let page = PlistReport.html(for: Data("{ a = (".utf8), name: "x.plist", path: "/tmp")
        XCTAssertTrue(page.contains("does not read as one"))
    }
}
