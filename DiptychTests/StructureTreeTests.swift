import XCTest
@testable import Diptych

/// Text Edit's tree: what it reads, and what each of its edits does to the text.
final class StructureTreeTests: XCTestCase {

    private func editor(_ text: String, _ format: TextFormat, indent: LineEditing.Indent? = nil) throws
    -> StructureEditor {
        var style = TextStyle()
        if let indent { style.indents[format.rawValue] = indent }
        let root = try XCTUnwrap(StructureTree.parse(text as NSString, as: format), "parsed")
        return StructureEditor(text: text as NSString, format: format, root: root, style: style)
    }

    private func applied(_ edit: TreeEdit?, to text: String) -> String {
        guard let edit else { return "nil" }
        let changed = NSMutableString(string: text)
        for change in edit.changes.sorted(by: { $0.range.location > $1.range.location }) {
            changed.replaceCharacters(in: change.range, with: change.text)
        }
        return changed as String
    }

    /// A move as the tree does it: out, read again, in.
    private func move(_ text: String, _ format: TextFormat, _ path: [Int], into parent: [Int], at index: Int)
    throws -> String {
        let before = try editor(text, format)
        XCTAssertTrue(before.canMove(path, into: parent, at: index))
        let copied = try XCTUnwrap(before.copy(path))
        let removed = applied(before.delete(path), to: text)
        let (target, at) = TreeMoves.adjust(parent: parent, index: index, afterRemoving: path)
        return applied(try editor(removed, format).insert(.copy(copied), into: target, at: at), to: removed)
    }

    // MARK: - JSON

    let json = """
    {
      "name": "Diptych",
      "tags": ["a", "b"],
      "window": {
        "width": 800,
        "on": true
      }
    }
    """

    func testJSONIsRead() throws {
        let root = try XCTUnwrap(StructureTree.parse(json as NSString, as: .json))
        let object = root.children[0]
        XCTAssertEqual(object.kind, .object)
        XCTAssertEqual(object.children.map(\.key), ["name", "tags", "window"])
        XCTAssertEqual(object.children[0].value, "Diptych")
        XCTAssertEqual(object.children[1].children.map(\.value), ["a", "b"])
        XCTAssertEqual(object.children[2].children.map(\.kind), [.number, .boolean])
        XCTAssertNil(StructureTree.parse("{\"a\":}" as NSString, as: .json))
    }

