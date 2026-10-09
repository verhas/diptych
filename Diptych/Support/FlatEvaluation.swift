import Darwin
import Foundation

/// What the flat view's expression is asked about: one item found while
/// walking the tree.
nonisolated struct FlatSubject: Sendable {
    let url: URL
    let name: String
    /// A folder, and not a package: a package -- an app, a .rtfd -- is one
    /// item, and is not walked into.
    let isDirectory: Bool
    let size: Int64
    let mode: mode_t
    let owner: String
    let group: String
    let created: Date
    let modified: Date

    init(url: URL, name: String, isDirectory: Bool, size: Int64, mode: mode_t,
         owner: String, group: String, created: Date, modified: Date) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.mode = mode
        self.owner = owner
        self.group = group
        self.created = created
        self.modified = modified
    }

    init(_ item: FileItem) {
        self.init(url: item.url, name: item.name,
                  isDirectory: item.isDirectory && !item.isPackage,
                  size: item.byteSize, mode: item.mode, owner: item.owner, group: item.group,
                  created: item.created, modified: item.modified)
    }
}

nonisolated extension FlatQuery {

    /// Whether an item is listed, and -- for a folder -- whether it is
    /// walked into.
    struct Decision: Equatable, Sendable {
        let list: Bool
        let traverse: Bool
    }

    /// The question a folder is asked: listed, or walked into. A file is
    /// asked once.
    enum Pass: Sendable { case file, list, traverse }

    func decide(_ subject: FlatSubject) -> Decision {
        guard let expression else { return Decision(list: true, traverse: subject.isDirectory) }
        // About files only: every folder is listed and walked into.
        if !namesKinds && subject.isDirectory { return Decision(list: true, traverse: true) }
        if subject.isDirectory {
            return Decision(list: Self.holds(expression, subject, .list),
                            traverse: Self.holds(expression, subject, .traverse))
        }
        return Decision(list: Self.holds(expression, subject, .file), traverse: false)
    }

    static func holds(_ expression: Expression, _ subject: FlatSubject, _ pass: Pass) -> Bool {
        switch expression {
        case .and(let a, let b): holds(a, subject, pass) && holds(b, subject, pass)
        case .or(let a, let b):  holds(a, subject, pass) || holds(b, subject, pass)
        case .not(let a):        !holds(a, subject, pass)
        case .primitive(let p):  holds(p, subject, pass)
        }
    }

    private static func holds(_ primitive: Primitive, _ subject: FlatSubject,
                              _ pass: Pass) -> Bool {
        switch primitive {
        case .file:
            return !subject.isDirectory
        case .directory(let part):
            guard subject.isDirectory else { return false }
            switch part {
            case .both:      return true
            case .traversed: return pass == .traverse
            case .listed:    return pass == .list
            }
        case .size(let comparison, let bytes):
            // A folder has no size of its own worth comparing.
            return !subject.isDirectory && comparison.holds(subject.size, bytes)
        case .name(let test):
            return test.holds(subject.name, glob: true)
        case .owner(let test):
            return test.holds(subject.owner, glob: false)
        case .group(let test):
            return test.holds(subject.group, glob: false)
        case .access(let mask, let negated):
            return mask.holds(subject.mode) != negated
        case .created(let comparison, let moment):
            return subject.created != .distantPast && moment.holds(subject.created, comparison)
        case .modified(let comparison, let moment):
            return moment.holds(subject.modified, comparison)
        case .xattrExists(let name):
            return FlatContent.xattrName(name, on: subject.url) != nil
        case .xattr(let name, let test):
            guard let found = FlatContent.xattrName(name, on: subject.url) else { return false }
            return FlatContent.xattrValues(found, on: subject.url).contains {
                test.holds($0, glob: false)
            }
        case .contains(let text):
            return !subject.isDirectory && FlatContent.contains(text, in: subject.url)
        case .constant(let value):
            return value
        case .containsMatch(let regex):
            return !subject.isDirectory && FlatContent.containsLine(matching: regex,
                                                                    in: subject.url)
        }
    }
}

