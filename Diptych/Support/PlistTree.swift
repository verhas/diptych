import Foundation

/// A property list's XML as a tree of keys and values: a dictionary's
/// `<key>` and the element after it are one node, named by the key.
///
/// The XML is what is edited, as with the other formats: a change replaces
/// a key's text or a value's element and leaves the rest of the file -- its
/// tabs, its comments -- as it was.
nonisolated struct PlistTree {
    let text: NSString

    init(_ text: NSString) { self.text = text }

    func parse() -> StructureNode? {
        guard let nodes = XMLDocumentReader.parse(text),
              let plist = nodes.first(where: { $0.kind == .element }), plist.name == "plist" else { return nil }
        let values = plist.children.filter { $0.kind == .element }
        guard values.count == 1, let top = value(values[0], key: nil) else { return nil }
        return StructureNode(kind: .document, range: NSRange(location: 0, length: text.length), children: [top])
    }

    private func value(_ xml: XMLNode, key: XMLNode?) -> StructureNode? {
        guard let kind = Self.kind(of: xml.name) else { return nil }
        var node = StructureNode(kind: kind, range: xml.range, inner: xml.inner, selfClosing: xml.selfClosing)
        node.element = xml.range
        if let key {
            node.key = XMLTree.decode(key.inner.map(text.substring) ?? "")
            node.keyRange = key.inner
            node.range = NSRange(location: key.range.location, length: NSMaxRange(xml.range) - key.range.location)
        }
        let elements = xml.children.filter { $0.kind == .element }
        switch kind {
        case .dictionary:
            guard elements.count.isMultiple(of: 2) else { return nil }
            for index in stride(from: 0, to: elements.count, by: 2) {
                guard elements[index].name == "key",
                      let member = value(elements[index + 1], key: elements[index]) else { return nil }
                node.children.append(member)
            }
        case .array:
            for element in elements {
                guard let item = value(element, key: nil) else { return nil }
                node.children.append(item)
            }
        case .boolean:
            node.value = xml.name
        default:
            guard elements.isEmpty else { return nil }
            let raw = xml.inner.map(text.substring) ?? ""
            // A string keeps its spaces; a number, a date or data does not mean them.
            node.value = XMLTree.decode(kind == .string ? raw : raw.trimmingCharacters(in: .whitespacesAndNewlines))
            node.valueRange = xml.inner
        }
        return node
    }

    static func kind(of name: String) -> StructureNode.Kind? {
        switch name {
        case "dict": .dictionary
        case "array": .array
        case "string": .string
        case "integer": .integer
        case "real": .real
        case "true", "false": .boolean
        case "date": .date
        case "data": .data
        default: nil
        }
    }
}

extension StructureEditor {

    static let plistKinds: [StructureNode.Kind] = [.string, .integer, .real, .boolean, .date, .data,
                                                   .dictionary, .array]

    /// The written value of `text` as `kind`, or nil when it is not one --
    /// `12.5` is no integer, `maybe` no boolean.
    static func plistValue(_ text: String, as kind: StructureNode.Kind) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .string: return text
        case .integer: return Int(trimmed).map(String.init)
        case .real: return Double(trimmed) != nil && !trimmed.isEmpty ? trimmed : nil
        case .boolean: return boolean(trimmed).map { $0 ? "true" : "false" }
        case .date: return ISO8601DateFormatter().date(from: trimmed) != nil ? trimmed : nil
        case .data:
            let packed = trimmed.filter { !$0.isWhitespace }
            return Data(base64Encoded: packed) != nil ? packed : nil
        default: return nil
        }
    }

    /// A value's element: what it was turned into where it can be, an
    /// empty or zero one where it cannot.
    static func plistElement(_ kind: StructureNode.Kind, value: String?) -> String {
        let written = value.flatMap { plistValue($0, as: kind) }
        switch kind {
        case .dictionary: return "<dict/>"
        case .array: return "<array/>"
        case .boolean: return written == "true" ? "<true/>" : "<false/>"
        case .string: return "<string>\(xmlEscape(written ?? "", quote: nil))</string>"
        case .integer: return "<integer>\(written ?? "0")</integer>"
        case .real: return "<real>\(written ?? "0.0")</real>"
        case .date:
            let now = ISO8601DateFormatter().string(from: Date())
            return "<date>\(written ?? now)</date>"
        case .data: return "<data>\(written ?? "")</data>"
        default: return "<string></string>"
        }
    }

    func plistSetValue(_ node: StructureNode, _ path: [Int], _ value: String) -> TreeEdit? {
        guard let element = node.element, Self.plistValue(value, as: node.kind) != nil else { return nil }
        return TreeEdit(changes: [TextChange(range: element, text: Self.plistElement(node.kind, value: value))],
                        select: path)
    }

    func insertPlist(_ fragment: TreeFragment, into parent: StructureNode, _ parentPath: [Int],
                     at wanted: Int) -> TreeEdit? {
        guard [.dictionary, .array].contains(parent.kind), let element = parent.element else { return nil }
        let index = min(max(0, wanted), parent.children.count)
        let key: String
        let value: (String) -> String
        switch fragment {
        case .new(let kind, let wantedKey, let wantedValue):
            key = uniqueKey(wantedKey ?? "key", in: parent)
            value = { _ in Self.plistElement(kind, value: wantedValue) }
        case .copy(let copied):
            key = uniqueKey(copied.key ?? "key", in: parent)
            value = { Self.reindent(copied.valueText ?? copied.text, from: copied.pad, to: $0) }
        }
        let body: (String) -> String = { pad in
            parent.kind == .dictionary
                ? "<key>\(Self.xmlEscape(key, quote: nil))</key>\n" + pad + value(pad) : value(pad)
        }
        let parentPad = pad(at: element.location)
        if parent.selfClosing {
            let name = parent.kind == .dictionary ? "dict" : "array"
            let childPad = parentPad + indent.unit
            return TreeEdit(changes: [TextChange(range: element,
                                                 text: "<\(name)>\n" + childPad + body(childPad) + "\n"
                                                    + parentPad + "</\(name)>")],
                            select: parentPath + [index])
        }
        return place(body, among: parent.children, at: index, separator: "", emptyInner: parent.inner,
                     parentPad: parentPad, select: parentPath + [index])
    }
}
