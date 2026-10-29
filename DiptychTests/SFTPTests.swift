import XCTest
import Crypto
import NIOSSH
@testable import Diptych

/// The SFTP connection's parts that need no server: how hosts are filed,
/// the host keys kept for them, and what a listing's mode bits mean.
final class SFTPTests: XCTestCase {

    /// Fresh ed25519 keys, so the tests never depend on a made-up key string.
    private func newKey() -> NIOSSHPublicKey {
        NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
    }

    private func temporaryKeys() -> SFTPHostKeys {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sftp-tests-\(UUID().uuidString)")
        return SFTPHostKeys(file: dir.appendingPathComponent("known_hosts"))
    }

    func testTheDefaultPortIsFiledBare() {
        XCTAssertEqual(SFTPHostKeys.filing(host: "nas", port: 22), "nas")
        XCTAssertEqual(SFTPHostKeys.filing(host: "nas", port: 2222), "[nas]:2222")
    }

    func testNothingIsTrustedBeforeItIsKept() {
        let keys = temporaryKeys()
        XCTAssertNil(keys.key(for: "nas"))
    }

    func testAKeptKeyIsFoundAgainForItsHostOnly() throws {
        let keys = temporaryKeys()
        let key = newKey()
        try keys.trust(key, for: "nas")
        XCTAssertEqual(keys.key(for: "nas"), key)
        XCTAssertNil(keys.key(for: "other"))
    }

    func testTrustingAgainReplacesTheKeyForThatHostOnly() throws {
        let keys = temporaryKeys()
        let first = newKey()
        let second = newKey()
        try keys.trust(first, for: "nas")
        try keys.trust(first, for: "[nas]:2222")
        try keys.trust(second, for: "nas")
        XCTAssertEqual(keys.key(for: "nas"), second)
        XCTAssertEqual(keys.key(for: "[nas]:2222"), first)
    }

    func testAModeKeepsItsTypeApartFromItsPermissions() {
        XCTAssertEqual(SFTPEntry.kind(ofPermissions: 0o040755), .directory)
        XCTAssertEqual(SFTPEntry.kind(ofPermissions: 0o100644), .file)
        XCTAssertEqual(SFTPEntry.kind(ofPermissions: 0o120777), .symlink)
        XCTAssertEqual(SFTPEntry.kind(ofPermissions: nil), .other)
    }

    // MARK: - ~/.ssh/known_hosts

    private func knownHosts(_ text: String) -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("known-hosts-\(UUID().uuidString)")
        try! text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func line(_ host: String, _ key: NIOSSHPublicKey) -> String {
        "\(host) \(String(openSSHPublicKey: key))"
    }

    func testKnownHostsAbsentWhenThereIsNoFileOrNoEntry() {
        let key = newKey()
        XCTAssertEqual(KnownHosts.standing(host: "nas", port: 22, key: key,
                                           file: URL(fileURLWithPath: "/nonexistent/known_hosts")), .absent)
        XCTAssertEqual(KnownHosts.standing(host: "nas", port: 22, key: key,
                                           file: knownHosts(line("other", key))), .absent)
    }

    func testKnownHostsTrustedOnlyForTheSameKey() {
        let key = newKey()
        let file = knownHosts(line("nas", key))
        XCTAssertEqual(KnownHosts.standing(host: "nas", port: 22, key: key, file: file), .trusted)
        XCTAssertEqual(KnownHosts.standing(host: "nas", port: 22, key: newKey(), file: file), .differs)
    }

    func testAnotherPortIsFiledInBrackets() {
        let key = newKey()
        let file = knownHosts(line("[nas]:2222", key))
        XCTAssertEqual(KnownHosts.standing(host: "nas", port: 2222, key: key, file: file), .trusted)
        XCTAssertEqual(KnownHosts.standing(host: "nas", port: 22, key: key, file: file), .absent)
    }

    func testPatternsAndNegationsAsInOpenSSH() {
        let key = newKey()
        let wild = knownHosts(line("*.lan,!gate.lan", key))
        XCTAssertEqual(KnownHosts.standing(host: "nas.lan", port: 22, key: key, file: wild), .trusted)
        XCTAssertEqual(KnownHosts.standing(host: "gate.lan", port: 22, key: key, file: wild), .absent)
    }

    func testHashedNamesAreMatchedWithoutBeingRead() {
        let key = newKey()
        let salt = Data("0123456789abcdef".utf8)
        let hash = Data(HMAC<Insecure.SHA1>.authenticationCode(
            for: Data("nas".utf8), using: SymmetricKey(data: salt)))
        let hashed = "|1|\(salt.base64EncodedString())|\(hash.base64EncodedString()) "
            + String(openSSHPublicKey: key)
        let file = knownHosts(hashed + "\n")
        XCTAssertEqual(KnownHosts.standing(host: "nas", port: 22, key: key, file: file), .trusted)
        XCTAssertEqual(KnownHosts.standing(host: "other", port: 22, key: key, file: file), .absent)
    }

    func testMarkerLinesAreNotTrust() {
        let key = newKey()
        let file = knownHosts("@revoked " + line("nas", key) + "\n")
        XCTAssertEqual(KnownHosts.standing(host: "nas", port: 22, key: key, file: file), .absent)
    }

    func testTheFingerprintIsOpenSSHsShape() {
        let fingerprint = KnownHosts.fingerprint(of: newKey())
        XCTAssertTrue(fingerprint.hasPrefix("SHA256:"))
        XCTAssertEqual(fingerprint.count, "SHA256:".count + 43)
        XCTAssertFalse(fingerprint.contains("="))
    }

    func testTheLinesKeptForAHostAreNumberedAsAnEditorNumbersThem() throws {
        let keys = temporaryKeys()
        let first = newKey()
        let second = newKey()
        try keys.trust(first, for: "nas")
        try keys.trust(second, for: "other")
        // A blank line above the entry must still count, as an editor counts it.
        let text = try String(contentsOf: keys.file, encoding: .utf8)
        try ("\n" + text).write(to: keys.file, atomically: true, encoding: .utf8)
        let entries = keys.entries(for: "nas")
        XCTAssertEqual(entries.map(\.line), [2])
        XCTAssertTrue(entries[0].text.hasPrefix("nas ssh-ed25519 "))
        XCTAssertLessThan(entries[0].text.count, 80)
    }

    @MainActor
    func testAChangedKeyTellsThePersonWhichLinesToDelete() throws {
        let text = AppModel.changedKeyText(filing: "nas-that-is-not-kept")
        XCTAssertTrue(text.contains("has no line for nas-that-is-not-kept"))
    }
}
