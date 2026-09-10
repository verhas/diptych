import XCTest
@testable import Diptych

/// Markdown rendered for Quick Look.
///
/// The parsing is Foundation's, so what is worth testing is the shape: turning
/// a *flat* run of text carrying presentation intents into nested HTML, which
/// is where the work -- and the bugs -- live.
final class MarkdownReportTests: XCTestCase {

    private func html(_ markdown: String) -> String {
        MarkdownReport.html(for: markdown, name: "t.md",
                            baseURL: URL(fileURLWithPath: "/tmp"))
    }

    private func body(_ markdown: String) -> String {
        let rendered = html(markdown)
        guard let start = rendered.range(of: "<body>"),
              let end = rendered.range(of: "</body>") else { return "" }
        return String(rendered[start.upperBound ..< end.lowerBound])
    }

    func testHeadingsKeepTheirLevel() {
        XCTAssertTrue(body("# One").contains("<h1>One</h1>"))
        XCTAssertTrue(body("### Three").contains("<h3>Three</h3>"))
    }

    func testInlineStyles() {
        let out = body("A **b** and *i* and `c` and ~~s~~.")
        XCTAssertTrue(out.contains("<strong>b</strong>"))
        XCTAssertTrue(out.contains("<em>i</em>"))
        XCTAssertTrue(out.contains("<code>c</code>"))
        XCTAssertTrue(out.contains("<del>s</del>"))
    }

    func testLinksBecomeAnchors() {
        XCTAssertTrue(body("[text](https://example.com)")
            .contains("<a href=\"https://example.com\">text</a>"))
    }

    func testListsNest() {
        // The whole point of matching intents by identity: an inner list has to
        // close before the outer item does.
        let out = body("- one\n- two\n  - inner\n")
        XCTAssertTrue(out.contains("<ul>"))
        XCTAssertEqual(out.components(separatedBy: "<ul>").count - 1, 2, "an outer and an inner")
        XCTAssertEqual(out.components(separatedBy: "</ul>").count - 1, 2, "both closed")
    }

    func testOrderedAndUnorderedAreDistinct() {
        XCTAssertTrue(body("1. a\n2. b").contains("<ol>"))
        XCTAssertFalse(body("1. a\n2. b").contains("<ul>"))
    }

    func testFencedCodeKeepsItsLanguageAndIsNotInterpreted() {
        let out = body("```swift\nlet x = a < b && c\n```")
        XCTAssertTrue(out.contains("data-language=\"swift\""))
        // Inside a fence everything is literal, including what would be markup.
        XCTAssertTrue(out.contains("a &lt; b &amp;&amp; c"))
        XCTAssertFalse(out.contains("<em>"))
    }

    func testBlockQuotes() {
        XCTAssertTrue(body("> quoted").contains("<blockquote>"))
    }

    func testThematicBreak() {
        XCTAssertTrue(body("a\n\n---\n\nb").contains("<hr>"))
    }

    func testTablesGetHeaderCellsAndAlignment() {
        let out = body("| l | c | r |\n| :- | :-: | -: |\n| 1 | 2 | 3 |")
        XCTAssertTrue(out.contains("<table>"))
        XCTAssertTrue(out.contains("<th>l</th>"), "header cells are th, not td")
        XCTAssertTrue(out.contains("style=\"text-align:center\""))
        XCTAssertTrue(out.contains("style=\"text-align:right\""))
        XCTAssertTrue(out.contains("<td>1</td>"), "body cells are td")
    }

    func testHTMLInTheSourceIsEscapedRatherThanEmitted() {
        // A README that documents HTML must not have that HTML run.
        let out = body("Use <script>alert(1)</script> carefully.")
        XCTAssertTrue(out.contains("&lt;script&gt;"))
        XCTAssertFalse(out.contains("<script>"))
    }

    func testEveryOpenedTagIsClosed() {
        let out = body("""
            # Title

            - a
              1. b
            - c

            > quote with **bold**

            | x |
            | - |
            | y |
            """)
        for tag in ["ul", "ol", "li", "blockquote", "table", "tr", "p"] {
            XCTAssertEqual(out.components(separatedBy: "<\(tag)>").count
                           + out.components(separatedBy: "<\(tag) ").count - 2,
                           out.components(separatedBy: "</\(tag)>").count - 1,
                           "\(tag) is unbalanced")
        }
    }

    func testAnEmptyFileSaysSo() {
        XCTAssertTrue(body("").contains("empty"))
    }

    func testTaskListsRenderAsPlainItems() {
        // Foundation's parser does not recognise them, so the brackets arrive
        // as text. Better documented than silently surprising.
        let out = body("- [ ] todo")
        XCTAssertTrue(out.contains("<li>"))
        XCTAssertTrue(out.contains("[ ] todo"))
    }
}
