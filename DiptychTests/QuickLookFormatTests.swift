import XCTest
@testable import Diptych

/// Quick Look's Format button for JSON, JSON Lines and XML -- laid out as Text
/// Edit's Format Document lays them out -- and what the page says before the
/// text: where a file breaks its format, how many entries a JSON Lines file has.
final class QuickLookFormatTests: XCTestCase {

    private let style = TextStyle()

    private func preview(_ text: String, _ language: String, truncated: Bool = false)
        -> StructuredFormatter.Preview {
        StructuredFormatter.preview(text, languageID: language, style: style, truncated: truncated)
    }

    func testJSONIsLaidOutAsTextEditLaysItOut() throws {
        let text = #"{"z":1,"a":[1.50,2e3,"x, {y}: \"q\""],"e":{},"t":true,"n":null}"#
        let formatted = try XCTUnwrap(preview(text, "json").formatted)
        guard case .success(let edited) = StructuredFormatter.format(text, as: .json, style: style) else {
            return XCTFail("Text Edit formats it")
        }
        XCTAssertEqual(formatted, edited, "one layout for both")
        XCTAssertTrue(formatted.contains("\n"))
        XCTAssertTrue(formatted.contains("1.50") && formatted.contains("2e3"), "numbers as written")
        XCTAssertLessThan(try XCTUnwrap(formatted.range(of: "\"z\"")).lowerBound,
                          try XCTUnwrap(formatted.range(of: "\"a\"")).lowerBound, "keys in their order")
        let a = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary
        let b = try JSONSerialization.jsonObject(with: Data(formatted.utf8)) as? NSDictionary
        XCTAssertEqual(a, b, "the same value")
    }

    func testBrokenJSONSaysWhereAndHasNoButton() {
        let broken = preview("{\n  \"a\": 1,\n  \"b\" 2\n}", "json")
        XCTAssertNil(broken.formatted)
        let note = broken.notes.first ?? ""
        XCTAssertTrue(note.hasPrefix("It is not valid JSON:") && note.contains("line 3"), note)
    }

    func testWhatIsLaidOutAlreadyOrCutShortHasNoButton() throws {
        guard case .success(let laidOut) = StructuredFormatter.format(#"{"a":[1,2]}"#, as: .json, style: style) else {
            return XCTFail()
        }
        XCTAssertEqual(preview(laidOut, "json"), .init(), "nothing to do")
        XCTAssertEqual(preview(#"{"a": 1"#, "json", truncated: true), .init(), "cut short: neither checked nor laid out")
        XCTAssertEqual(preview("int main() {}", "c"), .init())
    }

    func testJSONWithCommentsKeepsThem() throws {
        let text = "{// the port\n\"port\":8080,/* why */\"host\":\"h\"}"
        let formatted = try XCTUnwrap(preview(text, "jsonc").formatted)
        XCTAssertTrue(formatted.contains("// the port"), formatted)
        XCTAssertTrue(formatted.contains("/* why */"), formatted)
        XCTAssertTrue(formatted.contains("8080"), formatted)
    }

    func testXMLIsLaidOutOrSaysWhereItBreaks() throws {
        let text = #"<?xml version="1.0"?><a x="1" b="2"><b>t</b><c/></a>"#
        let formatted = try XCTUnwrap(preview(text, "xml").formatted)
        XCTAssertTrue(formatted.contains("\n"), formatted)
        XCTAssertTrue(formatted.contains(#"<a x="1" b="2">"#), "attributes in their order: \(formatted)")
        let broken = preview("<a><b></a>", "xml")
        XCTAssertNil(broken.formatted)
        XCTAssertTrue(broken.notes.first?.hasPrefix("It is not valid XML:") == true, "\(broken.notes)")
    }

    // MARK: - JSON Lines

    func testJSONLinesAreCountedAndLaidOutOneAfterAnother() throws {
        let text = "{\"id\":1,\"tags\":[\"a\"]}\n\n{\"id\":2}\n{\"id\":3}\n"
        let shown = preview(text, "jsonl")
        XCTAssertEqual(shown.notes, ["3 entries."])
        let formatted = try XCTUnwrap(shown.formatted)
        XCTAssertEqual(formatted.components(separatedBy: "\n\n").count, 3, formatted)
        XCTAssertTrue(formatted.contains("\"tags\""))
    }

    func testABrokenLineIsNamed() {
        let shown = preview("{\"id\":1}\n{\"id\":\n{\"id\":3}\n", "jsonl")
        XCTAssertEqual(shown.notes.first, "2 entries.")
        XCTAssertTrue(shown.notes.last?.hasPrefix("Line 2 is not JSON:") == true, "\(shown.notes)")
    }

    func testTheLastLineOfAFileCutShortIsNotCalledBroken() {
        let shown = preview("{\"id\":1}\n{\"id\":2}\n{\"id\"", "jsonl", truncated: true)
        XCTAssertEqual(shown.notes, ["2 entries in the part shown."])
    }

    func testOneEntryIsOneEntry() {
        XCTAssertEqual(preview("{\"a\":1}\n", "jsonl").notes, ["1 entry."])
    }

    // MARK: - The page

    func testThePageHasBothAButtonBetweenThemAndTheNotes() throws {
        let language = try XCTUnwrap(TextMateRegistry.shared.language(for: URL(fileURLWithPath: "/x.jsonl"),
                                                                       firstLine: nil))
        XCTAssertEqual(language.id, "jsonl")
        let text = "{\"a\":1}\n{\"a\":2}\n"
        let shown = preview(text, language.id)
        let html = SourceReport.html(text: text, url: URL(fileURLWithPath: "/x.jsonl"), language: language,
                                     size: text.count, truncated: false, coloured: false,
                                     formatted: shown.formatted, showFormatted: true, notes: shown.notes)
        XCTAssertTrue(html.contains("<input type=checkbox id=format class=toggle checked>"))
        XCTAssertTrue(html.contains("class=written") && html.contains("class=formatted"))
        XCTAssertTrue(html.contains("<p class=note>2 entries.</p>"))
        let plain = SourceReport.html(text: text, url: URL(fileURLWithPath: "/x.jsonl"), language: language,
                                      size: text.count, truncated: false, coloured: false)
        XCTAssertFalse(plain.contains("id=format"), "no button without a formatted version")
    }
}
