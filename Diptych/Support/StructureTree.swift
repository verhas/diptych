import Foundation

/// A JSON, XML or YAML file as a tree, each node knowing where it is in the
/// text -- what Text Edit's tree view shows and edits.
///
/// The text stays what is edited. Renaming, changing a value, adding,
/// deleting and moving a node are each worked out as replacements in the
/// text that touch only that node and the separators around it, so the rest
/// of the file -- its layout, its comments -- is left as it was, and Undo
/// is the text's own.
nonisolated struct StructureNode: Equatable {

    enum Kind: String, Equatable, CaseIterable, Sendable {
        case document
        // JSON
        case object, array, string, number, boolean, null
        // XML
        case element, attribute, text, comment, cdata, instruction, declaration
        // YAML
        case mapping, sequence, scalar
        // Plist; `array`, `string` and `boolean` as in JSON.
        case dictionary, integer, real, date, data

        var title: String {
            switch self {
            case .document: "Document"
            case .object: "Object"
            case .array: "Array"
            case .string: "String"
            case .number: "Number"
            case .boolean: "Boolean"
            case .null: "Null"
            case .element: "Element"
            case .attribute: "Attribute"
            case .text: "Text"
            case .comment: "Comment"
            case .cdata: "CDATA"
            case .instruction: "Instruction"
            case .declaration: "Declaration"
            case .mapping: "Mapping"
            case .sequence: "Sequence"
            case .scalar: "Value"
            case .dictionary: "Dictionary"
            case .integer: "Integer"
            case .real: "Real"
            case .date: "Date"
            case .data: "Data"
            }
        }
    }

    var kind: Kind
    /// A JSON or YAML key, an element's or attribute's name.
    var key: String?
    var keyRange: NSRange?
    /// The element's name in its end tag.
    var endKeyRange: NSRange?
    /// What a value says, unquoted and unescaped.
    var value: String?
    /// Where the value is written: JSON's with its quotes, an attribute's
    /// inside them, YAML's as written, an element's text between its tags.
    var valueRange: NSRange?
    /// All of it: a member from its key to the end of its value, an element
    /// from < to >, a YAML entry from its key or dash to its last line.
    var range: NSRange
    /// Inside the brackets, or between an element's tags.
    var inner: NSRange?
    var children: [StructureNode] = []
    /// XML: the first `attributeCount` children are the attributes.
    var attributeCount = 0
    /// XML: an element with nothing in it but text, shown as its value.
    var textOnly = false
    var selfClosing = false
    /// YAML: right after the key's colon.
    var afterColon: Int?
    /// YAML: how the value or key was quoted, if it was.
    var quote: Character?
    var keyQuote: Character?
    /// YAML: a `{}` or `[]` written for an empty one.
    var flow = false
    /// Plist: the value's element, after its `<key>` in a dictionary.
    var element: NSRange?

    var isContainer: Bool {
        [.document, .object, .array, .element, .mapping, .sequence, .dictionary].contains(kind)
    }

    /// The children that are not attributes.
    var content: ArraySlice<StructureNode> { children[attributeCount...] }

    func node(at path: [Int]) -> StructureNode? {
        guard let first = path.first else { return self }
        guard first >= 0, first < children.count else { return nil }
        return children[first].node(at: Array(path.dropFirst()))
    }
}

/// One replacement in the text.
nonisolated struct TextChange: Equatable, Sendable {
    var range: NSRange
    var text: String
}

/// What a tree operation does to the text, and the node to select after.
nonisolated struct TreeEdit: Equatable {
    var changes: [TextChange]
    var select: [Int]?
}

/// What is put in by Add, or carried by a move or Duplicate.
nonisolated enum TreeFragment: Equatable {
    case new(StructureNode.Kind, key: String?, value: String?)
    case copy(CopiedNode)
}

/// A node taken out of the text, to go in elsewhere.
nonisolated struct CopiedNode: Equatable {
    var kind: StructureNode.Kind
    var key: String?
    /// The key as written.
    var keyText: String?
    /// All of it as written.
    var text: String
    /// Its value as written, for JSON, and YAML on the key's line.
    var valueText: String?
    /// YAML: what is under it, from its first child, and that child's column.
    var childText: String?
    var childColumn = 0
    /// The indentation its first line had.
    var pad: String
    var column: Int
}

nonisolated enum StructureTree {

    static func parse(_ text: NSString, as format: TextFormat) -> StructureNode? {
        switch format {
        case .json:
            var tree = JSONTree(text)
            return tree.parse()
        case .xml:
            return XMLTree(text).parse()
        case .yaml:
            var tree = YAMLTree(text)
            return tree.parse()
        case .plist:
            return PlistTree(text).parse()
        case .toml:
            return nil
        }
    }

    /// The line, one-based, where the YAML tree stopped reading a file it
    /// does not show.
    static func yamlStop(_ text: NSString) -> Int? {
        var tree = YAMLTree(text)
        guard tree.parse() == nil, !tree.lines.isEmpty else { return nil }
        return min(tree.l, tree.lines.count - 1) + 1
    }

    static func supports(_ format: TextFormat?) -> Bool {
        format == .json || format == .xml || format == .yaml || format == .plist
    }
}

// MARK: - Editing

