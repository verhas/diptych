import XCTest
@testable import Diptych

/// Certificates, requests, revocation lists and keys in every form they come
/// in -- and the page that says what each is and how they fit together.
final class CertificateReportTests: XCTestCase {

    private func read(_ data: Data) throws -> CertificateFile { try CertificateFile.read(data) }

    private func certificates(_ file: CertificateFile) -> [X509] {
        file.items.compactMap { if case .certificate(let certificate, _) = $0 { return certificate } else { return nil } }
    }

    private func onlyPrivateKey(_ data: Data) throws -> CertificateFile.PrivateKey {
        let file = try read(data)
        guard file.items.count == 1, case .privateKey(let key) = file.items[0] else {
            XCTFail("not one private key: \(file.items)")
            throw DER.Bad()
        }
        return key
    }

    private func page(_ data: Data, _ name: String) -> String {
        CertificateReport.html(for: data, name: name, path: "/tmp", now: CertificateFixtures.madeOn)
    }

    // MARK: - Certificates

    func testCertificateInPEMAndDER() throws {
        for data in [CertificateFixtures.www, CertificateFixtures.wwwDER] {
            let certificate = try XCTUnwrap(certificates(try read(data)).first)
            XCTAssertEqual(X509.shortName(certificate.subject), "www.example.com")
            XCTAssertEqual(X509.shortName(certificate.issuer), "Diptych Sample Issuing CA")
            XCTAssertEqual(certificate.key, "RSA 2048")
            XCTAssertEqual(certificate.signatureAlgorithm, "ECDSA with SHA-256")
            XCTAssertEqual(certificate.alternativeNames, ["DNS:www.example.com", "DNS:*.example.com", "IP:192.0.2.10",
                                                          "IP:2001:db8::10", "email:admin@example.com"])
            XCTAssertEqual(certificate.usage, ["digital signature", "key encipherment", "TLS server", "TLS client"])
            XCTAssertEqual(certificate.serial.replacingOccurrences(of: ":", with: ""), CertificateFixtures.wwwSerial)
            XCTAssertFalse(certificate.isAuthority)
        }
        XCTAssertEqual(try read(CertificateFixtures.wwwDER).encoding, "DER")
    }

    func testAuthorityAndKinds() throws {
        let root = try XCTUnwrap(certificates(try read(CertificateFixtures.root)).first)
        XCTAssertTrue(root.isAuthority)
        XCTAssertTrue(root.isSelfIssued)
        XCTAssertEqual(root.key, "RSA 3072")
        XCTAssertEqual(root.usage, ["certificate signing", "CRL signing"])
        let ed = try XCTUnwrap(certificates(try read(CertificateFixtures.ed25519Certificate)).first)
        XCTAssertEqual(ed.key, "Ed25519")
        XCTAssertEqual(ed.signatureAlgorithm, "Ed25519")
    }

    func testValidityMarks() {
        XCTAssertTrue(page(CertificateFixtures.expired, "expired.crt").contains("<span class=bad>expired</span>"))
        XCTAssertTrue(page(CertificateFixtures.future, "future.crt").contains("<span class=bad>not valid yet</span>"))
        XCTAssertTrue(page(CertificateFixtures.soon, "soon.crt").contains("<span class=soon>expires in 9 days</span>"))
        XCTAssertFalse(page(CertificateFixtures.www, "www.crt").contains("class=bad"))
    }

    func testIPv6IsWrittenShort() {
        XCTAssertEqual(X509.ipv6([0x2001, 0xdb8, 0, 0, 0, 0, 0, 0x10]), "2001:db8::10")
        XCTAssertEqual(X509.ipv6([0, 0, 0, 0, 0, 0, 0, 1]), "::1")
        XCTAssertEqual(X509.ipv6([0x2001, 0xdb8, 0, 1, 0, 0, 0, 1]), "2001:db8:0:1::1")
        XCTAssertEqual(X509.ipv6([0x2001, 0xdb8, 0, 1, 2, 3, 4, 5]), "2001:db8:0:1:2:3:4:5")
    }

