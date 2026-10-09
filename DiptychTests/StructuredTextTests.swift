import XCTest
@testable import Diptych

/// Text Edit's formats: what folds, and where a file stops being what its
/// extension says.
final class StructuredTextTests: XCTestCase {

    private func analyse(_ text: String, _ format: TextFormat) -> StructureAnalysis {
        StructuredText.analyse(text, as: format)
    }

    private func problem(_ text: String, _ format: TextFormat,
                         file: StaticString = #filePath, line: UInt = #line) -> SyntaxProblem? {
        let found = analyse(text, format).problem
        XCTAssertNotNil(found, "no problem found in: \(text)", file: file, line: line)
        return found
    }

    private func noProblem(_ text: String, _ format: TextFormat,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(analyse(text, format).problem, text, file: file, line: line)
    }

    // MARK: - Extensions

    func testTheExtensionSaysTheFormat() {
        let map = TextFormat.defaultExtensions
        XCTAssertEqual(TextFormat.of(URL(fileURLWithPath: "/a/b.JSON"), extensions: map), .json)
        XCTAssertEqual(TextFormat.of(URL(fileURLWithPath: "/a/b.yml"), extensions: map), .yaml)
        XCTAssertEqual(TextFormat.of(URL(fileURLWithPath: "/a/b.yaml"), extensions: map), .yaml)
        XCTAssertNil(TextFormat.of(URL(fileURLWithPath: "/a/b.txt"), extensions: map))
        var more = map
        more[.json, default: []].append("geojson")
        XCTAssertEqual(TextFormat.of(URL(fileURLWithPath: "/a/b.geojson"), extensions: more), .json)
    }

    // MARK: - JSON

