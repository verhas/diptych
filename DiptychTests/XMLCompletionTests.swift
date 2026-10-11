import XCTest
@testable import Diptych

final class XMLCompletionTests: XCTestCase {

    /// The suggestion where `|` is.
    private func suggestion(_ marked: String) -> String? {
        let caret = (marked as NSString).range(of: "|").location
        let text = marked.replacingOccurrences(of: "|", with: "") as NSString
        return XMLCompletion.suggestion(in: text, at: caret)
    }

    /// The end tag put in after typing the `>` before `|`.
    private func endTag(_ marked: String) -> String? {
        let caret = (marked as NSString).range(of: "|").location
        let text = marked.replacingOccurrences(of: "|", with: "") as NSString
        return XMLCompletion.endTag(in: text, at: caret)
    }

    func testATagIsClosedWithAGreaterThan() {
        XCTAssertEqual(suggestion("<|"), ">")
        XCTAssertEqual(suggestion("<root><item|"), ">")
        XCTAssertEqual(suggestion("<item id=\"7\" |"), ">")
        XCTAssertEqual(suggestion("<item id=\"7|"), "\">", "the value too")
        XCTAssertEqual(suggestion("<item id='a>b|"), "'>", "a > in a value is not the end")
        XCTAssertEqual(suggestion("<br/|"), ">")
    }

    func testAnAttributeNameIsGivenItsValueQuotes() {
        XCTAssertEqual(suggestion("<kakukk makukk|"), "=\"\"")
        XCTAssertEqual(suggestion("<kakukk makukk |"), "=\"\"", "a space before = is allowed")
        XCTAssertEqual(suggestion("<a b=|"), "\"\"")
        XCTAssertEqual(suggestion("<a b = |"), "\"\"")
        XCTAssertEqual(suggestion("<a x:y|"), "=\"\"")
        XCTAssertEqual(suggestion("<a b=\"1\" c|"), "=\"\"")
        XCTAssertEqual(suggestion("<a b=\"1\"|"), ">", "a value given: the tag ends")
        XCTAssertEqual(suggestion("<a b=\"1\" |"), ">")
        XCTAssertEqual(XMLCompletion.caret(in: "=\"\""), 2)
        XCTAssertEqual(XMLCompletion.caret(in: "item>"), 5)
    }

    func testNothingIsOfferedBetweenTags() {
        XCTAssertNil(suggestion("|"))
        XCTAssertNil(suggestion("<root>|"))
        XCTAssertNil(suggestion("<root>text|"))
        XCTAssertNil(suggestion("<root> 1 < 2|"), "a < that starts nothing")
        XCTAssertNil(suggestion("<!-- <a> -->|"))
    }

    func testAnEndTagNamesTheElementStillOpen() {
        XCTAssertEqual(suggestion("<root><item>text</|"), "item>")
        XCTAssertEqual(suggestion("<root><item>text</it|"), "em>")
        XCTAssertEqual(suggestion("<root><item>text</item></|"), "root>")
        XCTAssertEqual(suggestion("<root><br/></|"), "root>", "self-closing is not open")
        XCTAssertEqual(suggestion("<root><!-- <a> --></|"), "root>", "nor what is in a comment")
        XCTAssertEqual(suggestion("<root></x|"), ">", "typed otherwise: only the end")
        XCTAssertEqual(suggestion("<root></root |"), ">")
        XCTAssertNil(suggestion("</|"), "nothing open")
    }

    func testCommentsAndTheRestAreFinished() {
        XCTAssertEqual(suggestion("<!-- note|"), "-->")
        XCTAssertEqual(suggestion("<!-- note -|"), "->")
        XCTAssertEqual(suggestion("<!-- note --|"), ">")
        XCTAssertEqual(suggestion("<?xml version=\"1.0\"|"), "?>")
        XCTAssertEqual(suggestion("<![CDATA[ a < b|"), "]]>")
        XCTAssertEqual(suggestion("<!DOCTYPE note|"), ">")
        XCTAssertNil(suggestion("<!-|"), "not yet known")
    }

    func testClosingAStartTagPutsInItsEndTag() {
        XCTAssertEqual(endTag("<root>|"), "</root>")
        XCTAssertEqual(endTag("<root><item id=\"1\">|"), "</item>")
        XCTAssertEqual(endTag("<root><item>|</root>"), "</item>", "the end further on is root's")
        XCTAssertNil(endTag("<root><item>|</item></root>"), "closed already")
        XCTAssertNil(endTag("<root><br/>|"), "self-closing")
        XCTAssertNil(endTag("<root></item>|"), "an end tag")
        XCTAssertNil(endTag("<!-- x -->|"))
        XCTAssertNil(endTag("<root|>"), "only right after the >")
    }
}

/// The same, in a Text Edit window's text view.
@MainActor
final class XMLCompletionEditorTests: XCTestCase {

    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("XMLCompletionEditorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Kept: the text view's delegate is weak.
    private var coordinator: PlainTextEditor.Coordinator?

    private func editor(_ name: String) -> TextEditController {
        let document = TextEditDocument(url: folder.appendingPathComponent(name))
        let controller = TextEditController(document: document)
        let coordinator = PlainTextEditor.Coordinator(document: document)
        coordinator.controller = controller
        controller.textView.delegate = coordinator
        self.coordinator = coordinator
        controller.loaded(text: "")
        return controller
    }

    private func type(_ text: String, into controller: TextEditController) {
        for character in text {
            controller.textView.insertText(String(character),
                                           replacementRange: controller.textView.selectedRange())
        }
    }

    func testTypingATagAndTakingTheSuggestion() {
        let controller = editor("a.xml")
        type("<root", into: controller)
        XCTAssertEqual(controller.suggestion, ">")
        XCTAssertTrue(controller.acceptSuggestion())
        XCTAssertEqual(controller.textView.string, "<root></root>")
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 6, length: 0),
                       "the caret between the tags")
        XCTAssertNil(controller.suggestion)

        type("<item>", into: controller)
        XCTAssertEqual(controller.textView.string, "<root><item></item></root>", "typed > as well")
        controller.textView.setSelectedRange(NSRange(location: 19, length: 0))
        type("</", into: controller)
        XCTAssertEqual(controller.suggestion, "root>")
        XCTAssertTrue(controller.acceptSuggestion())
        XCTAssertEqual(controller.textView.string, "<root><item></item></root></root>")
    }

    func testTakingAnAttributesQuotesPutsTheCaretBetweenThem() {
        let controller = editor("a.xml")
        type("<kakukk makukk", into: controller)
        XCTAssertEqual(controller.suggestion, "=\"\"")
        XCTAssertTrue(controller.acceptSuggestion())
        XCTAssertEqual(controller.textView.string, "<kakukk makukk=\"\"", "no end tag: the tag is not closed")
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 16, length: 0))
        type("1", into: controller)
        XCTAssertEqual(controller.textView.string, "<kakukk makukk=\"1\"")
    }

    func testOnlyXML() {
        let controller = editor("a.txt")
        type("<root>", into: controller)
        XCTAssertNil(controller.suggestion)
        XCTAssertEqual(controller.textView.string, "<root>")
        XCTAssertFalse(controller.acceptSuggestion())
    }
}
