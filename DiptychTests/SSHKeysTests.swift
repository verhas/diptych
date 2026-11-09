import XCTest
import NIOSSH
@testable import Diptych

/// Signing in the way `ssh` does, against a real ssh-agent and a real sshd, both
/// started here with throwaway keys, so nothing of the person's is touched.
/// `useKeychain` stays off throughout: a test has no business in the Keychain.
final class SSHKeysTests: XCTestCase {

    private var directory: URL!
    private var processes: [Process] = []
    private var socket: String { directory.appendingPathComponent("a.sock").path }

    override func setUpWithError() throws {
        // A socket path is limited to about a hundred bytes.
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("dpt-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        processes.forEach { $0.terminate() }
        processes = []
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func newKey(_ name: String, passphrase: String = "") throws -> URL {
        let key = directory.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", "ed25519", "-N", passphrase, "-C", name, "-f", key.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return key
    }

    private func startAgent() throws -> SSHAgent {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        process.arguments = ["-D", "-a", socket]
        try process.run()
        processes.append(process)
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: socket) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return SSHAgent(socketPath: socket)
    }

    // MARK: - What ssh -G says

    func testTheSettingsAreReadAsSshPrintsThem() {
        let settings = SSHHostSettings.parse("""
            user bob
            identityfile ~/.ssh/first
            identityfile /keys/with a space
            identityfile %d/.ssh/third
            addkeystoagent true
            identitiesonly yes
            """, home: "/Users/bob")
        XCTAssertEqual(settings.identityFiles.map(\.path),
                       ["/Users/bob/.ssh/first", "/keys/with a space", "/Users/bob/.ssh/third"])
        XCTAssertTrue(settings.addKeysToAgent)
        XCTAssertTrue(settings.identitiesOnly)
    }

    func testOnlyAPlainYesAddsKeysToTheAgent() {
        for value in ["false", "ask", "confirm"] {
            XCTAssertFalse(SSHHostSettings.parse("addkeystoagent \(value)", home: "/").addKeysToAgent, value)
        }
    }

    func testSshItselfGivesTheSettings() {
        let settings = SSHHostSettings.resolve(host: "example.org", port: 22, username: "bob")
        XCTAssertFalse(settings.identityFiles.contains { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testTheNamedKeysAreOfferedFirstAsOpenSSHDoes() {
        let one = SSHAgent.Identity(blob: Data([1]), comment: "one")
        let two = SSHAgent.Identity(blob: Data([2]), comment: "two")
        var settings = SSHHostSettings(identityFiles: [], addKeysToAgent: false,
                                       identitiesOnly: false, useKeychain: false)
        XCTAssertEqual(settings.offerOrder([one, two], named: [Data([2])]), [two, one])
        settings.identitiesOnly = true
        XCTAssertEqual(settings.offerOrder([one, two], named: [Data([2])]), [two])
    }

    // MARK: - ssh-add

    func testAKeyWithoutAPassphraseIsAdded() throws {
        let agent = try startAgent()
        let key = try newKey("plain")
        XCTAssertFalse(agent.holds(key))
        XCTAssertEqual(agent.load(key, useKeychain: false), .added)
        XCTAssertTrue(agent.holds(key))
    }

    func testAnEncryptedKeyAsksThenRefusesTheWrongPassphraseThenLoads() throws {
        let agent = try startAgent()
        let key = try newKey("locked", passphrase: "right")
        XCTAssertEqual(agent.load(key, useKeychain: false), .needsPassphrase)
        XCTAssertEqual(agent.load(key, useKeychain: false, passphrase: "wrong"), .needsPassphrase)
        XCTAssertFalse(agent.holds(key))
        XCTAssertEqual(agent.load(key, useKeychain: false, passphrase: "right"), .added)
        XCTAssertTrue(agent.holds(key))
    }

    func testAMissingKeyIsAFailureNotAPassphraseQuestion() throws {
        let agent = try startAgent()
        guard case .failed = agent.load(directory.appendingPathComponent("absent"), useKeychain: false) else {
            return XCTFail("expected a failure")
        }
    }

    // MARK: - Against a server

    /// A private sshd on a free port, trusted in a list of its own.
    private func startServer(allowPassword: Bool, authorized: [URL]) throws -> (port: Int, keys: SFTPHostKeys) {
        let sshd = "/usr/sbin/sshd"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: sshd), "no sshd here")
        let hostKey = try newKey("host")
        let lines = try authorized.map { try String(contentsOfFile: $0.path + ".pub", encoding: .utf8) }
        let authorizedFile = directory.appendingPathComponent("authorized")
        try lines.joined().write(to: authorizedFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authorizedFile.path)

        let port = Int.random(in: 42000..<52000)
        let config = directory.appendingPathComponent("sshd_config")
        try """
            Port \(port)
            ListenAddress 127.0.0.1
            HostKey \(hostKey.path)
            AuthorizedKeysFile \(authorizedFile.path)
            PidFile \(directory.appendingPathComponent("sshd.pid").path)
            StrictModes no
            UsePAM no
            PasswordAuthentication \(allowPassword ? "yes" : "no")
            KbdInteractiveAuthentication no
            Subsystem sftp internal-sftp
            """.write(to: config, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshd)
        process.arguments = ["-D", "-e", "-f", config.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        processes.append(process)
        Thread.sleep(forTimeInterval: 0.5)
        try XCTSkipUnless(process.isRunning, "sshd would not start here")

        let keys = SFTPHostKeys(file: directory.appendingPathComponent("known"))
        let text = try String(contentsOfFile: hostKey.path + ".pub", encoding: .utf8)
        let line = text.split(separator: " ").prefix(2).joined(separator: " ")
        try keys.trust(try NIOSSHPublicKey(openSSHPublicKey: line),
                       for: SFTPHostKeys.filing(host: "127.0.0.1", port: port))
        return (port, keys)
    }

    func testAKeysOnlyServerSaysItTakesNoPassword() async throws {
        let server = try startServer(allowPassword: false, authorized: [])
        let methods = try await SFTPSession.offeredMethods(
            host: "127.0.0.1", port: server.port, username: NSUserName(), keys: server.keys)
        XCTAssertTrue(methods.contains(.publicKey))
        XCTAssertFalse(methods.contains(.password))
    }

    func testAServerThatTakesPasswordsSaysSo() async throws {
        let server = try startServer(allowPassword: true, authorized: [])
        let methods = try await SFTPSession.offeredMethods(
            host: "127.0.0.1", port: server.port, username: NSUserName(), keys: server.keys)
        XCTAssertTrue(methods.contains(.password))
    }

    func testAnUntrustedHostIsReportedWhenAsking() async throws {
        let server = try startServer(allowPassword: false, authorized: [])
        let strangers = SFTPHostKeys(file: directory.appendingPathComponent("empty"))
        do {
            _ = try await SFTPSession.offeredMethods(
                host: "127.0.0.1", port: server.port, username: NSUserName(), keys: strangers)
            XCTFail("expected the host key to be questioned")
        } catch {
            XCTAssertTrue(error is SFTPHostKeyProblem, "\(error)")
        }
    }

    func testNobodyListeningIsAConnectionError() async {
        do {
            _ = try await SFTPSession.offeredMethods(host: "127.0.0.1", port: 1, username: "x")
            XCTFail("expected a failure")
        } catch {
            XCTAssertFalse(error is SFTPHostKeyProblem, "\(error)")
        }
    }

    /// The key after the first in the agent: Citadel asks a login only once, so
    /// each key needs its own connection.
    func testEachAgentKeyCanSignInByItself() async throws {
        let agent = try startAgent()
        let wrong = try newKey("wrong")
        let right = try newKey("right")
        XCTAssertEqual(agent.load(wrong, useKeychain: false), .added)
        XCTAssertEqual(agent.load(right, useKeychain: false), .added)
        let server = try startServer(allowPassword: false, authorized: [right])

        let identities = try agent.identities()
        XCTAssertEqual(identities.map(\.comment), ["wrong", "right"])

        do {
            let refused = try await SFTPSession.connect(
                host: "127.0.0.1", port: server.port, username: NSUserName(),
                login: .agent(agent, identities[0]), keys: server.keys)
            await refused.close()
            XCTFail("the wrong key signed in")
        } catch {}

        let session = try await SFTPSession.connect(
            host: "127.0.0.1", port: server.port, username: NSUserName(),
            login: .agent(agent, identities[1]), keys: server.keys)
        await session.close()
    }
}