    func testJSONRenameAndValues() throws {
        let tree = try editor(json, .json)
        XCTAssertTrue(applied(tree.rename([0, 0], to: "title"), to: json).contains("\"title\": \"Diptych\""))
        XCTAssertTrue(applied(tree.setValue([0, 0], to: "say \"hi\""), to: json)
                        .contains(#""name": "say \"hi\"""#))
        XCTAssertTrue(applied(tree.setValue([0, 2, 0], to: "1.5e3"), to: json).contains("\"width\": 1.5e3"))
        XCTAssertNil(tree.setValue([0, 2, 0], to: "wide"), "not a number")
        XCTAssertTrue(applied(tree.setValue([0, 2, 1], to: "no"), to: json).contains("\"on\": false"))
        XCTAssertFalse(tree.canRename([0, 1, 0]), "an array's element has no key")
        XCTAssertTrue(applied(tree.changeType([0, 2], to: .array), to: json).contains("\"window\": []"))
    }

    func testJSONDelete() throws {
        let tree = try editor(json, .json)
        XCTAssertEqual(applied(tree.delete([0, 0]), to: json), """
        {
          "tags": ["a", "b"],
          "window": {
            "width": 800,
            "on": true
          }
        }
        """)
        XCTAssertEqual(applied(tree.delete([0, 2]), to: json), """
        {
          "name": "Diptych",
          "tags": ["a", "b"]
        }
        """)
        XCTAssertTrue(applied(tree.delete([0, 1, 1]), to: json).contains("\"tags\": [\"a\"]"))
        let single = "{\"a\": [1]}"
        XCTAssertEqual(applied(try editor(single, .json).delete([0, 0, 0]), to: single), "{\"a\": []}")
        XCTAssertFalse(tree.canDelete([0]), "the document's value")
    }

    func testJSONAdd() throws {
        let tree = try editor(json, .json)
        XCTAssertEqual(applied(tree.insert(.new(.number, key: "height", value: "600"), into: [0, 2], at: 2),
                               to: json), """
        {
          "name": "Diptych",
          "tags": ["a", "b"],
          "window": {
            "width": 800,
            "on": true,
            "height": 600
          }
        }
        """)
        XCTAssertTrue(applied(tree.insert(.new(.string, key: nil, value: "z"), into: [0, 1], at: 0), to: json)
                        .contains(#""tags": ["z", "a", "b"]"#))
        let added = applied(tree.insert(.new(.string, key: "name", value: ""), into: [0], at: 0), to: json)
        XCTAssertTrue(added.hasPrefix("{\n  \"name 2\": \"\",\n  \"name\""), added)
        let empty = "{\n  \"a\": {}\n}"
        XCTAssertEqual(applied(try editor(empty, .json).insert(.new(.object, key: "b", value: nil), into: [0, 0],
                                                               at: 0), to: empty),
                       "{\n  \"a\": {\n    \"b\": {}\n  }\n}")
    }

    func testJSONMove() throws {
        XCTAssertEqual(try move(json, .json, [0, 2], into: [0], at: 0), """
        {
          "window": {
            "width": 800,
            "on": true
          },
          "name": "Diptych",
          "tags": ["a", "b"]
        }
        """)
        XCTAssertTrue(try move(json, .json, [0, 2, 0], into: [0, 1], at: 2)
                        .contains(#""tags": ["a", "b", 800]"#), "the key goes in an array")
        XCTAssertEqual(try move(json, .json, [0, 0], into: [0], at: 3), """
        {
          "tags": ["a", "b"],
          "window": {
            "width": 800,
            "on": true
          },
          "name": "Diptych"
        }
        """)
        let tree = try editor(json, .json)
        XCTAssertFalse(tree.canMove([0, 2], into: [0, 2], at: 0), "not into itself")
    }

    // MARK: - XML

    let xml = """
    <?xml version="1.0"?>
    <config version="2">
        <name>Diptych</name>
        <!-- windows -->
        <window width="800" height="600"/>
        <empty></empty>
    </config>
    """

    func testXMLIsRead() throws {
        let root = try XCTUnwrap(StructureTree.parse(xml as NSString, as: .xml))
        XCTAssertEqual(root.children.map(\.kind), [.instruction, .element])
        let config = root.children[1]
        XCTAssertEqual(config.attributeCount, 1)
        XCTAssertEqual(config.children.map(\.kind), [.attribute, .element, .comment, .element, .element])
        XCTAssertEqual(config.children[1].value, "Diptych", "text only: its value")
        XCTAssertTrue(config.children[1].children.isEmpty)
        XCTAssertEqual(config.children[2].value, "windows")
        XCTAssertEqual(config.children[3].children.map(\.value), ["800", "600"])
    }

    func testXMLEdits() throws {
        let tree = try editor(xml, .xml)
        XCTAssertTrue(applied(tree.rename([1, 1], to: "title"), to: xml).contains("<title>Diptych</title>"))
        XCTAssertNil(tree.rename([1, 1], to: "two words"))
        XCTAssertTrue(applied(tree.setValue([1, 1], to: "a < b"), to: xml).contains("<name>a &lt; b</name>"))
        XCTAssertTrue(applied(tree.setValue([1, 3, 0], to: "\"wide\""), to: xml)
                        .contains(#"width="&quot;wide&quot;""#))
        XCTAssertTrue(applied(tree.setValue([1, 4], to: "now"), to: xml).contains("<empty>now</empty>"))
        XCTAssertTrue(applied(tree.setValue([1, 3], to: "x"), to: xml).contains(#"height="600">x</window>"#),
                      "<a/> opened")
        XCTAssertEqual(applied(tree.delete([1, 2]), to: xml), xml.replacingOccurrences(of: "\n    <!-- windows -->", with: ""))
        XCTAssertTrue(applied(tree.delete([1, 3, 1]), to: xml).contains(#"<window width="800"/>"#))
        XCTAssertTrue(applied(tree.insert(.new(.attribute, key: "id", value: "w"), into: [1, 3], at: 2), to: xml)
                        .contains(#"<window width="800" height="600" id="w"/>"#))
        XCTAssertTrue(applied(tree.insert(.new(.element, key: "pane", value: nil), into: [1, 3], at: 2), to: xml)
                        .contains("<window width=\"800\" height=\"600\">\n        <pane></pane>\n    </window>"))
        XCTAssertTrue(applied(tree.insert(.new(.element, key: "first", value: nil), into: [1], at: 1), to: xml)
                        .contains("<config version=\"2\">\n    <first></first>\n    <name>"))
        XCTAssertTrue(applied(tree.insert(.new(.comment, key: nil, value: "end"), into: [1], at: 5), to: xml)
                        .contains("<empty></empty>\n    <!-- end -->\n</config>"))
    }

    func testXMLMove() throws {
        let moved = try move(xml, .xml, [1, 3], into: [1], at: 1)
        XCTAssertTrue(moved.contains("<config version=\"2\">\n    <window width=\"800\" height=\"600\"/>\n    <name>"),
                      moved)
        let tree = try editor(xml, .xml)
        XCTAssertFalse(tree.canMove([1, 0], into: [1], at: 3), "an attribute among the elements")
        XCTAssertTrue(tree.canMove([1, 0], into: [1, 3], at: 0))
        XCTAssertTrue(try move(xml, .xml, [1, 0], into: [1, 3], at: 2)
                        .contains(#"<window width="800" height="600" version="2"/>"#))
    }

    /// An element made an attribute or the other way, as the tree does it.
    private func converted(_ text: String, _ path: [Int], named name: String? = nil) throws -> String {
        let conversion = try XCTUnwrap(try editor(text, .xml).conversion(path, named: name), "convertible")
        let removed = applied(conversion.removal, to: text)
        return applied(try editor(removed, .xml).insert(conversion.fragment, into: conversion.parent,
                                                         at: conversion.index), to: removed)
    }

    func testXMLElementAndAttribute() throws {
        let tree = try editor(xml, .xml)
        XCTAssertTrue(tree.canMakeAttribute([1, 1]), "<name>Diptych</name>")
        XCTAssertFalse(tree.canMakeAttribute([1, 3]), "has attributes")
        XCTAssertFalse(tree.canMakeAttribute([1, 2]), "a comment")
        XCTAssertTrue(tree.canMakeElement([1, 0]))
        XCTAssertFalse(tree.canMakeElement([1, 1]))

        let attribute = try converted(xml, [1, 1])
        XCTAssertTrue(attribute.contains(#"<config version="2" name="Diptych">"#), attribute)
        XCTAssertFalse(attribute.contains("<name>"))
        XCTAssertTrue(try converted(xml, [1, 4], named: "blank").contains(#"version="2" blank="""#), "<empty></empty>")

        let element = try converted(xml, [1, 3, 1])
        XCTAssertTrue(element.contains("<window width=\"800\">\n        <height>600</height>\n    </window>"), element)
        let first = try converted(xml, [1, 0], named: "release")
        XCTAssertTrue(first.contains("<config>\n    <release>2</release>\n    <name>"), first)

        let taken = "<a x=\"1\"><b><x>2</x></b><x>3</x></a>"
        XCTAssertFalse(try editor(taken, .xml).canMakeAttribute([0, 2]), "a already has x")
        XCTAssertNil(try editor(taken, .xml).conversion([0, 1, 0], named: "not a name"))
        XCTAssertTrue(try converted("<a><v>a &lt; \"b\"</v></a>", [0, 0]).contains(#"<a v="a &lt; &quot;b&quot;">"#))
    }

    // MARK: - YAML

    let yaml = """
    # settings
    name: Diptych
    tags:
      - a
      - b
    window:
      width: 800   # pixels
      on: true
    panes:
      - path: /tmp
        sort: name
      - path: ~
    """

    func testYAMLIsRead() throws {
        let root = try XCTUnwrap(StructureTree.parse(yaml as NSString, as: .yaml))
        let map = root.children[0]
        XCTAssertEqual(map.kind, .mapping)
        XCTAssertEqual(map.children.map(\.key), ["name", "tags", "window", "panes"])
        XCTAssertEqual(map.children[1].children.map(\.value), ["a", "b"])
        XCTAssertEqual(map.children[2].children[0].value, "800")
        XCTAssertEqual(map.children[3].children[0].kind, .mapping, "compact")
        XCTAssertEqual(map.children[3].children[0].children.map(\.key), ["path", "sort"])
        XCTAssertNil(StructureTree.parse("a: 1\n---\nb: 2\n" as NSString, as: .yaml), "two documents")
        let quoted = try XCTUnwrap(StructureTree.parse("'a b': \"x\\ny\"\nc: |\n  one\n  two\n" as NSString,
                                                       as: .yaml))
        XCTAssertEqual(quoted.children[0].children.map(\.key), ["a b", "c"])
        XCTAssertEqual(quoted.children[0].children.map(\.value), ["x\ny", "one\ntwo"])
    }

    func testYAMLDirectivesAndFlowOverLines() throws {
        let text = "%YAML 1.2\n%TAG !e! tag:example.com,2026:\n---\nlist: [\n  a,\n  b,\n]\nnext: 1\n"
        let root = try XCTUnwrap(StructureTree.parse(text as NSString, as: .yaml))
        XCTAssertEqual(root.children[0].children.map(\.key), ["list", "next"])
        XCTAssertEqual(root.children[0].children[0].value, "[ a, b, ]")
        XCTAssertNil(StructureTree.yamlStop(text as NSString))
        XCTAssertEqual(StructureTree.yamlStop("a: 1\n? b\n: 2\n" as NSString), 2, "explicit keys are not read")
        XCTAssertEqual(StructureTree.yamlStop("a: [1,\n  2\n" as NSString), 2, "never closed: the last line")
    }

    func testYAMLEdits() throws {
        let tree = try editor(yaml, .yaml)
        XCTAssertTrue(applied(tree.rename([0, 0], to: "title"), to: yaml).contains("\ntitle: Diptych\n"))
        XCTAssertTrue(applied(tree.setValue([0, 2, 0], to: "1024"), to: yaml).contains("width: 1024   # pixels"))
        XCTAssertTrue(applied(tree.setValue([0, 0], to: "a: b"), to: yaml).contains("name: \"a: b\""),
                      "quoted where plain would not read back")
        XCTAssertEqual(applied(tree.delete([0, 1]), to: yaml),
                       yaml.replacingOccurrences(of: "tags:\n  - a\n  - b\n", with: ""))
        XCTAssertTrue(applied(tree.delete([0, 3, 0, 0]), to: yaml).contains("panes:\n  - sort: name\n  - path: ~"),
                      "the first of a compact mapping")
        XCTAssertTrue(applied(tree.delete([0, 2, 1]), to: yaml).contains("width: 800   # pixels\npanes:"))
        XCTAssertTrue(applied(tree.insert(.new(.scalar, key: "height", value: "600"), into: [0, 2], at: 2),
                              to: yaml).contains("  on: true\n  height: 600\npanes:"))
        XCTAssertTrue(applied(tree.insert(.new(.scalar, key: nil, value: "c"), into: [0, 1], at: 0), to: yaml)
                        .contains("tags:\n  - c\n  - a\n"))
        let compact = applied(tree.insert(.new(.scalar, key: "x", value: "1"), into: [0, 3, 1], at: 1), to: yaml)
        XCTAssertTrue(compact.contains("  - path: ~\n    x: 1"), compact)
        let empty = "a: {}\nb: []\n"
        let small = try editor(empty, .yaml)
        XCTAssertEqual(applied(small.insert(.new(.scalar, key: "k", value: "v"), into: [0, 0], at: 0), to: empty),
                       "a:\n  k: v\nb: []\n")
        XCTAssertEqual(applied(small.insert(.new(.scalar, key: nil, value: "v"), into: [0, 1], at: 0), to: empty),
                       "a: {}\nb:\n  - v\n")
        XCTAssertEqual(applied(tree.changeType([0, 0], to: .sequence), to: yaml).components(separatedBy: "\n")[1],
                       "name: []")
    }

    func testYAMLMove() throws {
        XCTAssertTrue(try move(yaml, .yaml, [0, 2], into: [0], at: 0).hasPrefix(
            "# settings\nwindow:\n  width: 800   # pixels\n  on: true\nname: Diptych\n"))
        let into = try move(yaml, .yaml, [0, 2], into: [0, 1], at: 2)
        XCTAssertTrue(into.contains("tags:\n  - a\n  - b\n  - width: 800   # pixels\n    on: true\npanes:"), into)
        let out = try move(yaml, .yaml, [0, 3, 0], into: [0], at: 0)
        XCTAssertTrue(out.hasPrefix("# settings\nkey:\n  path: /tmp\n  sort: name\nname:"), out)
    }

    // MARK: - Plist

    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
    \t<!-- a comment the tree passes over -->
    \t<key>name</key>
    \t<string>Diptych</string>
    \t<key>count</key>
    \t<integer>3</integer>
    \t<key>list</key>
    \t<array>
    \t\t<true/>
    \t</array>
    \t<key>empty</key>
    \t<dict/>
    </dict>
    </plist>

    """

    private func object(_ text: String) throws -> [String: Any] {
        let read = try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)
        return try XCTUnwrap(read as? [String: Any], "a dictionary:\n\(text)")
    }

    func testAPlistIsATreeOfKeysAndValues() throws {
        let edit = try editor(plist, .plist)
        let top = try XCTUnwrap(edit.find([0]))
        XCTAssertEqual(top.kind, .dictionary)
        XCTAssertEqual(top.children.map(\.key), ["name", "count", "list", "empty"])
        XCTAssertEqual(top.children.map(\.kind), [.string, .integer, .array, .dictionary])
        XCTAssertEqual(edit.find([0, 0])?.value, "Diptych")
        XCTAssertEqual(edit.find([0, 2, 0])?.kind, .boolean)
        XCTAssertEqual(edit.find([0, 2, 0])?.value, "true")
        XCTAssertFalse(edit.canDelete([0]), "the top value stays")
        XCTAssertNil(StructureTree.parse("<plist><dict><key>a</key></dict></plist>" as NSString, as: .plist),
                     "a key without its value is no plist")
    }

    func testPlistKeysAndValuesAreEditedInTheirElements() throws {
        let edit = try editor(plist, .plist)
        XCTAssertTrue(applied(edit.rename([0, 0], to: "title & more"), to: plist)
            .contains("\t<key>title &amp; more</key>\n\t<string>Diptych</string>"))
        XCTAssertNil(edit.rename([0, 0], to: "count"), "a key the dictionary has")
        XCTAssertNil(edit.setValue([0, 1], to: "three"), "no integer")
        XCTAssertEqual(try object(applied(edit.setValue([0, 1], to: "42"), to: plist))["count"] as? Int, 42)
        XCTAssertEqual(try object(applied(edit.changeType([0, 1], to: .string), to: plist))["count"] as? String, "3")
        XCTAssertEqual(try object(applied(edit.changeType([0, 1], to: .real), to: plist))["count"] as? Double, 3)
        XCTAssertEqual(try object(applied(edit.setValue([0, 2, 0], to: "no"), to: plist))["list"] as? [Bool], [false])
        XCTAssertNil(edit.setValue([0, 1], to: ""), "")
    }

    func testPlistNodesAreAddedDeletedAndMoved() throws {
        let edit = try editor(plist, .plist)
        let emptied = applied(edit.delete([0, 2, 0]), to: plist)
        XCTAssertTrue(emptied.contains("\t<key>list</key>\n\t<array/>\n"), emptied)

        let deleted = applied(edit.delete([0, 1]), to: plist)
        XCTAssertNil(try object(deleted)["count"])
        XCTAssertTrue(deleted.contains("\t<string>Diptych</string>\n\t<key>list</key>"), deleted)

        let intoEmpty = applied(edit.insert(.new(.string, key: nil, value: "x"), into: [0, 3], at: 0), to: plist)
        XCTAssertTrue(intoEmpty.contains("\t<key>empty</key>\n\t<dict>\n\t\t<key>key</key>\n\t\t<string>x</string>\n\t</dict>"),
                      intoEmpty)
        let atEnd = applied(edit.insert(.new(.integer, key: "n", value: "7"), into: [0], at: 4), to: plist)
        XCTAssertTrue(atEnd.contains("\t<dict/>\n\t<key>n</key>\n\t<integer>7</integer>\n</dict>"), atEnd)

        // From the dictionary into the array: the key stays behind.
        let moved = try move(plist, .plist, [0, 0], into: [0, 2], at: 0)
        let read = try object(moved)
        XCTAssertNil(read["name"])
        XCTAssertEqual((read["list"] as? [Any])?.first as? String, "Diptych", moved)
        // And back: a key is made for it.
        let back = try move(moved, .plist, [0, 1, 0], into: [0], at: 0)
        XCTAssertEqual(try object(back)["key"] as? String, "Diptych", back)
    }

    // MARK: - Paths

    func testPathsAreWrittenAsTheFormatsToolsWriteThem() throws {
        func path(_ text: String, _ format: TextFormat, _ at: [Int]) throws -> String? {
            let root = try XCTUnwrap(StructureTree.parse(text as NSString, as: format))
            return StructurePath.path(at, in: root, format: format)
        }
        let xml = "<?xml-stylesheet href=\"a\"?><a x=\"1\"><b/><c/><b>t</b><!--k--></a>"
        XCTAssertEqual(try path(xml, .xml, [1]), "/a")
        XCTAssertEqual(try path(xml, .xml, [1, 0]), "/a/@x")
        XCTAssertEqual(try path(xml, .xml, [1, 1]), "/a/b[1]")
        XCTAssertEqual(try path(xml, .xml, [1, 2]), "/a/c")
        XCTAssertEqual(try path(xml, .xml, [1, 3]), "/a/b[2]")
        XCTAssertEqual(try path(xml, .xml, [1, 4]), "/a/comment()")
        XCTAssertEqual(try path(xml, .xml, [0]), "/processing-instruction('xml-stylesheet')")

        let json = #"{"a": {"b c": [1, {"d": 2}], "it's": 0}}"#
        XCTAssertEqual(try path(json, .json, [0]), "$")
        XCTAssertEqual(try path(json, .json, [0, 0]), "$.a")
        XCTAssertEqual(try path(json, .json, [0, 0, 0, 1, 0]), "$.a['b c'][1].d")
        XCTAssertEqual(try path(json, .json, [0, 0, 1]), #"$.a['it\'s']"#)

        let yaml = "a:\n  b c:\n    - 1\n    - d: 2\n"
        XCTAssertEqual(try path(yaml, .yaml, [0]), ".")
        XCTAssertEqual(try path(yaml, .yaml, [0, 0]), ".a")
        XCTAssertEqual(try path(yaml, .yaml, [0, 0, 0, 1, 0]), #".a."b c"[1].d"#)

        XCTAssertEqual(try path(plist, .plist, [0]), ":")
        XCTAssertEqual(try path(plist, .plist, [0, 2, 0]), ":list:0")
        XCTAssertEqual(StructurePath.title(for: .xml), "Copy XPath")
        XCTAssertEqual(StructurePath.title(for: .plist), "Copy Key Path")
    }

    // MARK: - XML declarations

    func testTheDoctypeAndInstructionsAreEditedAsWritten() throws {
        let text = "<?xml-stylesheet href=\"a.css\"?>\n<!DOCTYPE a>\n<a/>\n"
        let edit = try editor(text, .xml)
        XCTAssertEqual(edit.find([1])?.kind, .declaration)
        XCTAssertTrue(edit.canEditValue([1]))
        XCTAssertEqual(applied(edit.setValue([1], to: "<!DOCTYPE a [\n  <!ENTITY e \"x\">\n]>"), to: text),
                       "<?xml-stylesheet href=\"a.css\"?>\n<!DOCTYPE a [\n  <!ENTITY e \"x\">\n]>\n<a/>\n")
        XCTAssertNil(edit.setValue([1], to: "<!DOCTYPE a"), "its > missing")
        XCTAssertEqual(applied(edit.setValue([0], to: "<?xml-stylesheet href=\"b.css\"?>"), to: text),
                       "<?xml-stylesheet href=\"b.css\"?>\n<!DOCTYPE a>\n<a/>\n")
    }
}
