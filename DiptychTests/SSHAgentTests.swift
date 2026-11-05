import XCTest
import Crypto
@testable import Diptych

/// The agent client against a real ssh-agent: a temporary one, started here
/// with a throwaway key, so no key of the person's is touched.
final class SSHAgentTests: XCTestCase {

    private var directory: URL!
    private var agent: Process?
    /// A socket path is limited to about a hundred bytes, which the long
    /// temporary folder paths exceed, so the socket lives in a short folder.
    private var socket: String { directory.appendingPathComponent("a.sock").path }

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("dpt-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        agent?.terminate()
        agent = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// Runs a command, failing the test if it does not succeed.
    @discardableResult
    private func run(_ tool: String, _ arguments: [String], environment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, text)
        return text
    }

    /// A temporary agent holding one new ed25519 key, with no passphrase.
    private func startAgentWithKey() throws -> URL {
        let key = directory.appendingPathComponent("k")
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "diptych-test", "-f", key.path])
        agent = Process()
        agent?.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        agent?.arguments = ["-D", "-a", socket]
        try agent?.run()
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: socket) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        try run("/usr/bin/ssh-add", [key.path], environment: ["SSH_AUTH_SOCK": socket])
        return key
    }

    func testTheAgentListsItsKeysWithTheirComments() throws {
        _ = try startAgentWithKey()
        let identities = try SSHAgent(socketPath: socket).identities()
        XCTAssertEqual(identities.map(\.comment), ["diptych-test"])
    }

    func testAgentSignsWhatItIsAskedAndTheSignatureVerifies() throws {
        _ = try startAgentWithKey()
        let agent = SSHAgent(socketPath: socket)
        let identity = try XCTUnwrap(try agent.identities().first)
        let message = Data("the session identifier".utf8)

        let signature = try agent.sign(message, with: identity.blob)

        // The public key is "ssh-ed25519" then the 32 key bytes; the signature
        // is "ssh-ed25519" then the 64 signature bytes.
        var key = WireReader(identity.blob)
        XCTAssertEqual(String(decoding: try key.string(), as: UTF8.self), "ssh-ed25519")
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: try key.string())

        var reader = WireReader(signature)
        XCTAssertEqual(String(decoding: try reader.string(), as: UTF8.self), "ssh-ed25519")
        XCTAssertTrue(publicKey.isValidSignature(try reader.string(), for: message))
    }

    func testAnAgentThatIsNotThereIsReportedAsSuch() {
        let agent = SSHAgent(socketPath: directory.appendingPathComponent("absent.sock").path)
        XCTAssertThrowsError(try agent.identities()) { error in
            guard case SSHAgent.Problem.unreachable = error else {
                return XCTFail("\(error)")
            }
        }
    }
}
