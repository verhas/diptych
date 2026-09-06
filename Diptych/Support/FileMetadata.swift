import Foundation

/// Extended attributes, straight over the Darwin syscalls.
enum ExtendedAttributes {

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

    /// Returns nil on success, or a message.
    static func set(_ value: Data, name: String, on path: String) -> String? {
        let result = value.withUnsafeBytes {
            setxattr(path, name, $0.baseAddress, value.count, 0, 0)
        }
        return result == 0 ? nil : String(cString: strerror(errno))
    }

    static func remove(name: String, from path: String) -> String? {
        removexattr(path, name, 0) == 0 ? nil : String(cString: strerror(errno))
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

    /// Returns nil on success, or a message.
    static func setText(_ text: String, on path: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            // An empty ACL is how an ACL is removed.
            guard let empty = acl_init(0) else { return String(cString: strerror(errno)) }
            defer { acl_free(UnsafeMutableRawPointer(empty)) }
            return acl_set_file(path, ACL_TYPE_EXTENDED, empty) == 0
                ? nil : String(cString: strerror(errno))
        }
        guard let acl = acl_from_text(trimmed) else {
            return "The access control list could not be parsed."
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }

        return acl_set_file(path, ACL_TYPE_EXTENDED, acl) == 0
            ? nil : String(cString: strerror(errno))
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

    static func set(_ names: [String], on url: URL) -> String? {
        let path = url.path

        guard !names.isEmpty else {
            let message = ExtendedAttributes.remove(name: xattrName, from: path)
            // Removing an attribute that is not there is not a failure.
            return errno == ENOATTR ? nil : message
        }

        let entries = names.map { "\($0)\n\(colourIndex(of: $0))" }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: entries,
                                                             format: .binary,
                                                             options: 0) else {
            return "The tags could not be encoded."
        }
        return ExtendedAttributes.set(data, name: xattrName, on: path)
    }
}
