import XCTest
@testable import Diptych

/// JSON and XML laid out for Quick Look's Format button.
final class PrettyTextTests: XCTestCase {

    func testJSONIsIndentedWithNothingElseChanged() throws {
        let text = #"{"z":1,"a":[1.50,2e3,"x, {y}: \"q\""],"e":{},"f":[],"t":true,"n":null}"#
        let formatted = try XCTUnwrap(PrettyText.format(text, languageID: "json"))
        XCTAssertEqual(formatted, """
            {
              "z": 1,
              "a": [
                1.50,
                2e3,
                "x, {y}: \\"q\\""
              ],
              "e": {},
              "f": [],
              "t": true,
              "n": null
            }
            """)
        // The same value, keys in the order they were written.
        let a = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary
        let b = try JSONSerialization.jsonObject(with: Data(formatted.utf8)) as? NSDictionary
        XCTAssertEqual(a, b)
    }

    func testWhatIsNotJSONOrIsLaidOutAlreadyHasNoButton() {
        XCTAssertNil(PrettyText.format(#"{"a": 1"#, languageID: "json"), "does not parse")
        XCTAssertNil(PrettyText.format("{\n  \"a\": 1\n}\n", languageID: "json"), "nothing to do")
        XCTAssertNil(PrettyText.format("int main() {}", languageID: "c"))
    }

    func testJSONWithCommentsKeepsThem() throws {
        let text = "{// the port\n\"port\":8080,/* why */\"host\":\"h\"}"
        let formatted = try XCTUnwrap(PrettyText.format(text, languageID: "jsonc"))
        XCTAssertTrue(formatted.contains("// the port\n  \"port\": 8080,"), formatted)
        XCTAssertTrue(formatted.contains("/* why */"), formatted)
    }

    func testXMLIsIndentedAndReadsNothingOutside() throws {
        let text = #"<?xml version="1.0"?><a x="1" b="2"><b>t</b><c/><![CDATA[<raw>]]></a>"#
        let formatted = try XCTUnwrap(PrettyText.format(text, languageID: "xml"))
        XCTAssertTrue(formatted.contains("\n"), formatted)
        XCTAssertTrue(formatted.contains(#"<a x="1" b="2">"#), "attributes in their order: \(formatted)")
        XCTAssertTrue(formatted.contains("<![CDATA[<raw>]]>"), formatted)
        XCTAssertNil(PrettyText.format("<a><b></a>", languageID: "xml"), "does not parse")
    }

    func testThePageHasBothAndAButtonBetweenThem() throws {
        let language = try XCTUnwrap(TextMateRegistry.shared.language(for: URL(fileURLWithPath: "/x.json"),
                                                                       firstLine: nil))
        let text = #"{"a":1}"#
        let html = SourceReport.html(text: text, url: URL(fileURLWithPath: "/x.json"), language: language,
                                     size: text.count, truncated: false, coloured: false,
                                     formatted: PrettyText.format(text, languageID: "json"), showFormatted: true)
        XCTAssertTrue(html.contains("<input type=checkbox id=format class=toggle checked>"))
        XCTAssertTrue(html.contains("class=written") && html.contains("class=formatted"))
        let plain = SourceReport.html(text: text, url: URL(fileURLWithPath: "/x.json"), language: language,
                                      size: text.count, truncated: false, coloured: false)
        XCTAssertFalse(plain.contains("id=format"), "no button without a formatted version")
    }
}
