import XCTest
@testable import Diptych

/// The TextMate engine: Oniguruma patterns read by ICU, the tokenizer, the
/// grammars Diptych ships, and colouring again after an edit.
final class TextMateTests: XCTestCase {

    private let registry = TextMateRegistry.shared

    // MARK: - Patterns

    func testPatternsAreReadTheOnigurumaWay() throws {
        // \h is a hex digit, not horizontal space.
        let hex = try XCTUnwrap(TextMateRegex(#"0x\h+"#).free)
        XCTAssertNotNil(hex.firstMatch(in: "0xBEEF", range: NSRange(location: 0, length: 6)))
        XCTAssertNil(hex.firstMatch(in: "0x  ", range: NSRange(location: 0, length: 4)))
        // A { that starts no repeat count is a literal.
        let brace = try XCTUnwrap(TextMateRegex(#"\$\{|{|}"#).free)
        XCTAssertNotNil(brace.firstMatch(in: "a{b", range: NSRange(location: 0, length: 3)))
        XCTAssertNotNil(TextMateRegex(#"a{2,3}"#).free)
        XCTAssertNotNil(TextMateRegex(#"[\h_]"#).free)
        XCTAssertNotNil(TextMateRegex(#"[[:alpha:]][^]x]"#).free)
    }

    func testGHoldsOnlyWhereTheLastMatchEnded() throws {
        let regex = TextMateRegex(#"\G\s*(x)"#)
        XCTAssertTrue(regex.usesG)
        let text = "ab  x"
        let at = try XCTUnwrap(regex.expression(atAnchor: true))
        let options = regex.options(atAnchor: true)
        XCTAssertEqual(at.firstMatch(in: text, options: options,
                                     range: NSRange(location: 2, length: 3))?.range(at: 1).location, 4,
                       "at the start of the search")
        XCTAssertNil(at.firstMatch(in: text, options: options, range: NSRange(location: 1, length: 4)),
                     "nowhere else in it")
        // "Not where the last match ended": the end of a region that has
        // begun and must first move on. ICU got this wrong with transparent bounds.
        let moved = TextMateRegex(#"(?!\G)"#)
        XCTAssertEqual(moved.expression(atAnchor: true)?.firstMatch(
            in: "abcde", options: moved.options(atAnchor: true), range: NSRange(location: 2, length: 3))?.range.location, 3)
        XCTAssertNil(regex.expression(atAnchor: false)?.firstMatch(in: text, options: TextMateRegex.options,
                                                                   range: NSRange(location: 2, length: 3)))
        // ^ is the start of the line, not of the search.
        let caret = try XCTUnwrap(TextMateRegex("^x").free)
        XCTAssertNil(caret.firstMatch(in: "ax", options: TextMateRegex.options, range: NSRange(location: 1, length: 1)))
    }

    func testBackReferencesAreFilledInEscaped() {
        XCTAssertEqual(TextMateRegex.resolvingBackReferences(#"\1\)"#, captures: ["<<EOF", "E.F"]), #"E\.F\)"#)
        XCTAssertTrue(TextMateRegex.hasBackReferences(#"^\1$"#))
        XCTAssertFalse(TextMateRegex.hasBackReferences(#"\d+"#))
    }

    /// Every pattern of every grammar shipped, compiled: those ICU refuses
    /// never match. A few may; a grammar losing many would colour wrongly.
    func testNearlyEveryPatternOfEveryGrammarCompiles() throws {
        let manifest = try XCTUnwrap(Bundle.main.url(forResource: "Grammars", withExtension: "json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        let scopes = (json["grammars"] as? [[String: Any]] ?? []).compactMap { $0["scope"] as? String }
        XCTAssertGreaterThan(scopes.count, 70)
        var total = 0
        var failed: [String: [String]] = [:]
        for scope in scopes {
            let url = try XCTUnwrap(Bundle.main.url(forResource: scope, withExtension: "json"), scope)
            let grammar = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)))
            func walk(_ value: Any) {
                if let dictionary = value as? [String: Any] {
                    for (key, inner) in dictionary {
                        if ["match", "begin", "end", "while"].contains(key), let source = inner as? String {
                            total += 1
                            let source = TextMateRegex.hasBackReferences(source)
                                ? TextMateRegex.resolvingBackReferences(source, captures: Array(repeating: "x", count: 10)) : source
                            let regex = TextMateRegex(source)
                            if regex.anchored == nil || regex.free == nil { failed[scope, default: []].append(source) }
                        } else {
                            walk(inner)
                        }
                    }
                } else if let array = value as? [Any] {
                    array.forEach(walk)
                }
            }
            walk(grammar)
        }
        let count = failed.values.map(\.count).reduce(0, +)
        for (scope, sources) in failed.sorted(by: { $0.key < $1.key }) {
            print("TextMate: \(scope) \(sources.count) refused, e.g. \(sources.prefix(2))")
        }
        print("TextMate: \(count) of \(total) patterns refused")
        XCTAssertLessThan(Double(count), Double(total) * 0.01, "more than 1% of the patterns refused")
    }

    // MARK: - Languages

    func testTheLanguageOfAFile() {
        XCTAssertEqual(registry.language(for: URL(fileURLWithPath: "/x/main.swift"))?.id, "swift")
        XCTAssertEqual(registry.language(for: URL(fileURLWithPath: "/x/Makefile"))?.id, "makefile")
        XCTAssertEqual(registry.language(for: URL(fileURLWithPath: "/x/App.TSX"))?.id, "typescriptreact")
        XCTAssertEqual(registry.language(for: URL(fileURLWithPath: "/x/run"), firstLine: "#!/usr/bin/env python3")?.id, "python")
        XCTAssertEqual(registry.language(for: URL(fileURLWithPath: "/x/Dockerfile"))?.id, "dockerfile")
        XCTAssertNil(registry.language(for: URL(fileURLWithPath: "/x/notes.unknownext")))
    }

    // MARK: - Tokens

    private func roles(_ text: String, _ language: String) throws -> [(String, SyntaxColouring.Role)] {
        let colourer = try XCTUnwrap(SourceColourer(language: XCTUnwrap(registry.language(id: language))))
        let ns = text as NSString
        return colourer.colour(text).spans.map { (ns.substring(with: $0.range), $0.role) }
    }

    func testSwiftIsColoured() throws {
        let found = try roles("""
            import Foundation
            // a comment
            struct Point { let x = 42; func moved() -> String { "here \\(x)" } }
            """, "swift")
        func role(of text: String) -> SyntaxColouring.Role? { found.first { $0.0 == text }?.1 }
        XCTAssertEqual(role(of: "import"), .keyword)
        XCTAssertEqual(role(of: "// a comment"), .comment)
        XCTAssertEqual(role(of: "struct"), .keyword)
        XCTAssertEqual(role(of: "42"), .number)
        XCTAssertEqual(role(of: "moved"), .function)
        XCTAssertTrue(found.contains { $0.1 == .string && $0.0.contains("here") })
    }

    func testRegionsGoAcrossLinesAndEmbeddedLanguagesAreColoured() throws {
        let found = try roles("""
            <html>
            <!-- a
                 comment -->
            <style>body { color: red; }</style>
            <script>let n = 1;</script>
            </html>
            """, "html")
        XCTAssertTrue(found.contains { $0.0.contains("comment -->") && $0.1 == .comment }, "\(found)")
        XCTAssertTrue(found.contains { $0.0 == "html" && $0.1 == .tag })
        XCTAssertTrue(found.contains { $0.0 == "let" && $0.1 == .keyword }, "JavaScript in it")
        XCTAssertTrue(found.contains { $0.0 == "color" && $0.1 == .key || $0.0 == "color" && $0.1 == .type }, "CSS in it: \(found)")
    }

    func testAHeredocEndsWhereItsOwnWordIs() throws {
        // The end pattern is made from what the begin pattern captured.
        let found = try roles("cat <<EOF\nnot code; ls\nEOF\nls -l\n", "shellscript")
        XCTAssertTrue(found.contains { $0.0.contains("not code") && $0.1 == .string }, "\(found)")
        XCTAssertFalse(found.contains { $0.0.contains("ls -l") && $0.1 == .string })
    }

    func testMarkdownWhileRegions() throws {
        let found = try roles("# Title\n\n> quoted\n> still\n\nplain `code` here\n", "markdown")
        XCTAssertTrue(found.contains { $0.0.contains("Title") && $0.1 == .keyword }, "\(found)")
        XCTAssertTrue(found.contains { $0.0.contains("still") && $0.1 == .comment }, "\(found)")
        XCTAssertTrue(found.contains { $0.0.contains("code") && $0.1 == .string })
    }

    // MARK: - After an edit

    func testColouringAgainAfterAnEditIsTheSameAsFromScratch() throws {
        let language = try XCTUnwrap(registry.language(id: "typescript"))
        var lines = (0..<300).map { "function f\($0)(a: number): string { return `n${a}` + \"\($0)\"; } // \($0)" }
        let colourer = try XCTUnwrap(SourceColourer(language: language))
        _ = colourer.colour(lines.joined(separator: "\n"))

        // Opening a comment in the middle changes everything after it…
        lines[150] = "/* an open comment"
        let edited = lines.joined(separator: "\n")
        let incremental = colourer.colour(edited)
        let fresh = try XCTUnwrap(SourceColourer(language: language)).colour(edited)
        XCTAssertEqual(incremental.spans.map(\.range), fresh.spans.map(\.range))
        XCTAssertEqual(incremental.spans.map(\.role), fresh.spans.map(\.role))
        // …and closing it puts it back.
        lines[150] = "let x = 1"
        lines.insert("const y = 'two'", at: 20)
        lines.append("export {}")
        let again = lines.joined(separator: "\n")
        let back = colourer.colour(again)
        let scratch = try XCTUnwrap(SourceColourer(language: language)).colour(again)
        XCTAssertEqual(back.spans.map(\.range), scratch.spans.map(\.range))
        XCTAssertEqual(back.spans.map(\.role), scratch.spans.map(\.role))
        XCTAssertTrue(back.complete)
    }

    func testALargeFileIsColouredInReasonableTime() throws {
        let language = try XCTUnwrap(registry.language(id: "typescript"))
        // The tests are a debug build, several times slower than the app.
        let text = (0..<400).map { "export class C\($0) extends Base<string> { private n = \($0); get v(): string { return `${this.n}`; } }" }
            .joined(separator: "\n")
        let colourer = try XCTUnwrap(SourceColourer(language: language))
        let start = Date()
        let result = colourer.colour(text, budget: 30)
        let took = Date().timeIntervalSince(start)
        print("TextMate: 400 TypeScript lines in \(took) s")
        XCTAssertTrue(result.complete)
        XCTAssertLessThan(took, 20)
        let one = Date()
        _ = colourer.colour(text.replacingOccurrences(of: "C1500 ", with: "D1500 "))
        print("TextMate: recoloured after an edit in \(Date().timeIntervalSince(one)) s")
        XCTAssertLessThan(Date().timeIntervalSince(one), 0.5, "an edit recolours a few lines, not all")
    }

    func testEveryLanguageColoursASampleWithoutHanging() throws {
        let sample = "x = 1 # c\n\"s\" 'q' {a: [1, 2.5e3]} <tag a=\"b\">\nfunction f() { return null; }\n"
        for language in registry.languages {
            let colourer = try XCTUnwrap(SourceColourer(language: language), language.id)
            let start = Date()
            _ = colourer.colour(sample, budget: 5)
            XCTAssertLessThan(Date().timeIntervalSince(start), 2, language.id)
        }
    }

    // MARK: - Where it shows

    func testTheQuickLookPageIsColouredAndNumbered() throws {
        let language = try XCTUnwrap(registry.language(id: "python"))
        let url = URL(fileURLWithPath: "/tmp/tool.py")
        let html = SourceReport.html(text: "def f(x):\n    return \"<b>\" # done\n", url: url, language: language,
                                     size: 40, truncated: false)
        XCTAssertTrue(html.contains("<span class=keyword>def</span>"), html)
        XCTAssertTrue(html.contains("&lt;b&gt;"), "the text is escaped")
        XCTAssertTrue(html.contains("<span class=comment>"))
        XCTAssertTrue(html.contains("<td class=n>2</td>"))
        XCTAssertTrue(html.contains("Python, 2 lines"))
        let plain = SourceReport.html(text: "def f(): pass\n", url: url, language: language, size: 14,
                                      truncated: true, coloured: false)
        XCTAssertFalse(plain.contains("<span class="))
        XCTAssertTrue(plain.contains("are shown"))
    }

    @MainActor
    func testTextEditColoursSourceCodeByItsGrammar() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TextMateEdit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = TextEditDocument(url: folder.appendingPathComponent("main.go"))
        let controller = TextEditController(document: document)
        controller.loaded(text: "package main\n\nfunc main() { println(\"hi\") } // go\n")
        let deadline = Date().addingTimeInterval(10)
        while !controller.colouringIsCurrent || controller.colouring.spans.isEmpty {
            guard Date() < deadline else { return XCTFail("never coloured") }
            try await Task.sleep(for: .milliseconds(50))
        }
        let text = controller.textView.string as NSString
        let found = controller.colouring.spans.map { (text.substring(with: $0.range), $0.role) }
        XCTAssertTrue(found.contains { $0.0 == "func" && $0.1 == .keyword }, "\(found)")
        XCTAssertTrue(found.contains { $0.0.contains("hi") && $0.1 == .string })
        XCTAssertTrue(found.contains { $0.0 == "// go" && $0.1 == .comment })
    }
}
