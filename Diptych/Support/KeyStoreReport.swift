import Foundation

/// A key store for Quick Look: each alias with its kind and its certificates
/// -- who they are for, who issued them, until when, with what key -- and
/// whether the store opens with a default password. Quick Look shows a key
/// store as a name and a size.
nonisolated enum KeyStoreReport {

    /// How soon an expiry is worth a warning.
    static let soon: TimeInterval = 30 * 24 * 3600

    static let extensions: Set<String> = ["jks", "jceks", "keystore", "ks", "truststore", "p12", "pfx"]

    static func html(for data: Data, name: String, path: String, now: Date = Date()) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        let store: KeyStore
        do {
            store = try KeyStore.read(data)
        } catch {
            return page(title: name, body: "<h1>\(escape(name))</h1><p class=lead>Named like a key store, "
                        + "\(escape(size)), but it does not read as one.</p>"
                        + "<p>\(escape(String(describing: error)))</p><p class=meta>\(escape(path))</p>")
        }

        var body = "<h1>\(escape(name))</h1>"
        let count = store.entries.count
        var lead = "\(store.format.rawValue) key store"
        if let version = store.version, store.format != .pkcs12 { lead += ", version \(version)" }
        lead += ", \(count) entr\(count == 1 ? "y" : "ies"), \(size)"
        body += "<p class=lead>\(escape(lead))</p><p class=meta>\(escape(path))</p>"
        body += passwordNote(store)
        for note in store.notes { body += "<p class='note'>\(escape(note))</p>" }

        let entries = store.entries.sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
        if !entries.isEmpty {
            body += "<table class=summary><tr><th>Alias</th><th>Kind</th><th>For</th><th>Valid until</th></tr>"
            for entry in entries {
                let leaf = entry.chain.first
                body += "<tr><td><b>\(alias(entry))</b></td><td>\(escape(entry.kind.rawValue))</td>"
                    + "<td>\(escape(leaf.map { X509.shortName($0.subject) } ?? "\u{2014}"))</td>"
                    + "<td>\(leaf.map { validity($0, now: now, short: true) } ?? "\u{2014}")</td></tr>"
            }
            body += "</table>"
        }
        for entry in entries { body += card(entry, now: now) }
        return page(title: name, body: body)
    }

    // MARK: - Pieces

    private static func passwordNote(_ store: KeyStore) -> String {
        var text: String
        var style = "note"
        switch store.password {
        case .known(""):
            text = "It opens with no password at all: anybody who has the file can read it."
            style = "warn"
        case .known(let password):
            text = "Its password is \(password), Java's well-known default: anybody who has the file can open it."
            style = "warn"
        case .notNeeded:
            text = "It has no integrity check: nothing shows whether it was changed since it was made."
        case .unknown:
            text = "Its password is not one of the defaults and is not asked for. "
                + (store.format == .pkcs12
                   ? "What it keeps unencrypted is shown."
                   : "The certificates are shown as stored; whether the file was changed is not checked.")
        }
        if let integrity = store.integrity { text += " Integrity: \(integrity)." }
        return "<p class=\(style)>\(escape(text))</p>"
    }

    private static func alias(_ entry: KeyStore.Entry) -> String {
        entry.alias.isEmpty ? "<span class=dim>no alias</span>" : escape(entry.alias)
    }

    private static func card(_ entry: KeyStore.Entry, now: Date) -> String {
        var out = "<section class=card><div class=head><b>\(alias(entry))</b> "
            + "<span class=kind>\(escape(entry.kind.rawValue))</span>"
        if let created = entry.created {
            out += " <span class=dim>added \(escape(created.formatted(date: .abbreviated, time: .shortened)))</span>"
        }
        out += "</div>"
        if let protection = entry.protection {
            // A key kept unencrypted inside the store is worth seeing at once.
            let value = protection == "Not encrypted" ? "<span class=bad>\(escape(protection))</span>" : escape(protection)
            out += "<div class=row><span>Protection</span><span>\(value)</span></div>"
        }
        if entry.chain.isEmpty, entry.kind != .secretKey {
            out += "<div class=row><span>Certificate</span><span class=dim>none that could be read</span></div>"
        }
        for (index, certificate) in entry.chain.enumerated() {
            if index > 0 { out += "<div class=issued>issued by</div>" }
            out += certificateRows(certificate, now: now)
        }
        return out + "</section>"
    }

    static func certificateRows(_ certificate: X509, now: Date) -> String {
        func row(_ label: String, _ value: String) -> String {
            "<div class=row><span>\(escape(label))</span><span>\(value)</span></div>"
        }
        var out = "<div class=cert>"
        out += row("Subject", escape(X509.text(of: certificate.subject)))
        out += row("Issuer", certificate.isSelfIssued
                   ? "<span class=dim>itself (self-signed)</span>" : escape(X509.text(of: certificate.issuer)))
        out += row("Valid", validity(certificate, now: now, short: false))
        var key = certificate.key + " \u{00B7} signed with " + certificate.signatureAlgorithm
        if certificate.isAuthority { key += " \u{00B7} a certificate authority" }
        out += row("Key", escape(key))
        if !certificate.alternativeNames.isEmpty {
            out += row("Also for", escape(certificate.alternativeNames.joined(separator: ", ")))
        }
        if !certificate.usage.isEmpty {
            out += row("Usage", escape(certificate.usage.joined(separator: ", ")))
        }
        out += row("Serial", "<code>\(escape(certificate.serial))</code>")
        out += row("SHA-256", "<code>\(escape(certificate.sha256))</code>")
        out += row("SHA-1", "<code>\(escape(certificate.sha1))</code>")
        return out + "</div>"
    }

    static func validity(_ certificate: X509, now: Date, short: Bool) -> String {
        let until = escape(certificate.notAfter.formatted(date: .abbreviated, time: .omitted))
        let from = escape(certificate.notBefore.formatted(date: .abbreviated, time: .omitted))
        var text = short ? until : "\(from) to \(until)"
        if certificate.isExpired(at: now) {
            text += " <span class=bad>expired</span>"
        } else if certificate.isNotYetValid(at: now) {
            text += " <span class=bad>not valid yet</span>"
        } else if certificate.notAfter.timeIntervalSince(now) < soon {
            let days = max(0, Int(certificate.notAfter.timeIntervalSince(now) / 86_400))
            text += " <span class=soon>expires in \(days) day\(days == 1 ? "" : "s")</span>"
        }
        return text
    }

    static func escape(_ text: String) -> String { PlistReport.escape(text) }

    static func page(title: String, body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title><style>
        :root { color-scheme: light dark;
                --ink: #1c1c1e; --dim: #6c6c70; --rule: #e4e4e8; --bg: #fff; --panel: #f6f6f8;
                --bad: #c41a16; --soon: #a65c00; --warnbg: #fff4e5; --kind: #0b4f79; }
        @media (prefers-color-scheme: dark) {
          :root { --ink: #ececf0; --dim: #9a9aa0; --rule: #333336; --bg: #1c1c1e; --panel: #262629;
                  --bad: #ff6b5e; --soon: #ffb340; --warnbg: #3a2a12; --kind: #5dd8ff; }
        }
        body { font: 13px -apple-system, system-ui, sans-serif; color: var(--ink);
               background: var(--bg); margin: 0; padding: 18px 22px; }
        h1 { font-size: 17px; margin: 0 0 2px; }
        .lead { margin: 0 0 2px; color: var(--dim); }
        .meta { color: var(--dim); font-size: 11px; margin: 0 0 12px; }
        .note, .warn { margin: 0 0 10px; padding: 8px 10px; border-radius: 6px; background: var(--panel); }
        .warn { background: var(--warnbg); }
        .dim { color: var(--dim); }
        .bad { color: var(--bad); font-weight: 600; } .soon { color: var(--soon); font-weight: 600; }
        table.summary { border-collapse: collapse; width: 100%; margin: 6px 0 16px; }
        .summary th { text-align: left; font-size: 11px; color: var(--dim); font-weight: 600;
                      border-bottom: 1px solid var(--rule); padding: 3px 8px; }
        .summary td { border-bottom: 1px solid var(--rule); padding: 3px 8px; overflow-wrap: anywhere; }
        .card { border: 1px solid var(--rule); border-radius: 6px; margin: 0 0 12px; overflow: hidden; }
        .card .head { background: var(--panel); padding: 6px 10px; border-bottom: 1px solid var(--rule); }
        .kind { color: var(--kind); font-size: 11px; margin-left: 6px; }
        .row { display: grid; grid-template-columns: 90px 1fr; gap: 8px; padding: 2px 10px; }
        .row > span:first-child { color: var(--dim); font-size: 11px; padding-top: 1px; }
        .row > span:last-child { overflow-wrap: anywhere; }
        .cert { padding: 4px 0; }
        .issued { color: var(--dim); font-size: 11px; padding: 2px 10px; border-top: 1px dashed var(--rule); }
        code { font: 11px ui-monospace, Menlo, monospace; }
        .good { color: var(--kind); }
        </style></head><body>\(body)</body></html>
        """
    }
}
