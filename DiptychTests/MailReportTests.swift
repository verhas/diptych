import XCTest
@testable import Diptych

/// E-mail messages and mailboxes, from text written here. Every address is
/// at a reserved example domain.
final class MailReportTests: XCTestCase {

    private func message(_ text: String) -> MailMessage {
        MailMessage(data: Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8))
    }

    func testEncodedHeaders() {
        XCTAssertEqual(MailMessage.decodeWords("=?UTF-8?B?w4lrZXpldGVr?= =?UTF-8?Q?_=C3=A9s_sorok?="), "Ékezetek és sorok")
        XCTAssertEqual(MailMessage.decodeWords("Re: =?iso-8859-2?Q?=E1rv=EDzt=FBr=F5?= x"), "Re: árvíztűrő x")
        XCTAssertEqual(MailMessage.decodeWords("plain text"), "plain text")
        let mail = message("""
            From: =?UTF-8?Q?Zs=C3=B3fia?= <zsofia@example.com>
            Subject: A long
             folded subject
            To: reader@example.org

            Body.
            """)
        XCTAssertEqual(mail.from, "Zsófia <zsofia@example.com>")
        XCTAssertEqual(mail.subject, "A long folded subject")
        XCTAssertEqual(mail.bodyText?.text, "Body.")
    }

    func testQuotedPrintableAndCharset() {
        let mail = message("""
            Subject: q
            Content-Type: text/plain; charset=ISO-8859-2
            Content-Transfer-Encoding: quoted-printable

            =E1rv=EDzt=FBr=F5 soft =
            break
            """)
        XCTAssertEqual(mail.bodyText?.text, "árvíztűrő soft break")
    }

    func testAlternativePrefersPlainText() {
        let mail = message("""
            Subject: both
            Content-Type: multipart/alternative; boundary="b"

            --b
            Content-Type: text/plain; charset=utf-8

            The plain text.
            --b
            Content-Type: text/html; charset=utf-8

            <p>The <b>HTML</b>.</p>
            --b--
            """)
        XCTAssertEqual(mail.bodyText?.text, "The plain text.")
        XCTAssertEqual(mail.bodyText?.fromHTML, false)
        XCTAssertTrue(mail.attachments.isEmpty)
    }

    func testHTMLOnlyAndMisleadingLinks() {
        let mail = message("""
            From: Bank <service@example.com>
            Subject: confirm
            Content-Type: text/html; charset=utf-8

            <html><head><style>p{}</style><script>alert(1)</script></head><body>
            <p>Go to <a href="https://login.example.net/x">https://www.example.com/account</a> now&nbsp;&amp; <a href="https://www.example.com/help">help</a>.</p>
            <img src="https://tracker.example.net/p.gif"><br>Thanks
            </body></html>
            """)
        let text = mail.bodyText
        XCTAssertEqual(text?.fromHTML, true)
        XCTAssertEqual(text?.text, "Go to https://www.example.com/account now & help.\n\nThanks")
        XCTAssertEqual(mail.misleadingLinks.map(\.target), ["https://login.example.net/x"])
        let html = MailReport.html(for: mail, url: URL(fileURLWithPath: "/m.eml"))
        XCTAssertTrue(html.contains("A link shows one address and goes to another"))
        XCTAssertFalse(html.contains("tracker.example.net/p.gif\""))
        XCTAssertFalse(html.contains("<script>"))
    }

    func testAttachments() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]).base64EncodedString()
        let mail = message("""
            From: sender@example.com
            Subject: files
            Content-Type: multipart/mixed; boundary="outer"

            preamble
            --outer
            Content-Type: text/plain

            See the files.
            --outer
            Content-Type: image/png; name="dot.png"
            Content-Disposition: attachment; filename="dot.png"
            Content-Transfer-Encoding: base64

            \(png)
            --outer
            Content-Type: application/octet-stream
            Content-Disposition: attachment;
             filename*0*=UTF-8''%C3%A1rv%C3%ADz;
             filename*1*=t%C5%B1r%C5%91.pdf.exe
            Content-Transfer-Encoding: base64

            TVo=
            --outer--
            epilogue
            """)
        XCTAssertEqual(mail.bodyText?.text, "See the files.")
        let attachments = mail.attachments
        XCTAssertEqual(attachments.map(\.name), ["dot.png", "árvíztűrő.pdf.exe"])
        XCTAssertEqual(attachments.map(\.size), [11, 2])
        let html = MailReport.html(for: mail, url: URL(fileURLWithPath: "/m.eml"))
        XCTAssertTrue(html.contains("2 attachments"))
        XCTAssertTrue(html.contains("can run code when opened"))
        XCTAssertTrue(html.contains("data:image/png;base64,"))
    }

    func testForwardedMessage() {
        let mail = message("""
            Subject: Fwd
            Content-Type: multipart/mixed; boundary="f"

            --f
            Content-Type: text/plain

            Look.
            --f
            Content-Type: message/rfc822

            From: original@example.com
            Subject: The original

            Inner text.
            --f--
            """)
        let attachment = mail.attachments.first
        XCTAssertEqual(attachment?.name, "The original.eml")
        XCTAssertEqual(attachment?.message?.bodyText?.text, "Inner text.")
        XCTAssertTrue(MailReport.html(for: mail, url: URL(fileURLWithPath: "/m.eml")).contains("Attached message: The original"))
    }

    func testSuspiciousHeaders() {
        let mail = message("""
            Authentication-Results: mx.example.org; spf=fail smtp.mailfrom=example.com; dkim=pass; dmarc=fail
            From: Director <director@example.com>
            Reply-To: someone@example.net
            Subject: Pay now

            Pay.
            """)
        XCTAssertEqual(mail.authentication.map(\.check), ["SPF", "DKIM", "DMARC"])
        XCTAssertEqual(mail.authentication.map(\.result), ["fail", "pass", "fail"])
        let html = MailReport.html(for: mail, url: URL(fileURLWithPath: "/m.eml"))
        XCTAssertTrue(html.contains("could not confirm it came from where it says: SPF fail, DMARC fail"))
        XCTAssertTrue(html.contains("Answers go to <b>example.net</b>"))

        // The same registrable domain is no warning.
        let fine = message("From: a@mail.example.com\nReply-To: b@example.com\nSubject: s\n\nx")
        XCTAssertFalse(MailReport.html(for: fine, url: URL(fileURLWithPath: "/m.eml")).contains("Answers go to"))
    }

    func testSignedAndEncrypted() {
        let pgp = message("""
            Subject: s
            Content-Type: multipart/signed; protocol="application/pgp-signature"; boundary="s"

            --s
            Content-Type: text/plain

            Signed text.
            --s
            Content-Type: application/pgp-signature

            -----BEGIN PGP SIGNATURE-----
            -----END PGP SIGNATURE-----
            --s--
            """)
        XCTAssertEqual(pgp.bodyText?.text, "Signed text.")
        XCTAssertTrue(pgp.attachments.isEmpty)
        guard case .pgpSigned? = pgp.protection.first else { return XCTFail("not seen as signed") }

        let smime = message("""
            Subject: e
            Content-Type: application/pkcs7-mime; smime-type=enveloped-data; name=smime.p7m
            Content-Transfer-Encoding: base64

            MIAGCSqGSIb3DQEHA6CAMIACAQA=
            """)
        guard case .smimeEncrypted? = smime.protection.first else { return XCTFail("not seen as encrypted") }
        XCTAssertTrue(MailReport.html(for: smime, url: URL(fileURLWithPath: "/m.eml")).contains("Its text is encrypted."))
    }

    func testFlowedText() {
        XCTAssertEqual(MailMessage.unflowed("one \ntwo\n-- \nsig", delsp: false), "one two\n-- \nsig\n")
        XCTAssertEqual(MailMessage.unflowed("ab \ncd", delsp: true), "abcd\n")
    }

    func testEmlx() {
        let inner = "Subject: Stored by Mail\r\n\r\nText.\r\n"
        let data = Data("\(inner.utf8.count)\n\(inner)<?xml version=\"1.0\"?><plist><dict/></plist>".utf8)
        let mail = MailMessage(data: data)
        XCTAssertEqual(mail.subject, "Stored by Mail")
        XCTAssertEqual(mail.bodyText?.text, "Text.\n")
    }

    func testMailbox() {
        let text = """
            From alice@example.com Tue Nov 10 09:15:00 2026
            From: Alice <alice@example.com>
            Subject: First
            Date: Tue, 10 Nov 2026 09:15:00 +0000

            Hello.

            From bob@example.org Wed Nov 11 10:00:00 2026
            From: bob@example.org
            Subject: Second

            A line inside:
            >From now on, quoted.
            From the middle of a line is no separator.

            From carol@example.net Thu Nov 12 11:00:00 2026
            From: Carol <carol@example.net>
            Subject: =?UTF-8?Q?Harmadik_=C3=BCzenet?=

            Third.

            """
        let data = Data(text.utf8)
        XCTAssertTrue(Mailbox.looksLikeMailbox(data))
        XCTAssertFalse(Mailbox.looksLikeMailbox(Data("From: header only\n".utf8)))
        let box = Mailbox(data: data)
        XCTAssertEqual(box.entries.count, 3)
        XCTAssertNotNil(box.entries[1].envelopeDate)
        let second = MailMessage(data: box.message(box.entries[1]))
        XCTAssertEqual(second.subject, "Second")
        XCTAssertTrue(second.bodyText?.text.contains("\nFrom now on, quoted.") == true)
        XCTAssertEqual(box.headers(box.entries[2]).subject, "Harmadik üzenet")

        let html = MailReport.html(for: box, url: URL(fileURLWithPath: "/Sample.mbox"))
        XCTAssertTrue(html.contains("Mailbox, 3 messages"))
        XCTAssertTrue(html.contains("Alice"))
        XCTAssertTrue(html.contains("Harmadik üzenet"))
        XCTAssertEqual(html.components(separatedBy: "<details class=message>").count - 1, 3)
    }

    func testDisplayName() {
        XCTAssertEqual(MailReport.displayName("\"Alice A.\" <alice@example.com>"), "Alice A.")
        XCTAssertEqual(MailReport.displayName("<bob@example.org>"), "bob@example.org")
        XCTAssertEqual(MailReport.displayName("carol@example.net"), "carol@example.net")
    }

    func testDates() {
        XCTAssertNotNil(MailMessage.date("Tue, 10 Nov 2026 09:15:00 +0100"))
        XCTAssertNotNil(MailMessage.date("10 Nov 2026 09:15:00 +0100 (CET)"))
        XCTAssertNotNil(MailMessage.date("Tue, 10 Nov 2026 09:15 +0100"))
        XCTAssertNil(MailMessage.date("yesterday"))
    }

    /// Damaged messages: never a trap.
    func testDamagedMessagesDoNotCrash() {
        let original = Data("""
            From: a@example.com\r\nSubject: =?UTF-8?B?w4lr?=\r\nContent-Type: multipart/mixed; boundary="b"\r\n\r\n\
            --b\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nA=3Db=\r\n\
            --b\r\nContent-Type: image/png\r\nContent-Disposition: attachment; filename*0*=UTF-8''%C3%A1;\r\n\
            Content-Transfer-Encoding: base64\r\n\r\niVBORw0KGgo=\r\n--b--\r\n
            """.utf8)
        var generator = SeededGenerator(seed: 3)
        for round in 0..<500 {
            var data = original
            for _ in 0..<(1 + round % 5) {
                data[Int.random(in: 0..<data.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            let mail = MailMessage(data: data)
            _ = MailReport.html(for: mail, url: URL(fileURLWithPath: "/m.eml"))
        }
    }
}
