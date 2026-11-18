import Foundation

/// Certificates, signing requests, revocation lists and keys for Quick Look:
/// what each is for and whether it is still good; how the certificates in one
/// file chain together; which certificate a private key belongs to. Keys are
/// described, never shown.
nonisolated enum CertificateReport {

    static let extensions: Set<String> = ["cer", "crt", "pem", "der", "cert", "csr", "req", "crl",
                                          "p7b", "p7c", "key", "pub"]
    /// Extensions other applications use for their own files -- Keynote's
    /// `.key`, Publisher's `.pub` -- and SSH's names without one: when the
    /// contents are not keys, Quick Look shows them as it always did.
    private static let borrowed: Set<String> = ["key", "pub", ""]

    static func handles(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if extensions.contains(ext) { return true }
        let name = url.lastPathComponent
        return ext.isEmpty && (name.hasPrefix("id_") || name == "authorized_keys" || name == "authorized_keys2")
    }

    /// The page, or nil when the file is not one after all and the extension
    /// is one other kinds of file use as well.
    static func html(for data: Data, url: URL, now: Date = Date()) -> String? {
        let name = url.lastPathComponent
        let path = url.deletingLastPathComponent().path
        guard let file = try? CertificateFile.read(data) else {
            guard !borrowed.contains(url.pathExtension.lowercased()) else { return nil }
            return html(for: data, name: name, path: path, now: now)
        }
        return html(for: file, name: name, path: path, size: data.count, now: now)
    }

    static func html(for data: Data, name: String, path: String, now: Date = Date()) -> String {
        do {
            return html(for: try CertificateFile.read(data), name: name, path: path, size: data.count, now: now)
        } catch {
            let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            return KeyStoreReport.page(title: name, body: "<h1>\(escape(name))</h1><p class=lead>Named like a "
                                       + "certificate or a key, \(escape(size)), but it does not read as one.</p>"
                                       + "<p>\(escape(String(describing: error)))</p><p class=meta>\(escape(path))</p>")
        }
    }

    static func html(for file: CertificateFile, name: String, path: String, size: Int, now: Date) -> String {
        let items = file.items
        let certificates: [(index: Int, certificate: X509)] = items.enumerated().compactMap { index, item in
            if case .certificate(let certificate, _) = item { return (index, certificate) }
            return nil
        }
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        var body = "<h1>\(escape(name))</h1>"
        body += "<p class=lead>\(escape("\(file.encoding): \(contents(items)), \(sizeText)"))</p>"
        body += "<p class=meta>\(escape(path))</p>"
        if let chain = chainNote(certificates) { body += chain }

        if items.count > 1 {
            body += "<table class=summary><tr><th>#</th><th>What</th><th>For</th><th>Valid until</th></tr>"
            for (index, item) in items.enumerated() {
                let (what, who, until) = summary(item, now: now)
                body += "<tr><td>\(index + 1)</td><td>\(escape(what))</td><td>\(escape(who))</td><td>\(until)</td></tr>"
            }
            body += "</table>"
        }
        for (index, item) in items.enumerated() {
            body += card(item, number: index + 1, showNumber: items.count > 1, certificates: certificates,
                         items: items, now: now)
        }
        return KeyStoreReport.page(title: name, body: body)
    }

    // MARK: - Summary

    /// "3 certificates and a private key".
    private static func contents(_ items: [CertificateFile.Item]) -> String {
        var counts: [(String, Int)] = []
        func add(_ name: String) {
            if let index = counts.firstIndex(where: { $0.0 == name }) { counts[index].1 += 1 } else { counts.append((name, 1)) }
        }
        for item in items {
            switch item {
            case .certificate: add("certificate")
            case .request: add("certificate request")
            case .revocationList: add("revocation list")
            case .privateKey, .sshPrivateKey: add("private key")
            case .publicKey: add("public key")
            case .sshPublicKey(let key): add(key.certificate == nil ? "public key" : "SSH certificate")
            case .parameters: add("set of parameters")
            case .unreadable: add("unreadable block")
            }
        }
        let parts = counts.map { name, count in
            // "an SSH certificate": the article goes by the sound, and S is said "ess".
            count == 1 ? (name.hasPrefix("SSH") || name.first.map { "aeiou".contains($0) } == true ? "an " : "a ") + name
                       : "\(count) \(name)s"
        }
        guard parts.count > 1 else { return parts.first ?? "nothing" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }

    private static func summary(_ item: CertificateFile.Item, now: Date) -> (String, String, String) {
        let none = "\u{2014}"
        switch item {
        case .certificate(let certificate, _):
            return ("Certificate", X509.shortName(certificate.subject), KeyStoreReport.validity(certificate, now: now, short: true))
        case .request(let request): return ("Certificate request", X509.shortName(request.subject), none)
        case .revocationList(let list): return ("Revocation list", X509.shortName(list.issuer), none)
        case .privateKey(let key): return ("Private key", key.key ?? "encrypted", none)
        case .publicKey(let key): return ("Public key", key.key, none)
        case .sshPublicKey(let key):
            let until = key.certificate.map { span(from: nil, to: $0.validBefore, now: now) } ?? none
            return (key.certificate == nil ? "SSH public key" : "SSH certificate", key.comment ?? key.label, until)
        case .sshPrivateKey(let key): return ("SSH private key", key.keys.first?.comment ?? key.keys.first?.label ?? "", none)
        case .parameters(let text): return ("Parameters", text, none)
        case .unreadable(let label, _): return ("Unreadable", label, none)
        }
    }

    /// How the certificates link: in chain order, out of it, or not at all.
    private static func chainNote(_ certificates: [(index: Int, certificate: X509)]) -> String? {
        guard certificates.count > 1 else { return nil }
        let list = certificates.map(\.certificate)
        let issuers = list.map { certificate in
            certificate.isSelfIssued ? nil : list.firstIndex { $0.subjectBytes == certificate.issuerBytes }
        }
        let links = issuers.compactMap { $0 }.count
        guard links > 0 else {
            return "<p class=note>\(escape("\(list.count) certificates that do not issue one another: a bundle, not a chain."))</p>"
        }
        let inOrder = (0..<list.count - 1).allSatisfy { issuers[$0] == $0 + 1 }
        if inOrder, links == list.count - 1 {
            let text = list.last?.isSelfIssued == true
                ? "The certificates form one chain, each followed by its issuer, up to a self-signed root."
                : "The certificates form one chain, each followed by its issuer; the one that issued the last is not in the file."
            return "<p class=note>\(escape(text))</p>"
        }
        return "<p class=warn>\(escape("The certificates issue one another but are not in chain order (each followed by its issuer). A server that sends them like this may be refused."))</p>"
    }

    // MARK: - Cards

    private static func card(_ item: CertificateFile.Item, number: Int, showNumber: Bool,
                             certificates: [(index: Int, certificate: X509)], items: [CertificateFile.Item],
                             now: Date) -> String {
        let prefix = showNumber ? "#\(number) " : ""
        func head(_ title: String, _ detail: String? = nil) -> String {
            "<section class=card><div class=head><b>\(escape(prefix + title))</b>"
                + (detail.map { " <span class=kind>\(escape($0))</span>" } ?? "") + "</div>"
        }
        func row(_ label: String, _ value: String) -> String {
            "<div class=row><span>\(escape(label))</span><span>\(value)</span></div>"
        }
        func owner(_ match: [UInt8]?) -> String? {
            guard let match, !match.isEmpty, !certificates.isEmpty else { return nil }
            if let found = certificates.first(where: { CertificateFile.matchValue(of: $0.certificate) == match }) {
                return "<span class=good>\(escape("certificate #\(found.index + 1), \(X509.shortName(found.certificate.subject))"))</span>"
            }
            return "<span class=bad>no certificate in this file</span>"
        }

        switch item {
        case .certificate(let certificate, let trusted):
            var out = head("Certificate", trusted ? "with OpenSSL trust settings" : nil)
            if let linked = links(certificate, certificates: certificates) { out += row("In this file", escape(linked)) }
            for case .revocationList(let list) in items
            where X509.text(of: list.issuer) == X509.text(of: certificate.issuer)
                && list.revoked.contains(where: { $0.serial == certificate.serial }) {
                out += row("Revoked", "<span class=bad>in the revocation list in this file</span>")
            }
            return out + KeyStoreReport.certificateRows(certificate, now: now) + "</section>"

        case .request(let request):
            var out = head("Certificate request")
            out += row("Subject", escape(X509.text(of: request.subject)))
            out += row("Key", escape(request.key + " \u{00B7} signed with " + request.signatureAlgorithm))
            if !request.alternativeNames.isEmpty { out += row("Also for", escape(request.alternativeNames.joined(separator: ", "))) }
            if request.hasChallengePassword { out += row("Challenge", "a challenge password is set (not shown)") }
            if let owner = owner(request.match) { out += row("Same key as", owner) }
            return out + "</section>"

        case .revocationList(let list):
            var out = head("Revocation list")
            out += row("Issuer", escape(X509.text(of: list.issuer)))
            out += row("Issued", escape(list.thisUpdate.formatted(date: .abbreviated, time: .shortened)))
            if let next = list.nextUpdate {
                let late = next < now ? " <span class=bad>overdue: a newer list should exist</span>" : ""
                out += row("Next by", escape(next.formatted(date: .abbreviated, time: .shortened)) + late)
            }
            if let number = list.number { out += row("Number", escape(number)) }
            out += row("Signed with", escape(list.signatureAlgorithm))
            out += row("Revoked", list.revoked.isEmpty ? "none" : "\(list.revoked.count)")
            if !list.revoked.isEmpty {
                out += "<table class='summary revoked'><tr><th>Serial</th><th>Revoked on</th><th>Reason</th></tr>"
                for entry in list.revoked.prefix(1000) {
                    out += "<tr><td><code>\(escape(entry.serial))</code></td>"
                        + "<td>\(escape(entry.date.formatted(date: .abbreviated, time: .shortened)))</td>"
                        + "<td>\(escape(entry.reason ?? "\u{2014}"))</td></tr>"
                }
                out += "</table>"
            }
            return out + "</section>"

        case .privateKey(let key):
            var out = head("Private key", key.format)
            out += row("Key", escape(key.key ?? "not known until it is decrypted"))
            out += row("Protection", key.protection.map { escape("Encrypted with " + $0) }
                       ?? "<span class=soon>Not encrypted: whoever can read the file has the key</span>")
            if let owner = owner(key.match) { out += row("Belongs to", owner) }
            return out + "</section>"

        case .publicKey(let key):
            var out = head("Public key", key.format)
            out += row("Key", escape(key.key))
            if let owner = owner(key.match) { out += row("Belongs to", owner) }
            out += row("SHA-256", "<code>\(escape(key.sha256))</code>")
            return out + "</section>"

        case .sshPublicKey(let key):
            var out = head(key.certificate == nil ? "SSH public key" : "SSH certificate", key.type)
            out += sshRows(key, now: now)
            return out + "</section>"

        case .sshPrivateKey(let key):
            var out = head("SSH private key", "OpenSSH")
            out += row("Protection", key.encryption.map { escape("Passphrase, " + $0) }
                       ?? "<span class=soon>No passphrase: whoever can read the file has the key</span>")
            for (index, publicKey) in key.keys.enumerated() {
                if key.keys.count > 1 { out += "<div class=issued>key \(index + 1)</div>" }
                out += sshRows(publicKey, now: now)
            }
            return out + "</section>"

        case .parameters(let text):
            return head("Parameters") + row("What", escape(text)) + "</section>"

        case .unreadable(let label, let reason):
            return head("Unreadable block", label) + row("Why", escape(reason)) + "</section>"
        }
    }

    /// "issued by #2, issues #1": where a certificate stands among the others.
    private static func links(_ certificate: X509, certificates: [(index: Int, certificate: X509)]) -> String? {
        guard certificates.count > 1 else { return nil }
        var parts: [String] = []
        if !certificate.isSelfIssued {
            if let issuer = certificates.first(where: { $0.certificate.subjectBytes == certificate.issuerBytes }) {
                parts.append("issued by #\(issuer.index + 1)")
            } else {
                parts.append("its issuer is not in the file")
            }
        }
        let issued = certificates.filter {
            !$0.certificate.isSelfIssued && $0.certificate.issuerBytes == certificate.subjectBytes
                && $0.certificate.encoded != certificate.encoded
        }
        if !issued.isEmpty { parts.append("issued " + issued.map { "#\($0.index + 1)" }.joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    private static func sshRows(_ key: SSHKey.Public, now: Date) -> String {
        func row(_ label: String, _ value: String) -> String {
            "<div class=row><span>\(escape(label))</span><span>\(value)</span></div>"
        }
        var out = row("Key", escape(key.label + (key.bits.map { ", \($0) bits" } ?? "")))
        if !key.fingerprint.isEmpty { out += row("Fingerprint", "<code>\(escape(key.fingerprint))</code>") }
        if let comment = key.comment, !comment.isEmpty { out += row("Comment", escape(comment)) }
        if let options = key.options { out += row("Options", "<code>\(escape(options))</code>") }
        if let certificate = key.certificate {
            out += row("For", escape(certificate.isHost ? "a host" : "a user"))
            out += row("Key ID", escape(certificate.keyID))
            out += row("Serial", "\(certificate.serial)")
            out += row("Principals", certificate.principals.isEmpty
                       ? "<span class=soon>any (none named)</span>" : escape(certificate.principals.joined(separator: ", ")))
            out += row("Valid", span(from: certificate.validAfter, to: certificate.validBefore, now: now))
            if !certificate.criticalOptions.isEmpty { out += row("Restrictions", escape(certificate.criticalOptions.joined(separator: ", "))) }
            if !certificate.extensions.isEmpty { out += row("Permits", escape(certificate.extensions.joined(separator: ", "))) }
            out += row("Signed by", "<code>\(escape(certificate.signedBy))</code>")
        }
        return out
    }

    /// "12 Nov 2026 to 12 Nov 2027", with expired or not yet valid marked.
    private static func span(from start: Date?, to end: Date?, now: Date) -> String {
        let from = start.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "always"
        let until = end.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "forever"
        var text = escape(start == nil && end == nil ? "always" : "\(from) to \(until)")
        if let end, end < now { text += " <span class=bad>expired</span>" }
        else if let start, start > now { text += " <span class=bad>not valid yet</span>" }
        else if let end, end.timeIntervalSince(now) < KeyStoreReport.soon {
            let days = max(0, Int(end.timeIntervalSince(now) / 86_400))
            text += " <span class=soon>expires in \(days) day\(days == 1 ? "" : "s")</span>"
        }
        return text
    }

    static func escape(_ text: String) -> String { PlistReport.escape(text) }
}
