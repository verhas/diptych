import Foundation

/// A `.webloc`, `.inetloc` or `.url` as a page: the address it opens, which
/// app opens it, the address taken apart, and plain words for anything about
/// it that is not what it seems.
nonisolated enum LocationReport {

    typealias R = ExecutableReport

    static func html(for location: InternetLocation, url: URL, size: Int, opener: String?) -> String {
        let name = url.lastPathComponent
        var body = "<h1>\(R.escape((name as NSString).deletingPathExtension))</h1>"
        body += "<p class=lead>\(R.escape("\(kind(of: url, location)), \(R.bytes(size))"))</p>"
        body += "<p class=meta>\(R.escape(url.path))</p>"

        let parts = location.parts
        let address = R.escape(location.target)
        let linked = ["http", "https"].contains(parts?.scheme ?? "") && location.warnings.isEmpty
        body += "<p class=target>\(linked ? "<a href=\"\(address)\">\(address)</a>" : "<code>\(address)</code>")</p>"
        for warning in location.warnings { body += "<p class=warn>\(R.escape(warning))</p>" }

        body += "<div class=card><div class=head><b>Opens</b></div><div class=cert>"
        if let opener { body += R.row("With", R.escape(opener)) }
        if let parts {
            body += R.row("Kind", R.escape(schemeText(parts.scheme)))
            if let host = parts.host, !host.isEmpty {
                var text = "<code>\(R.escape(parts.unicodeHost ?? host))</code>"
                if parts.unicodeHost != nil { text += " <span class=dim>written <code>\(R.escape(host))</code></span>" }
                body += R.row("Site", text)
            }
            if let user = parts.user, !user.isEmpty { body += R.row("User name", "<code>\(R.escape(user))</code>") }
            if let port = parts.port { body += R.row("Port", "\(port)") }
            if !parts.path.isEmpty, parts.path != "/" {
                body += R.row(parts.scheme == "mailto" ? "To" : "Path", "<code>\(R.escape(parts.path.removingPercentEncoding ?? parts.path))</code>")
            }
            if let fragment = parts.fragment, !fragment.isEmpty { body += R.row("Part", "<code>\(R.escape(fragment))</code>") }
            if parts.scheme == "http" { body += R.row("Connection", "<span class=soon>not encrypted</span> <span class=dim>— http, not https</span>") }
        }
        if location.fromResourceFork {
            body += R.row("Stored", "in its resource fork <span class=dim>— as the classic Mac OS wrote it; copied to a disk or a server that keeps no forks, it is empty</span>")
        }
        if let modified = location.modified { body += R.row("Modified", R.escape(modified.formatted(date: .long, time: .shortened))) }
        if let icon = location.iconFile { body += R.row("Icon", "<code>\(R.escape(icon))</code>") }
        if let directory = location.workingDirectory { body += R.row("Starts in", "<code>\(R.escape(directory))</code>") }
        body += "</div></div>"

        if let parts, !parts.query.isEmpty {
            body += "<h2>Query <span class=count>\(parts.query.count)</span></h2><table class=summary>"
            for (key, value) in parts.query {
                body += "<tr><td><code>\(R.escape(key))</code>"
                if let meaning = tracking(key) { body += "<br><span class=dim>\(R.escape(meaning))</span>" }
                body += "</td><td><code>\(R.escape(String(value.prefix(4000))))</code></td></tr>"
            }
            body += "</table>"
        }
        let others = location.settings.filter {
            !($0.section.caseInsensitiveCompare("InternetShortcut") == .orderedSame
              && ["iconfile", "workingdirectory", "modified"].contains($0.key.lowercased()))
        }
        if !others.isEmpty {
            body += "<details><summary><h2>Other Settings <span class=count>\(others.count)</span></h2></summary><table class=summary>"
            body += "<tr><th>Section</th><th>Name</th><th>Value</th></tr>"
            for setting in others.prefix(500) {
                body += "<tr><td>\(R.escape(setting.section))</td><td><code>\(R.escape(setting.key))</code></td>"
                body += "<td><code>\(R.escape(String(setting.value.prefix(2000))))</code></td></tr>"
            }
            body += "</table></details>"
        }
        return KeyStoreReport.page(title: name, body: R.style + style + body)
    }

    static func html(failure: Error, url: URL, size: Int) -> String {
        R.html(failure: failure, kind: url.pathExtension.lowercased() == "url" ? "Windows Internet shortcut" : "Finder location",
               name: url.lastPathComponent, path: url.deletingLastPathComponent().path, size: size)
    }

    private static func kind(of url: URL, _ location: InternetLocation) -> String {
        switch url.pathExtension.lowercased() {
        case "webloc": "Web location"
        case "inetloc": "Internet location"
        case "fileloc": "File location"
        case "ftploc": "FTP location"
        case "afploc": "File server location"
        case "mailloc": "Mail location"
        case "newsloc": "News location"
        default: location.kind.rawValue
        }
    }

    private static func schemeText(_ scheme: String) -> String {
        switch scheme {
        case "https": "a web page, over an encrypted connection"
        case "http": "a web page"
        case "mailto": "a new e-mail message"
        case "ftp", "sftp", "ftps": "a file transfer server"
        case "file": "a file or folder"
        case "smb", "afp", "nfs", "cifs": "a shared folder on a file server"
        case "ssh": "a terminal session on another computer"
        case "vnc": "screen sharing"
        case "tel", "facetime", "facetime-audio": "a call"
        case "sms", "imessage": "a message"
        case "x-apple.systempreferences": "a pane of System Settings"
        case "itms-apps", "macappstore", "itms-appss": "the App Store"
        case "javascript", "vbscript": "a script"
        case "data": "data written into the link"
        default: "the app that handles “\(scheme):” addresses"
        }
    }

    /// The query parameters added only to count who clicked.
    private static func tracking(_ name: String) -> String? {
        let lower = name.lowercased()
        if lower.hasPrefix("utm_") { return "campaign tracking" }
        return ["fbclid": "Facebook click tracking", "gclid": "Google Ads click tracking", "msclkid": "Microsoft Ads click tracking",
                "mc_eid": "Mailchimp tracking", "igshid": "Instagram tracking", "yclid": "Yandex click tracking"][lower]
    }

    static let style = """
        <style>
        .target { font-size: 14px; margin: 0 0 12px; overflow-wrap: anywhere; }
        .target code { font-size: 13px; }
        a { color: var(--kind); }
        </style>
        """
}
