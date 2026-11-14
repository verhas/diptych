import Foundation

/// An e-mail message (RFC 5322 with MIME), read for showing: its headers
/// decoded, its text, its attachments, and what its headers and signature
/// say about where it came from. Nothing is fetched: no remote image, no link.
nonisolated struct MailMessage {

    struct Part {
        var headers: [(name: String, value: String)] = []
        var type = "text/plain"
        var parameters: [String: String] = [:]
        var disposition: String?
        var filename: String?
        var contentID: String?
        var body = Data()
        var parts: [Part] = []

        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        var isMultipart: Bool { type.hasPrefix("multipart/") }
        var isSignature: Bool {
            ["application/pkcs7-signature", "application/x-pkcs7-signature", "application/pgp-signature"].contains(type)
        }

        var isAttachment: Bool {
            if isSignature || type == "application/pgp-encrypted" { return false }
            if disposition == "attachment" { return true }
            if filename != nil, !type.hasPrefix("text/") || disposition == "attachment" { return true }
            return !isMultipart && !type.hasPrefix("text/") && type != "message/delivery-status"
                && !type.hasPrefix("application/pkcs7-signature") && !type.hasPrefix("application/x-pkcs7-signature")
                && type != "application/pgp-signature" && type != "application/pgp-encrypted"
        }

        var text: String { MailMessage.string(body, charset: parameters["charset"]) }
    }

    struct Attachment {
        var name: String
        var type: String
        var size: Int
        var data: Data
        var inline: Bool
        /// A forwarded message, read in turn.
        var message: MailMessage?
    }

    let root: Part
    let size: Int

    static let extensions: Set<String> = ["eml", "emlx", "msg822"]
    static let maximumSize = 64 * 1024 * 1024

    init(data raw: Data, depth: Int = 0) {
        var data = raw
        // Apple Mail's .emlx: the message's length on the first line, a
        // property list after the message.
        if let newline = data.prefix(16).firstIndex(of: 0x0A),
           let length = Int(String(decoding: data[data.startIndex..<newline], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)), length > 0 {
            data = data[(newline + 1)...].prefix(length)
        }
        size = data.count
        root = Self.part(Self.normalized(data), depth: depth)
    }

    /// Line ends as LF, so the rest need look for only one kind.
    static func normalized(_ data: Data) -> Data {
        guard data.contains(0x0D) else { return data }
        var out = Data(capacity: data.count)
        var previous: UInt8 = 0
        for byte in data {
            if byte == 0x0A, previous == 0x0D { out[out.count - 1] = 0x0A } else { out.append(byte) }
            previous = byte
        }
        return out
    }

    // MARK: - Parts

    static func part(_ data: Data, depth: Int) -> Part {
        var part = Part()
        let (headerData, body) = split(data)
        part.headers = headers(headerData)
        let (type, parameters) = contentType(part.header("Content-Type") ?? "text/plain")
        part.type = type
        part.parameters = parameters
        if let disposition = part.header("Content-Disposition") {
            let (kind, values) = contentType(disposition)
            part.disposition = kind
            part.filename = values["filename"].map(decodeWords)
        }
        if part.filename == nil { part.filename = parameters["name"].map(decodeWords) }
        part.contentID = part.header("Content-ID")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))

        if type.hasPrefix("multipart/"), let boundary = parameters["boundary"], depth < 16 {
            part.parts = parts(body, boundary: boundary).prefix(500).map { Self.part($0, depth: depth + 1) }
        } else {
            let encoding = part.header("Content-Transfer-Encoding")?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
            part.body = switch encoding {
            case "base64": Data(base64Encoded: body, options: .ignoreUnknownCharacters) ?? Data()
            case "quoted-printable": quotedPrintable(body)
            default: body
            }
        }
        return part
    }

    /// Headers and body, at the first empty line.
    private static func split(_ data: Data) -> (Data, Data) {
        if data.first == 0x0A { return (Data(), data.dropFirst()) }
        if let range = data.range(of: Data([0x0A, 0x0A])) {
            return (data[data.startIndex..<range.lowerBound + 1], data[range.upperBound...])
        }
        return (data, Data())
    }

    static func headers(_ data: Data) -> [(name: String, value: String)] {
        // Headers should be ASCII; a raw UTF-8 one is read as such, anything
        // else as Latin-1 so nothing is lost.
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        var out: [(String, String)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.first == " " || line.first == "\t", !out.isEmpty {
                out[out.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                out.append((String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                            String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            }
            if out.count >= 2000 { break }
        }
        return out
    }

    /// "text/plain; charset=utf-8" into a lowercased type and its
    /// parameters, RFC 2231 continuations and encodings joined.
    static func contentType(_ value: String) -> (String, [String: String]) {
        var pieces: [String] = [], current = "", quoted = false
        for character in value {
            if character == "\"" { quoted.toggle(); continue }
            if character == ";", !quoted { pieces.append(current); current = ""; continue }
            current.append(character)
        }
        pieces.append(current)
        let type = pieces.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var plain: [String: String] = [:]
        var continued: [String: [(Int, String, Bool)]] = [:]
        for piece in pieces.dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            var key = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            let encoded = key.hasSuffix("*")
            if encoded { key.removeLast() }
            if let star = key.lastIndex(of: "*"), let index = Int(key[key.index(after: star)...]) {
                continued[String(key[..<star]), default: []].append((index, value, encoded))
            } else if encoded {
                plain[key] = rfc2231(value, first: true)
            } else {
                plain[key] = value
            }
        }
        for (key, parts) in continued {
            plain[key] = parts.sorted { $0.0 < $1.0 }.enumerated().map { offset, part in
                part.2 ? rfc2231(part.1, first: offset == 0) : part.1
            }.joined()
        }
        return (type, plain)
    }

    /// `utf-8'en'na%C3%AFve.txt`: the charset, the language, then percent-encoded bytes.
    private static func rfc2231(_ value: String, first: Bool) -> String {
        var charset = "utf-8", text = Substring(value)
        if first {
            let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
            if pieces.count == 3 { charset = String(pieces[0]); text = pieces[2] }
        }
        var bytes = Data(), index = text.startIndex
        while index < text.endIndex {
            if text[index] == "%", let end = text.index(index, offsetBy: 3, limitedBy: text.endIndex),
               let byte = UInt8(text[text.index(after: index)..<end], radix: 16) {
                bytes.append(byte)
                index = end
            } else {
                bytes.append(contentsOf: Array(String(text[index]).utf8))
                index = text.index(after: index)
            }
        }
        return string(bytes, charset: charset.isEmpty ? "utf-8" : charset)
    }

    private static func parts(_ body: Data, boundary: String) -> [Data] {
        let marker = Data("--".utf8) + Data(boundary.utf8)
        var out: [Data] = []
        var start: Data.Index?
        var search = body.startIndex
        while let range = body.range(of: marker, in: search..<body.endIndex) {
            let atLineStart = range.lowerBound == body.startIndex || body[range.lowerBound - 1] == 0x0A
            search = range.upperBound
            guard atLineStart else { continue }
            if let begin = start {
                let end = range.lowerBound > begin && body[range.lowerBound - 1] == 0x0A ? range.lowerBound - 1 : range.lowerBound
                out.append(body[begin..<max(begin, end)])
            }
            let closing = body[range.upperBound...].prefix(2) == Data("--".utf8)
            if closing { return out }
            // The part starts on the line after the boundary.
            guard let newline = body[range.upperBound...].firstIndex(of: 0x0A) else { return out }
            start = newline + 1
            if out.count >= 1000 { return out }
        }
        if let begin = start, begin < body.endIndex { out.append(body[begin...]) }
        return out
    }

    static func quotedPrintable(_ data: Data) -> Data {
        var out = Data(capacity: data.count)
        let bytes = [UInt8](data)
        var index = 0
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: byte - 0x30
            case 0x41...0x46: byte - 0x37
            case 0x61...0x66: byte - 0x57
            default: nil
            }
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x3D {
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 2; continue }
                if index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                    out.append(high << 4 | low)
                    index += 3
                    continue
                }
            }
            out.append(byte)
            index += 1
        }
        return out
    }

    /// Bytes in a named character set, falling back to UTF-8 and then Latin-1.
    static func string(_ data: Data, charset: String?) -> String {
        if let charset {
            let name = charset.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased()
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let text = String(data: data, encoding: encoding) { return text }
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
    }

    /// RFC 2047 encoded words (`=?utf-8?B?...?=`) in a header, decoded;
    /// the space between two of them dropped, as the standard says.
    static func decodeWords(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        let pattern = #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let text = value as NSString
        var out = "", last = 0, previousWasWord = false
        for match in expression.matches(in: value, range: NSRange(location: 0, length: text.length)) {
            let between = text.substring(with: NSRange(location: last, length: match.range.location - last))
            if !(previousWasWord && between.trimmingCharacters(in: .whitespaces).isEmpty) { out += between }
            let charset = text.substring(with: match.range(at: 1)).split(separator: "*").first.map(String.init) ?? ""
            let mode = text.substring(with: match.range(at: 2)).uppercased()
            let encoded = text.substring(with: match.range(at: 3))
            let bytes: Data
            if mode == "B" {
                bytes = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
                    ?? Data(base64Encoded: encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)) ?? Data()
            } else {
                bytes = quotedPrintable(Data(encoded.replacingOccurrences(of: "_", with: " ").utf8))
            }
            out += string(bytes, charset: charset)
            last = match.range.location + match.range.length
            previousWasWord = true
        }
        out += text.substring(from: last)
        return out
    }

    // MARK: - What it says

    func header(_ name: String) -> String? { root.header(name).map(Self.decodeWords) }
    func headers(_ name: String) -> [String] {
        root.headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    var subject: String? { header("Subject") }
    var from: String? { header("From") }
    var date: Date? { header("Date").flatMap(Self.date) }

    static func date(_ text: String) -> Date? {
        var cleaned = text
        if let comment = cleaned.firstIndex(of: "(") { cleaned = String(cleaned[..<comment]) }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z",
                       "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm Z", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }

    /// Every leaf part, depth first.
    var leaves: [Part] {
        var out: [Part] = []
        func walk(_ part: Part) {
            if part.parts.isEmpty { out.append(part) } else { part.parts.forEach(walk) }
        }
        walk(root)
        return out
    }

    /// The text to show: plain text where there is one, else the HTML as text.
    var bodyText: (text: String, fromHTML: Bool)? {
        func pick(_ part: Part) -> Part? {
            if part.type == "multipart/alternative" {
                return part.parts.first { $0.type == "text/plain" && !$0.isAttachment }
                    ?? part.parts.reversed().compactMap(pick).first
            }
            if part.isMultipart { return part.parts.lazy.compactMap(pick).first }
            if (part.type == "text/plain" || part.type == "text/html"), !part.isAttachment, part.disposition != "attachment" {
                return part
            }
            return nil
        }
        guard let part = pick(root) else { return nil }
        if part.type == "text/html" { return (HTMLText.text(part.text), true) }
        var text = part.text
        if part.parameters["format"]?.lowercased() == "flowed" { text = Self.unflowed(text, delsp: part.parameters["delsp"] == "yes") }
        return (text, false)
    }

    var html: String? {
        leaves.first { $0.type == "text/html" && !$0.isAttachment }?.text
    }

    /// RFC 3676: a line ending in a space continues on the next.
    static func unflowed(_ text: String, delsp: Bool) -> String {
        var out = "", pending = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(line)
            if line.hasPrefix(" ") { line.removeFirst() }
            if line.hasSuffix(" "), line != "-- " {
                pending += delsp ? String(line.dropLast()) : line
            } else {
                out += pending + line + "\n"
                pending = ""
            }
        }
        return out + pending
    }

    var attachments: [Attachment] {
        leaves.compactMap { part in
            guard part.isAttachment else { return nil }
            let type = part.type
            var name = part.filename ?? ""
            var message: MailMessage?
            if type == "message/rfc822" {
                message = MailMessage(data: part.body, depth: 1)
                if name.isEmpty { name = (message?.subject).map { $0 + ".eml" } ?? "message.eml" }
            }
            if name.isEmpty { name = part.contentID ?? "unnamed \(type)" }
            return Attachment(name: name, type: type, size: part.body.count, data: part.body,
                              inline: part.disposition == "inline" || part.contentID != nil, message: message)
        }
    }

    // MARK: - Signed and encrypted

    enum Protection {
        case smimeSigned(signer: X509?, certificates: [X509], signedAt: Date?)
        case smimeEncrypted
        case pgpSigned
        case pgpEncrypted
    }

    var protection: [Protection] {
        var out: [Protection] = []
        func walk(_ part: Part) {
            let protocolName = part.parameters["protocol"]?.lowercased() ?? ""
            if part.type == "multipart/signed", protocolName.contains("pgp") { out.append(.pgpSigned) }
            if part.type == "multipart/encrypted" { out.append(.pgpEncrypted) }
            if part.type.hasSuffix("pkcs7-signature") || (part.type.hasSuffix("pkcs7-mime")
                && part.parameters["smime-type"]?.lowercased() == "signed-data") {
                let (certificates, time) = MachOFile.CodeSignature.details(ofCMS: [UInt8](part.body))
                let signer = certificates.first { leaf in
                    !certificates.contains { $0.issuerBytes == leaf.subjectBytes && $0.subjectBytes != leaf.subjectBytes }
                }
                out.append(.smimeSigned(signer: signer, certificates: certificates, signedAt: time))
            }
            if part.type.hasSuffix("pkcs7-mime"), part.parameters["smime-type"]?.lowercased() != "signed-data" {
                out.append(.smimeEncrypted)
            }
            part.parts.forEach(walk)
        }
        walk(root)
        if out.isEmpty, root.type == "text/plain" {
            let start = root.text.prefix(4096)
            if start.contains("-----BEGIN PGP MESSAGE-----") { out.append(.pgpEncrypted) }
            else if start.contains("-----BEGIN PGP SIGNED MESSAGE-----") { out.append(.pgpSigned) }
        }
        return out
    }

    /// The receiving server's verdict: SPF, DKIM, DMARC, from the topmost
    /// Authentication-Results header (the one the last server added).
    var authentication: [(check: String, result: String)] {
        guard let results = headers("Authentication-Results").first ?? headers("ARC-Authentication-Results").first
        else { return [] }
        var out: [(String, String)] = []
        for check in ["spf", "dkim", "dmarc"] {
            guard let range = results.range(of: #"\b\#(check)=([a-z]+)"#, options: [.regularExpression, .caseInsensitive])
            else { continue }
            let value = results[range].split(separator: "=").last.map(String.init)?.lowercased() ?? ""
            out.append((check.uppercased(), value))
        }
        return out
    }

    /// The domain of the first address in a header.
    static func domain(_ address: String?) -> String? {
        guard let address else { return nil }
        let inside = address.range(of: #"<[^>]*>"#, options: .regularExpression).map { String(address[$0]) } ?? address
        guard let at = inside.lastIndex(of: "@") else { return nil }
        let domain = inside[inside.index(after: at)...].trimmingCharacters(in: CharacterSet(charactersIn: "<> \"'"))
            .lowercased()
        return domain.isEmpty ? nil : domain
    }

    /// The registrable part of a domain, roughly: the last two labels, three
    /// for the usual country second levels (co.uk, com.au).
    static func base(_ domain: String) -> String {
        let labels = domain.split(separator: ".")
        guard labels.count > 2 else { return domain }
        let keep = ["co", "com", "org", "net", "ac", "gov", "edu"].contains(String(labels[labels.count - 2]))
            && labels.last!.count == 2 ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    /// Links in the HTML whose text shows one address and whose target is another site.
    var misleadingLinks: [(shown: String, target: String)] {
        guard let html else { return [] }
        return HTMLText.links(html).compactMap { link in
            let shown = link.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard shown.range(of: #"^(https?://)?([a-z0-9-]+\.)+[a-z]{2,}(/\S*)?$"#,
                              options: [.regularExpression, .caseInsensitive]) != nil,
                  let target = URL(string: link.href)?.host?.lowercased() else { return nil }
            let shownHost = (URL(string: shown.lowercased().hasPrefix("http") ? shown : "http://" + shown)?.host ?? "").lowercased()
            guard !shownHost.isEmpty, Self.base(shownHost) != Self.base(target) else { return nil }
            return (shown, link.href)
        }
    }

    static let riskyExtensions: Set<String> = [
        "exe", "scr", "com", "pif", "bat", "cmd", "vbs", "vbe", "js", "jse", "wsf", "wsh", "hta", "msi", "jar",
        "ps1", "lnk", "iso", "img", "dmg", "pkg", "app", "command", "docm", "xlsm", "pptm", "html", "htm", "svg",
    ]
}

// MARK: - HTML as text

/// Mail's HTML read as text, without a browser: nothing in it is loaded or run.
nonisolated enum HTMLText {

    /// HTML beyond this is not read: the patterns below get slow on
    /// pathological markup, and nobody reads that much mail.
    static let maximumHTML = 2 * 1024 * 1024

    static func text(_ html: String) -> String {
        var text = String(html.prefix(maximumHTML))
        for (pattern, replacement) in [
            (#"(?is)<(script|style|head|title)\b.*?</\1\s*>"#, ""),
            (#"(?is)<!--.*?-->"#, ""),
            (#"(?i)<br\s*/?>"#, "\n"),
            (#"(?i)</(p|div|h[1-6]|tr|li|blockquote|table|ul|ol)\s*>"#, "\n"),
            (#"(?i)<li\b[^>]*>"#, "• "),
            (#"(?i)</t[dh]\s*>"#, "\t"),
            (#"(?s)<[^>]+>"#, ""),
        ] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        text = entities(text)
        // Spaces collapsed, at most one empty line in a row.
        text = text.replacingOccurrences(of: #"[ \t\x{00A0}]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func entities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
                                       "copy": "©", "reg": "®", "hellip": "…", "mdash": "—", "ndash": "–",
                                       "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "zwnj": "\u{200C}",
                                       "euro": "€", "bull": "•", "middot": "·", "trade": "™"]
        guard let expression = try? NSRegularExpression(pattern: "&(#[xX]?[0-9a-fA-F]+|[a-zA-Z]+);") else { return text }
        let source = text as NSString
        var out = "", last = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            out += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let name = source.substring(with: match.range(at: 1))
            var replacement: String?
            if name.hasPrefix("#") {
                let digits = name.dropFirst()
                let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                replacement = value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[name.lowercased()]
            }
            out += replacement ?? source.substring(with: match.range)
            last = match.range.location + match.range.length
        }
        return out + source.substring(from: last)
    }

    static func links(_ html: String) -> [(href: String, text: String)] {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?is)<a\b[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a\s*>"#) else { return [] }
        let html = String(html.prefix(maximumHTML / 2))
        let source = html as NSString
        return expression.matches(in: html, range: NSRange(location: 0, length: source.length)).prefix(2000).map {
            (entities(source.substring(with: $0.range(at: 1))), text(source.substring(with: $0.range(at: 2))))
        }
    }
}

// MARK: - mbox

/// A Unix mailbox: messages one after another, each after a "From " line.
nonisolated struct Mailbox {

    struct Entry {
        var range: Range<Int>
        var envelopeDate: Date?
    }

    static let extensions: Set<String> = ["mbox", "mbx", "mbs"]

    let data: Data
    let entries: [Entry]
    let truncated: Bool

    static func looksLikeMailbox(_ data: Data) -> Bool {
        guard data.prefix(5) == Data("From ".utf8) else { return false }
        let line = data.prefix(1024).split(separator: 0x0A).first ?? Data()
        // "From address date": at least a sender and a year.
        return String(decoding: line, as: UTF8.self).range(of: #"^From \S+ .*\d{4}"#, options: .regularExpression) != nil
    }

    init(data: Data, limit: Int = 100_000) {
        self.data = data
        var starts: [Int] = []
        let marker = Data("\nFrom ".utf8)
        if data.prefix(5) == Data("From ".utf8) { starts.append(0) }
        var search = data.startIndex
        while starts.count < limit, let range = data.range(of: marker, in: search..<data.endIndex) {
            // After an empty line, as mboxo and mboxrd write it; a lone
            // "From " inside a message would have been quoted with ">".
            let previous = range.lowerBound - 1
            if previous < data.startIndex || data[previous] == 0x0A || (data[previous] == 0x0D && previous > data.startIndex) {
                starts.append(range.lowerBound + 1 - data.startIndex)
            }
            search = range.upperBound
        }
        truncated = starts.count >= limit
        var entries: [Entry] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : data.count
            let base = data.startIndex
            let line = data[(base + start)..<(base + end)].prefix(512).split(separator: 0x0A, maxSplits: 1).first ?? Data()
            let text = String(decoding: line, as: UTF8.self)
            // "From sender Tue Feb 13 09:00:00 2024"
            let parts = text.split(separator: " ", maxSplits: 2)
            let date = parts.count == 3 ? MailMessage.date(String(parts[2])) : nil
            entries.append(Entry(range: start..<end, envelopeDate: date))
        }
        self.entries = entries
    }

    /// The message's own bytes: the From line dropped, quoted ">From " lines unquoted.
    func message(_ entry: Entry, limit: Int = 32 * 1024 * 1024) -> Data {
        let base = data.startIndex
        var bytes = data[(base + entry.range.lowerBound)..<(base + entry.range.upperBound)]
        if let newline = bytes.firstIndex(of: 0x0A) { bytes = bytes[(newline + 1)...] }
        let raw = Data(bytes.prefix(limit))
        guard raw.range(of: Data("\n>From ".utf8)) != nil else { return raw }
        let text = String(decoding: raw, as: UTF8.self)
        return Data(text.replacingOccurrences(of: #"(?m)^>(>*From )"#, with: "$1", options: .regularExpression).utf8)
    }

    /// Only the headers, for a row in the list.
    func headers(_ entry: Entry) -> MailMessage {
        let full = message(entry, limit: 64 * 1024)
        let end = full.range(of: Data("\n\n".utf8))?.upperBound ?? full.range(of: Data("\r\n\r\n".utf8))?.upperBound ?? full.endIndex
        return MailMessage(data: full[full.startIndex..<end])
    }
}
