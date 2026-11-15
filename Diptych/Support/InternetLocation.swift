import Foundation

/// A file that stands for an address: Finder's `.webloc` and its kin -- a
/// property list, or in old ones only a `url ` resource -- and Windows'
/// `.url`, an INI file. What matters is where it goes, and whether that is
/// what it looks like.
nonisolated struct InternetLocation: Sendable {

    static let macExtensions: Set<String> = ["webloc", "inetloc", "fileloc", "ftploc", "afploc", "mailloc", "newsloc"]
    static let extensions: Set<String> = macExtensions.union(["url"])
    static let maximumSize = 1024 * 1024

    enum Problem: Error, CustomStringConvertible {
        case noAddress, notAShortcut
        var description: String {
            switch self {
            case .noAddress: "It holds no address."
            case .notAShortcut: "It is not an Internet shortcut: it has no [InternetShortcut] section."
            }
        }
    }

    enum Kind: String, Sendable {
        case finder = "Finder location"
        case windows = "Windows Internet shortcut"
    }

    var kind: Kind
    var target: String
    /// Only in the resource fork, as the classic Mac OS and early Mac OS X wrote it.
    var fromResourceFork = false
    /// The `.url` file's other settings, by section.
    var settings: [(section: String, key: String, value: String)] = []
    var iconFile: String?
    var workingDirectory: String?
    var modified: Date?

    // MARK: - Reading

    /// A Finder location from its property list -- or, when the data fork
    /// is empty, from the `url ` resource in its resource fork.
    init(finder data: Data, resourceFork: Data?) throws {
        kind = .finder
        if !data.isEmpty,
           let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let address = (list["URL"] ?? list["url"]) as? String, !address.isEmpty {
            target = address
            return
        }
        if let fork = resourceFork, let resource = Self.resource("url ", in: fork) {
            target = String(decoding: resource, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
            fromResourceFork = true
            guard !target.isEmpty else { throw Problem.noAddress }
            return
        }
        throw Problem.noAddress
    }

    /// A Windows `.url`: INI sections, the address under [InternetShortcut].
    init(windows data: Data) throws {
        kind = .windows
        let text = Self.decode(data)
        var section = ""
        var found: String?
        var inShortcut = false
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).prefix(10_000) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                if section.caseInsensitiveCompare("InternetShortcut") == .orderedSame { inShortcut = true }
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            let isShortcut = section.caseInsensitiveCompare("InternetShortcut") == .orderedSame
            switch (isShortcut, key.lowercased()) {
            case (true, "url") where found == nil: found = value
            case (true, "iconfile"): iconFile = value
            case (true, "workingdirectory"): workingDirectory = value
            case (true, "modified"): modified = Self.fileTime(value)
            default: break
            }
            if !(isShortcut && key.lowercased() == "url" && found == value) {
                settings.append((section, key, value))
            }
        }
        guard inShortcut else { throw Problem.notAShortcut }
        guard let found, !found.isEmpty else { throw Problem.noAddress }
        target = found
    }

    private static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        return String(data: body, encoding: .utf8) ?? String(data: body, encoding: .windowsCP1252) ?? ""
    }

    /// `Modified=` holds a FILETIME as its eight bytes in hex, sometimes
    /// with more after them.
    private static func fileTime(_ hex: String) -> Date? {
        let digits = Array(hex.prefix(16))
        guard digits.count == 16 else { return nil }
        var value: UInt64 = 0
        for index in stride(from: 14, through: 0, by: -2) {
            guard let byte = UInt8(String(digits[index...index + 1]), radix: 16) else { return nil }
            value = value << 8 | UInt64(byte)
        }
        guard value > 0 else { return nil }
        let seconds = Double(value) / 10_000_000 - 11_644_473_600
        guard seconds > 0, seconds < 8_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// The first resource of a type, from a resource fork: header, map,
    /// type list, reference list, then the data -- each offset checked.
    static func resource(_ type: String, in fork: Data) -> Data? {
        let reader = BinaryReader(fork, bigEndian: true)
        guard let dataStart = try? Int(reader.u32(0)), let mapStart = try? Int(reader.u32(4)),
              let typeListOffset = try? Int(reader.u16(mapStart + 24)) else { return nil }
        let typeList = mapStart + typeListOffset
        guard let typeCount = try? Int(reader.u16(typeList)) else { return nil }
        let wanted = Data(type.utf8)
        for index in 0...min(typeCount, 255) {
            let entry = typeList + 2 + index * 8
            guard let code = try? reader.bytes(entry, 4), code == wanted,
                  let referenceOffset = try? Int(reader.u16(entry + 6)),
                  let offset = try? reader.u32(typeList + referenceOffset + 4) else { continue }
            let at = dataStart + Int(offset & 0x00FF_FFFF)
            guard let length = try? Int(reader.u32(at)), length <= 64 * 1024,
                  let bytes = try? reader.bytes(at + 4, length) else { return nil }
            return bytes
        }
        return nil
    }

    // MARK: - What the address is

    struct Parts: Sendable {
        var scheme: String
        var host: String?
        /// The host as people read it, where it is spelled in punycode.
        var unicodeHost: String?
        var port: Int?
        var user: String?
        var path: String
        var query: [(name: String, value: String)]
        var fragment: String?
    }

    var parts: Parts? {
        guard let components = URLComponents(string: target.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme else { return nil }
        // Foundation reads a punycode name back as letters: the name as it
        // goes over the network is the encoded one, and decoded here.
        let host = components.encodedHost ?? components.percentEncodedHost
        let unicode = host.flatMap { $0.lowercased().contains("xn--") ? Self.unicode(host: $0) : nil }
        return Parts(scheme: scheme.lowercased(), host: host, unicodeHost: unicode, port: components.port,
                     user: components.user, path: components.path,
                     query: (components.queryItems ?? []).prefix(300).map { ($0.name, $0.value ?? "") },
                     fragment: components.fragment)
    }

    /// Plain words for what is unusual about where it goes.
    var warnings: [String] {
        var out: [String] = []
        let lower = target.lowercased().trimmingCharacters(in: .whitespaces)
        let parts = self.parts
        if lower.hasPrefix("\\\\") || lower.hasPrefix("file://///") || lower.hasPrefix("file:////")
            || (parts?.scheme == "file" && !(parts?.host ?? "").isEmpty && parts?.host != "localhost") {
            out.append("It points at a file on another computer: opening it on Windows sends the user's sign-in to that computer.")
        } else if parts?.scheme == "file" || (parts == nil && (lower.hasPrefix("/") || lower.dropFirst().hasPrefix(":\\"))) {
            out.append("It points at a file, not a web page: opening it opens or runs that file.")
        }
        if let scheme = parts?.scheme, ["javascript", "vbscript", "data"].contains(scheme) {
            out.append("Its address is \(scheme == "data" ? "data written into the link itself" : "a script"), not a place: opening it runs or shows what is in it.")
        }
        if let parts, let user = parts.user, !user.isEmpty, let host = parts.host {
            out.append("The part before “@”, “\(user)”, is only a user name: the address goes to \(parts.unicodeHost ?? host).")
        }
        if let parts, let unicode = parts.unicodeHost {
            out.append("Its site name uses letters beyond plain Latin, \(unicode): check it is the site it looks like.")
        }
        if let host = parts?.host, host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$|^\[.*\]$"#, options: .regularExpression) != nil {
            out.append("It goes to a bare network address, not a named site.")
        }
        let last = ((parts?.path ?? target) as NSString).lastPathComponent
        let risky = ["exe", "scr", "bat", "cmd", "com", "pif", "js", "jse", "vbs", "vbe", "wsf", "hta", "lnk", "ps1",
                     "msi", "jar", "reg", "cpl", "app", "pkg", "command", "sh", "dmg", "iso"]
        if let ext = last.split(separator: ".").last.map({ $0.lowercased() }), last.contains("."), risky.contains(ext) {
            out.append("It goes straight to a program or an installer, “\(last)”.")
        }
        if let icon = iconFile?.lowercased(), icon.hasPrefix("\\\\") || icon.hasPrefix("http") || icon.hasPrefix("file://") && !icon.hasPrefix("file:///") {
            out.append("Its icon is fetched from another computer: Windows asks that computer for it as soon as the folder is shown.")
        }
        return out
    }

    private static func unicode(host: String) -> String? {
        let labels = host.split(separator: ".").map { label -> String in
            label.lowercased().hasPrefix("xn--") ? (Punycode.decode(String(label.dropFirst(4))) ?? String(label)) : String(label)
        }
        let joined = labels.joined(separator: ".")
        return joined == host ? nil : joined
    }
}