    // MARK: - Chains

    func testChainInOrder() throws {
        let file = try read(CertificateFixtures.fullchain)
        XCTAssertEqual(certificates(file).map { X509.shortName($0.subject) },
                       ["www.example.com", "Diptych Sample Issuing CA", "Diptych Sample Root CA"])
        let text = page(CertificateFixtures.fullchain, "fullchain.pem")
        XCTAssertTrue(text.contains("form one chain, each followed by its issuer, up to a self-signed root"))
        XCTAssertTrue(text.contains("issued by #2"))
    }

    func testChainOutOfOrderAndIncomplete() {
        XCTAssertTrue(page(CertificateFixtures.outOfOrder, "x.pem").contains("are not in chain order"))
        XCTAssertTrue(page(CertificateFixtures.missingRoot, "x.pem").contains("the one that issued the last is not in the file"))
        XCTAssertTrue(page(CertificateFixtures.caBundle, "x.crt").contains("not in chain order")
                      || page(CertificateFixtures.caBundle, "x.crt").contains("a bundle, not a chain"))
    }

    func testPKCS7Bundles() throws {
        for (data, encoding) in [(CertificateFixtures.p7b, "DER"), (CertificateFixtures.p7c, "PEM")] {
            let file = try read(data)
            XCTAssertEqual(file.encoding, encoding)
            XCTAssertEqual(certificates(file).count, 3)
        }
    }

    // MARK: - Keys and matching

    func testKeyBelongsToItsCertificate() {
        let right = page(CertificateFixtures.withKey, "x.pem")
        XCTAssertTrue(right.contains("<span class=good>certificate #1, www.example.com</span>"))
        let wrong = page(CertificateFixtures.wrongKey, "x.pem")
        XCTAssertTrue(wrong.contains("<span class=bad>no certificate in this file</span>"))
    }

    func testPrivateKeyForms() throws {
        let pkcs8 = try onlyPrivateKey(CertificateFixtures.rsaPKCS8)
        XCTAssertEqual(pkcs8.format, "PKCS#8")
        XCTAssertEqual(pkcs8.key, "RSA 2048")
        XCTAssertNil(pkcs8.protection)
        let pkcs1 = try onlyPrivateKey(CertificateFixtures.rsaPKCS1)
        XCTAssertEqual(pkcs1.format, "PKCS#1")
        XCTAssertEqual(pkcs1.match, pkcs8.match, "the same key in two containers")
        XCTAssertEqual(try onlyPrivateKey(CertificateFixtures.rsaDER).key, "RSA 2048")

        let ec = try onlyPrivateKey(CertificateFixtures.ecSEC1)
        XCTAssertEqual(ec.format, "SEC1")
        XCTAssertEqual(ec.key, "EC P-256")
        XCTAssertEqual(try onlyPrivateKey(CertificateFixtures.ed25519Key).key, "Ed25519")
    }

    func testEncryptedKeysSayHow() throws {
        let pkcs8 = try onlyPrivateKey(CertificateFixtures.rsaPKCS8Encrypted)
        XCTAssertNil(pkcs8.key, "an encrypted PKCS#8 key hides even its type")
        XCTAssertEqual(pkcs8.protection, "PBES2, AES-256-CBC")
        let pkcs1 = try onlyPrivateKey(CertificateFixtures.rsaPKCS1Encrypted)
        XCTAssertEqual(pkcs1.key, "RSA")
        XCTAssertEqual(pkcs1.protection?.hasPrefix("AES-128-CBC"), true)
    }

    func testDerivedPublicHalvesMatchCertificates() throws {
        // An Ed25519 key in PKCS#8 carries no public key: it is worked out.
        let pair = CertificateFixtures.ed25519Certificate + CertificateFixtures.ed25519Key
        XCTAssertTrue(page(pair, "pair.pem").contains("<span class=good>certificate #1, ed25519.example.com</span>"))
    }

