import XCTest
@testable import Diptych

/// Text Edit's editing by lines, pairs and indentation. `|` marks the caret;
/// `[` and `]` a selection.
final class LineEditingTests: XCTestCase {

    private func split(_ marked: String) -> (NSString, NSRange) {
        var text = marked
        if let open = text.firstIndex(of: "["), let close = text.firstIndex(of: "]") {
            let start = text.distance(from: text.startIndex, to: open)
            let length = text.distance(from: open, to: close) - 1
            text.remove(at: close)
            text.remove(at: open)
            return (text as NSString, NSRange(location: start, length: length))
        }
        let caret = (text as NSString).range(of: "|").location
        return (text.replacingOccurrences(of: "|", with: "") as NSString, NSRange(location: caret, length: 0))
    }

    private func apply(_ edit: LineEditing.Edit?, to text: NSString) -> String {
        guard let edit else { return "nil" }
        let changed = NSMutableString(string: text)
        changed.replaceCharacters(in: edit.range, with: edit.replacement)
        if edit.selection.length == 0 {
            changed.insert("|", at: edit.selection.location)
        } else {
            changed.insert("]", at: NSMaxRange(edit.selection))
            changed.insert("[", at: edit.selection.location)
        }
        return changed as String
    }

    private func move(_ marked: String, up: Bool) -> String {
        let (text, selection) = split(marked)
        return apply(LineEditing.move(selection, in: text, up: up), to: text)
    }

    func testMovingLines() {
        XCTAssertEqual(move("a\nb|b\nc\n", up: true), "b|b\na\nc\n")
        XCTAssertEqual(move("a\nb|b\nc\n", up: false), "a\nc\nb|b\n")
        XCTAssertEqual(move("a\nb\nc|", up: true), "a\nc|\nb")
        XCTAssertEqual(move("a|\nb", up: false), "b\na|")
        XCTAssertEqual(move("a|\nb", up: true), "nil")
        XCTAssertEqual(move("a\nb|", up: false), "nil")
        XCTAssertEqual(move("1\n[2\n3]\n4\n", up: true), "[2\n3]\n1\n4\n")
        XCTAssertEqual(move("1\n[2\n3\n]4\n", up: false), "1\n4\n[2\n3\n]", "a selection to a line's start")
    }

    private func delete(_ marked: String) -> String {
        let (text, selection) = split(marked)
        return apply(LineEditing.delete(selection, in: text), to: text)
    }

    func testDeletingLines() {
        XCTAssertEqual(delete("abc\nde|f\nghij\n"), "abc\ngh|ij\n")
        XCTAssertEqual(delete("abc\ndefgh|\nij\n"), "abc\nij|\n", "the column, as far as the line goes")
        XCTAssertEqual(delete("abc\nd|ef"), "a|bc")
        XCTAssertEqual(delete("only|"), "|")
        XCTAssertEqual(delete("[a\nb]\nc"), "|c")
    }

    func testTheWholeLineIsCopiedAndPastedAbove() {
        let text = "one\ntwo\nthree" as NSString
        XCTAssertEqual(LineEditing.wholeLine(at: 5, in: text).text, "two\n")
        XCTAssertEqual(LineEditing.wholeLine(at: 10, in: text).text, "three\n")
        XCTAssertEqual(apply(LineEditing.pasteLine("new\n", at: 5, in: text), to: text), "one\nnew\nt|wo\nthree")
        XCTAssertEqual(apply(LineEditing.pasteLine("new\n", at: 9, in: "one\nthree" as NSString),
                             to: "one\nthree" as NSString), "one\nnew\nthree|")
    }

    private func shift(_ marked: String, out: Bool, indent: LineEditing.Indent = .two) -> String {
        let (text, selection) = split(marked)
        return apply(LineEditing.shift(selection, in: text, by: indent, outwards: out), to: text)
    }

    func testShiftingLines() {
        XCTAssertEqual(shift("[a\nb]\n", out: false), "[  a\n  b]\n", "whole lines stay whole")
        XCTAssertEqual(shift("  [a\n    b]\n", out: true), "[a\n  b]\n")
        XCTAssertEqual(shift("\t|a", out: true, indent: .init(tabs: true, width: 4)), "|a")
        XCTAssertEqual(shift("|a", out: true), "nil")
        XCTAssertEqual(shift("[a\n\nb]", out: false), "[  a\n\n  b]", "empty lines stay empty")
    }

    private func newline(_ marked: String, _ format: TextFormat?) -> String {
        let (text, selection) = split(marked)
        return apply(LineEditing.newline(at: selection, in: text, format: format, indent: .two), to: text)
    }

    func testReturnIndents() {
        XCTAssertEqual(newline("  \"a\": 1,|", .json), "  \"a\": 1,\n  |")
        XCTAssertEqual(newline("{|}", .json), "{\n  |\n}")
        XCTAssertEqual(newline("  \"a\": [|", .json), "  \"a\": [\n    |")
        XCTAssertEqual(newline("<a>|</a>", .xml), "<a>\n  |\n</a>")
        XCTAssertEqual(newline("  <a x=\"1\">|", .xml), "  <a x=\"1\">\n    |")
        XCTAssertEqual(newline("<a/>|", .xml), "<a/>\n|")
        XCTAssertEqual(newline("<a>x</a>|", .xml), "<a>x</a>\n|")
        XCTAssertEqual(newline("key:|", .yaml), "key:\n  |")
        XCTAssertEqual(newline("key: value|", .yaml), "key: value\n|")
        XCTAssertEqual(newline("  plain|", nil), "  plain\n  |")
        XCTAssertEqual(newline("a| b", nil), "a\n|b", "the space does not move down")
    }

