import XCTest
@testable import Diptych

/// Trying passwords against an encrypted zip: the verifier read once, the
/// keyboard-weighted walk out from a guess, and the brute-force odometer with
/// its honest estimate.
final class PasswordRecoveryTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychRecovery-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    /// Confirms a candidate the way the real search does: by decrypting.
    private func confirm(for zip: URL) -> @Sendable (String) -> Bool {
        { Archiving.zipPasswordOpens($0, zip) }
    }

    private func encryptedZip(_ encryption: Archiving.ZipEncryption, password: String) throws -> URL {
        let source = root.appendingPathComponent("src-\(UUID().uuidString)")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("the secret contents".utf8).write(to: source.appendingPathComponent("a.txt"))
        var options = Archiving.Options()
        options.format = .zip
        options.zipEncryption = encryption
        let zip = root.appendingPathComponent("enc-\(UUID().uuidString).zip")
        do { try Archiving.create([source], at: zip, options: options, password: password) }
        catch { XCTFail(error.message); throw error }
        return zip
    }

    // MARK: - The verifier

    func testTheVerifierAgreesWithIsZipPassword() throws {
        for encryption in [Archiving.ZipEncryption.zipCrypto, .aes256] {
            let zip = try encryptedZip(encryption, password: "Sol3il!")
            let verifier = try XCTUnwrap(Archiving.ZipPasswordVerifier(zip), "\(encryption)")
            XCTAssertTrue(verifier.accepts("Sol3il!"), "\(encryption)")
            XCTAssertFalse(verifier.accepts("wrong"), "\(encryption)")
            XCTAssertEqual(Archiving.isZipPassword("Sol3il!", rightFor: zip), true, "\(encryption)")
            XCTAssertEqual(Archiving.isZipPassword("wrong", rightFor: zip), false, "\(encryption)")
            XCTAssertEqual(verifier.guessIsExpensive, encryption == .aes256, "\(encryption)")
        }
    }

    func testAnUnencryptedZipHasNoVerifier() throws {
        let source = root.appendingPathComponent("plain")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: source.appendingPathComponent("a.txt"))
        let zip = root.appendingPathComponent("plain.zip")
        try Archiving.create([source], at: zip, options: Archiving.Options())
        XCTAssertNil(Archiving.ZipPasswordVerifier(zip))
    }

    // MARK: - Keyboard distance

    func testAdjacentKeysAreNearerThanDistantOnes() {
        XCTAssertEqual(KeyboardLayout.substitutionCost("a", "a"), 0)
        XCTAssertLessThan(KeyboardLayout.substitutionCost("a", "s"),
                          KeyboardLayout.substitutionCost("a", "p"))
        // A held or missed Shift is cheaper than reaching another key.
        XCTAssertEqual(KeyboardLayout.substitutionCost("a", "A"), 0.5, accuracy: 0.0001)
        XCTAssertLessThan(KeyboardLayout.substitutionCost("a", "A"),
                          KeyboardLayout.substitutionCost("a", "s"))
    }

    func testNeighboursCoverEachKindOfSlip() {
        let neighbours = Set(KeyboardLayout.neighbours(of: "ab", maxLength: 8).map(\.0))
        XCTAssertTrue(neighbours.contains("ba"), "a transposition")
        XCTAssertTrue(neighbours.contains("b"), "a deletion")
        XCTAssertTrue(neighbours.contains("sb"), "a near-key substitution")
        XCTAssertTrue(neighbours.contains("aab"), "a doubled key")
    }

    // MARK: - Searching from a guess

    func testFindsAPasswordAFewKeysFromTheGuess() throws {
        let zip = try encryptedZip(.zipCrypto, password: "garden")
        let verifier = try XCTUnwrap(Archiving.ZipPasswordVerifier(zip))
        // "farsen": g→f and d→s, two neighbouring-key slips.
        let source = PasswordRecovery.NearGuessSource(seed: "farsen")
        let search = PasswordRecovery.Search(verifier: verifier, source: source,
                                             confirm: confirm(for: zip))
        XCTAssertEqual(search.run { _ in }, .found("garden"))
    }

    func testTheExactGuessIsTriedFirst() throws {
        let zip = try encryptedZip(.zipCrypto, password: "hunter2")
        let verifier = try XCTUnwrap(Archiving.ZipPasswordVerifier(zip))
        let source = PasswordRecovery.NearGuessSource(seed: "hunter2")
        XCTAssertEqual(source.next(), "hunter2", "the guess itself is the first candidate")
        XCTAssertTrue(verifier.accepts("hunter2"))
    }

    // MARK: - Brute force

    func testBruteForceFindsAShortPassword() throws {
        let zip = try encryptedZip(.zipCrypto, password: "zz")
        let verifier = try XCTUnwrap(Archiving.ZipPasswordVerifier(zip))
        let source = PasswordRecovery.BruteForceSource(alphabet: Array("abz"), maxLength: 2)
        let search = PasswordRecovery.Search(verifier: verifier, source: source,
                                             confirm: confirm(for: zip))
        XCTAssertEqual(search.run { _ in }, .found("zz"))
    }

    func testBruteForceRunsOutWhenThePasswordIsLonger() throws {
        let zip = try encryptedZip(.zipCrypto, password: "hello")
        let verifier = try XCTUnwrap(Archiving.ZipPasswordVerifier(zip))
        let source = PasswordRecovery.BruteForceSource(alphabet: Array("ab"), maxLength: 2)
        let search = PasswordRecovery.Search(verifier: verifier, source: source,
                                             confirm: confirm(for: zip))
        XCTAssertEqual(search.run { _ in }, .exhausted)
    }

    func testCancellingStopsTheSearch() throws {
        let zip = try encryptedZip(.zipCrypto, password: "neverfound")
        let verifier = try XCTUnwrap(Archiving.ZipPasswordVerifier(zip))
        // A space large enough that it will not finish before it is cancelled.
        let source = PasswordRecovery.BruteForceSource(alphabet: Array("abcdefgh"), maxLength: 8)
        let search = PasswordRecovery.Search(verifier: verifier, source: source,
                                             confirm: confirm(for: zip))
        let cancelled = expectation(description: "cancelled")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { search.cancel() }
        DispatchQueue.global().async {
            XCTAssertEqual(search.run { _ in }, .cancelled)
            cancelled.fulfill()
        }
        wait(for: [cancelled], timeout: 10)
    }

    // MARK: - Counting and estimating

    func testSpaceCountsAndOverflowsToNil() {
        XCTAssertEqual(PasswordRecovery.space(alphabet: 26, maxLength: 3), 26 + 676 + 17_576)
        XCTAssertEqual(PasswordRecovery.space(alphabet: 10, maxLength: 1), 10)
        XCTAssertNil(PasswordRecovery.space(alphabet: 95, maxLength: 40), "far past a UInt64")
    }

    func testEstimateReadsAsTime() {
        XCTAssertEqual(PasswordRecovery.describe(seconds: 0.1), "under a second")
        XCTAssertEqual(PasswordRecovery.describe(seconds: 5), "about 5 seconds")
        XCTAssertEqual(PasswordRecovery.describe(seconds: 120), "about 2 minutes")
        XCTAssertEqual(PasswordRecovery.estimate(space: nil, secondsPerGuess: 1e-6),
                       "effectively forever -- more guesses than can be counted")
        XCTAssertTrue(PasswordRecovery.estimate(space: 1_000_000_000_000_000_000,
                                                secondsPerGuess: 1, cores: 1).contains("forever"))
    }

    func testAGuessCostsMoreUnderAESThanZipCrypto() throws {
        let aes = try XCTUnwrap(Archiving.ZipPasswordVerifier(try encryptedZip(.aes256, password: "s3cret!")))
        let zipCrypto = try XCTUnwrap(Archiving.ZipPasswordVerifier(try encryptedZip(.zipCrypto, password: "s3cret!")))
        let aesCost = PasswordRecovery.secondsPerGuess(aes)
        let zipCryptoCost = PasswordRecovery.secondsPerGuess(zipCrypto)
        XCTAssertGreaterThan(aesCost, 0)
        XCTAssertGreaterThan(zipCryptoCost, 0)
        XCTAssertGreaterThan(aesCost, zipCryptoCost, "PBKDF2 is far dearer than ZipCrypto")
    }
}
