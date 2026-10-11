import Foundation

/// Where a node of the tree is, written as the tools for its format write
/// it: an XPath for XML, a JSONPath for JSON -- `$.store.book[0].title` --
/// for YAML the path `yq` takes, `.store.book[0].title`, and for a plist
/// the one PlistBuddy takes, `:CFBundleURLTypes:0:CFBundleURLSchemes`.
nonisolated enum StructurePath {

    /// The right-click menu's item.
    static func title(for format: TextFormat) -> String {
        switch format {
        case .xml: "Copy XPath"
        case .json: "Copy JSON Path"
        case .yaml, .toml: "Copy YAML Path"
        case .plist: "Copy Key Path"
        }
    }

    /// Nil where there is no such path: the DOCTYPE has no XPath.
    static func path(_ path: [Int], in root: StructureNode, format: TextFormat) -> String? {
        switch format {
        case .xml: xpath(path, in: root)
        case .json: keyed(path, in: root, start: "$", quoted: { "['\(escape($0, "'"))']" })
        case .yaml: keyed(path, in: root, start: ".", quoted: { ".\"\(escape($0, "\""))\"" })
        case .plist: keyPath(path, in: root)
        case .toml: nil
        }
    }

    /// PlistBuddy's: each key or index after a colon.
    private static func keyPath(_ path: [Int], in root: StructureNode) -> String? {
        guard let top = path.first, var node = root.node(at: [top]) else { return nil }
        var written = ""
        for index in path.dropFirst() {
            guard index < node.children.count else { return nil }
            let child = node.children[index]
            written += ":" + (node.kind == .dictionary ? child.key ?? "" : String(index))
            node = child
        }
        return written.isEmpty ? ":" : written
    }

    private static func escape(_ key: String, _ quote: Character) -> String {
        key.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: String(quote), with: "\\" + String(quote))
    }

    /// Written after a dot; anything else is quoted.
    private static func isIdentifier(_ key: String) -> Bool {
        key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    /// JSON and YAML: keys after dots, indexes in brackets. The first step
    /// is the document's one value, which the start stands for.
    private static func keyed(_ path: [Int], in root: StructureNode, start: String,
                              quoted: (String) -> String) -> String? {
        guard let top = path.first, var node = root.node(at: [top]) else { return nil }
        var written = start
        for index in path.dropFirst() {
            guard index < node.children.count else { return nil }
            let child = node.children[index]
            if [.object, .mapping].contains(node.kind), let key = child.key {
                if isIdentifier(key) {
                    written += written == "." ? key : "." + key
                } else {
                    let step = quoted(key)
                    // yq: `."a b"`, and at the start `."a b"` too, not `.."a b"`.
                    written += written == "." && step.hasPrefix(".") ? String(step.dropFirst()) : step
                }
            } else {
                written += "[\(index)]"
            }
            node = child
        }
        return written
    }

    /// XML: element names with a position where a name repeats, `@name` for
    /// an attribute, `text()`, `comment()` and `processing-instruction()`.
    private static func xpath(_ path: [Int], in root: StructureNode) -> String? {
        var node = root
        var written = ""
        for index in path {
            guard index < node.children.count else { return nil }
            let child = node.children[index]
            let siblings = Array(node.content)
            func step(_ name: String, matching: (StructureNode) -> Bool) -> String {
                let same = siblings.filter(matching)
                guard same.count > 1, let position = same.firstIndex(where: { $0 == child }) else { return name }
                return "\(name)[\(position + 1)]"
            }
            switch child.kind {
            case .element:
                let name = child.key ?? "*"
                written += "/" + step(name) { $0.kind == .element && $0.key == child.key }
            case .attribute:
                written += "/@" + (child.key ?? "*")
            case .text, .cdata:
                written += "/" + step("text()") { [.text, .cdata].contains($0.kind) }
            case .comment:
                written += "/" + step("comment()") { $0.kind == .comment }
            case .instruction:
                let target = instructionTarget(child.value ?? "")
                written += "/" + step("processing-instruction('\(target)')") {
                    $0.kind == .instruction && instructionTarget($0.value ?? "") == target
                }
            default:
                return nil
            }
            node = child
        }
        return written.isEmpty ? "/" : written
    }

    private static func instructionTarget(_ text: String) -> String {
        let body = text.hasPrefix("<?") ? text.dropFirst(2) : Substring(text)
        return String(body.prefix { !$0.isWhitespace && $0 != "?" })
    }
}
