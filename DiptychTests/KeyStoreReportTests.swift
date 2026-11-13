import XCTest
@testable import Diptych

/// Key stores read without their password -- or with a default one the store
/// itself confirms -- and the page Quick Look shows.
final class KeyStoreReportTests: XCTestCase {

    private func read(_ data: Data) throws -> KeyStore { try KeyStore.read(data) }

    private func entry(_ store: KeyStore, _ alias: String) throws -> KeyStore.Entry {
        try XCTUnwrap(store.entries.first { $0.alias == alias }, "no entry \(alias)")
    }

    // MARK: - JKS and JCEKS

    func testJKSWithTheDefaultPassword() throws {
        let store = try read(KeyStoreFixtures.jks)
        XCTAssertEqual(store.format, .jks)
        XCTAssertEqual(store.version, 2)
        XCTAssertEqual(store.password, .known("changeit"))
        XCTAssertEqual(Set(store.entries.map(\.alias)), ["sample-ca", "server", "expired-ec"])

        let server = try entry(store, "server")
        XCTAssertEqual(server.kind, .privateKey)
        XCTAssertEqual(server.protection, "Sun's own JKS key protection")
        XCTAssertEqual(server.chain.map { X509.shortName($0.subject) }, ["server.example.com", "Diptych Sample CA"])
        let leaf = try XCTUnwrap(server.chain.first)
        XCTAssertEqual(leaf.key, "RSA 2048")
        XCTAssertEqual(leaf.signatureAlgorithm, "SHA-384 with RSA")
        XCTAssertEqual(leaf.alternativeNames, ["DNS:server.example.com", "DNS:localhost"])
        XCTAssertEqual(X509.text(of: leaf.subject),
                       "CN=server.example.com, OU=Web, O=Diptych Samples, L=Budapest, C=HU")
        XCTAssertFalse(leaf.isAuthority)
        XCTAssertTrue(server.chain[1].isAuthority)
        XCTAssertTrue(server.chain[1].isSelfIssued)

        XCTAssertEqual(try entry(store, "sample-ca").kind, .trustedCertificate)
        let expired = try XCTUnwrap(try entry(store, "expired-ec").chain.first)
        XCTAssertEqual(expired.key, "EC P-256")
        XCTAssertTrue(expired.isExpired(at: KeyStoreFixtures.madeOn))
    }

    func testJCEKSStepsOverTheSecretKey() throws {
        // The secret key is the first entry, a serialized Java object: unless
        // it is stepped over, nothing after it can be read.
        let store = try read(KeyStoreFixtures.jceks)
        XCTAssertEqual(store.format, .jceks)
        XCTAssertEqual(store.password, .unknown, "its password is not a default one")
        XCTAssertEqual(store.entries.count, 4)
        XCTAssertTrue(store.notes.isEmpty, "\(store.notes)")
        let secret = try entry(store, "api-secret")
        XCTAssertEqual(secret.kind, .secretKey)
        XCTAssertEqual(secret.protection, "Sealed with PBEWithMD5AndTripleDES")
        XCTAssertEqual(try entry(store, "server").protection, "PBE with MD5 and Triple DES")
        XCTAssertEqual(try entry(store, "server").chain.count, 2)
    }

    func testJKSIntegrity() {
        XCTAssertEqual(JavaKeyStore.integrity([], "").count, 20)
    }

    // MARK: - PKCS#12

    func testModernPKCS12OpensWithTheDefault() throws {
        let store = try read(KeyStoreFixtures.p12)
        XCTAssertEqual(store.format, .pkcs12)
        XCTAssertEqual(store.password, .known("changeit"))
        XCTAssertEqual(store.integrity, "HMAC-SHA256, \(10_000.formatted()) iterations")
        XCTAssertTrue(store.notes.isEmpty, "\(store.notes)")
        let server = try entry(store, "server")
        XCTAssertEqual(server.kind, .privateKey)
        XCTAssertEqual(server.protection, "PBES2, AES-256-CBC")
        XCTAssertEqual(server.chain.count, 2)
        XCTAssertEqual(try entry(store, "sample-ca").kind, .trustedCertificate)
        XCTAssertEqual(try entry(store, "expired-ec").chain.count, 1)
    }