nonisolated struct StructureEditor {
    let text: NSString
    let format: TextFormat
    let root: StructureNode
    let indent: LineEditing.Indent
    let style: TextStyle

    init(text: NSString, format: TextFormat, root: StructureNode, style: TextStyle) {
        self.text = text
        self.format = format
        self.root = root
        self.style = style
        indent = style.indent(for: format)
    }

    func find(_ path: [Int]) -> StructureNode? { root.node(at: path) }

    // MARK: What may be done

    func canRename(_ path: [Int]) -> Bool {
        guard let node = find(path), let parent = find(Array(path.dropLast())) else { return false }
        switch format {
        case .json: return parent.kind == .object
        case .yaml: return parent.kind == .mapping
        case .xml: return node.kind == .element || node.kind == .attribute
        case .plist: return parent.kind == .dictionary
        case .toml: return false
        }
    }

    func canEditValue(_ path: [Int]) -> Bool {
        guard let node = find(path) else { return false }
        switch node.kind {
        case .string, .number, .boolean, .scalar, .attribute, .text, .comment, .cdata: return true
        // Edited as written, `<!DOCTYPE …>` and `<?…?>` included.
        case .declaration, .instruction: return true
        case .integer, .real, .date, .data: return true
        case .element: return node.textOnly || (node.content.isEmpty)
        default: return false
        }
    }

    /// The kinds a node can be added as, in a container.
    func addable(into path: [Int]) -> [StructureNode.Kind] {
        guard let parent = find(path) else { return [] }
        switch (format, parent.kind) {
        case (.json, .object), (.json, .array):
            return [.string, .number, .boolean, .null, .object, .array]
        case (.yaml, .mapping), (.yaml, .sequence):
            return [.scalar, .mapping, .sequence]
        case (.yaml, .document):
            return parent.children.isEmpty ? [.mapping, .sequence] : []
        case (.xml, .element):
            return [.element, .attribute, .text, .comment]
        case (.xml, .document):
            return parent.content.contains { $0.kind == .element } ? [.comment] : [.element, .comment]
        case (.plist, .dictionary), (.plist, .array):
            return Self.plistKinds
        default:
            return []
        }
    }

    /// The kinds a value can be changed to.
    func types(for path: [Int]) -> [StructureNode.Kind] {
        guard let node = find(path), !path.isEmpty else { return [] }
        switch format {
        case .json where node.kind != .document: return [.string, .number, .boolean, .null, .object, .array]
        case .yaml where node.kind != .document: return [.scalar, .mapping, .sequence]
        case .plist where node.kind != .document: return Self.plistKinds
        default: return []
        }
    }

    func canDelete(_ path: [Int]) -> Bool {
        guard !path.isEmpty, find(path) != nil else { return false }
        if format != .xml, path.count == 1 { return false }
        return true
    }

    /// Whether `node` may go into `parent` at `index` -- not into itself, an
    /// attribute only among attributes.
    func canMove(_ path: [Int], into parentPath: [Int], at index: Int) -> Bool {
        guard canDelete(path), let moving = find(path), let parent = find(parentPath),
              !(parentPath.count >= path.count && Array(parentPath.prefix(path.count)) == path)
        else { return false }
        let allowed = addable(into: parentPath)
        switch format {
        case .xml:
            if moving.kind == .attribute {
                return parent.kind == .element && index <= parent.attributeCount
            }
            guard index >= parent.attributeCount || parent.kind == .document else { return false }
            if parent.kind == .document { return moving.kind == .comment || moving.kind == .instruction }
            return allowed.contains(.element)
        default:
            return !allowed.isEmpty && parent.kind != .document
        }
    }

    // MARK: Text helpers

    func string(_ range: NSRange) -> String { text.substring(with: range) }

    func lineStart(_ location: Int) -> Int {
        text.lineRange(for: NSRange(location: location, length: 0)).location
    }

    /// The indentation of the line `location` is on.
    func pad(at location: Int) -> String { LineEditing.leading(ofLineAt: location, in: text) }

    func column(_ location: Int) -> Int { location - lineStart(location) }

    /// Whether only spaces come before `location` on its line.
    func startsLine(_ location: Int) -> Bool {
        let start = lineStart(location)
        return string(NSRange(location: start, length: location - start)).allSatisfy { $0 == " " || $0 == "\t" }
    }

    func whitespace(before location: Int) -> NSRange {
        var start = location
        while start > 0, [0x20, 0x09, 0x0A, 0x0D].contains(text.character(at: start - 1)) { start -= 1 }
        return NSRange(location: start, length: location - start)
    }

    func whitespace(after location: Int) -> NSRange {
        var end = location
        while end < text.length, [0x20, 0x09, 0x0A, 0x0D].contains(text.character(at: end)) { end += 1 }
        return NSRange(location: location, length: end - location)
    }

    /// Lines after the first moved from one indentation to another.
    static func reindent(_ text: String, from old: String, to new: String) -> String {
        guard old != new else { return text }
        var lines = text.components(separatedBy: "\n")
        for k in lines.indices.dropFirst() where !lines[k].isEmpty {
            if lines[k].hasPrefix(old) {
                lines[k] = new + lines[k].dropFirst(old.count)
            } else if new.hasPrefix(old) == false, old.hasPrefix(new) == false {
                lines[k] = new + lines[k].drop { $0 == " " || $0 == "\t" }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func reindent(_ text: String, fromColumn old: Int, toColumn new: Int) -> String {
        guard old != new else { return text }
        var lines = text.components(separatedBy: "\n")
        for k in lines.indices.dropFirst() where !lines[k].isEmpty {
            let spaces = lines[k].prefix { $0 == " " }.count
            let kept = max(0, spaces - old)
            lines[k] = String(repeating: " ", count: new + kept) + lines[k].dropFirst(spaces)
        }
        return lines.joined(separator: "\n")
    }

    func uniqueKey(_ wanted: String, in parent: StructureNode, except: Int? = nil) -> String {
        let taken = Set(parent.children.enumerated().filter { $0.offset != except }.compactMap(\.element.key))
        guard taken.contains(wanted) else { return wanted }
        var n = 2
        while taken.contains("\(wanted) \(n)") { n += 1 }
        return "\(wanted) \(n)"
    }

    // MARK: Copy

    func copy(_ path: [Int]) -> CopiedNode? {
        guard let node = find(path) else { return nil }
        var copied = CopiedNode(kind: node.kind, key: node.key,
                                keyText: node.keyRange.map(string), text: string(node.range),
                                pad: pad(at: node.range.location), column: column(node.range.location))
        switch format {
        case .json:
            copied.valueText = node.valueRange.map(string)
        case .yaml:
            if let first = node.children.first, !node.flow {
                copied.childText = string(NSRange(location: first.range.location,
                                                  length: NSMaxRange(node.range) - first.range.location))
                copied.childColumn = column(first.range.location)
            } else if let value = node.valueRange {
                copied.valueText = string(NSRange(location: value.location,
                                                  length: NSMaxRange(node.range) - value.location))
            }
        case .plist:
            copied.valueText = node.element.map(string)
        default:
            break
        }
        return copied
    }

    // MARK: Rename

    func rename(_ path: [Int], to name: String) -> TreeEdit? {
        guard canRename(path), let node = find(path), let keyRange = node.keyRange,
              !name.isEmpty, name != node.key else { return nil }
        switch format {
        case .json:
            return TreeEdit(changes: [TextChange(range: keyRange, text: Self.jsonString(name))], select: path)
        case .yaml:
            return TreeEdit(changes: [TextChange(range: keyRange,
                                                 text: Self.yamlScalar(name, quote: node.keyQuote, isKey: true))],
                            select: path)
        case .xml:
            guard Self.isXMLName(name) else { return nil }
            var changes = [TextChange(range: keyRange, text: name)]
            if let end = node.endKeyRange { changes.append(TextChange(range: end, text: name)) }
            return TreeEdit(changes: changes, select: path)
        case .plist:
            guard let parent = find(Array(path.dropLast())),
                  uniqueKey(name, in: parent, except: path.last) == name else { return nil }
            return TreeEdit(changes: [TextChange(range: keyRange, text: Self.xmlEscape(name, quote: nil))],
                            select: path)
        case .toml:
            return nil
        }
    }

    // MARK: Element and attribute

    /// What turning an XML element into an attribute takes, or the other way
    /// round: the node taken out, then -- in the text read again -- the new
    /// one put in among its parent's children at `index`.
    struct Conversion {
        let removal: TreeEdit
        let fragment: TreeFragment
        let parent: [Int]
        let index: Int
    }

    /// An element with nothing in it but text, and no attributes, whose
    /// parent is an element without an attribute of that name.
    func canMakeAttribute(_ path: [Int]) -> Bool {
        guard format == .xml, let node = find(path), node.kind == .element, node.attributeCount == 0,
              node.content.isEmpty, let name = node.key,
              let parent = find(Array(path.dropLast())), parent.kind == .element else { return false }
        return !parent.children.prefix(parent.attributeCount).contains { $0.key == name }
    }

    func canMakeElement(_ path: [Int]) -> Bool {
        format == .xml && find(path)?.kind == .attribute
    }

    /// `<name>value</name>` as `name="value"` on its parent, after the
    /// attributes it has; an attribute as such an element, first in its
    /// parent's content. Named `name`, or as it was.
    func conversion(_ path: [Int], named name: String? = nil) -> Conversion? {
        guard let node = find(path), let wanted = name ?? node.key, Self.isXMLName(wanted),
              let parent = find(Array(path.dropLast())) else { return nil }
        let parentPath = Array(path.dropLast())
        if canMakeAttribute(path) {
            guard wanted == node.key || !parent.children.prefix(parent.attributeCount).contains(where: {
                $0.key == wanted
            }), let removal = delete(path) else { return nil }
            return Conversion(removal: removal, fragment: .new(.attribute, key: wanted, value: node.value ?? ""),
                              parent: parentPath, index: parent.attributeCount)
        }
        if canMakeElement(path), let removal = delete(path) {
            return Conversion(removal: removal, fragment: .new(.element, key: wanted, value: node.value ?? ""),
                              parent: parentPath, index: parent.attributeCount - 1)
        }
        return nil
    }

    // MARK: Value

    func setValue(_ path: [Int], to value: String) -> TreeEdit? {
        guard canEditValue(path), let node = find(path) else { return nil }
        if format == .plist { return plistSetValue(node, path, value) }
        switch (format, node.kind) {
        case (.json, .string):
            return replaceValue(node, path, Self.jsonString(value))
        case (.json, .number):
            guard Self.isJSONNumber(value) else { return nil }
            return replaceValue(node, path, value)
        case (.json, .boolean):
            guard let flag = Self.boolean(value) else { return nil }
            return replaceValue(node, path, flag ? "true" : "false")
        case (.yaml, .scalar):
            guard !value.contains("\n") || node.quote != nil || true else { return nil }
            return replaceValue(node, path, Self.yamlScalar(value, quote: node.quote, isKey: false,
                                                            column: column(node.range.location)))
        case (.xml, .attribute):
            let quote = node.valueRange.map { text.character(at: $0.location - 1) } ?? 0x22
            return replaceValue(node, path, Self.xmlEscape(value, quote: quote))
        case (.xml, .text):
            return replaceValue(node, path, Self.xmlEscape(value, quote: nil))
        case (.xml, .comment):
            guard !value.contains("--") else { return nil }
            return TreeEdit(changes: [TextChange(range: node.range, text: "<!-- \(value) -->")], select: path)
        case (.xml, .declaration):
            let written = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard written.hasPrefix("<!"), written.hasSuffix(">") else { return nil }
            // An internal subset closed before the end: `[ … ]>`.
            if written.contains("[") {
                guard written.dropLast().trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("]")
                else { return nil }
            }
            return TreeEdit(changes: [TextChange(range: node.range, text: written)], select: path)
        case (.xml, .instruction):
            let written = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard written.hasPrefix("<?"), written.hasSuffix("?>") else { return nil }
            return TreeEdit(changes: [TextChange(range: node.range, text: written)], select: path)
        case (.xml, .cdata):
            guard !value.contains("]]>") else { return nil }
            return TreeEdit(changes: [TextChange(range: node.range, text: "<![CDATA[\(value)]]>")], select: path)
        case (.xml, .element):
            let escaped = Self.xmlEscape(value, quote: nil)
            if let inner = node.inner {
                return TreeEdit(changes: [TextChange(range: inner, text: escaped)], select: path)
            }
            // <a/> becomes <a>value</a>.
            let start = string(node.startTag(in: text))
            let open = String(start.dropLast(2)).replacingOccurrences(of: #"\s+$"#, with: "",
                                                                       options: .regularExpression)
            return TreeEdit(changes: [TextChange(range: node.range,
                                                 text: open + ">" + escaped + "</\(node.key ?? "")>")],
                            select: path)
        default:
            return nil
        }
    }

    private func replaceValue(_ node: StructureNode, _ path: [Int], _ written: String) -> TreeEdit? {
        guard let range = node.valueRange else {
            // YAML `key:` with nothing: the value after the colon.
            guard let colon = node.afterColon else { return nil }
            return TreeEdit(changes: [TextChange(range: NSRange(location: colon, length: 0), text: " " + written)],
                            select: path)
        }
        return TreeEdit(changes: [TextChange(range: range, text: written)], select: path)
    }

    // MARK: Type

    func changeType(_ path: [Int], to kind: StructureNode.Kind) -> TreeEdit? {
        guard types(for: path).contains(kind), let node = find(path), node.kind != kind else { return nil }
        let current = node.value ?? ""
        switch format {
        case .plist:
            guard let element = node.element else { return nil }
            return TreeEdit(changes: [TextChange(range: element, text: Self.plistElement(kind, value: current))],
                            select: path)
        case .json:
            let written: String = switch kind {
            case .string: Self.jsonString(current)
            case .number: Self.isJSONNumber(current) ? current : "0"
            case .boolean: Self.boolean(current) == true ? "true" : "false"
            case .null: "null"
            case .object: "{}"
            default: "[]"
            }
            guard let range = node.valueRange else { return nil }
            return TreeEdit(changes: [TextChange(range: range, text: written)], select: path)
        case .yaml:
            let written: String = switch kind {
            case .mapping: "{}"
            case .sequence: "[]"
            default: Self.yamlScalar(current, quote: nil, isKey: false)
            }
            // The whole value: after the key's colon or the item's dash,
            // and anything under it.
            if let colon = node.afterColon {
                return TreeEdit(changes: [TextChange(range: NSRange(location: colon,
                                                                    length: NSMaxRange(node.range) - colon),
                                                     text: " " + written)], select: path)
            }
            if node.key == nil, path.count > 1 {
                let dash = node.range.location + 1
                return TreeEdit(changes: [TextChange(range: NSRange(location: dash,
                                                                    length: NSMaxRange(node.range) - dash),
                                                     text: " " + written)], select: path)
            }
            return TreeEdit(changes: [TextChange(range: node.range, text: written)], select: path)
        default:
            return nil
        }
    }

    // MARK: Delete

    func delete(_ path: [Int]) -> TreeEdit? {
        guard canDelete(path), let index = path.last, let parent = find(Array(path.dropLast())),
              let node = find(path) else { return nil }
        let parentPath = Array(path.dropLast())
        let after: [Int]? = {
            let remaining = parent.children.count - 1
            if remaining == 0 { return parentPath.isEmpty ? nil : parentPath }
            return parentPath + [min(index, remaining - 1)]
        }()
        switch format {
        case .plist:
            if parent.children.count == 1, let element = parent.element {
                let empty = parent.kind == .dictionary ? "<dict/>" : "<array/>"
                return TreeEdit(changes: [TextChange(range: element, text: empty)], select: after)
            }
            let before = whitespace(before: node.range.location)
            return TreeEdit(changes: [TextChange(range: NSRange(location: before.location,
                                                                length: NSMaxRange(node.range) - before.location),
                                                 text: "")], select: after)
        case .json:
            let items = parent.children
            if items.count == 1, let inner = parent.inner {
                return TreeEdit(changes: [TextChange(range: inner, text: "")], select: after)
            }
            if index < items.count - 1 {
                let range = NSRange(location: node.range.location,
                                    length: items[index + 1].range.location - node.range.location)
                return TreeEdit(changes: [TextChange(range: range, text: "")], select: after)
            }
            let previousEnd = NSMaxRange(items[index - 1].range)
            return TreeEdit(changes: [TextChange(range: NSRange(location: previousEnd,
                                                                length: NSMaxRange(node.range) - previousEnd),
                                                 text: "")], select: after)
        case .xml:
            if node.kind == .attribute {
                let space = whitespace(before: node.range.location)
                return TreeEdit(changes: [TextChange(range: NSRange(location: space.location,
                                                                    length: NSMaxRange(node.range) - space.location),
                                                     text: "")], select: after)
            }
            let content = Array(parent.content)
            if content.count == 1, parent.kind == .element, let inner = parent.inner {
                return TreeEdit(changes: [TextChange(range: inner, text: "")], select: after)
            }
            let before = whitespace(before: node.range.location)
            let isFirst = index == parent.attributeCount
            if !isFirst || before.length == 0 || parent.kind == .document && before.location > 0 {
                return TreeEdit(changes: [TextChange(range: NSRange(location: before.location,
                                                                    length: NSMaxRange(node.range) - before.location),
                                                     text: "")], select: after)
            }
            let following = whitespace(after: NSMaxRange(node.range))
            return TreeEdit(changes: [TextChange(range: NSRange(location: node.range.location,
                                                                length: NSMaxRange(following) - node.range.location),
                                                 text: "")], select: after)
        case .yaml:
            let items = parent.children
            if items.count == 1 {
                if parent.kind == .document {
                    return TreeEdit(changes: [TextChange(range: node.range, text: "")], select: nil)
                }
                let empty = parent.kind == .mapping ? "{}" : "[]"
                if let colon = parent.afterColon {
                    return TreeEdit(changes: [TextChange(range: NSRange(location: colon,
                                                                        length: NSMaxRange(parent.range) - colon),
                                                         text: " " + empty)], select: after)
                }
                return TreeEdit(changes: [TextChange(range: node.range, text: empty)], select: after)
            }
            if startsLine(node.range.location) {
                // Its lines, whole: what is around them stays.
                let first = lineStart(node.range.location)
                let last = text.lineRange(for: NSRange(location: max(node.range.location,
                                                                     NSMaxRange(node.range) - 1), length: 0))
                return TreeEdit(changes: [TextChange(range: NSRange(location: first, length: NSMaxRange(last) - first),
                                                     text: "")], select: after)
            }
            // The first of a compact mapping, after its dash: the next one moves up.
            let range = NSRange(location: node.range.location,
                                length: items[index + 1].range.location - node.range.location)
            return TreeEdit(changes: [TextChange(range: range, text: "")], select: after)
        case .toml:
            return nil
        }
    }

    // MARK: Insert

    func insert(_ fragment: TreeFragment, into parentPath: [Int], at wanted: Int) -> TreeEdit? {
        guard let parent = find(parentPath) else { return nil }
        switch format {
        case .json: return insertJSON(fragment, into: parent, parentPath, at: wanted)
        case .xml: return insertXML(fragment, into: parent, parentPath, at: wanted)
        case .yaml: return insertYAML(fragment, into: parent, parentPath, at: wanted)
        case .plist: return insertPlist(fragment, into: parent, parentPath, at: wanted)
        case .toml: return nil
        }
    }

    /// Where a new child goes among `items`, and how it is separated: before
    /// one of them, or after the last, with the space they are laid out
    /// with; or into an empty container on a line of its own.
    func place(_ body: (String) -> String, among items: [StructureNode], at index: Int,
                       separator: String, emptyInner: NSRange?, parentPad: String, select: [Int]) -> TreeEdit? {
        if items.isEmpty {
            guard let inner = emptyInner else { return nil }
            let childPad = parentPad + indent.unit
            return TreeEdit(changes: [TextChange(range: inner,
                                                 text: "\n" + childPad + body(childPad) + "\n" + parentPad)],
                            select: select)
        }
        let anchor = items[min(index, items.count - 1)]
        let childPad = startsLine(anchor.range.location) ? pad(at: anchor.range.location) : parentPad + indent.unit
        // The space the items are laid out with: after the first one.
        let between = string(whitespace(before: items[items.count > 1 ? 1 : 0].range.location))
        let spacing = between.contains("\n") ? "\n" + childPad : (items.count > 1 ? between : "")
        if index < items.count {
            return TreeEdit(changes: [TextChange(range: NSRange(location: anchor.range.location, length: 0),
                                                 text: body(childPad) + separator + spacing)],
                            select: select)
        }
        let last = items[items.count - 1]
        let trailing = items.count > 1 || between.contains("\n") ? spacing : (separator.isEmpty ? "" : " ")
        return TreeEdit(changes: [TextChange(range: NSRange(location: NSMaxRange(last.range), length: 0),
                                             text: separator + trailing + body(childPad))],
                        select: select)
    }

    private func insertJSON(_ fragment: TreeFragment, into parent: StructureNode, _ parentPath: [Int],
                            at wanted: Int) -> TreeEdit? {
        guard parent.kind == .object || parent.kind == .array else { return nil }
        let index = min(max(0, wanted), parent.children.count)
        let colon = style.jsonSpaceBeforeColon ? " : " : ": "
        let body: (String) -> String = { childPad in
            var key: String?
            var value: String
            switch fragment {
            case .new(let kind, let wantedKey, let wantedValue):
                key = Self.jsonString(uniqueKey(wantedKey ?? "key", in: parent))
                value = switch kind {
                case .string: Self.jsonString(wantedValue ?? "")
                case .number: wantedValue.flatMap { Self.isJSONNumber($0) ? $0 : nil } ?? "0"
                case .boolean: Self.boolean(wantedValue ?? "") == true ? "true" : "false"
                case .object: "{}"
                case .array: "[]"
                default: "null"
                }
            case .copy(let copied):
                let original = copied.key ?? "key"
                let unique = uniqueKey(original, in: parent)
                key = unique == original && copied.keyText != nil ? copied.keyText : Self.jsonString(unique)
                value = Self.reindent(copied.valueText ?? copied.text, from: copied.pad, to: childPad)
            }
            return parent.kind == .object ? key! + colon + value : value
        }
        return place(body, among: parent.children, at: index, separator: ",",
                     emptyInner: parent.inner, parentPad: pad(at: parent.range.location),
                     select: parentPath + [index])
    }

    private func insertXML(_ fragment: TreeFragment, into parent: StructureNode, _ parentPath: [Int],
                           at wanted: Int) -> TreeEdit? {
        let kind: StructureNode.Kind = switch fragment {
        case .new(let kind, _, _): kind
        case .copy(let copied): copied.kind
        }
        if kind == .attribute {
            guard parent.kind == .element else { return nil }
            let index = min(max(0, wanted), parent.attributeCount)
            let written: String
            switch fragment {
            case .new(_, let key, let value):
                let name = uniqueKey(key ?? "name", in: parent).replacingOccurrences(of: " ", with: "-")
                written = "\(name)=\"\(Self.xmlEscape(value ?? "", quote: 0x22))\""
            case .copy(let copied):
                written = copied.text
            }
            if index < parent.attributeCount {
                let anchor = parent.children[index]
                return TreeEdit(changes: [TextChange(range: NSRange(location: anchor.range.location, length: 0),
                                                     text: written + " ")],
                                select: parentPath + [index])
            }
            let after = parent.attributeCount > 0 ? NSMaxRange(parent.children[parent.attributeCount - 1].range)
                : NSMaxRange(parent.keyRange!)
            return TreeEdit(changes: [TextChange(range: NSRange(location: after, length: 0), text: " " + written)],
                            select: parentPath + [index])
        }
        let content = Array(parent.content)
        let index = min(max(parent.attributeCount, wanted), parent.children.count) - parent.attributeCount
        let body: (String) -> String = { childPad in
            switch fragment {
            case .new(let kind, let key, let value):
                switch kind {
                case .text: return Self.xmlEscape(value ?? "text", quote: nil)
                case .comment: return "<!-- \(value ?? "") -->"
                default:
                    let name = (key ?? "element").replacingOccurrences(of: " ", with: "-")
                    return "<\(name)>\(Self.xmlEscape(value ?? "", quote: nil))</\(name)>"
                }
            case .copy(let copied):
                return Self.reindent(copied.text, from: copied.pad, to: childPad)
            }
        }
        let select = parentPath + [parent.attributeCount + (parent.textOnly ? 0 : index)]
        if parent.kind == .document {
            if content.isEmpty {
                return TreeEdit(changes: [TextChange(range: NSRange(location: text.length, length: 0),
                                                     text: body(""))], select: select)
            }
            return place(body, among: content, at: index, separator: "", emptyInner: nil, parentPad: "",
                         select: select)
        }
        let parentPad = pad(at: parent.range.location)
        if parent.selfClosing {
            let start = string(parent.startTag(in: text))
            let open = String(start.dropLast(2)).replacingOccurrences(of: #"\s+$"#, with: "",
                                                                       options: .regularExpression)
            let childPad = parentPad + indent.unit
            return TreeEdit(changes: [TextChange(range: parent.range,
                                                 text: open + ">\n" + childPad + body(childPad) + "\n"
                                                    + parentPad + "</\(parent.key ?? "")>")],
                            select: parentPath + [parent.attributeCount])
        }
        if parent.textOnly, let inner = parent.inner {
            let existing = string(inner)
            if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return place(body, among: [], at: 0, separator: "", emptyInner: inner, parentPad: parentPad,
                             select: parentPath + [parent.attributeCount])
            }
            // Text and now an element: mixed, the element after the text.
            return TreeEdit(changes: [TextChange(range: NSRange(location: NSMaxRange(inner), length: 0),
                                                 text: body(parentPad + indent.unit))],
                            select: parentPath + [parent.attributeCount + 1])
        }
        return place(body, among: content, at: index, separator: "", emptyInner: parent.inner,
                     parentPad: parentPad, select: select)
    }

    private func insertYAML(_ fragment: TreeFragment, into parent: StructureNode, _ parentPath: [Int],
                            at wanted: Int) -> TreeEdit? {
        let items = parent.children
        let index = min(max(0, wanted), items.count)
        let intoSequence = parent.kind == .sequence
        // The column the children start at.
        let childColumn: Int
        if let first = items.first {
            childColumn = column(first.range.location)
        } else if parent.kind == .document {
            childColumn = 0
        } else if parent.afterColon != nil {
            childColumn = column(parent.range.location) + indent.width
        } else {
            // A sequence item's empty value: a compact one, after its dash.
            childColumn = column(parent.valueRange?.location ?? parent.range.location)
        }
        let body = yamlBody(fragment, intoSequence: intoSequence, parent: parent, column: childColumn)
        let select = parentPath + [index]
        if parent.kind == .document {
            if items.isEmpty {
                return TreeEdit(changes: [TextChange(range: NSRange(location: text.length, length: 0),
                                                     text: body + "\n")], select: [0])
            }
            if parent.kind == .document, let root = items.first, root.isContainer {
                return nil
            }
        }
        if items.isEmpty {
            // `key: {}` or `- []`: the children go where the brackets were.
            if let colon = parent.afterColon {
                return TreeEdit(changes: [TextChange(range: NSRange(location: colon,
                                                                    length: NSMaxRange(parent.range) - colon),
                                                     text: "\n" + String(repeating: " ", count: childColumn) + body)],
                                select: select)
            }
            guard let value = parent.valueRange else { return nil }
            return TreeEdit(changes: [TextChange(range: value, text: body)], select: select)
        }
        let spaces = String(repeating: " ", count: childColumn)
        if index < items.count {
            return TreeEdit(changes: [TextChange(range: NSRange(location: items[index].range.location, length: 0),
                                                 text: body + "\n" + spaces)], select: select)
        }
        // After the last one's line, comment and all.
        let end = LineEditing.lineEndLocation(after: NSMaxRange(items[items.count - 1].range), in: text)
        return TreeEdit(changes: [TextChange(range: NSRange(location: end, length: 0),
                                             text: "\n" + spaces + body)], select: select)
    }

    /// A YAML entry or item as written at `column`.
    private func yamlBody(_ fragment: TreeFragment, intoSequence: Bool, parent: StructureNode,
                          column: Int) -> String {
        let width = indent.width
        switch fragment {
        case .new(let kind, let key, let value):
            let written = switch kind {
            case .mapping: "{}"
            case .sequence: "[]"
            default: Self.yamlScalar(value ?? "", quote: nil, isKey: false)
            }
            if intoSequence { return "- " + written }
            return Self.yamlScalar(uniqueKey(key ?? "key", in: parent), quote: nil, isKey: true) + ": " + written
        case .copy(let copied):
            let wasItem = copied.key == nil
            if wasItem == intoSequence {
                var text = Self.reindent(copied.text, fromColumn: copied.column, toColumn: column)
                if !intoSequence, let key = copied.key, uniqueKey(key, in: parent) != key,
                   let keyText = copied.keyText, text.hasPrefix(keyText) {
                    text = Self.yamlScalar(uniqueKey(key, in: parent), quote: nil, isKey: true)
                        + text.dropFirst(keyText.count)
                }
                return text
            }
            if intoSequence {
                if let child = copied.childText {
                    return "- " + Self.reindent(child, fromColumn: copied.childColumn, toColumn: column + 2)
                }
                let value = copied.valueText.map { Self.reindent($0, fromColumn: copied.column, toColumn: column + 2) }
                return "- " + (value ?? "null")
            }
            let key = Self.yamlScalar(uniqueKey("key", in: parent), quote: nil, isKey: true)
            if let child = copied.childText {
                return key + ":\n" + String(repeating: " ", count: column + width)
                    + Self.reindent(child, fromColumn: copied.childColumn, toColumn: column + width)
            }
            let value = copied.valueText.map { Self.reindent($0, fromColumn: copied.column, toColumn: column + width) }
            return key + ": " + (value ?? "null")
        }
    }

    // MARK: Writing values

    static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    static func isJSONNumber(_ text: String) -> Bool {
        text.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
    }

    static func boolean(_ text: String) -> Bool? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "yes", "1", "on": true
        case "false", "no", "0", "off", "": false
        default: nil
        }
    }

    static func isXMLName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              CharacterSet.letters.contains(first) || first == "_" || first == ":" else { return false }
        return name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "_:-.".unicodeScalars.contains($0)
        }
    }

    static func xmlEscape(_ value: String, quote: UInt16?) -> String {
        var out = value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        if quote == nil { out = out.replacingOccurrences(of: ">", with: "&gt;") }
        if quote == 0x22 { out = out.replacingOccurrences(of: "\"", with: "&quot;") }
        if quote == 0x27 { out = out.replacingOccurrences(of: "'", with: "&apos;") }
        return out
    }

    /// A YAML scalar written so it reads back as the same text: plain where
    /// that is safe, otherwise in the quotes it had, or double quotes.
    static func yamlScalar(_ value: String, quote: Character?, isKey: Bool, column: Int = 0) -> String {
        if quote == "'" , !value.contains("\n") {
            return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }
        if quote == nil, isPlainSafe(value) { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t") + "\""
    }

    static func isPlainSafe(_ value: String) -> Bool {
        guard let first = value.first, let last = value.last, first != " ", last != " " else { return false }
        if "-?:,[]{}#&*!|>'\"%@`".contains(first) {
            // `-1` and `-x` read fine; `- x` does not.
            if !(first == "-" && value.count > 1 && value.dropFirst().first != " ") { return false }
        }
        return !value.contains(": ") && !value.contains(" #") && !value.hasSuffix(":")
            && !value.contains("\n") && !value.contains("\t")
    }
}

