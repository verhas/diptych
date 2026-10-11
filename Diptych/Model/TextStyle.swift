import Foundation

/// How Text Edit indents, pairs and formats, from Settings ▸ Behaviour ▸
/// Text Edit. Indentation is by format, as editors keep it: two spaces in
/// JSON and YAML, four in XML and elsewhere, unless set otherwise. YAML is
/// always indented with spaces: tabs are not allowed in it.
nonisolated struct TextStyle: Codable, Equatable, Sendable {

    typealias Indent = LineEditing.Indent

    /// By `TextFormat.rawValue`, and `plain` for every other file.
    var indents: [String: Indent] = TextStyle.defaultIndents
    /// `{`, `[` and quotes typed get their closing one; typing it steps over.
    var closePairs = true
    /// XML: the grey rest of the markup, and the end tag put in after a start tag.
    var closeTags = true
    /// Format keeps at most this many empty lines where there were some.
    var keepBlankLines = 1
    /// JSON: `"key" : value` rather than `"key": value`.
    var jsonSpaceBeforeColon = false
    /// JSON: an array of numbers, strings and the like on one line.
    var jsonShortArraysOnOneLine = false
    /// XML: a tag with more than one attribute has each on a line of its own.
    var xmlAttributesOnLines = false
    /// XML: `<br />` rather than `<br/>`.
    var xmlSpaceBeforeSlash = false
    /// The tree's Type column. Off: the name and the colour of the value say
    /// as much -- `@` before an attribute, a number in blue.
    var treeShowsTypes = false
    /// The text's and the tree's size: View ▸ Bigger Text and Smaller Text
    /// while Text Edit is in front.
    var fontSize = TextStyle.defaultFontSize

    /// The structure around the caret, shaded: how many levels out the
    /// menu goes at most, and where a new window starts -- 0 for none.
    var emphasisLimit = 5
    var emphasisStart = 0

    static let defaultFontSize = 13.0
    static let emphasisLimits = 1 ... 9
    static let fontSizes = 8.0 ... 36.0

    static let plainKey = "plain"

    static let defaultIndents: [String: Indent] = [
        TextFormat.json.rawValue: .two,
        TextFormat.xml.rawValue: .standard,
        TextFormat.yaml.rawValue: .two,
        TextFormat.toml.rawValue: .standard,
        // As Xcode and plutil write them.
        TextFormat.plist.rawValue: Indent(tabs: true, width: 4),
        plainKey: .standard,
    ]

    func indent(for format: TextFormat?) -> Indent {
        let key = format?.rawValue ?? Self.plainKey
        var indent = indents[key] ?? Self.defaultIndents[key] ?? .standard
        if format == .yaml { indent.tabs = false }
        indent.width = min(max(indent.width, 1), 8)
        return indent
    }

    init() {}

    /// Every key optional, as in `Configuration`: a setting added later must
    /// not throw the rest away.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TextStyle()
        indents = defaults.indents.merging(
            (try? container.decode([String: Indent].self, forKey: .indents)) ?? [:]) { _, set in set }
        closePairs = (try? container.decode(Bool.self, forKey: .closePairs)) ?? defaults.closePairs
        closeTags = (try? container.decode(Bool.self, forKey: .closeTags)) ?? defaults.closeTags
        keepBlankLines = min(max((try? container.decode(Int.self, forKey: .keepBlankLines))
                                 ?? defaults.keepBlankLines, 0), 3)
        jsonSpaceBeforeColon = (try? container.decode(Bool.self, forKey: .jsonSpaceBeforeColon))
            ?? defaults.jsonSpaceBeforeColon
        jsonShortArraysOnOneLine = (try? container.decode(Bool.self, forKey: .jsonShortArraysOnOneLine))
            ?? defaults.jsonShortArraysOnOneLine
        xmlAttributesOnLines = (try? container.decode(Bool.self, forKey: .xmlAttributesOnLines))
            ?? defaults.xmlAttributesOnLines
        xmlSpaceBeforeSlash = (try? container.decode(Bool.self, forKey: .xmlSpaceBeforeSlash))
            ?? defaults.xmlSpaceBeforeSlash
        treeShowsTypes = (try? container.decode(Bool.self, forKey: .treeShowsTypes)) ?? defaults.treeShowsTypes
        fontSize = min(max((try? container.decode(Double.self, forKey: .fontSize)) ?? defaults.fontSize,
                           Self.fontSizes.lowerBound), Self.fontSizes.upperBound)
        emphasisLimit = min(max((try? container.decode(Int.self, forKey: .emphasisLimit)) ?? defaults.emphasisLimit,
                                Self.emphasisLimits.lowerBound), Self.emphasisLimits.upperBound)
        emphasisStart = min(max((try? container.decode(Int.self, forKey: .emphasisStart)) ?? defaults.emphasisStart,
                                0), emphasisLimit)
    }
}