    func testJSONFoldsBetweenItsBrackets() {
        let text = "{\n  \"a\": [\n    1,\n    2\n  ],\n  \"b\": {}\n}\n"
        let result = analyse(text, .json)
        XCTAssertNil(result.problem)
        XCTAssertEqual(result.folds.count, 2)
        let outer = result.folds.first { $0.firstLine == 0 }
        XCTAssertEqual(outer?.lastLine, 6)
        XCTAssertEqual(outer?.label, "2 keys")
        let array = result.folds.first { $0.firstLine == 1 }
        XCTAssertEqual(array?.label, "2 items")
        // The brackets stay; what is between them folds.
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: NSRange(location: array!.hidden.location - 1, length: 1)), "[")
        XCTAssertEqual(ns.substring(with: NSRange(location: NSMaxRange(array!.hidden), length: 1)), "]")
    }

    func testJSONProblemsSayWhere() {
        let missingComma = problem("{\n  \"a\": 1\n  \"b\": 2\n}", .json)
        XCTAssertEqual(missingComma?.line, 3)
        XCTAssertEqual(missingComma?.column, 3)
        XCTAssertTrue(missingComma?.message.contains("comma") == true)

        XCTAssertTrue(problem("[1, 2,]", .json)?.message.contains("comma before ]") == true)
        XCTAssertTrue(problem("{\"a\": True}", .json)?.message.contains("True") == true)
        XCTAssertTrue(problem("{'a': 1}", .json)?.message.contains("double quotes") == true)
        let open = problem("{\n\"a\": [1,\n", .json)
        XCTAssertEqual(open?.line, 2, "the array is what is not closed")
        XCTAssertTrue(problem("{\"a\": \"x}", .json)?.message.contains("not closed") == true)
        XCTAssertTrue(problem("// hi\n{}", .json)?.message.contains("comments") == true)
        XCTAssertTrue(problem("{} {}", .json)?.message.contains("one more") == true)
        XCTAssertTrue(problem("[01]", .json)?.message.contains("0") == true)
        XCTAssertTrue(problem(#"["\q"]"#, .json)?.message.contains("escape") == true)
        noProblem(#"{"a": [1, -2.5e3, true, false, null, "\u00e9\n"], "b": {"c": {}}}"#, .json)
        noProblem("   \n", .json)
    }

    // MARK: - XML

    func testXMLFoldsElementsOverLines() {
        let text = "<root>\n  <a>\n    <b/>\n  </a>\n  <c>x</c>\n</root>\n"
        let result = analyse(text, .xml)
        XCTAssertNil(result.problem)
        XCTAssertEqual(Set(result.folds.map(\.firstLine)), [0, 1])
        let a = result.folds.first { $0.firstLine == 1 }!
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: a.hidden), "\n    <b/>\n  ", "between the tags")
        XCTAssertEqual(result.folds.first { $0.firstLine == 0 }?.label, "2 elements")
    }

    func testXMLProblemsSayWhere() {
        let mismatch = problem("<root>\n  <a>\n  </b>\n</root>", .xml)
        XCTAssertEqual(mismatch?.line, 3)
        let unclosed = problem("<root>\n  <a>\n", .xml)
        XCTAssertTrue(unclosed?.message.contains("<a>") == true, unclosed?.message ?? "")
        XCTAssertNotNil(problem("<a b=\"1\" b=\"2\"/>", .xml))
        XCTAssertNotNil(problem("<a>&</a>", .xml))
        noProblem("<?xml version=\"1.0\"?>\n<a x='1'><!-- c --><![CDATA[<>]]></a>", .xml)
    }

    // MARK: - TOML

    func testTOMLFoldsTablesArraysAndStrings() {
        let text = """
        title = "x"

        [server]
        host = "localhost"
        ports = [
          80,
          443,
        ]

        [server.tls]
        on = true
        text = \"\"\"
        a
        b\"\"\"
        """
        let result = analyse(text, .toml)
        XCTAssertNil(result.problem, result.problem?.message ?? "")
        XCTAssertNotNil(result.folds.first { $0.firstLine == 2 && $0.lastLine == 7 },
                        "[server] to before the next header, blank lines left out")
        XCTAssertNotNil(result.folds.first { $0.firstLine == 4 && $0.label == "2 items" })
        XCTAssertNotNil(result.folds.first { $0.firstLine == 9 })
        XCTAssertNotNil(result.folds.first { $0.firstLine == 11 }, "the multi-line string")
    }

    func testTOMLProblemsSayWhere() {
        let noEquals = problem("a = 1\nb 2\n", .toml)
        XCTAssertEqual(noEquals?.line, 2)
        XCTAssertTrue(noEquals?.message.contains("=") == true)
        XCTAssertTrue(problem("a = 1\na = 2", .toml)?.message.contains("twice") == true)
        XCTAssertTrue(problem("[t]\n[t]", .toml)?.message.contains("twice") == true)
        XCTAssertTrue(problem("a = hello", .toml)?.message.contains("quotes") == true)
        XCTAssertTrue(problem("a = \"x", .toml)?.message.contains("not closed") == true)
        XCTAssertTrue(problem("a = [1, 2", .toml)?.message.contains("not closed") == true)
        XCTAssertTrue(problem("a = {b = 1,}", .toml)?.message.contains("comma") == true)
        XCTAssertTrue(problem("a = 1 2", .toml)?.message.contains("comment") == true)
        XCTAssertTrue(problem(#"a = "\q""#, .toml)?.message.contains("escape") == true)
        XCTAssertNotNil(problem("[a", .toml))
        noProblem("""
        # comment
        a = 1_000
        b = 0xDEAD_BEEF
        c = -3.14e+2
        d = inf
        e = 1979-05-27T07:32:00Z
        f = 1979-05-27 07:32:00
        g = 07:32:00
        h = 'C:\\path'
        "quoted key".x = { y = [1, "two", [3]], z = false }
        [[fruit]]
        name = "apple"
        [[fruit]]
        name = "banana"
        """, .toml)
    }

    // MARK: - YAML

    func testYAMLFoldsWhatIsIndentedUnder() {
        let text = "a:\n  b: 1\n  c:\n    - x\n    - y\nd: 2\n"
        let result = analyse(text, .yaml)
        XCTAssertNil(result.problem, result.problem?.message ?? "")
        XCTAssertNotNil(result.folds.first { $0.firstLine == 0 && $0.lastLine == 4 })
        XCTAssertNotNil(result.folds.first { $0.firstLine == 2 && $0.lastLine == 4 })
        XCTAssertNil(result.folds.first { $0.firstLine == 5 })
    }

    func testYAMLProblemsSayWhere() {
        let tab = problem("a:\n\tb: 1\n", .yaml)
        XCTAssertEqual(tab?.line, 2)
        XCTAssertTrue(tab?.message.contains("tabs") == true)

        let underValue = problem("a: 1\n  b: 2\n", .yaml)
        XCTAssertEqual(underValue?.line, 2)
        XCTAssertTrue(underValue?.message.contains("already has its value") == true)

        let noLevel = problem("a:\n    b: 1\n  c: 2\n", .yaml)
        XCTAssertEqual(noLevel?.line, 3)
        XCTAssertTrue(noLevel?.message.contains("no level") == true)

        XCTAssertTrue(problem("a: 1\nb: 2\na: 3\n", .yaml)?.message.contains("twice") == true)
        XCTAssertTrue(problem("a: 1\njust text\n", .yaml)?.message.contains("colon") == true)
        XCTAssertTrue(problem("a: \"open\nb: 2\n", .yaml)?.message.contains("never closed") == true)
        XCTAssertTrue(problem("a: [1, 2\nb: 3\n", .yaml)?.message.contains("not closed") == true)
    }

    func testYAMLThatIsFine() {
        noProblem("""
        # a comment
        name: Diptych
        list:
          - one
          - two: 2
            three: 3
          -
            four: 4
        text: |
          a: this is text,
            not keys: at all
        folded: >-
          more
        flow: {a: 1, b: [1, 2]}
        multi: [1,
          2]
        quoted: "a # not a comment"
        plain: goes
          on here
        url: http://example.com:8080/x
        'single': 'it''s'
        ---
        name: second document
        """, .yaml)
    }
}
