import Citadel
import Foundation
import NIOCore
@preconcurrency import NIOSSH

// Signing in with the keys an ssh-agent holds. The private keys stay in the
// agent: NIOSSH asks for each signature, and the signature is the agent's.

/// What an agent key signs with: the algorithm named in the login request,
/// and the flags that ask the agent for it.
protocol AgentAlgorithm {
    /// The algorithm's name on the wire: what the login request says.
    static var name: String { get }
    /// The agent's flags for a signature with this algorithm.
    static var flags: UInt32 { get }
    /// The name at the start of the key's blob the agent lists.
    static var blobName: String { get }
}

/// RSA signed with SHA-2 (RFC 8332). Current servers refuse the SHA-1 form.
enum AgentRSASHA256: AgentAlgorithm {
    static let name = "rsa-sha2-256"
    static let flags = SSHAgent.rsaSHA2256
    static let blobName = "ssh-rsa"
}

enum AgentEd25519: AgentAlgorithm {
    static let name = "ssh-ed25519"
    static let flags: UInt32 = 0
    static let blobName = "ssh-ed25519"
}

/// The public half of an agent key, as the login sends it. NIOSSH writes the
/// algorithm's name in front of whatever `write` produces, so this writes the
/// agent's blob without its own leading name: the name is the algorithm's.
struct AgentPublicKey<Algorithm: AgentAlgorithm>: NIOSSHPublicKeyProtocol {

    /// The agent's blob: the key's name, then its numbers.
    let blob: Data

    static var publicKeyPrefix: String { Algorithm.name }

    var rawRepresentation: Data { blob }

    /// The blob after its leading name, which is what NIOSSH does not write.
    private var body: Data {
        var reader = WireReader(blob)
        _ = try? reader.string()
        return reader.remainder
    }

    /// Only signatures are asked of the agent, so a signature is never checked
    /// here. Nothing in the login asks.
    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        false
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeBytes(body)
    }

    static func read(from buffer: inout ByteBuffer) throws -> AgentPublicKey<Algorithm> {
        throw SSHAgent.Problem.malformed
    }
}

/// A signature the agent made: its raw bytes, written as the SSH signature
/// blob expects, after the algorithm's name.
struct AgentSignature<Algorithm: AgentAlgorithm>: NIOSSHSignatureProtocol {

    let rawRepresentation: Data

    static var signaturePrefix: String { Algorithm.name }

    func write(to buffer: inout ByteBuffer) -> Int {
        var written = buffer.writeInteger(UInt32(rawRepresentation.count))
        written += buffer.writeBytes(rawRepresentation)
        return written
    }

    static func read(from buffer: inout ByteBuffer) throws -> AgentSignature<Algorithm> {
        throw SSHAgent.Problem.malformed
    }
}

/// A key the agent holds, as NIOSSH uses a private key: its public half is
/// the agent's blob, and each signature is asked of the agent.
struct AgentPrivateKey<Algorithm: AgentAlgorithm>: NIOSSHPrivateKeyProtocol {

    let agent: SSHAgent
    let blob: Data

    static var keyPrefix: String { Algorithm.name }

    var publicKey: NIOSSHPublicKeyProtocol {
        AgentPublicKey<Algorithm>(blob: blob)
    }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        let answer = try agent.sign(Data(data), with: blob, flags: Algorithm.flags)
        var reader = WireReader(answer)
        guard String(decoding: try reader.string(), as: UTF8.self) == Algorithm.name else {
            throw SSHAgent.Problem.malformed
        }
        return AgentSignature<Algorithm>(rawRepresentation: try reader.string())
    }
}

/// Offers the agent's keys to the server one at a time, in the order the
/// agent lists them. Keys of kinds Diptych cannot sign with are skipped.
final class SSHAgentLogin: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {

    private let username: String
    private let offers: [NIOSSHPrivateKey]
    private var next = 0

    init(username: String, identities: [SSHAgent.Identity], agent: SSHAgent) {
        self.username = username
        self.offers = identities.compactMap { identity in
            let kind = WireKind.of(identity.blob)
            switch kind {
            case AgentRSASHA256.blobName:
                return NIOSSHPrivateKey(custom: AgentPrivateKey<AgentRSASHA256>(agent: agent, blob: identity.blob))
            case AgentEd25519.blobName:
                return NIOSSHPrivateKey(custom: AgentPrivateKey<AgentEd25519>(agent: agent, blob: identity.blob))
            default:
                return nil
            }
        }
    }

    /// How many keys the agent offered that Diptych can use.
    var count: Int { offers.count }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard availableMethods.contains(.publicKey), next < offers.count else {
            nextChallengePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
            return
        }
        let key = offers[next]
        next += 1
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username, serviceName: "ssh-connection",
            offer: .privateKey(.init(privateKey: key))))
    }
}

/// The algorithm a key blob names: its first string.
enum WireKind {
    static func of(_ blob: Data) -> String? {
        var reader = WireReader(blob)
        return try? String(decoding: reader.string(), as: UTF8.self)
    }
}
