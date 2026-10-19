import XCTest
import Darwin
@testable import Diptych

/// Archives under a password: zips by tar, AES-256 or ZipCrypto, and Apple
/// Encrypted Archives by aea -- made, listed and unpacked, and the password
/// never on a command line.
final class ArchiveEncryptionTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default
    private let longPassword = "correct horse battery staple"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiptychEncryption-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    /// `src/photos/a.txt` and `src/photos/sub/b.txt`.
    private func makeFolder() throws -> URL {
        let folder = root.appendingPathComponent("src/photos")
        try fm.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Data("world".utf8).write(to: folder.appendingPathComponent("sub/b.txt"))
        return folder
    }

    private func create(_ items: [URL], _ options: Archiving.Options, password: String?,
                        named name: String) -> URL {
        let target = root.appendingPathComponent(name)
        do { try Archiving.create(items, at: target, options: options, password: password) }
        catch { XCTFail(error.message) }
        return target
    }

    private func secret(_ password: String, newline: Bool) throws -> Archiving.PasswordFile {
        do { return try Archiving.PasswordFile(password, endsWithNewline: newline) }
        catch { XCTFail(error.message); throw error }
    }

    /// Unpacked with `password`, or the failure.
    private func unpack(_ archive: URL, password: String?) throws -> Result<URL, Archiving.Failure> {
        let kind = try XCTUnwrap(Archiving.kind(of: archive))
        let out = root.appendingPathComponent("out-\(UUID().uuidString)")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let file = try password.map { try secret($0, newline: kind == .zip) }
        do {
            let entries = try Archiving.entries(of: archive, kind: kind, password: file)
            try Archiving.unpack(archive, kind: kind, into: out, password: file, entries: entries)
            return .success(out)
        } catch {
            return .failure(error)
        }
    }

    private func text(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - Zip

    func testAnAESZipOpensWithItsPasswordOnly() throws {
        var options = Archiving.Options()
        options.zipEncryption = .aes256
        let zip = create([try makeFolder()], options, password: "s3cret", named: "p.zip")
        XCTAssertTrue(Archiving.isEncryptedZip(zip))
        XCTAssertTrue(Archiving.needsPassword(zip, kind: .zip))

        let out = try unpack(zip, password: "s3cret").get()
        XCTAssertEqual(text(out.appendingPathComponent("photos/a.txt")), "hello")
        XCTAssertEqual(text(out.appendingPathComponent("photos/sub/b.txt")), "world")

        let started = Date()
        guard case .failure(let failure) = try unpack(zip, password: "wrong") else {
            return XCTFail("opened with the wrong password")
        }
        XCTAssertTrue(failure.isWrongPassword, failure.message)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "tar was left to try ten thousand times")
        XCTAssertEqual(Archiving.isZipPassword("s3cret", rightFor: zip), true)
        XCTAssertEqual(Archiving.isZipPassword("s3cre", rightFor: zip), false)
    }

    func testAZipCryptoZipOpensWithUnzip() throws {
        var options = Archiving.Options()
        options.zipEncryption = .zipCrypto
        let zip = create([try makeFolder()], options, password: "s3cret", named: "weak.zip")
        XCTAssertTrue(Archiving.isEncryptedZip(zip))
        // What every other unzip does: the old scheme, opened anywhere.
        let out = root.appendingPathComponent("unzipped")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-P", "s3cret", zip.path, "-d", out.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(text(out.appendingPathComponent("photos/a.txt")), "hello")
        XCTAssertEqual(Archiving.isZipPassword("s3cret", rightFor: zip), true)
        XCTAssertEqual(Archiving.isZipPassword("guess", rightFor: zip), false)
        guard case .failure(let failure) = try unpack(zip, password: "guess") else {
            return XCTFail("opened with the wrong password")
        }
        XCTAssertTrue(failure.isWrongPassword, failure.message)
    }

    func testAPlainZipNeedsNoPassword() throws {
        let zip = create([try makeFolder()], Archiving.Options(), password: nil, named: "plain.zip")
        XCTAssertFalse(Archiving.isEncryptedZip(zip))
        XCTAssertFalse(Archiving.needsPassword(zip, kind: .zip))
        XCTAssertEqual(text(try unpack(zip, password: nil).get()
            .appendingPathComponent("photos/a.txt")), "hello")
    }

    func testAnEncryptedZipIsNamedAfterItsFormatAndWantsAPassword() {
        var options = Archiving.Options()
        options.zipEncryption = .aes256
        XCTAssertTrue(options.needsPassword)
        XCTAssertEqual(options.fileExtension, "zip")
        XCTAssertNotNil(options.passwordProblem(""))
        XCTAssertNotNil(options.passwordProblem("two\nlines"))
        XCTAssertNil(options.passwordProblem("short"))
        XCTAssertThrowsError(try Archiving.create([root], at: root.appendingPathComponent("x.zip"),
                                                  options: options, password: nil))
    }

    // MARK: - Apple Encrypted Archive

    func testAnAppleEncryptedArchiveOpensWithItsPasswordOnly() throws {
        var options = Archiving.Options()
        options.format = .appleArchive
        options.aarEncrypted = true
        XCTAssertEqual(options.fileExtension, "aea")
        let archive = create([try makeFolder()], options, password: longPassword, named: "p.aea")
        XCTAssertEqual(try Data(contentsOf: archive).prefix(4), Data("AEA1".utf8))
        XCTAssertEqual(Archiving.kind(of: archive), .appleEncrypted)
        XCTAssertTrue(Archiving.needsPassword(archive, kind: .appleEncrypted))

        let secret = try secret(longPassword, newline: false)
        let entries: [Archiving.Entry]
        do { entries = try Archiving.entries(of: archive, kind: .appleEncrypted, password: secret) }
        catch { return XCTFail(error.message) }
        XCTAssertTrue(entries.contains { $0.path == "photos/sub/b.txt" && $0.size == 5 })

        let out = try unpack(archive, password: longPassword).get()
        XCTAssertEqual(text(out.appendingPathComponent("photos/sub/b.txt")), "world")

        guard case .failure(let failure) = try unpack(archive, password: longPassword + "!") else {
            return XCTFail("opened with the wrong password")
        }
        XCTAssertTrue(failure.isWrongPassword, failure.message)
    }

    func testAShortAppleArchivePasswordIsRefusedBeforeAnythingRuns() throws {
        var options = Archiving.Options()
        options.format = .appleArchive
        options.aarEncrypted = true
        XCTAssertNotNil(options.passwordProblem("only nineteen chars"))
        XCTAssertNil(options.passwordProblem(longPassword))
        let target = root.appendingPathComponent("short.aea")
        XCTAssertThrowsError(try Archiving.create([try makeFolder()], at: target, options: options,
                                                  password: "too short"))
        XCTAssertFalse(fm.fileExists(atPath: target.path))
    }

    // MARK: - The password itself

    func testThePasswordIsNeverAnArgument() throws {
        let secret = try secret("hunter2", newline: true)
        var options = Archiving.Options()
        options.zipEncryption = .aes256
        let zip = Archiving.encryptedZipInvocation([root], output: root.appendingPathComponent("a.zip"),
                                                   options: options, password: secret.url)
        XCTAssertEqual(zip.input, secret.url)
        XCTAssertFalse(zip.arguments.contains { $0.contains("hunter2") })
        let aea = Archiving.appleEncryptInvocation(output: root.appendingPathComponent("a.aea"),
                                                   compression: .lzfse, password: secret.url)
        XCTAssertFalse(aea.arguments.contains { $0.contains("hunter2") })
        XCTAssertTrue(aea.arguments.contains(secret.url.path))
    }

    func testThePasswordFileIsTheUsersAloneAndGoesAway() throws {
        let secret = try secret("hunter2", newline: true)
        var info = stat()
        XCTAssertEqual(stat(secret.url.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(stat(secret.url.deletingLastPathComponent().path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertEqual(text(secret.url), "hunter2\n")
        secret.remove()
        XCTAssertFalse(fm.fileExists(atPath: secret.url.deletingLastPathComponent().path))
    }

    func testTheRestoreScriptReadsThePasswordFromItsFile() throws {
        let password = URL(fileURLWithPath: "/private/tmp/key/p")
        let placement = Archiving.Placement(wrapper: nil, moves: [("photos", root.appendingPathComponent("photos"))])
        let zip = Archiving.restoreScript(archive: root.appendingPathComponent("p.zip"), sha256: "ab",
                                          kind: .zip, differences: [], placement: placement,
                                          destination: root, quarantine: nil, password: password)
        XCTAssertTrue(zip.contains("/usr/bin/tar '-x' '-p' '-v' '-f' \"$R\"'/archive' '-C' \"$R\"'/x' "
                                   + "< '/private/tmp/key/p'"), zip)
        let aea = Archiving.restoreScript(archive: root.appendingPathComponent("p.aea"), sha256: "ab",
                                          kind: .appleEncrypted, differences: [], placement: placement,
                                          destination: root, quarantine: nil, password: password)
        XCTAssertTrue(aea.contains("/usr/bin/aea decrypt -i \"$R/archive\" -password '/private/tmp/key/p' | "
                                   + "/usr/bin/aa extract -d \"$R/x\""), aea)
        XCTAssertTrue(aea.contains("set -o pipefail"))
    }

    // MARK: - Progress

    func testUnpackingATarCountsTheBytesRead() throws {
        var options = Archiving.Options()
        options.format = .tar
        let tar = create([try makeFolder()], options, password: nil, named: "p.tar.gz")
        let job = Archiving.Job()
        let out = root.appendingPathComponent("tar-out")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        do { try Archiving.unpack(tar, kind: .tar, into: out, job: job) }
        catch { return XCTFail(error.message) }
        let snapshot = job.snapshot()
        let size = try XCTUnwrap(try fm.attributesOfItem(atPath: tar.path)[.size] as? Int64)
        XCTAssertEqual(snapshot.totalBytes, size)
        XCTAssertEqual(snapshot.bytes, size)
        XCTAssertEqual(text(out.appendingPathComponent("photos/a.txt")), "hello")
    }

    func testUnpackingAZipCountsWhatDittoSays() throws {
        let zip = create([try makeFolder()], Archiving.Options(), password: nil, named: "c.zip")
        let entries: [Archiving.Entry]
        do { entries = try Archiving.entries(of: zip, kind: .zip) } catch { return XCTFail(error.message) }
        XCTAssertEqual(entries.compactMap(\.size).reduce(0, +), 10)
        let job = Archiving.Job()
        let out = root.appendingPathComponent("zip-out")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        do { try Archiving.unpack(zip, kind: .zip, into: out, entries: entries, job: job) }
        catch { return XCTFail(error.message) }
        let snapshot = job.snapshot()
        XCTAssertEqual(snapshot.totalBytes, 10)
        XCTAssertGreaterThanOrEqual(snapshot.bytes, 10)
    }
}
