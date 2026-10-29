import Citadel
import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

// SFTP: a file server reached over SSH and browsed without mounting it.
//
// macOS cannot mount SFTP by itself, so Diptych talks to the server through
// Citadel. The panes do not use this yet; it is the connection they will be
// given.

// MARK: - Host keys

/// The host keys Diptych trusts, one line each: the host as it is filed,
/// a space, then the key in OpenSSH's form. Kept apart from ~/.ssh/known_hosts,
/// which belongs to OpenSSH and is not Diptych's to write.
nonisolated struct SFTPHostKeys: Sendable {

    let file: URL

    static let standard = SFTPHostKeys(
        file: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".diptych/sftp_known_hosts"))

    /// How a host is filed: `nas`, or `[nas]:2222` off the default port.
    static func filing(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    /// The key kept for `filing`, if there is one.
    func key(for filing: String) -> NIOSSHPublicKey? {
        for line in lines() {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0] == filing else { continue }
            return try? NIOSSHPublicKey(openSSHPublicKey: String(parts[1]))
        }
        return nil
    }

    /// Keeps `key` for `filing`, in place of any key kept for it before.
    func trust(_ key: NIOSSHPublicKey, for filing: String) throws {
        var kept = lines().filter { !$0.isEmpty && !$0.hasPrefix("\(filing) ") }
        kept.append("\(filing) \(String(openSSHPublicKey: key))")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (kept.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// The lines kept for `filing`, numbered as an editor numbers them, and
    /// each one shortened so that it can be read in a dialog.
    func entries(for filing: String) -> [(line: Int, text: String)] {
        lines().enumerated()
            .filter { $0.element.hasPrefix("\(filing) ") }
            .map { (line: $0.offset + 1, text: Self.abstract($0.element)) }
    }

    /// The first and last few characters of a line: enough to recognise it.
    static func abstract(_ line: String) -> String {
        guard line.count > 60 else { return line }
        return String(line.prefix(40)) + "\u{2026}" + String(line.suffix(12))
    }

    /// Every line, blank ones included, so that the numbers are the editor's.
    private func lines() -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n")
    }
}

/// The server presented a host key Diptych does not trust for that host.
nonisolated enum SFTPHostKeyProblem: Error, Equatable, Sendable {
    /// Nothing is kept for the host yet. `presented` is its key, to confirm.
    case unknown(filing: String, presented: String)
    /// A different key is kept. A changed key is also what an impostor
    /// presents, so it is refused, not offered.
    case changed(filing: String, presented: String)
}

/// Accepts only the key already kept for the host, and records what it was
/// shown so the caller can say why the connection was refused.
///
/// A key Diptych has never seen is refused rather than trusted: whether to
/// trust a new host is the person's decision, and it is made in the UI.
final class SFTPHostKeyCheck: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private let filing: String
    private let keys: SFTPHostKeys
    private var refusal: SFTPHostKeyProblem?

    init(filing: String, keys: SFTPHostKeys) {
        self.filing = filing
        self.keys = keys
    }

    /// Why the last connection was refused, when it was refused for its key.
    var problem: SFTPHostKeyProblem? {
        lock.lock(); defer { lock.unlock() }
        return refusal
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if let kept = keys.key(for: filing), kept == hostKey {
            validationCompletePromise.succeed(())
            return
        }
        let presented = String(openSSHPublicKey: hostKey)
        let kept = keys.key(for: filing) != nil
        let problem: SFTPHostKeyProblem = kept
            ? .changed(filing: filing, presented: presented)
            : .unknown(filing: filing, presented: presented)
        lock.lock()
        refusal = problem
        lock.unlock()
        validationCompletePromise.fail(problem)
    }
}

// MARK: - Listings

/// One item in a remote folder, as the server describes it.
nonisolated struct SFTPEntry: Equatable, Sendable {

    enum Kind: Equatable, Sendable {
        case file, directory, symlink, other
    }

    let name: String
    let kind: Kind
    /// Zero when the server did not say.
    let size: UInt64
    /// The permission bits, without the type. Nil when the server did not say.
    let mode: UInt32?
    let modified: Date?
    /// The owner and group the server reports, as numbers.
    let uid: UInt32?
    let gid: UInt32?

    init(name: String, kind: Kind, size: UInt64 = 0, mode: UInt32? = nil,
         modified: Date? = nil, uid: UInt32? = nil, gid: UInt32? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.mode = mode
        self.modified = modified
        self.uid = uid
        self.gid = gid
    }

    init(_ component: SFTPPathComponent) {
        let attributes = component.attributes
        name = component.filename
        size = attributes.size ?? 0
        mode = attributes.permissions.map { $0 & 0o7777 }
        modified = attributes.accessModificationTime?.modificationTime
        uid = attributes.uidgid?.userId
        gid = attributes.uidgid?.groupId
        kind = Self.kind(ofPermissions: attributes.permissions)
    }

    /// The file-type bits of a Unix mode (`S_IFMT`).
    static func kind(ofPermissions permissions: UInt32?) -> Kind {
        switch (permissions ?? 0) & 0o170000 {
        case 0o040000: .directory
        case 0o100000: .file
        case 0o120000: .symlink
        default: .other
        }
    }
}