    func testParametersAndPublicKeys() throws {
        let file = try read(CertificateFixtures.ecWithParameters)
        XCTAssertEqual(file.items.count, 2)
        guard case .parameters(let text) = file.items[0] else { return XCTFail("\(file.items[0])") }
        XCTAssertEqual(text, "EC parameters for P-256")
        for data in [CertificateFixtures.rsaPublic, CertificateFixtures.rsaPublicPKCS1] {
            guard case .publicKey(let key) = try read(data).items.first else { return XCTFail() }
            XCTAssertEqual(key.key, "RSA 2048")
            XCTAssertEqual(key.match, try onlyPrivateKey(CertificateFixtures.rsaPKCS8).match)
        }
    }

    // MARK: - Requests and lists

    func testRequest() throws {
        for data in [CertificateFixtures.csr, CertificateFixtures.csrDER] {
            guard case .request(let request) = try read(data).items.first else { return XCTFail() }
            XCTAssertEqual(X509.shortName(request.subject), "www.example.com")
            XCTAssertEqual(request.key, "RSA 2048")
            XCTAssertEqual(request.alternativeNames.first, "DNS:www.example.com")
            XCTAssertFalse(request.hasChallengePassword)
        }
    }

    func testRevocationList() throws {
        for data in [CertificateFixtures.crl, CertificateFixtures.crlDER] {
            guard case .revocationList(let list) = try read(data).items.first else { return XCTFail() }
            XCTAssertEqual(X509.shortName(list.issuer), "Diptych Sample Issuing CA")
            XCTAssertEqual(list.revoked.count, 1)
            XCTAssertEqual(list.revoked.first?.reason, "key compromise")
            XCTAssertEqual(list.number, "4096")
            XCTAssertNotNil(list.nextUpdate)
        }
    }

    // MARK: - SSH

    func testSSHPublicKeysMatchSSHKeygen() throws {
        for (data, fingerprint, label, bits) in [
            (CertificateFixtures.sshEd25519Public, CertificateFixtures.ed25519Fingerprint, "ED25519", 256),
            (CertificateFixtures.sshRSAPublic, CertificateFixtures.rsaFingerprint, "RSA", 3072),
            (CertificateFixtures.sshCA, CertificateFixtures.caFingerprint, "ED25519", 256),
        ] {
            guard case .sshPublicKey(let key) = try read(data).items.first else { return XCTFail() }
            XCTAssertEqual(key.fingerprint, fingerprint)
            XCTAssertEqual(key.label, label)
            XCTAssertEqual(key.bits, bits)
        }
    }

    func testSSHPrivateKeys() throws {
        guard case .sshPrivateKey(let open) = try read(CertificateFixtures.sshEd25519).items.first else { return XCTFail() }
        XCTAssertNil(open.encryption)
        XCTAssertEqual(open.keys.first?.fingerprint, CertificateFixtures.ed25519Fingerprint)
        XCTAssertEqual(open.keys.first?.comment, "sample@diptych.example", "read from beside the secret, which is skipped")

        guard case .sshPrivateKey(let locked) = try read(CertificateFixtures.sshRSA).items.first else { return XCTFail() }
        XCTAssertEqual(locked.encryption, "aes256-ctr, key derived with bcrypt, 24 rounds")
        XCTAssertEqual(locked.keys.first?.fingerprint, CertificateFixtures.rsaFingerprint)
        XCTAssertNil(locked.keys.first?.comment, "an encrypted key keeps its comment inside")

        guard case .sshPrivateKey(let ecdsa) = try read(CertificateFixtures.sshECDSA).items.first else { return XCTFail() }
        XCTAssertEqual(ecdsa.keys.first?.fingerprint, CertificateFixtures.ecdsaFingerprint)
        XCTAssertEqual(try read(CertificateFixtures.sshECDSA).encoding, "OpenSSH")
    }

