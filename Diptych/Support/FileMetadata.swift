import Foundation

/// Extended attributes, straight over the Darwin syscalls.
enum ExtendedAttributes {

    /// A failed syscall, carrying the errno rather than only a message, so a
    /// caller can tell "you may not write here" from "that name is invalid" and
    /// offer to do something about it.
    struct Failure: Error {
        let code: Int32
        private let text: String?

        init(code: Int32) {
            self.code = code
            text = nil
        }

        /// For a failure of ours rather than the kernel's -- a value that could
        /// not be encoded, an ACL that would not parse.
        init(message: String) {
            code = EINVAL
            text = message
        }

        var message: String { text ?? String(cString: strerror(code)) }

        /// Refused for want of write access, which is recoverable.
        var isPermissionDenied: Bool { text == nil && (code == EACCES || code == EPERM) }
    }


    struct Attribute: Identifiable, Hashable {
        var name: String
        var data: Data
        var id: String { name }

        /// Attributes holding text can be edited as text; the rest are shown as
        /// a hex dump and can only be removed.
        var text: String? {
            guard !data.isEmpty, let string = String(data: data, encoding: .utf8) else { return nil }
            return string.unicodeScalars.contains { $0.value < 9 } ? nil : string
        }

        var hexPreview: String {
            data.prefix(64)
                .map { String(format: "%02x", $0) }
                .joined(separator: " ")
                + (data.count > 64 ? " ..." : "")
        }
    }

    static func names(of path: String) -> [String] {
        let size = listxattr(path, nil, 0, 0)
        guard size > 0 else { return [] }

        var buffer = [CChar](repeating: 0, count: size)
        guard listxattr(path, &buffer, size, 0) > 0 else { return [] }

        // The kernel returns the names as one NUL-separated block.
        return buffer.split(separator: 0).compactMap {
            String(cString: Array($0) + [0])
        }
    }

    static func data(of path: String, name: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size >= 0 else { return nil }

        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        return read >= 0 ? data : nil
    }

    static func all(of path: String) -> [Attribute] {
        names(of: path).compactMap { name in
            data(of: path, name: name).map { Attribute(name: name, data: $0) }
        }
    }

    /// Returns nil on success.
    static func set(_ value: Data, name: String, on path: String) -> Failure? {
        let result = value.withUnsafeBytes {
            setxattr(path, name, $0.baseAddress, value.count, 0, 0)
        }
        return result == 0 ? nil : Failure(code: errno)
    }

    static func remove(name: String, from path: String) -> Failure? {
        removexattr(path, name, 0) == 0 ? nil : Failure(code: errno)
    }
}

/// Access control lists, as text.
///
/// The text form is what `acl_to_text` produces and `acl_from_text` accepts --
/// verified to round-trip -- so the editor is a text editor. Building a
/// structured editor for every ACL entry type would be a large UI for something
/// most files never carry.
enum AccessControl {

    /// The ACL as text, or nil when the file has none.
    static func text(of path: String) -> String? {
        guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }

        var length: ssize_t = 0
        guard let raw = acl_to_text(acl, &length) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(raw)) }

        return String(cString: raw)
    }

    /// Returns nil on success.
    static func setText(_ text: String, on path: String) -> ExtendedAttributes.Failure? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            // An empty ACL is how an ACL is removed.
            guard let empty = acl_init(0) else { return .init(code: errno) }
            defer { acl_free(UnsafeMutableRawPointer(empty)) }
            return acl_set_file(path, ACL_TYPE_EXTENDED, empty) == 0
                ? nil : .init(code: errno)
        }
        guard let acl = acl_from_text(trimmed) else {
            return .init(message: "The access control list could not be parsed.")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }

        return acl_set_file(path, ACL_TYPE_EXTENDED, acl) == 0 ? nil : .init(code: errno)
    }

    /// The same change for `chmod(1)`, for the escalated path.
    ///
    /// `chmod -E` does not read the format `acl_to_text` writes: it wants what
    /// `ls -le` prints -- `user:name allow read` -- and rejects the UUID form
    /// outright. So the entries are translated. A principal whose name carries
    /// a space cannot survive that syntax, and rather than hand root an ACL for
    /// the wrong principal we decline to offer the escalated path at all.
    static func command(setting text: String, on path: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/bin/chmod -N \(Shell.quoted(path))" }

        var entries: [String] = []
        for line in trimmed.split(separator: "\n") where !line.hasPrefix("!#acl") {
            // tag : uuid : name : id : allow|deny : comma-separated permissions
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 6, !fields[2].isEmpty, !fields[2].contains(" ") else { return nil }
            entries.append("\(fields[0]):\(fields[2]) \(fields[4]) \(fields[5])")
        }
        guard !entries.isEmpty else { return nil }

        return "printf '%s\\n' \(Shell.quoted(entries.joined(separator: "\n")))"
             + " | /bin/chmod -E \(Shell.quoted(path))"
    }
}

