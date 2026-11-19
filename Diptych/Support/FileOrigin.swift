import Foundation

/// Where a file came from, as its extended attributes tell it: the address it
/// was downloaded from and the page that linked to it, whether macOS still
/// holds it in quarantine and since when, the app that made or changed it,
/// and whatever else is attached to it. Read once, shown by Quick Look under
/// a report and by the Info window.
///
/// Not a file format: any file can carry these, so this is made apart from
/// the previews and added to each of them.
nonisolated struct FileOrigin: Sendable, Equatable {

    struct Quarantine: Sendable, Equatable {
        /// The app that downloaded or unpacked it: "Safari", "Diptych".
        var agent: String
        var date: Date?
        /// Opened since it was downloaded -- and so checked by Gatekeeper.
        var opened: Bool
    }

    struct Attribute: Sendable, Equatable {
        var name: String
        var size: Int
    }

    /// The download address first, then the page it was linked from.
    var whereFrom: [String] = []
    var quarantine: Quarantine?
    /// The raw `com.apple.provenance` value; put in words on the main actor,
    /// where the lookups made for it are kept.
    var provenance: Data?
    /// Every other extended attribute, by name, with its size.
    var others: [Attribute] = []
    /// The opened archive the file came out of: its quarantine is the
    /// archive's, put on it when it was unpacked.
    var archive: URL?

    var isEmpty: Bool { whereFrom.isEmpty && quarantine == nil && provenance == nil && others.isEmpty }

    /// Came from somewhere else: downloaded, or held in quarantine. Nearly
    /// every file an app writes carries a provenance tag, so that alone is
    /// not worth a section under every preview.
    var isDownload: Bool { !whereFrom.isEmpty || quarantine != nil }

    static let quarantineName = "com.apple.quarantine"
    static let whereFromName = "com.apple.metadata:kMDItemWhereFroms"

    /// Neither part of where a file came from nor worth listing: the Finder's
    /// own bookkeeping, shown in the Info window's other tabs.
    private static let unlisted: Set<String> = [
        "com.apple.FinderInfo", "com.apple.ResourceFork", "com.apple.metadata:_kMDItemUserTags",
        "com.apple.lastuseddate#PS",
    ]

    /// Nil for a file on a server: what is shown of it is a copy Diptych
    /// fetched, and its attributes say how Diptych got it, not where it came
    /// from.
    static func read(_ url: URL) -> FileOrigin? {
        guard RemoteBrowsing.server(of: url) == nil else { return nil }
        var origin = FileOrigin()
        for name in names(of: url) {
            guard let data = value(name, of: url) else { continue }
            switch name {
            case whereFromName:
                if let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
                    origin.whereFrom = list.filter { !$0.isEmpty }
                }
            case quarantineName:
                origin.quarantine = quarantine(from: data)
            case Provenance.xattrName:
                origin.provenance = data
            default:
                if !unlisted.contains(name) { origin.others.append(Attribute(name: name, size: data.count)) }
            }
        }
        origin.others.sort { $0.name < $1.name }
        if origin.quarantine != nil { origin.archive = ArchiveBrowsing.opened(containing: url)?.archive }
        return origin
    }

    /// `flags;seconds;agent;event`, in hex where it is a number. Flag 0x40
    /// is set once the file has been opened and let through.
    static func quarantine(from data: Data) -> Quarantine? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let flags = parts.first.flatMap({ UInt32($0, radix: 16) }) else { return nil }
        let date = parts.count > 1
            ? UInt64(parts[1], radix: 16).map { Date(timeIntervalSince1970: TimeInterval($0)) } : nil
        return Quarantine(agent: parts.count > 2 ? parts[2] : "", date: date, opened: flags & 0x40 != 0)
    }

    // MARK: - In words

    /// What is unusual enough to say plainly.
    var warnings: [String] {
        var out: [String] = []
        if let quarantine, !quarantine.opened, archive == nil {
            out.append("Downloaded and never opened: macOS checks it the first time it is opened.")
        }
        for address in whereFrom {
            guard let host = URLComponents(string: address)?.encodedHost,
                  host.lowercased().contains("xn--"), let read = Self.unicode(host: host) else { continue }
            out.append("It came from \(read), a site name with letters beyond plain Latin: check it is the site it looks like.")
        }
        return out
    }

    /// The quarantine, as one line.
    var quarantineText: String? {
        guard let quarantine else { return nil }
        var text = "Quarantined"
        if !quarantine.agent.isEmpty { text += " by \(quarantine.agent)" }
        if let date = quarantine.date { text += ", \(date.formatted(date: .long, time: .shortened))" }
        text += quarantine.opened ? "; opened since" : "; not opened yet"
        return text
    }

    var archiveText: String? {
        archive.map { "The quarantine of \($0.lastPathComponent), put on everything in it when it was unpacked" }
    }

    /// The web address as it is read: a punycode site name decoded.
    static func unicode(host: String) -> String? {
        let labels = host.split(separator: ".").map { label -> String in
            label.lowercased().hasPrefix("xn--")
                ? (Punycode.decode(String(label.dropFirst(4))) ?? String(label)) : String(label)
        }
        let joined = labels.joined(separator: ".")
        return joined == host ? nil : joined
    }

    // MARK: - For Quick Look

    static let marker = "<!-- diptych:origin -->"

    /// A section to end a report with, for a file that came from elsewhere;
    /// empty for any other. Self-contained -- its own style -- since every
    /// report has its own.
    func html(provenanceText: String?) -> String {
        guard isDownload else { return "" }
        func esc(_ text: String) -> String { ExecutableReport.escape(text) }
        var rows: [(String, String)] = []
        for (index, address) in whereFrom.enumerated() {
            let label = index == 0 ? "Downloaded from" : index == 1 ? "Linked from" : ""
            let link = address.lowercased().hasPrefix("http")
                ? "<a href=\"\(esc(address))\">\(esc(address))</a>" : esc(address)
            rows.append((label, link))
        }
        if let text = quarantineText { rows.append(("Quarantine", esc(text))) }
        if let text = archiveText { rows.append(("", esc(text))) }
        if let provenanceText { rows.append(("Provenance", esc(provenanceText))) }
        for (index, attribute) in others.enumerated() {
            rows.append((index == 0 ? "Other attributes" : "",
                         "<code>\(esc(attribute.name))</code> \u{2014} \(esc(ExecutableReport.bytes(attribute.size)))"))
        }
        let table = rows.map { "<div class=o-row><span>\(esc($0.0))</span><span>\($0.1)</span></div>" }.joined()
        let warned = warnings.map { "<p class=o-warn>\u{26A0}\u{FE0E} \(esc($0))</p>" }.joined()
        return """
            \(Self.marker)
            <style>
            #diptych-origin { margin: 24px 0 8px; padding-top: 10px; border-top: 1px solid rgba(128,128,128,.35);
                              font: 12px -apple-system, sans-serif; }
            #diptych-origin h2 { font-size: 13px; margin: 0 0 6px; }
            #diptych-origin .o-row { display: grid; grid-template-columns: 140px 1fr; gap: 8px; margin: 2px 0; }
            #diptych-origin .o-row > span:first-child { opacity: .6; text-align: right; }
            #diptych-origin .o-row > span:last-child { overflow-wrap: anywhere; }
            #diptych-origin .o-warn { color: #d07000; margin: 6px 0; }
            #diptych-origin code { font: 11px ui-monospace, Menlo, monospace; }
            </style>
            <section id=diptych-origin><h2>Where it came from</h2>\(warned)\(table)</section>
            """
    }

    /// The page with the section added before its end -- once.
    static func adding(_ section: String, to page: String) -> String {
        guard !section.isEmpty, !page.contains(marker) else { return page }
        if let end = page.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
            return page.replacingCharacters(in: end, with: section + "</body>")
        }
        return page + section
    }

    // MARK: - Reading the attributes

    private static func names(of url: URL) -> [String] {
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        guard listxattr(url.path, &buffer, size, XATTR_NOFOLLOW) == size else { return [] }
        return buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }

    private static func value(_ name: String, of url: URL) -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        guard size > 0 else { return Data() }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return read == size ? data : nil
    }
}