nonisolated extension FlatQuery.TextTest {

    /// `=` against a shell pattern for names, as the pane's filter does;
    /// against the whole text for the rest. Case never matters.
    func holds(_ value: String, glob: Bool) -> Bool {
        switch self {
        case .equals(let wanted, let negated):
            let equal = glob && wanted.contains(where: { $0 == "*" || $0 == "?" || $0 == "[" })
                ? fnmatch(wanted, value, FNM_CASEFOLD) == 0
                : value.caseInsensitiveCompare(wanted) == .orderedSame
            return equal != negated
        case .matches(let regex, let negated):
            return regex.matches(value) != negated
        }
    }
}

/// Reading what is in a file, and its extended attributes, for `contains`
/// and `xattr`.
nonisolated enum FlatContent {

    private static let chunk = 1 << 20

    /// Only a plain file is read: a pipe or a device would never answer, or
    /// never stop. Through a symbolic link, to what it points at.
    private static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// A NUL among the first bytes: a binary file, as grep and Git judge
    /// it. Three letters turn up in any image's bytes by chance; that is
    /// never what was looked for.
    static func isBinary(_ start: Data) -> Bool {
        start.prefix(8192).contains(0)
    }

    /// The text anywhere in the file, ignoring case; bytes that are not
    /// UTF-8 are read as what UTF-8 makes of them. A binary file never has
    /// it.
    static func contains(_ text: String, in url: URL) -> Bool {
        guard isRegularFile(url), let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        // Enough of the last piece kept over to find the text across the
        // seam between two reads.
        let overlap = text.utf8.count * 4
        var carried = Data()
        var first = true
        while true {
            guard let piece = try? handle.read(upToCount: chunk), !piece.isEmpty else {
                // An empty file has the empty text, as nothing else.
                return first && text.isEmpty
            }
            if first {
                first = false
                if isBinary(piece) { return false }
                if text.isEmpty { return true }
            }
            let window = carried + piece
            if String(decoding: window, as: UTF8.self)
                .range(of: text, options: [.caseInsensitive]) != nil {
                return true
            }
            carried = window.suffix(overlap)
        }
    }

    /// A line of the file matching, as grep does; never in a binary file.
    static func containsLine(matching regex: FlatQuery.Regex, in url: URL) -> Bool {
        guard isRegularFile(url), let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        var partial = Data()
        var first = true
        while true {
            let piece = (try? handle.read(upToCount: chunk)) ?? nil
            guard let piece, !piece.isEmpty else {
                return !partial.isEmpty && regex.matches(String(decoding: partial, as: UTF8.self))
            }
            if first {
                first = false
                if isBinary(piece) { return false }
            }
            var data = partial + piece
            // Whole lines, the last unfinished one carried to the next read.
            guard let lastBreak = data.lastIndex(of: 0x0A) else {
                partial = data
                continue
            }
            partial = data[data.index(after: lastBreak)...]
            data = data[data.startIndex..<lastBreak]
            let lines = String(decoding: data, as: UTF8.self).split(
                separator: "\n", omittingEmptySubsequences: false)
            if lines.contains(where: { regex.matches(String($0)) }) { return true }
        }
    }

    /// The attribute's own name, found ignoring case; nil when the item
    /// has none by that name. The item's own, not through a link.
    static func xattrName(_ name: String, on url: URL) -> String? {
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard listxattr(url.path, &buffer, size, XATTR_NOFOLLOW) == size else { return nil }
        let names = buffer.split(separator: 0).map {
            String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return names.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The attribute as text: its bytes as UTF-8 -- or, for a property list
    /// such as where a download came from, each string in it.
    static func xattrValues(_ name: String, on url: URL) -> [String] {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes {
            getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW)
        }
        guard read >= 0 else { return [] }
        data = data.prefix(read)
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            if let text = plist as? String { return [text] }
            if let texts = plist as? [Any] { return texts.compactMap { $0 as? String } }
            if let number = plist as? NSNumber { return [number.stringValue] }
        }
        var text = String(decoding: data, as: UTF8.self)
        // A C string's closing zero is not part of the value.
        while text.hasSuffix("\0") { text.removeLast() }
        return [text]
    }
}