// MARK: - Session

/// How Diptych proves who the person is to a server.
nonisolated enum SFTPLogin: Sendable {
    case password(String)
    /// An OpenSSH private key file. Encrypted keys are refused: there is no
    /// passphrase prompt yet, so they are skipped like a missing key.
    case keyFile(URL)
    /// The keys an ssh-agent holds. The agent signs; no private key is read here.
    case agent(SSHAgent)

    /// The keys in `~/.ssh` that can be tried, in the order OpenSSH tries them.
    static var keyFilesInSSHFolder: [URL] {
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        return ["id_ed25519", "id_rsa"]
            .map { ssh.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func method(username: String) throws -> SSHAuthenticationMethod {
        switch self {
        case .password(let password):
            return .passwordBased(username: username, password: password)
        case .agent(let agent):
            let login = SSHAgentLogin(username: username, identities: try agent.identities(), agent: agent)
            guard login.count > 0 else { throw SFTPLoginError.noUsableAgentKeys }
            return .custom(login)
        case .keyFile(let file):
            let text = try String(contentsOf: file, encoding: .utf8)
            switch try SSHKeyDetection.detectPrivateKeyType(from: text) {
            case .ed25519:
                return .ed25519(username: username,
                                privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: text))
            case .rsa:
                return .rsa(username: username,
                            privateKey: try Insecure.RSA.PrivateKey(sshRsa: text))
            default:
                throw SFTPLoginError.unsupportedKey(file.lastPathComponent)
            }
        }
    }
}

nonisolated enum SFTPLoginError: Error, Equatable, Sendable {
    case unsupportedKey(String)
    /// The agent holds no key Diptych can sign with.
    case noUsableAgentKeys
}

/// A connected SFTP session, shared by whatever asks for a listing.
///
/// Every request goes through `SFTPClient`, which is `Sendable`. The
/// `SSHClient` is not, and is held only to keep the connection open and to
/// close it, so the session is marked `@unchecked Sendable` on that basis.
final class SFTPSession: @unchecked Sendable {

    private let ssh: SSHClient
    private let sftp: SFTPClient
    /// The thread the connection runs on. Its own, so that a signature the
    /// agent is slow to make stalls only this connection.
    private let group: MultiThreadedEventLoopGroup

    private init(ssh: SSHClient, sftp: SFTPClient, group: MultiThreadedEventLoopGroup) {
        self.ssh = ssh
        self.sftp = sftp
        self.group = group
    }

    /// Connects and signs in as `username`, and checks the host key against
    /// `keys` first.
    ///
    /// When the host key is refused, the error is `SFTPHostKeyProblem`, which
    /// says whether the host is new or its key has changed.
    static func connect(host: String, port: Int = 22, username: String, login: SFTPLogin,
                        keys: SFTPHostKeys = .standard) async throws -> SFTPSession {
        let check = SFTPHostKeyCheck(
            filing: SFTPHostKeys.filing(host: host, port: port), keys: keys)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let ssh: SSHClient
        do {
            ssh = try await SSHClient.connect(
                host: host, port: port,
                authenticationMethod: try login.method(username: username),
                hostKeyValidator: .custom(check),
                reconnect: .never,
                group: group)
        } catch {
            try? await group.shutdownGracefully()
            if let problem = check.problem { throw problem }
            throw error
        }
        do {
            return SFTPSession(ssh: ssh, sftp: try await ssh.openSFTP(), group: group)
        } catch {
            try? await ssh.close()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    /// The folder the server starts a session in, as an absolute path.
    func homeDirectory() async throws -> String {
        try await sftp.getRealPath(atPath: ".")
    }

    /// What is in `path`, without `.` and `..`.
    func list(_ path: String) async throws -> [SFTPEntry] {
        try await sftp.listDirectory(atPath: path)
            .flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." }
            .map(SFTPEntry.init)
    }

    func close() async {
        try? await sftp.close()
        try? await ssh.close()
        try? await group.shutdownGracefully()
    }
}

/// The server, as the mirror needs it: a folder's entries and a file's bytes.
/// `SFTPSession` is the real one; tests put a fake in its place.
nonisolated protocol RemoteListing: Sendable {
    func entries(in path: String) async throws -> [SFTPEntry]
    /// Writes the file's bytes to `destination`, which it creates.
    func download(_ path: String, to destination: URL) async throws
}

extension SFTPSession: RemoteListing {

    func entries(in path: String) async throws -> [SFTPEntry] {
        try await list(path)
    }

    /// Streams the file to `destination` a piece at a time, so a large one is
    /// never held in memory whole.
    func download(_ path: String, to destination: URL) async throws {
        let file = try await sftp.openFile(filePath: path, flags: .read)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        do {
            var offset: UInt64 = 0
            while true {
                let chunk = try await file.read(from: offset, length: 256 * 1024)
                guard chunk.readableBytes > 0 else { break }
                try output.write(contentsOf: Data(chunk.readableBytesView))
                offset += UInt64(chunk.readableBytes)
            }
        } catch {
            try? await file.close()
            throw error
        }
        try await file.close()
    }
}
