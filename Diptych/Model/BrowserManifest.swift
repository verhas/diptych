import Foundation

/// The serialized listing of one directory in a browsable source.
///
/// A manifest describes what a pane shows, apart from the bytes behind it:
/// each child's name, kind and typed attributes, and where -- if anywhere --
/// its content can be read. One manifest is one directory, so a source can
/// answer a directory at a time rather than describing a whole tree at once.
///
/// The format is deliberately general. Version 1 produces it only for file
/// sources (archives), where the attributes are the familiar file ones, but
/// nothing here assumes a file: a later source for processes or settings uses
/// its own attribute keys, columns and actions without changing the format.
/// See `object-browser-design.md`.
struct BrowserManifest: Codable, Equatable, Sendable {

    /// Marks the file as one of ours, so the reader can tell it from an
    /// archive entry that happens to be named like the manifest.
    static let marker = "diptych.browser.v1"
    var format = BrowserManifest.marker
    /// Raised only for a change the older reader could not understand.
    var schema = 1
    /// What produced it: "archive" now; "sftp", "process"… later. Data for
    /// the reader, never shown.
    var source: String
    /// Source-specific locator and freshness, opaque to the UI (an archive's
    /// path, its SHA-256, the holder its backing store is under).
    var origin: [String: String] = [:]
    var capabilities = Capabilities()
    /// The columns the source wants shown; nil means the standard file
    /// columns, which is all version 1 uses.
    var columns: [Column]?
    /// This directory's children.
    var nodes: [Node]

    init(schema: Int = 1, source: String, origin: [String: String] = [:],
         capabilities: Capabilities = Capabilities(), columns: [Column]? = nil, nodes: [Node]) {
        self.schema = schema
        self.source = source
        self.origin = origin
        self.capabilities = capabilities
        self.columns = columns
        self.nodes = nodes
    }

    private enum CodingKeys: String, CodingKey {
        case format, schema, source, origin, capabilities, columns, nodes
    }

    // Tolerant of missing fields, so a newer reader opens an older manifest
    // and a reader opens one written without the optional parts.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = (try? container.decode(String.self, forKey: .format)) ?? ""
        schema = (try? container.decode(Int.self, forKey: .schema)) ?? 1
        source = (try? container.decode(String.self, forKey: .source)) ?? ""
        origin = (try? container.decode([String: String].self, forKey: .origin)) ?? [:]
        capabilities = (try? container.decode(Capabilities.self, forKey: .capabilities)) ?? Capabilities()
        columns = try? container.decode([Column].self, forKey: .columns)
        nodes = (try? container.decode([Node].self, forKey: .nodes)) ?? []
    }

    /// What may be done to a source, beyond reading it.
    struct Capabilities: Codable, Equatable, Sendable {
        /// Items can be changed in place -- contents, permissions, anything.
        /// False for an archive; a future SFTP source sets it.
        var writable = false
        /// Verbs the source offers that are not the file ones -- "kill",
        /// "disable" -- named by the source, surfaced later as a menu. Empty
        /// for a file source.
        var actions: [String] = []
    }

    /// A column a non-file source wants shown. Absent for file sources, which
    /// use the pane's usual columns.
    struct Column: Codable, Equatable, Sendable {
        var key: String
        var title: String
        var type: AttributeType
    }

    /// One row.
    struct Node: Codable, Equatable, Sendable {
        /// Stable within the source. For a file it is the path relative to the
        /// source root; for a process it would be a pid. Opaque to the UI.
        var id: String
        var kind: Kind
        var name: String
        /// Typed values by key. File sources use the well-known keys in
        /// `Attribute`; other sources use their own.
        var attributes: [String: AttributeValue] = [:]
        /// For a symlink, where it points -- shown as data, never followed off
        /// the source.
        var linkTarget: String?
        /// How to get a local file to open, preview or copy out: a path in the
        /// backing store, content generated on demand, or -- for a lazy source
        /// -- nothing until it is materialized.
        var backing: Backing = .none

        func attribute(_ key: String) -> AttributeValue? { attributes[key] }

        init(id: String, kind: Kind, name: String,
             attributes: [String: AttributeValue] = [:], linkTarget: String? = nil,
             backing: Backing = .none) {
            self.id = id
            self.kind = kind
            self.name = name
            self.attributes = attributes
            self.linkTarget = linkTarget
            self.backing = backing
        }

        private enum CodingKeys: String, CodingKey {
            case id, kind, name, attributes, linkTarget, backing
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? container.decode(String.self, forKey: .id)) ?? ""
            kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .other
            name = (try? container.decode(String.self, forKey: .name)) ?? ""
            attributes = (try? container.decode([String: AttributeValue].self, forKey: .attributes)) ?? [:]
            linkTarget = try? container.decode(String.self, forKey: .linkTarget)
            backing = (try? container.decode(Backing.self, forKey: .backing)) ?? .none
        }
    }

    enum Kind: String, Codable, Sendable {
        case file, directory, symlink, other
        // Version 2: process, setting, job, socket…
    }

    enum Backing: Codable, Equatable, Sendable {
        /// A path in the source's backing store, relative to its holder.
        case file(String)
        /// Generated when asked -- a folder listing, a process report.
        case report
        /// Not materialized yet; a lazy source fetches on demand.
        case none

        private enum CodingKeys: String, CodingKey { case t, v }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .t) {
            case "file": self = .file(try container.decode(String.self, forKey: .v))
            case "report": self = .report
            default: self = .none
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .file(let path):
                try container.encode("file", forKey: .t)
                try container.encode(path, forKey: .v)
            case .report: try container.encode("report", forKey: .t)
            case .none: try container.encode("none", forKey: .t)
            }
        }
    }

    /// The well-known attribute keys a file source fills in. Other sources are
    /// free to use their own strings.
    enum Attribute {
        static let size = "size"
        static let mode = "mode"
        static let uid = "uid"
        static let gid = "gid"
        static let modified = "mtime"
        static let created = "btime"
    }
}