    func testSSHCertificate() throws {
        guard case .sshPublicKey(let key) = try read(CertificateFixtures.sshCertificate).items.first,
              let certificate = key.certificate else { return XCTFail() }
        XCTAssertEqual(key.fingerprint, CertificateFixtures.ed25519Fingerprint, "a certificate's fingerprint is its key's")
        XCTAssertEqual(certificate.keyID, "sample-user")
        XCTAssertEqual(certificate.serial, 42)
        XCTAssertEqual(certificate.principals, ["alice", "deploy"])
        XCTAssertFalse(certificate.isHost)
        XCTAssertEqual(certificate.signedBy, "ED25519 " + CertificateFixtures.caFingerprint)
        XCTAssertTrue(certificate.extensions.contains("permit-pty"))
    }

    func testAuthorizedKeysAndRFC4716() throws {
        let file = try read(CertificateFixtures.authorizedKeys)
        XCTAssertEqual(file.encoding, "authorized_keys")
        let keys = file.items.compactMap { if case .sshPublicKey(let key) = $0 { return key } else { return nil } }
        XCTAssertEqual(keys.count, 4, "the comment line is not a key")
        XCTAssertEqual(keys[1].options, #"from="192.0.2.0/24",no-port-forwarding,no-pty"#)
        XCTAssertEqual(keys[1].fingerprint, CertificateFixtures.rsaFingerprint)
        XCTAssertEqual(keys[3].options, #"cert-authority,principals="alice""#)

        let rfc = try read(CertificateFixtures.sshRFC4716)
        XCTAssertEqual(rfc.encoding, "RFC 4716")
        guard case .sshPublicKey(let key) = rfc.items.first else { return XCTFail() }
        XCTAssertEqual(key.fingerprint, CertificateFixtures.ed25519Fingerprint)
        XCTAssertEqual(key.comment, "sample@diptych.example")
    }

    func testSSHProtocol1Key() throws {
        let line = "2048 65537 " + String(repeating: "1234567890", count: 60) + " old-host"
        guard case .sshPublicKey(let key) = try read(Data(line.utf8)).items.first else { return XCTFail() }
        XCTAssertEqual(key.bits, 2048)
        XCTAssertTrue(key.label.contains("obsolete"))
        XCTAssertEqual(key.comment, "old-host")
    }

    // MARK: - Not certificates

    func testWhatIsNotACertificate() {
        let text = Data("This file is named like a certificate but holds only this sentence.\n".utf8)
        XCTAssertThrowsError(try read(text))
        XCTAssertTrue(page(text, "x.crt").contains("does not read as one"))
        // A .key or .pub that is not one -- Keynote, Publisher -- is left to Quick Look.
        XCTAssertNil(CertificateReport.html(for: text, url: URL(fileURLWithPath: "/tmp/talk.key")))
        XCTAssertNil(CertificateReport.html(for: text, url: URL(fileURLWithPath: "/tmp/flyer.pub")))
        XCTAssertNotNil(CertificateReport.html(for: text, url: URL(fileURLWithPath: "/tmp/x.crt")))
    }

    func testWhichFilesAreHandled() {
        for name in ["a.crt", "a.CER", "a.pem", "a.p7b", "a.crl", "a.csr", "id_ed25519", "authorized_keys", "a.pub"] {
            XCTAssertTrue(CertificateReport.handles(URL(fileURLWithPath: "/tmp/" + name)), name)
        }
        for name in ["README", "a.txt", "a.p12", "id_rsa.bak"] {
            XCTAssertFalse(CertificateReport.handles(URL(fileURLWithPath: "/tmp/" + name)), name)
        }
    }

    func testDamagedBlockIsSaidSo() throws {
        let broken = Data("-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n".utf8)
        guard case .unreadable(let label, _) = try read(broken).items.first else { return XCTFail() }
        XCTAssertEqual(label, "CERTIFICATE")
    }

    func testPageSummaryLine() {
        XCTAssertTrue(page(CertificateFixtures.withKey, "x.pem").contains("PEM: a certificate and a private key"))
        XCTAssertTrue(page(CertificateFixtures.sshCertificate, "x.pub").contains("OpenSSH: an SSH certificate"))
        XCTAssertTrue(page(CertificateFixtures.authorizedKeys, "authorized_keys").contains("authorized_keys: 4 public keys"))
    }
}