    private func type(_ typed: String, _ marked: String, _ format: TextFormat?, pairs: Bool = true) -> String {
        let (text, selection) = split(marked)
        return apply(LineEditing.typing(typed, at: selection, in: text, format: format, indent: .two, pairs: pairs),
                     to: text)
    }

    func testPairs() {
        XCTAssertEqual(type("{", "|", .json), "{|}")
        XCTAssertEqual(type("[", "a: |", .yaml), "a: [|]")
        XCTAssertEqual(type("\"", "|", .json), "\"|\"")
        XCTAssertEqual(type("\"", "\"abc|\"", .json), "\"abc\"|", "typed over")
        XCTAssertEqual(type("}", "{|}", .json), "{}|")
        XCTAssertEqual(type("\"", "abc|", .json), "nil", "after a word")
        XCTAssertEqual(type("{", "|x", .json), "nil", "something follows")
        XCTAssertEqual(type("\"", "[abc]", .json), "\"[abc]\"", "around the selection")
        XCTAssertEqual(type("\"", "<a x=|", .xml), "<a x=\"|\"")
        XCTAssertEqual(type("\"", "<a>|", .xml), "nil", "text, not a tag")
        XCTAssertEqual(type("{", "|", nil), "nil", "plain text")
        XCTAssertEqual(type("{", "|", .json, pairs: false), "nil")
        XCTAssertEqual(type("}", "{\n    |", .json), "{\n  }|", "a level out")
    }

    func testDeletingAnEmptyPair() {
        let (text, selection) = split("{|}")
        XCTAssertEqual(apply(LineEditing.deletingPair(at: selection, in: text, pairs: true), to: text), "|")
        let (other, at) = split("{a|}")
        XCTAssertNil(LineEditing.deletingPair(at: at, in: other, pairs: true))
    }

    private func comment(_ marked: String, _ format: TextFormat) -> String {
        let (text, selection) = split(marked)
        return apply(LineEditing.toggleComment(selection, in: text, format: format), to: text)
    }

    func testComments() {
        XCTAssertEqual(comment("a: 1|\n", .yaml), "# a: 1|\n")
        XCTAssertEqual(comment("# a: 1|\n", .yaml), "a: 1|\n")
        XCTAssertEqual(comment("[  a: 1\n    b: 2]", .yaml), "[  # a: 1\n  #   b: 2]")
        XCTAssertEqual(comment("  <a/>|", .xml), "  [<!-- <a/> -->]")
        XCTAssertEqual(comment("  <!-- <a/> -->|", .xml), "  [<a/>]")
        XCTAssertEqual(comment("{}|", .json), "nil")
    }
}

final class StructuredFormatterTests: XCTestCase {

    private func format(_ text: String, _ format: TextFormat, _ change: (inout TextStyle) -> Void = { _ in })
    -> String {
        var style = TextStyle()
        change(&style)
        switch StructuredFormatter.format(text, as: format, style: style) {
        case .success(let text): return text
        case .failure(let failure): return "\(failure)"
        }
    }

    func testJSON() {
        XCTAssertEqual(format(#"{"b":1,"a":[1,2.50,{}],"c":{"d":null}}"#, .json), """
        {
          "b": 1,
          "a": [
            1,
            2.50,
            {}
          ],
          "c": {
            "d": null
          }
        }
        """)
        XCTAssertEqual(format("[1,2]\n", .json) { $0.indents["json"] = .init(tabs: true, width: 4) },
                       "[\n\t1,\n\t2\n]\n")
        XCTAssertEqual(format(#"{"a":[1,"x"]}"#, .json) { $0.jsonShortArraysOnOneLine = true },
                       "{\n  \"a\": [1, \"x\"]\n}")
        XCTAssertEqual(format(#"{"a":1}"#, .json) { $0.jsonSpaceBeforeColon = true }, "{\n  \"a\" : 1\n}")
        XCTAssertEqual(format("{\"a\":1,\n\n\n\"b\":2}", .json), "{\n  \"a\": 1,\n\n  \"b\": 2\n}",
                       "one empty line kept")
        XCTAssertTrue(format("{\"a\":}", .json).hasPrefix("invalid"))
        XCTAssertEqual(try StructuredFormatter.compact("{\n  \"a\": [1, 2]\n}\n").get(), "{\"a\":[1,2]}\n")
    }

    func testXML() {
        XCTAssertEqual(format("<?xml version=\"1.0\"?><r><a x=\"1\"  y='2'/><b>text  here</b><c><d/></c>"
                              + "<m>mixed <i>it</i> stays</m></r>\n", .xml), """
        <?xml version="1.0"?>
        <r>
            <a x="1" y='2'/>
            <b>text  here</b>
            <c>
                <d/>
            </c>
            <m>mixed <i>it</i> stays</m>
        </r>

        """)
        XCTAssertEqual(format("<r><a x=\"1\" y=\"2\"/></r>", .xml) {
            $0.xmlAttributesOnLines = true
            $0.xmlSpaceBeforeSlash = true
            $0.indents["xml"] = .two
        }, "<r>\n  <a\n    x=\"1\"\n    y=\"2\" />\n</r>")
        XCTAssertEqual(format("<r><!-- c --><a/></r>", .xml) { $0.indents["xml"] = .two },
                       "<r>\n  <!-- c -->\n  <a/>\n</r>")
        XCTAssertEqual(format("<r><s><![CDATA[\nx < y\n]]></s></r>", .xml) { $0.indents["xml"] = .two },
                       "<r>\n  <s><![CDATA[\nx < y\n]]></s>\n</r>", "CDATA is text: nothing added to it")
        XCTAssertEqual(format("a: 1", .yaml), "notFormattable")
    }
}
