import Foundation

/// E-mail as pages: one message with its headers, text and attachments,
/// or a mailbox as a list of messages that open in place. Nothing in a
/// message is loaded from the network or run.
nonisolated enum MailReport {

    typealias R = ExecutableReport

    static let shownText = 512 * 1024
    static let shownImages = 16 * 1024 * 1024

    static func html(for message: MailMessage, url: URL) -> String {
        let subject = message.subject.flatMap { $0.isEmpty ? nil : $0 }
        var body = "<h1>\(R.escape(subject ?? "(no subject)"))</h1>"
        let attachments = message.attachments
        var lead = "E-mail message, " + R.bytes(message.size)
        if !attachments.isEmpty { lead += ", \(attachments.count) attachment\(attachments.count == 1 ? "" : "s")" }
        body += "<p class=lead>\(R.escape(lead))</p><p class=meta>\(R.escape(url.path))</p>"
        body += content(message, depth: 0)
        return KeyStoreReport.page(title: url.lastPathComponent, body: R.style + style + body)
    }

    // MARK: - One message

    /// Notes, the header card, the text and the attachments.
    /// `textLimit`: the characters of its text shown; a mailbox shows fewer.
    static func content(_ message: MailMessage, depth: Int, textLimit: Int = shownText) -> String {
        var out = notes(message)
        out += "<div class=card><div class=cert>"
        for name in ["From", "To", "Cc", "Bcc", "Reply-To"] {
            guard let value = message.header(name), !value.isEmpty else { continue }
            out += R.row(name, R.escape(value))
        }
        if let date = message.date {
            out += R.row("Date", R.escape(date.formatted(date: .complete, time: .shortened)))
        } else if let raw = message.header("Date") {
            out += R.row("Date", R.escape(raw))
        }
        if let mailer = message.header("X-Mailer") ?? message.header("User-Agent") {
            out += R.row("Written with", R.escape(mailer))
        }
        let checks = message.authentication
        if !checks.isEmpty {
            out += R.row("On arrival", checks.map { check in
                let good = check.result == "pass"
                let bad = ["fail", "softfail", "permerror"].contains(check.result)
                return "\(check.check) <span class=\(good ? "good" : bad ? "bad" : "dim")>\(R.escape(check.result))</span>"
            }.joined(separator: ", ") + " <span class=dim>— checked by the receiving server</span>")
        }
        for protection in message.protection { out += protectionRow(protection) }
        out += "</div></div>"

        if let (text, fromHTML) = message.bodyText, !text.isEmpty {
            let shown = String(text.prefix(textLimit))
            out += "<div class=mail>\(R.escape(shown))</div>"
            if text.count > textLimit { out += "<p class=dim>The first \(textLimit.formatted()) characters shown.</p>" }
            if fromHTML {
                out += "<p class=dim>Shown as text, from its HTML: no image or anything else is loaded from the web.</p>"
            }
        } else if message.protection.contains(where: { if case .smimeEncrypted = $0 { true } else if case .pgpEncrypted = $0 { true } else { false } }) {
            out += "<p class=dim>Its text is encrypted.</p>"
        } else {
            out += "<p class=dim>No text.</p>"
        }

        let attachments = message.attachments
        if !attachments.isEmpty {
            out += "<h2>Attachments <span class=count>\(attachments.count)</span></h2><table class=summary>"
            for attachment in attachments {
                let ext = (attachment.name as NSString).pathExtension.lowercased()
                let risky = MailMessage.riskyExtensions.contains(ext)
                out += "<tr><td>\(R.escape(attachment.name))"
                if risky { out += " <span class=soon>— can run code when opened</span>" }
                out += "</td><td class=dim>\(R.escape(attachment.type))\(attachment.inline ? ", in the text" : "")</td>"
                out += "<td>\(R.tableSize(UInt64(attachment.size)))</td></tr>"
            }
            out += "</table>"
            var budget = shownImages
            let images = attachments.filter {
                ["image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp"].contains($0.type) && $0.size > 0
            }
            // Pictures on a message's own page only: a mailbox would grow huge.
            if !images.isEmpty, depth == 0 {
                out += "<div class=images>"
                for image in images where image.size <= budget {
                    budget -= image.size
                    out += "<figure><img src=\"data:\(image.type);base64,\(image.data.base64EncodedString())\">"
                    out += "<figcaption>\(R.escape(image.name))</figcaption></figure>"
                }
                out += "</div>"
            }
            for attachment in attachments where depth < 3 {
                guard let inner = attachment.message else { continue }
                out += "<details class=forwarded><summary><h2>Attached message: \(R.escape(inner.subject ?? "(no subject)"))</h2></summary>"
                out += content(inner, depth: depth + 1) + "</details>"
            }
        }

        let hops = message.headers("Received")
        if !hops.isEmpty {
            out += "<details><summary><h2>Delivered Through <span class=count>\(hops.count)</span></h2></summary><table class=summary>"
            for hop in hops.reversed() {
                let parts = hop.split(separator: ";", maxSplits: 1)
                out += "<tr><td><code>\(R.escape(String(parts[0]).trimmingCharacters(in: .whitespaces)))</code></td>"
                out += "<td class=dim>\(R.escape(parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""))</td></tr>"
            }
            out += "</table></details>"
        }
        out += "<details><summary><h2>All Headers <span class=count>\(message.root.headers.count)</span></h2></summary>"
        out += "<table class=summary>" + message.root.headers.map {
            "<tr><td><code>\(R.escape($0.name))</code></td><td class=wrap>\(R.escape(MailMessage.decodeWords($0.value)))</td></tr>"
        }.joined() + "</table></details>"
        return out
    }

    private static func notes(_ message: MailMessage) -> String {
        var out = ""
        let failed = message.authentication.filter { ["fail", "softfail", "permerror"].contains($0.result) }
        if !failed.isEmpty {
            out += "<p class=warn>The receiving server could not confirm it came from where it says: "
                + "\(R.escape(failed.map { "\($0.check) \($0.result)" }.joined(separator: ", "))).</p>"
        }
        if let from = MailMessage.domain(message.header("From")), let reply = MailMessage.domain(message.header("Reply-To")),
           MailMessage.base(from) != MailMessage.base(reply) {
            out += "<p class=note>Answers go to <b>\(R.escape(reply))</b>, not to the sender's <b>\(R.escape(from))</b>.</p>"
        }
        let misleading = message.misleadingLinks
        if !misleading.isEmpty {
            out += "<p class=warn>\(misleading.count == 1 ? "A link shows" : "\(misleading.count) links show") one address and "
                + "\(misleading.count == 1 ? "goes" : "go") to another:</p><table class=summary>"
            for link in misleading.prefix(20) {
                out += "<tr><td>\(R.escape(link.shown))</td><td>→ <code>\(R.escape(link.target))</code></td></tr>"
            }
            out += "</table>"
        }
        let risky = message.attachments.filter { MailMessage.riskyExtensions.contains(($0.name as NSString).pathExtension.lowercased()) }
        if !risky.isEmpty {
            out += "<p class=note>\(risky.count == 1 ? "An attachment" : "\(risky.count) attachments") can run code "
                + "when opened: \(R.escape(R.list(risky.map(\.name)))).</p>"
        }
        return out
    }

    private static func protectionRow(_ protection: MailMessage.Protection) -> String {
        switch protection {
        case .smimeSigned(let signer, let certificates, let signedAt):
            var text = "S/MIME"
            if let signer {
                text += ", by " + R.escape(X509.shortName(signer.subject))
                let issuer = certificates.first { $0.subjectBytes == signer.issuerBytes }
                text += " <span class=dim>— issued by \(R.escape(X509.shortName(issuer?.subject ?? signer.issuer)))"
                if signer.isExpired() { text += ", certificate expired" }
                text += "</span>"
            }
            if let signedAt { text += "<br><span class=dim>signed \(R.escape(signedAt.formatted(date: .long, time: .shortened)))</span>" }
            return R.row("Signed", text + "<br><span class=dim>the signature itself is not checked here</span>")
        case .smimeEncrypted: return R.row("Encrypted", "S/MIME <span class=dim>— only the recipient's key opens it</span>")
        case .pgpSigned: return R.row("Signed", "OpenPGP <span class=dim>— not checked here</span>")
        case .pgpEncrypted: return R.row("Encrypted", "OpenPGP <span class=dim>— only the recipient's key opens it</span>")
        }
    }

    static let style = """
        <style>
        .mail { white-space: pre-wrap; overflow-wrap: anywhere; font: 13px -apple-system, system-ui, sans-serif;
                background: var(--panel); border-radius: 6px; padding: 10px 12px; margin: 10px 0; line-height: 1.45; }
        td.wrap { overflow-wrap: anywhere; }
        .images { display: flex; flex-wrap: wrap; gap: 10px; margin: 8px 0; }
        .images figure { margin: 0; max-width: 220px; }
        .images img { max-width: 220px; max-height: 220px; border-radius: 4px; border: 1px solid var(--rule); }
        .images figcaption { font-size: 11px; color: var(--dim); overflow-wrap: anywhere; }
        details.forwarded { border-left: 3px solid var(--rule); padding-left: 10px; margin: 10px 0; }
        details.message { border-bottom: 1px solid var(--rule); }
        details.message > summary { display: grid; grid-template-columns: 14px 150px minmax(120px, 1fr) 2fr 70px;
                                    gap: 8px; padding: 4px 0; align-items: baseline; }
        details.message > summary::before { width: auto; }
        .list-head { display: grid; grid-template-columns: 14px 150px minmax(120px, 1fr) 2fr 70px; gap: 8px;
                     font-weight: 600; color: var(--dim); font-size: 11px; padding: 6px 0 2px; border-bottom: 1px solid var(--rule); }
        .plain { display: grid; grid-template-columns: 14px 150px minmax(120px, 1fr) 2fr 70px; gap: 8px;
                 padding: 4px 0; border-bottom: 1px solid var(--rule); }
        .cell { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .opened { padding: 4px 0 12px 22px; }
        .size { text-align: right; color: var(--dim); }
        </style>
        """

    // MARK: - Mailbox

    /// Messages opened in full in the list; the rest are rows only.
    static let openedMessages = 300

    static func html(for mailbox: Mailbox, url: URL) -> String {
        let name = url.lastPathComponent
        var body = "<h1>\(R.escape(name))</h1>"
        let count = mailbox.entries.count
        var lead = "Mailbox, \(count.formatted()) message\(count == 1 ? "" : "s"), " + R.bytes(mailbox.data.count)
        if mailbox.truncated { lead += " — only the first \(count.formatted()) are listed" }
        body += "<p class=lead>\(R.escape(lead))</p><p class=meta>\(R.escape(url.path))</p>"
        if count == 0 {
            body += "<p class=warn>No messages found in it.</p>"
            return KeyStoreReport.page(title: name, body: R.style + style + body)
        }
        body += "<div class=list-head><span></span><span>Date</span><span>From</span><span>Subject</span><span class=size>Size</span></div>"
        for (index, entry) in mailbox.entries.enumerated() {
            let opened = index < openedMessages
            let message = opened ? MailMessage(data: mailbox.message(entry)) : mailbox.headers(entry)
            let date = message.date ?? entry.envelopeDate
            let from = displayName(message.from ?? "")
            let attachments = opened ? message.attachments.count : 0
            let subject = (message.subject.flatMap { $0.isEmpty ? nil : $0 } ?? "(no subject)")
                + (attachments > 0 ? "  📎\(attachments)" : "")
            let cells = "<span class=cell>\(R.escape(date?.formatted(date: .abbreviated, time: .shortened) ?? ""))</span>"
                + "<span class=cell>\(R.escape(from))</span><span class=cell>\(R.escape(subject))</span>"
                + "<span class=\"cell size\">\(R.bytes(entry.range.count))</span>"
            if opened {
                body += "<details class=message><summary>\(cells)</summary><div class=opened>\(content(message, depth: 1, textLimit: 64 * 1024))</div></details>"
            } else {
                body += "<div class=plain><span></span>\(cells)</div>"
            }
        }
        if count > openedMessages {
            body += "<p class=dim>The first \(openedMessages) messages open in the list; the rest are shown by their headers.</p>"
        }
        return KeyStoreReport.page(title: name, body: R.style + style + body)
    }

    /// "Name <address>" as the name, the address when there is none.
    static func displayName(_ from: String) -> String {
        if let open = from.firstIndex(of: "<") {
            let name = from[..<open].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if !name.isEmpty { return name }
            return from[from.index(after: open)...].trimmingCharacters(in: CharacterSet(charactersIn: "> "))
        }
        return from
    }

    static func html(reading url: URL) -> String {
        KeyStoreReport.page(title: url.lastPathComponent,
                            body: "<h1>\(R.escape(url.lastPathComponent))</h1><p class=lead>Mailbox, reading\u{2026}</p>"
                                + "<p class=meta>\(R.escape(url.path))</p>")
    }
}
