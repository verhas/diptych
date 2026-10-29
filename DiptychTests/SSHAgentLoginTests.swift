import XCTest
import NIOCore
@preconcurrency import NIOSSH
@testable import Diptych

/// The bytes an agent key puts on the wire, checked without a server: the
/// name NIOSSH writes is the algorithm's, and the signature is length-prefixed.
final class SSHAgentLoginTests: XCTestCase {

    /// A blob as an agent lists it: the key's name, then its numbers.
    private func rsaBlob(_ numbers: [UInt8]) -> Data {
        var writer = WireWriter()
        writer.string(Data("ssh-rsa".utf8))
        writer.string(Data(numbers))
        return Data(writer.bytes)
    }

    func testTheKeyBodyIsWrittenWithoutTheAgentsName() {
        let blob = rsaBlob([1, 2, 3])
        var buffer = ByteBufferAllocator().buffer(capacity: 16)
        _ = AgentPublicKey<AgentRSASHA256>(blob: blob).write(to: &buffer)
        // Just the body: the one string of numbers, with its length.
        XCTAssertEqual(Array(buffer.readableBytesView), [0, 0, 0, 3, 1, 2, 3])
        XCTAssertEqual(AgentPublicKey<AgentRSASHA256>.publicKeyPrefix, "rsa-sha2-256")
    }

    func testTheSignatureIsItsRawBytesWithALength() {
        var buffer = ByteBufferAllocator().buffer(capacity: 16)
        _ = AgentSignature<AgentRSASHA256>(rawRepresentation: Data([9, 8])).write(to: &buffer)
        XCTAssertEqual(Array(buffer.readableBytesView), [0, 0, 0, 2, 9, 8])
        XCTAssertEqual(AgentSignature<AgentRSASHA256>.signaturePrefix, "rsa-sha2-256")
    }

    func testOnlyKindsDiptychCanSignWithAreOffered() {
        let agent = SSHAgent(socketPath: "/nonexistent")
        let dsa = Data([0, 0, 0, 7] + Array("ssh-dss".utf8) + [0, 0, 0, 0])
        let login = SSHAgentLogin(username: "peter", identities: [
            SSHAgent.Identity(blob: dsa, comment: "old"),
            SSHAgent.Identity(blob: rsaBlob([1]), comment: "rsa"),
        ], agent: agent)
        XCTAssertEqual(login.count, 1)
    }
}