/// The 32-byte `com.apple.FinderInfo` block.
///
/// Only the flag word matters here: a big-endian UInt16 at offset 8, holding
/// the label colour in bits 1-3 and the custom-icon flag in bit 10. Two
/// unrelated features write it, so reading, changing one field and writing the
/// rest back untouched lives in one place.
enum FinderInfo {
    static let xattrName = "com.apple.FinderInfo"

    static func flags(of path: String) -> UInt16 {
        let bytes = [UInt8](ExtendedAttributes.data(of: path, name: xattrName) ?? Data())
        guard bytes.count >= 10 else { return 0 }
        return UInt16(bytes[8]) << 8 | UInt16(bytes[9])
    }

    /// The change that sets `flags` and leaves the other 30 bytes as they were.
    static func write(flags: UInt16, on path: String) -> XattrWrite {
        var bytes = [UInt8](ExtendedAttributes.data(of: path, name: xattrName) ?? Data(count: 32))
        if bytes.count < 32 {
            bytes.append(contentsOf: [UInt8](repeating: 0, count: 32 - bytes.count))
        }
        bytes[8] = UInt8(flags >> 8)
        bytes[9] = UInt8(flags & 0xFF)

        // All-zero Finder info is the same as none; do not leave 32 zero bytes
        // hanging off every file we touch.
        let empty = bytes.allSatisfy { $0 == 0 }
        return XattrWrite(name: xattrName, data: empty ? nil : Data(bytes))
    }
}

/// The tinted, symbol-bearing folder icons macOS 26 draws -- what Finder's
/// "Customize Folder" writes.
///
/// Three separate pieces have to agree or the folder stays plain blue, which is
/// why setting a tag alone does nothing to the icon:
///
///  * the **colour** is the Finder tag. There is no colour of its own;
///  * the **symbol** is an SF Symbol name in `com.apple.icon.folder#S`, as JSON;
///  * `kHasCustomIcon` in the Finder flags is what switches the composed icon on.
///
/// The `#S` on the attribute name is part of the name, not decoration: the
/// suffix marks the attribute syncable, and without it macOS ignores it.
enum FolderIcon {
    static let xattrName = "com.apple.icon.folder#S"

    /// kHasCustomIcon.
    static let flag: UInt16 = 0x0400

    static func isCustomised(_ path: String) -> Bool {
        FinderInfo.flags(of: path) & flag != 0
    }

    /// The SF Symbol drawn on the folder, if there is one.
    static func symbol(of path: String) -> String? {
        guard let data = ExtendedAttributes.data(of: path, name: xattrName),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["sym"] as? String
    }

    /// Turning the custom icon off removes the symbol too, rather than leaving
    /// an invisible one to reappear the next time it is switched on.
    static func writes(customised: Bool, symbol: String, on path: String) -> [XattrWrite] {
        let name = symbol.trimmingCharacters(in: .whitespaces)
        let flags = FinderInfo.flags(of: path)

        guard customised else {
            return [XattrWrite(name: xattrName, data: nil),
                    FinderInfo.write(flags: flags & ~flag, on: path)]
        }

        let payload = name.isEmpty ? nil
            : try? JSONSerialization.data(withJSONObject: ["sym": name])
        return [XattrWrite(name: xattrName, data: payload),
                FinderInfo.write(flags: flags | flag, on: path)]
    }
}