extension StructureNode {
    /// The start tag's range, for an element; the node itself otherwise.
    func startTag(in text: NSString) -> NSRange {
        guard kind == .element else { return range }
        if let inner { return NSRange(location: range.location, length: inner.location - range.location) }
        return range
    }
}

// MARK: - JSON

private nonisolated struct JSONTree {
    let text: NSString
    let tokens: [JSONToken]
    var k = 0

    init(_ text: NSString) {
        self.text = text
        tokens = JSONTokenizer.tokens(text).filter { $0.kind != .comment }
    }

    mutating func parse() -> StructureNode? {
        guard !tokens.isEmpty, let value = value(), k == tokens.count else { return nil }
        return StructureNode(kind: .document, range: NSRange(location: 0, length: text.length),
                             children: [value])
    }

    mutating func value() -> StructureNode? {
        guard k < tokens.count else { return nil }
        let token = tokens[k]
        k += 1
        switch token.kind {
        case .open:
            let isObject = token.text == "{"
            var children: [StructureNode] = []
            if k < tokens.count, tokens[k].kind == .close {
                let close = tokens[k]
                k += 1
                return container(isObject, token, close, children)
            }
            while true {
                if isObject {
                    guard k < tokens.count, tokens[k].kind == .string else { return nil }
                    let key = tokens[k]
                    k += 1
                    guard k < tokens.count, tokens[k].kind == .colon else { return nil }
                    k += 1
                    guard var member = value() else { return nil }
                    member.key = Self.decode(key.text)
                    member.keyRange = key.range
                    member.range = NSRange(location: key.range.location,
                                           length: NSMaxRange(member.valueRange!) - key.range.location)
                    children.append(member)
                } else {
                    guard let element = value() else { return nil }
                    children.append(element)
                }
                guard k < tokens.count else { return nil }
                let next = tokens[k]
                k += 1
                if next.kind == .comma { continue }
                guard next.kind == .close, (next.text == "}") == isObject else { return nil }
                return container(isObject, token, next, children)
            }
        case .string:
            return StructureNode(kind: .string, value: Self.decode(token.text), valueRange: token.range,
                                 range: token.range)
        case .scalar:
            let kind: StructureNode.Kind = switch token.text {
            case "true", "false": .boolean
            case "null": .null
            default: .number
            }
            return StructureNode(kind: kind, value: token.text, valueRange: token.range, range: token.range)
        default:
            return nil
        }
    }

    func container(_ isObject: Bool, _ open: JSONToken, _ close: JSONToken,
                   _ children: [StructureNode]) -> StructureNode {
        let range = NSRange(location: open.range.location, length: NSMaxRange(close.range) - open.range.location)
        return StructureNode(kind: isObject ? .object : .array, valueRange: range, range: range,
                             inner: NSRange(location: NSMaxRange(open.range),
                                            length: close.range.location - NSMaxRange(open.range)),
                             children: children)
    }

    static func decode(_ literal: String) -> String {
        (try? JSONDecoder().decode(String.self, from: Data(literal.utf8)))
            ?? String(literal.dropFirst().dropLast())
    }
}