    func testLockedPKCS12ShowsWhatIsInTheClear() throws {
        let store = try read(KeyStoreFixtures.locked)
        XCTAssertEqual(store.password, .unknown)
        // The keys sit outside the encrypted part, with their names.
        XCTAssertEqual(Set(store.entries.filter { $0.kind == .privateKey }.map(\.alias)), ["server", "expired-ec"])
        XCTAssertTrue(store.entries.allSatisfy { $0.chain.isEmpty })
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertTrue(store.notes[0].contains("PBES2, AES-256-CBC"))
    }

    func testOpenPKCS12NeedsNoPassword() throws {
        let store = try read(KeyStoreFixtures.open)
        XCTAssertEqual(store.password, .notNeeded)
        XCTAssertNil(store.integrity)
        XCTAssertEqual(try entry(store, "server").chain.count, 2)
        XCTAssertEqual(try entry(store, "sample-ca").kind, .trustedCertificate)
    }

    func testLegacyPFXWithAnEmptyPassword() throws {
        // RC2-40 for the certificates, Triple DES for the key, an empty password.
        let store = try read(KeyStoreFixtures.legacy)
        XCTAssertEqual(store.password, .known(""))
        XCTAssertEqual(store.integrity, "HMAC-SHA1, \(2048.formatted()) iterations")
        XCTAssertTrue(store.notes.isEmpty, "\(store.notes)")
        let server = try entry(store, "server")
        XCTAssertEqual(server.protection, "PBE with SHA-1 and Triple DES")
        XCTAssertEqual(server.chain.map { X509.shortName($0.subject) }, ["server.example.com", "Diptych Sample CA"])
        XCTAssertEqual(store.entries.filter { $0.kind == .certificate }.count, 2,
                       "the CA's and the expired certificates belong to no key here")
    }

    func testKeyDerivationKnownAnswer() {
        // RFC 7292's KDF, checked against OpenSSL's PKCS12_key_gen_uni for
        // the password "smeg", salt 0A58CF64530D823F, one iteration, ID 1.
        let key = PKCS12.kdf(.sha1, password: PKCS12.pkcs12Encodings("smeg")[0],
                             salt: [0x0A, 0x58, 0xCF, 0x64, 0x53, 0x0D, 0x82, 0x3F],
                             id: 1, iterations: 1, length: 24)
        XCTAssertEqual(key.map { String(format: "%02X", $0) }.joined(),
                       "8AAAE6297B6CB04642AB5B077851284EB7128F1A2A7FBCA3")
    }

    // MARK: - Not key stores

    func testNotAKeyStore() {
        XCTAssertThrowsError(try read(Data("hello, world".utf8)))
        let page = KeyStoreReport.html(for: Data("hello, world".utf8), name: "x.jks", path: "/tmp")
        XCTAssertTrue(page.contains("does not read as one"))
    }

    func testCutShort() throws {
        let store = try read(KeyStoreFixtures.jks.prefix(1500))
        XCTAssertFalse(store.notes.isEmpty, "a cut store says how far it got")
        XCTAssertEqual(store.password, .unknown)
        XCTAssertThrowsError(try read(KeyStoreFixtures.p12.prefix(1500)))
    }

    // MARK: - Page

    func testPage() {
        let page = KeyStoreReport.html(for: KeyStoreFixtures.jks, name: "sample.jks", path: "/tmp",
                                       now: KeyStoreFixtures.madeOn)
        XCTAssertTrue(page.contains("JKS key store, version 2, 3 entries"))
        XCTAssertTrue(page.contains("Its password is changeit, Java&#39;s well-known default")
                      || page.contains("Its password is changeit, Java's well-known default"))
        XCTAssertTrue(page.contains("<span class=bad>expired</span>"))
        XCTAssertFalse(page.contains("not valid yet"), "the others were good the day after they were made")
        XCTAssertTrue(page.contains("DNS:server.example.com, DNS:localhost"))
        XCTAssertTrue(page.contains("itself (self-signed)"))
        XCTAssertTrue(page.contains("issued by"))
    }

    func testPageForALockedStore() {
        let page = KeyStoreReport.html(for: KeyStoreFixtures.locked, name: "locked.p12", path: "/tmp",
                                       now: KeyStoreFixtures.madeOn)
        XCTAssertTrue(page.contains("not one of the defaults and is not asked for"))
        XCTAssertTrue(page.contains("needs the store&#39;s password") || page.contains("needs the store's password"))
    }
}
