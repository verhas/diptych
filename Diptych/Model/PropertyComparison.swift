import Foundation

/// Everything about two files besides what is in them, side by side: size,
/// permissions, owner, group, flags, dates, access control list and every
/// extended attribute.
///
/// What a folder comparison or a sync means when it says two files differ in
/// "permissions" or "extended attributes" -- comparing the text shows nothing
/// then, and this is what does. Read without following a symlink, the same
/// way the folder comparison reads.
nonisolated struct PropertyComparison: Sendable, Equatable {

    struct Row: Sendable, Equatable, Identifiable {
        var id: String { name }
        var name: String
        /// Nil where that side does not have it at all -- an attribute on one
        /// file only, or a side that could not be read.
        var left: String?
        var right: String?
        /// Told from the values themselves, not from how they are shown: two
        /// long attributes can show the same first bytes and still differ.
        var differs: Bool
    }

    var rows: [Row]
    /// Whether the two hold the same bytes, for two files; nil when that was
    /// not asked or could not be told. Two texts can read the same and not be
    /// -- line endings, a byte-order mark, another encoding.
    var bytesAreSame: Bool?

    var differing: [Row] { rows.filter(\.differs) }

    /// The names of what differs, for a line saying so.
    var summary: String {
        let names = differing.map { $0.name.hasPrefix(Self.attributePrefix)
            ? String($0.name.dropFirst(Self.attributePrefix.count)) : $0.name.lowercased() }
        return names.joined(separator: ", ")
    }

    static let attributePrefix = "Attribute "

    /// What differs, as the folder comparison's letters say it. Only what a
    /// file carries besides its bytes: kind, size and a link's target are
    /// left to whoever asks for them.
    var differences: DirectoryComparison.Difference {
        var differences: DirectoryComparison.Difference = []
        for row in differing {
            switch row.name {
            case "Permissions": differences.insert(.permissions)
            case "Owner", "Group": differences.insert(.ownership)
            case "Modified": differences.insert(.modified)
            case "Created": differences.insert(.created)
            case "Access control list": differences.insert(.acl)
            default:
                if row.name.hasPrefix(Self.attributePrefix) { differences.insert(.attributes) }
            }
        }
        return differences
    }

    /// One side as read from the disk.
    private struct Side {
        var info: stat?
        var linkTarget: String?
        var attributes: [String: Data?] = [:]
        var acl: String?
    }

    static func of(_ left: URL, _ right: URL, comparingBytes: Bool = false) -> PropertyComparison {
        let l = read(left.path)
        let r = read(right.path)
        var rows: [Row] = []

        func add(_ name: String, _ value: (Side) -> String?, same: ((Side, Side) -> Bool)? = nil) {
            let a = value(l)
            let b = value(r)
            rows.append(Row(name: name, left: a, right: b, differs: same.map { !$0(l, r) } ?? (a != b)))
        }

        add("Kind") { $0.info.map(kind) }
        add("Size") { $0.info.map { BinaryComparison.bytes(Int64($0.st_size)) } }
            same: { $0.info?.st_size == $1.info?.st_size }
        add("Permissions") { $0.info.map { FileOperations.rwxString($0.st_mode & 0o7777) } }
            same: { ($0.info?.st_mode ?? 0) & 0o7777 == ($1.info?.st_mode ?? 0) & 0o7777 }
        add("Owner") { $0.info.map { userName($0.st_uid) } }
        add("Group") { $0.info.map { groupName($0.st_gid) } }
        add("Flags") { $0.info.map { flags($0.st_flags) } }
        add("Modified") { $0.info.map { time($0.st_mtimespec) } }
        add("Created") { $0.info.map { time($0.st_birthtimespec) } }
        if l.linkTarget != nil || r.linkTarget != nil {
            add("Link target") { $0.linkTarget }
        }
        add("Access control list") { side in side.info.map { _ in describeACL(side.acl) } }

        let names = Set(l.attributes.keys).union(r.attributes.keys)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for name in names {
            add(attributePrefix + name) { side in
                side.attributes[name].map { describe($0) }
            } same: { a, b in
                // An unreadable value is never called the same as anything.
                guard let x = a.attributes[name], let y = b.attributes[name] else { return false }
                return x != nil && x == y
            }
        }

        var bytesAreSame: Bool?
        if comparingBytes, let a = l.info, let b = r.info,
           a.st_mode & S_IFMT == S_IFREG, b.st_mode & S_IFMT == S_IFREG {
            bytesAreSame = a.st_size == b.st_size
                && ((try? BinaryComparison.compare(left, right).isIdentical) ?? false)
        }
        return PropertyComparison(rows: rows, bytesAreSame: bytesAreSame)
    }

    // MARK: - Reading

    private static func read(_ path: String) -> Side {
        var side = Side()
        var info = stat()
        guard lstat(path, &info) == 0 else { return side }
        side.info = info
        let isLink = info.st_mode & S_IFMT == S_IFLNK
        if isLink {
            side.linkTarget = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? ""
        }
        let snapshot = DirectoryComparison.AttributeSnapshot.readNoFollow(at: path)
        for (name, data) in snapshot.readable { side.attributes[name] = .some(data) }
        for name in snapshot.unreadableNames { side.attributes[name] = .some(nil) }
        side.acl = DirectoryComparison.acl(at: path, isSymlink: isLink)
        return side
    }

    // MARK: - Showing

    private static func kind(_ info: stat) -> String {
        switch info.st_mode & S_IFMT {
        case S_IFDIR: "folder"
        case S_IFLNK: "symbolic link"
        case S_IFREG: info.st_nlink > 1 ? "file, \(info.st_nlink) hard links" : "file"
        default: "special file"
        }
    }

    private static func userName(_ uid: uid_t) -> String {
        guard let pw = getpwuid(uid) else { return "\(uid)" }
        return String(cString: pw.pointee.pw_name)
    }

    private static func groupName(_ gid: gid_t) -> String {
        guard let gr = getgrgid(gid) else { return "\(gid)" }
        return String(cString: gr.pointee.gr_name)
    }

    private static func flags(_ value: UInt32) -> String {
        guard value != 0, let raw = fflagstostr(UInt(value)) else { return "none" }
        defer { free(raw) }
        return String(cString: raw)
    }

    /// Local time, to the nanosecond when there is a fraction: two dates a
    /// sync calls different can be the same second.
    static func time(_ spec: timespec) -> String {
        var seconds = spec.tv_sec
        var parts = tm()
        localtime_r(&seconds, &parts)
        var buffer = [CChar](repeating: 0, count: 64)
        strftime(&buffer, buffer.count, "%Y-%m-%d %H:%M:%S", &parts)
        let whole = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                           as: UTF8.self)
        return spec.tv_nsec == 0 ? whole : whole + String(format: ".%09ld", spec.tv_nsec)
    }

    /// One line per entry, `name: allow read,write`, rather than the
    /// `user:UUID:name:id:allow:perms` lines `acl_to_text` gives.
    private static func describeACL(_ text: String?) -> String {
        guard let text else { return "none" }
        let lines = text.split(separator: "\n").filter { !$0.hasPrefix("!#acl") }.map { line in
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 6 else { return String(line) }
            let name = fields[2].isEmpty ? String(fields[1]) : String(fields[2])
            return "\(fields[0]) \(name): \(fields[4]) \(fields[5])"
        }
        return lines.isEmpty ? "none" : lines.joined(separator: "\n")
    }

    /// An attribute's value as something to read: text as text, a property
    /// list by what it holds, the rest as hex.
    private static func describe(_ data: Data?) -> String {
        guard let data else { return "(macOS does not let this be read)" }
        if data.starts(with: Array("bplist".utf8)),
           let value = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            return plist(value)
        }
        let attribute = ExtendedAttributes.Attribute(name: "", data: data)
        if let text = attribute.text { return text }
        if data.isEmpty { return "(empty)" }
        return attribute.hexPreview + "  (\(BinaryComparison.bytes(Int64(data.count))))"
    }

    private static func plist(_ value: Any) -> String {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        case let date as Date: return date.formatted(.iso8601)
        case let data as Data: return "\(data.count) bytes"
        case let array as [Any]: return "[" + array.map(plist).joined(separator: ", ") + "]"
        case let dictionary as [String: Any]:
            return "{" + dictionary.keys.sorted().map { "\($0): \(plist(dictionary[$0]!))" }
                .joined(separator: ", ") + "}"
        default: return String(describing: value)
        }
    }
}