// MARK: - XML

nonisolated struct XMLTree {
    let text: NSString

    init(_ text: NSString) { self.text = text }

    func parse() -> StructureNode? {
        guard let nodes = XMLDocumentReader.parse(text) else { return nil }
        return StructureNode(kind: .document, range: NSRange(location: 0, length: text.length),
                             children: nodes.compactMap(node))
    }

    func isBlank(_ node: XMLNode) -> Bool {
        node.kind == .text && node.name.allSatisfy { $0.isWhitespace }
    }

    func node(_ xml: XMLNode) -> StructureNode? {
        switch xml.kind {
        case .text:
            guard !isBlank(xml) else { return nil }
            return StructureNode(kind: .text, value: Self.decode(xml.name.trimmingCharacters(in: .whitespacesAndNewlines)),
                                 valueRange: xml.range, range: xml.range)
        case .comment:
            let inner = String(xml.name.dropFirst(4).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            return StructureNode(kind: .comment, value: inner, valueRange: xml.range, range: xml.range)
        case .cdata:
            return StructureNode(kind: .cdata, value: String(xml.name.dropFirst(9).dropLast(3)),
                                 valueRange: xml.range, range: xml.range)
        case .instruction:
            return StructureNode(kind: .instruction, value: xml.name, range: xml.range)
        case .declaration:
            return StructureNode(kind: .declaration, value: xml.name, range: xml.range)
        case .element:
            let attributes = xml.attributes.map {
                StructureNode(kind: .attribute, key: $0.name, keyRange: $0.nameRange,
                              value: Self.decode(String($0.rawValue.dropFirst().dropLast())),
                              valueRange: $0.valueRange, range: $0.range)
            }
            let content = xml.children.filter { !isBlank($0) }
            let textOnly = !xml.selfClosing && content.allSatisfy { $0.kind == .text }
            var node = StructureNode(kind: .element, key: xml.name, keyRange: xml.nameRange,
                                     endKeyRange: xml.endNameRange, range: xml.range, inner: xml.inner,
                                     children: attributes + (textOnly ? [] : content.compactMap(self.node)),
                                     attributeCount: attributes.count, textOnly: textOnly,
                                     selfClosing: xml.selfClosing)
            if textOnly, let inner = xml.inner {
                node.value = Self.decode(text.substring(with: inner).trimmingCharacters(in: .whitespacesAndNewlines))
                node.valueRange = inner
            }
            return node
        }
    }

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            guard let semi = rest[amp...].firstIndex(of: ";") else { break }
            let entity = rest[rest.index(after: amp)..<semi]
            switch entity {
            case "lt": out += "<"
            case "gt": out += ">"
            case "amp": out += "&"
            case "quot": out += "\""
            case "apos": out += "'"
            default:
                if entity.hasPrefix("#x"), let n = UInt32(entity.dropFirst(2), radix: 16), let s = Unicode.Scalar(n) {
                    out.unicodeScalars.append(s)
                } else if entity.hasPrefix("#"), let n = UInt32(entity.dropFirst()), let s = Unicode.Scalar(n) {
                    out.unicodeScalars.append(s)
                } else {
                    out += "&" + entity + ";"
                }
            }
            rest = rest[rest.index(after: semi)...]
        }
        return out + rest
    }
}