/// RFC 3492, decoding only: enough to show a site name as it is read.
nonisolated enum Punycode {
    static func decode(_ input: String) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        var output: [UnicodeScalar] = []
        var scalars = Array(input.unicodeScalars)
        if let dash = scalars.lastIndex(of: "-") {
            output = Array(scalars[..<dash])
            guard output.allSatisfy(\.isASCII) else { return nil }
            scalars = Array(scalars[(dash + 1)...])
        }
        var n = 128, i = 0, bias = 72, position = 0
        func adapt(_ delta: Int, _ count: Int, _ first: Bool) -> Int {
            var delta = first ? delta / damp : delta / 2
            delta += delta / count
            var k = 0
            while delta > ((base - tMin) * tMax) / 2 { delta /= base - tMin; k += base }
            return k + (base - tMin + 1) * delta / (delta + skew)
        }
        while position < scalars.count {
            let old = i
            var w = 1, k = base
            while true {
                guard position < scalars.count, output.count < 256 else { return nil }
                let c = scalars[position].value
                position += 1
                let digit: Int
                switch c {
                case 0x30...0x39: digit = Int(c) - 22
                case 0x41...0x5A: digit = Int(c) - 0x41
                case 0x61...0x7A: digit = Int(c) - 0x61
                default: return nil
                }
                let (product, overflow1) = digit.multipliedReportingOverflow(by: w)
                let (sum, overflow2) = i.addingReportingOverflow(product)
                guard !overflow1, !overflow2, sum < 1 << 31 else { return nil }
                i = sum
                let t = k <= bias ? tMin : k >= bias + tMax ? tMax : k - bias
                if digit < t { break }
                let (next, overflow3) = w.multipliedReportingOverflow(by: base - t)
                guard !overflow3, next < 1 << 31 else { return nil }
                w = next
                k += base
            }
            bias = adapt(i - old, output.count + 1, old == 0)
            n += i / (output.count + 1)
            i %= output.count + 1
            guard n < 0x110000, let scalar = UnicodeScalar(n) else { return nil }
            output.insert(scalar, at: i)
            i += 1
        }
        var text = ""
        text.unicodeScalars.append(contentsOf: output)
        return text
    }
}