/// The seven tags macOS gives a colour. Any other name is a plain tag.
enum FinderTag {
    static let coloured = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"]

    static let xattrName = "com.apple.metadata:_kMDItemUserTags"

    /// Finder's colour indexes. Reading tags goes through
    /// `URLResourceValues.tagNames`, but its *setter* needs macOS 26, so
    /// writing goes to the xattr directly -- a binary plist of "Name\nIndex"
    /// strings, which is exactly what Finder stores.
    static func colourIndex(of name: String) -> Int {
        switch name {
        case "Gray":   1
        case "Green":  2
        case "Purple": 3
        case "Blue":   4
        case "Yellow": 5
        case "Red":    6
        case "Orange": 7
        default:       0
        }
    }

    /// The attribute bytes a tag change amounts to.
    ///
    /// Returned rather than written so that the same bytes can go either down
    /// the syscall or, when we are refused, through `xattr(1)` as root. Both
    /// attributes are rewritten together: the pre-10.9 label is where some
    /// volumes keep the colour *exclusively* -- a folder on an external disk can
    /// carry a grey tag with no _kMDItemUserTags attribute at all, and touching
    /// only the modern attribute leaves that colour behind.
    static func writes(for names: [String], on path: String) throws -> [XattrWrite] {
        var writes: [XattrWrite] = []

        if names.isEmpty {
            writes.append(XattrWrite(name: xattrName, data: nil))
        } else {
            let entries = names.map { "\($0)\n\(colourIndex(of: $0))" }
            guard let data = try? PropertyListSerialization.data(fromPropertyList: entries,
                                                                 format: .binary,
                                                                 options: 0) else {
                throw ExtendedAttributes.Failure(message: "The tags could not be encoded.")
            }
            writes.append(XattrWrite(name: xattrName, data: data))
        }

        let colour = names.lazy.map(colourIndex(of:)).first { $0 != 0 } ?? 0
        writes.append(label(colour, on: path))
        return writes
    }

    static func set(_ names: [String], on url: URL) -> ExtendedAttributes.Failure? {
        do {
            return try writes(for: names, on: url.path)
                .lazy.compactMap { $0.apply(to: url.path) }.first
        } catch {
            return error as? ExtendedAttributes.Failure ?? .init(message: "\(error)")
        }
    }

    /// The label is bits 1-3 of the Finder flags.
    private static func label(_ colour: Int, on path: String) -> XattrWrite {
        let flags = FinderInfo.flags(of: path)
        return FinderInfo.write(flags: (flags & ~0x000E) | (UInt16(colour) << 1), on: path)
    }
}

/// One extended attribute set to a value, or removed when `data` is nil.
///
/// A change described rather than performed, so that the same description can
/// be carried out by us or, when we are refused, by `xattr(1)` as root.
struct XattrWrite {
    let name: String
    let data: Data?

    func apply(to path: String) -> ExtendedAttributes.Failure? {
        guard let data else {
            let result = ExtendedAttributes.remove(name: name, from: path)
            // Removing an attribute that is not there is not a failure.
            return result?.code == ENOATTR ? nil : result
        }
        return ExtendedAttributes.set(data, name: name, on: path)
    }

    /// Values travel as hex, so that a binary property list survives the shell.
    ///
    /// A removal is skipped outright when the attribute is not there: `xattr -d`
    /// exits non-zero in that case, which would fail the whole command for a
    /// step that had nothing to do.
    func command(for path: String) -> String? {
        guard let data else {
            guard ExtendedAttributes.data(of: path, name: name) != nil else { return nil }
            return "/usr/bin/xattr -d \(Shell.quoted(name)) \(Shell.quoted(path))"
        }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        return "/usr/bin/xattr -w -x \(Shell.quoted(name)) \(Shell.quoted(hex)) \(Shell.quoted(path))"
    }
}