// MARK: - YAML

/// Block YAML: mappings, sequences -- compact ones too, `- key: value` --
/// scalars plain, quoted or in blocks, empty `{}` and `[]`. Flow collections
/// with something in them are values, as written. One document.
private nonisolated struct YAMLTree {
    let text: NSString

    struct Line {
        let start: Int
        let indent: Int
        /// Without a comment and trailing spaces.
        let contentEnd: Int
        let end: Int
        var isBlank: Bool { contentEnd <= start + indent }
        var contentStart: Int { start + indent }
    }

    var lines: [Line] = []
    var l = 0

    init(_ text: NSString) {
        self.text = text
        var at = 0
        while at < text.length {
            let range = text.lineRange(for: NSRange(location: at, length: 0))
            var end = NSMaxRange(range)
            if end > range.location, text.character(at: end - 1) == 0x0A { end -= 1 }
            if end > range.location, text.character(at: end - 1) == 0x0D { end -= 1 }
            var indent = 0
            while range.location + indent < end, text.character(at: range.location + indent) == 0x20 { indent += 1 }
            lines.append(Line(start: range.location, indent: indent,
                              contentEnd: Self.contentEnd(text, from: range.location + indent, to: end), end: end))
            at = NSMaxRange(range)
        }
    }

    /// Where a line's content ends: before a comment, without trailing spaces.
    static func contentEnd(_ text: NSString, from start: Int, to end: Int) -> Int {
        var quote: UInt16?
        var at = start
        var last = start
        while at < end {
            let c = text.character(at: at)
            if let q = quote {
                if c == q { quote = nil }
            } else if c == 0x22 || c == 0x27 {
                let before: UInt16 = at > start ? text.character(at: at - 1) : 0x20
                if [0x20, 0x3A, 0x2D, 0x5B, 0x7B, 0x2C].contains(before) || at == start { quote = c }
            } else if c == 0x23, at == start || [0x20, 0x09].contains(text.character(at: at - 1)) {
                break
            }
            at += 1
            if c != 0x20, c != 0x09 { last = at }
        }
        return last
    }

    func string(_ from: Int, _ to: Int) -> String {
        text.substring(with: NSRange(location: from, length: max(0, to - from)))
    }

    mutating func skipBlank() {
        while l < lines.count, lines[l].isBlank { l += 1 }
    }

    mutating func parse() -> StructureNode? {
        if text.range(of: "\t").location != NSNotFound {
            // Tabs indenting: not YAML; the tree would guess.
            for line in lines where line.start + line.indent < line.end
                && text.character(at: line.start + line.indent) == 0x09 { return nil }
        }
        skipBlank()
        // %YAML and %TAG directives, before the ---.
        while l < lines.count, lines[l].indent == 0, string(lines[l].start, lines[l].contentEnd).hasPrefix("%") {
            l += 1
            skipBlank()
        }
        if l < lines.count, string(lines[l].contentStart, lines[l].contentEnd).hasPrefix("---") {
            l += 1
            skipBlank()
        }
        var document = StructureNode(kind: .document, range: NSRange(location: 0, length: text.length))
        guard l < lines.count else { return document }
        let line = lines[l]
        guard let root = block(column: line.indent, first: line.contentStart) else { return nil }
        document.children = [root]
        skipBlank()
        if l < lines.count {
            let rest = string(lines[l].contentStart, lines[l].contentEnd)
            if rest.hasPrefix("...") { return document }
            return nil
        }
        return document
    }

    /// A key at `start`: its range, and where its colon is.
    func key(at start: Int, end: Int) -> (range: NSRange, colon: Int, quote: Character?)? {
        guard start < end else { return nil }
        let first = text.character(at: start)
        if first == 0x22 || first == 0x27 {
            var at = start + 1
            while at < end {
                let c = text.character(at: at)
                if c == 0x5C, first == 0x22 { at += 2; continue }
                if c == first {
                    if first == 0x27, at + 1 < end, text.character(at: at + 1) == 0x27 { at += 2; continue }
                    break
                }
                at += 1
            }
            guard at < end, at + 1 < end || at + 1 == end else { return nil }
            let colon = at + 1
            guard colon < end, text.character(at: colon) == 0x3A,
                  colon + 1 == end || text.character(at: colon + 1) == 0x20 else { return nil }
            return (NSRange(location: start, length: colon - start), colon, Character(UnicodeScalar(first)!))
        }
        if [0x2D, 0x5B, 0x7B, 0x3F, 0x26, 0x2A, 0x21, 0x7C, 0x3E].contains(first) {
            if first == 0x2D, start + 1 < end, text.character(at: start + 1) != 0x20 {
                // -x: a key that starts with a hyphen.
            } else {
                return nil
            }
        }
        var at = start
        while at < end {
            if text.character(at: at) == 0x3A, at + 1 == end || text.character(at: at + 1) == 0x20 {
                return (NSRange(location: start, length: at - start), at, nil)
            }
            at += 1
        }
        return nil
    }

    func isItem(at start: Int, end: Int) -> Bool {
        start < end && text.character(at: start) == 0x2D && (start + 1 == end || text.character(at: start + 1) == 0x20)
    }

    /// A mapping or sequence whose entries are at `column`, the first one
    /// starting at `first` -- mid-line after a dash for a compact one.
    mutating func block(column: Int, first: Int) -> StructureNode? {
        let line = lines[l]
        let sequence = isItem(at: first, end: line.contentEnd)
        var node = StructureNode(kind: sequence ? .sequence : .mapping,
                                 range: NSRange(location: first, length: 0))
        var start = first
        while true {
            guard let entry = sequence ? item(at: start, column: column) : entry(at: start, column: column)
            else { return nil }
            node.children.append(entry)
            skipBlank()
            guard l < lines.count else { break }
            let next = lines[l]
            if next.indent < column { break }
            if next.indent > column { return nil }
            let begins = next.contentStart
            if sequence != isItem(at: begins, end: next.contentEnd) {
                if string(begins, next.contentEnd).hasPrefix("---") || string(begins, next.contentEnd).hasPrefix("...") {
                    break
                }
                // A sequence under a key at the key's own column ends here.
                if sequence { break }
                return nil
            }
            start = begins
        }
        let last = node.children.last!
        node.range.length = NSMaxRange(last.range) - first
        return node
    }

    /// What follows a key or a dash on its line, at `start`, for an entry at
    /// `column`: a value, a block under it, or nothing.
    mutating func value(into node: inout StructureNode, from start: Int, column: Int, isItem: Bool) -> Bool {
        let line = lines[l]
        let rest = string(start, line.contentEnd)
        var end = line.contentEnd
        if rest.isEmpty || rest.range(of: #"^[&!][^ ]*$"#, options: .regularExpression) != nil {
            l += 1
            skipBlank()
            if l < lines.count {
                let next = lines[l]
                let deeper = next.indent > column
                let sameColumnSequence = !isItem && next.indent == column
                    && self.isItem(at: next.contentStart, end: next.contentEnd)
                if deeper || sameColumnSequence {
                    guard let child = block(column: next.indent, first: next.contentStart) else { return false }
                    node.kind = child.kind
                    node.children = child.children
                    node.range.length = NSMaxRange(child.range) - node.range.location
                    return true
                }
            }
            node.kind = .scalar
            if !rest.isEmpty {
                node.value = rest
                node.valueRange = NSRange(location: start, length: end - start)
            } else {
                node.value = ""
            }
            node.range.length = end - node.range.location
            return true
        }
        if isItem, isItemStart(rest) || key(at: start, end: line.contentEnd) != nil {
            // Compact: `- key: value` or `- - x`, its own column after the dash.
            let compactColumn = start - line.start
            guard let child = block(column: compactColumn, first: start) else { return false }
            node.kind = child.kind
            node.children = child.children
            node.range.length = NSMaxRange(child.range) - node.range.location
            return true
        }
        if rest == "{}" || rest == "[]" {
            node.kind = rest == "{}" ? .mapping : .sequence
            node.flow = true
            node.valueRange = NSRange(location: start, length: 2)
            node.range.length = start + 2 - node.range.location
            l += 1
            return true
        }
        node.kind = .scalar
        if rest.hasPrefix("[") || rest.hasPrefix("{"), case var depth = Self.flowDepth(rest), depth > 0 {
            // A flow collection over several lines, at any indentation: one value.
            var parts = [rest]
            l += 1
            while l < self.lines.count, depth > 0 {
                let next = self.lines[l]
                let part = string(next.contentStart, next.contentEnd)
                if !next.isBlank {
                    depth += Self.flowDepth(part)
                    parts.append(part)
                    end = next.contentEnd
                }
                l += 1
            }
            guard depth == 0 else { return false }
            node.value = parts.joined(separator: " ")
            node.valueRange = NSRange(location: start, length: end - start)
            node.range.length = end - node.range.location
            return true
        }
        let isBlockScalar = rest.hasPrefix("|") || rest.hasPrefix(">")
        l += 1
        // Lines further in belong to it: a block scalar, or a value going on.
        var lines: [String] = []
        while l < self.lines.count {
            let next = self.lines[l]
            if next.isBlank {
                if isBlockScalar { lines.append(""); l += 1; continue }
                var ahead = l
                while ahead < self.lines.count, self.lines[ahead].isBlank { ahead += 1 }
                if ahead < self.lines.count, self.lines[ahead].indent > column { l += 1; continue }
                break
            }
            guard next.indent > column else { break }
            end = isBlockScalar ? next.end : next.contentEnd
            lines.append(string(next.contentStart, isBlockScalar ? next.end : next.contentEnd))
            l += 1
        }
        while lines.last == "" { lines.removeLast() }
        node.valueRange = NSRange(location: start, length: end - start)
        node.range.length = end - node.range.location
        if isBlockScalar {
            node.value = lines.joined(separator: rest.hasPrefix(">") ? " " : "\n")
        } else {
            let whole = ([rest] + lines).joined(separator: " ")
            let (value, quote) = Self.unquote(whole)
            node.value = value
            node.quote = quote
        }
        return true
    }

    func isItemStart(_ rest: String) -> Bool { rest == "-" || rest.hasPrefix("- ") }

    /// Brackets opened less those closed, outside quotes.
    static func flowDepth(_ text: String) -> Int {
        var depth = 0
        var quote: Character?
        for c in text {
            if let q = quote {
                if c == q { quote = nil }
                continue
            }
            switch c {
            case "\"", "'": quote = c
            case "[", "{": depth += 1
            case "]", "}": depth -= 1
            default: break
            }
        }
        return depth
    }

    mutating func entry(at start: Int, column: Int) -> StructureNode? {
        let line = lines[l]
        guard let key = key(at: start, end: line.contentEnd) else { return nil }
        let keyText = text.substring(with: key.range)
        var node = StructureNode(kind: .scalar, key: Self.unquote(keyText).0, keyRange: key.range,
                                 range: NSRange(location: start, length: 0))
        node.keyQuote = key.quote
        node.afterColon = key.colon + 1
        var valueStart = key.colon + 1
        while valueStart < line.contentEnd, text.character(at: valueStart) == 0x20 { valueStart += 1 }
        guard value(into: &node, from: valueStart, column: column, isItem: false) else { return nil }
        if node.isContainer, !node.flow { node.valueRange = nil }
        return node
    }

    mutating func item(at start: Int, column: Int) -> StructureNode? {
        let line = lines[l]
        var valueStart = start + 1
        while valueStart < line.contentEnd, text.character(at: valueStart) == 0x20 { valueStart += 1 }
        var node = StructureNode(kind: .scalar, range: NSRange(location: start, length: 0))
        guard value(into: &node, from: valueStart, column: column, isItem: true) else { return nil }
        if node.isContainer, !node.flow, node.children.first.map({ $0.range.location > valueStart }) ?? true {
            node.valueRange = nil
        } else if node.isContainer, !node.flow {
            // Compact: the value starts on the dash's line.
            node.valueRange = NSRange(location: valueStart, length: 0)
        }
        return node
    }

    static func unquote(_ text: String) -> (String, Character?) {
        if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") {
            return (String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'"), "'")
        }
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            let inner = String(text.dropFirst().dropLast())
            return ((try? JSONDecoder().decode(String.self, from: Data(("\"" + inner + "\"").utf8)))
                    ?? inner, "\"")
        }
        return (text, nil)
    }
}

/// A move is the node taken out, the text read again, and the node put in:
/// where it goes, counted again once it is out.
nonisolated enum TreeMoves {
    static func adjust(parent: [Int], index: Int, afterRemoving path: [Int]) -> ([Int], Int) {
        guard let removed = path.last else { return (parent, index) }
        let removedParent = Array(path.dropLast())
        var parent = parent
        var index = index
        if parent == removedParent {
            if index > removed { index -= 1 }
        } else if parent.count > removedParent.count,
                  Array(parent.prefix(removedParent.count)) == removedParent,
                  parent[removedParent.count] > removed {
            parent[removedParent.count] -= 1
        }
        return (parent, index)
    }
}