/// How an attribute's value should be read and shown, so the UI can render and
/// sort it without knowing the source.
enum AttributeType: String, Codable, Sendable {
    case int, string, date, mode, size, user, bool
}

/// A typed attribute value. Tagged on the wire (`{"t":"size","v":1024}`) so a
/// reader that does not know the key still parses it and a new type is added
/// without breaking the old reader.
enum AttributeValue: Equatable, Sendable {
    case int(Int64)
    case string(String)
    case date(Double)
    case bool(Bool)
    /// A value whose type this version does not know; kept so it round-trips.
    case unknown(type: String, raw: String)

    var intValue: Int64? { if case .int(let v) = self { return v }; return nil }
    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    var dateValue: Date? { if case .date(let v) = self { return Date(timeIntervalSince1970: v) }; return nil }
    var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }

    static func size(_ value: Int64) -> AttributeValue { .int(value) }
    static func mode(_ value: UInt16) -> AttributeValue { .int(Int64(value)) }
    static func user(_ value: UInt32) -> AttributeValue { .int(Int64(value)) }
    static func date(_ value: Date) -> AttributeValue { .date(value.timeIntervalSince1970) }
}

extension AttributeValue: Codable {
    private enum CodingKeys: String, CodingKey { case t, v }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .t)
        switch type {
        case "int", "mode", "size", "user":
            self = .int(try container.decode(Int64.self, forKey: .v))
        case "string": self = .string(try container.decode(String.self, forKey: .v))
        case "date": self = .date(try container.decode(Double.self, forKey: .v))
        case "bool": self = .bool(try container.decode(Bool.self, forKey: .v))
        default:
            // Keep the raw value as text so an unknown type survives a load
            // and save unchanged.
            let raw = (try? container.decode(String.self, forKey: .v))
                ?? (try? String(container.decode(Double.self, forKey: .v)))
                ?? (try? String(container.decode(Int64.self, forKey: .v))) ?? ""
            self = .unknown(type: type, raw: raw)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .int(let v): try container.encode("int", forKey: .t); try container.encode(v, forKey: .v)
        case .string(let v): try container.encode("string", forKey: .t); try container.encode(v, forKey: .v)
        case .date(let v): try container.encode("date", forKey: .t); try container.encode(v, forKey: .v)
        case .bool(let v): try container.encode("bool", forKey: .t); try container.encode(v, forKey: .v)
        case .unknown(let type, let raw):
            try container.encode(type, forKey: .t); try container.encode(raw, forKey: .v)
        }
    }
}
