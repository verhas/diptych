import Darwin
import Foundation

/// The client side of the ssh-agent protocol: the agent holds the person's
/// keys, and asks it for the keys it has and for signatures, never for the
/// keys themselves. See the agent's PROTOCOL.agent in the OpenSSH sources.
///
/// Blocking: each call waits for the agent on its socket. Callers keep these
/// off the main thread and off any event loop that serves other connections.
nonisolated struct SSHAgent: Sendable {

    /// A key the agent holds: its public key in SSH wire form, and the comment
    /// it was added with, usually the file it came from.
    struct Identity: Equatable, Sendable {
        let blob: Data
        let comment: String
    }

    enum Problem: Error, Equatable, Sendable {
        /// No agent socket is named, so there is no agent to ask.
        case notRunning
        /// The socket is named, but nothing answers on it.
        case unreachable(String)
        /// The agent answered that it could not do what was asked.
        case refused
        /// The agent answered with something this client does not understand.
        case malformed
    }

    /// Signature flags for RSA keys: sign with SHA-2 rather than SHA-1, which
    /// current servers refuse.
    static let rsaSHA2256: UInt32 = 2
    static let rsaSHA2512: UInt32 = 4

    private enum Message {
        static let failure: UInt8 = 5
        static let requestIdentities: UInt8 = 11
        static let identitiesAnswer: UInt8 = 12
        static let signRequest: UInt8 = 13
        static let signResponse: UInt8 = 14
    }

    let socketPath: String

    /// The agent named by `SSH_AUTH_SOCK`, when the environment names one.
    static var fromEnvironment: SSHAgent? {
        guard let path = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], !path.isEmpty else {
            return nil
        }
        return SSHAgent(socketPath: path)
    }

    /// The agent the person is using: the one `SSH_AUTH_SOCK` names, or else
    /// the one launchd runs for the login. An app started from Finder does not
    /// inherit `SSH_AUTH_SOCK`, so launchd is asked for the socket it reports.
    static func discovered() -> SSHAgent? {
        if let agent = fromEnvironment { return agent }
        return fromLaunchd()
    }

    /// The discovered agent, when it holds keys: the one worth offering.
    static func usable() -> SSHAgent? {
        guard let agent = discovered(), (try? agent.identities())?.isEmpty == false else { return nil }
        return agent
    }

    /// The socket of the ssh-agent launchd runs for this user, as `launchctl
    /// print` reports it under the job's environment.
    private static func fromLaunchd() -> SSHAgent? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/com.openssh.ssh-agent"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        for line in text.split(separator: "\n") {
            let parts = line.components(separatedBy: " => ")
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "SSH_AUTH_SOCK" {
                return SSHAgent(socketPath: parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// The keys the agent holds, in the order it lists them.
    func identities() throws -> [Identity] {
        let answer = try exchange([Message.requestIdentities])
        var reader = WireReader(answer)
        guard try reader.byte() == Message.identitiesAnswer else { throw Problem.malformed }
        let count = try reader.uint32()
        var identities: [Identity] = []
        for _ in 0..<count {
            let blob = try reader.string()
            let comment = String(decoding: try reader.string(), as: UTF8.self)
            identities.append(Identity(blob: blob, comment: comment))
        }
        return identities
    }

    /// The signature the key `blob` makes of `data`, as an SSH signature blob:
    /// the algorithm's name, then the signature itself.
    func sign(_ data: Data, with blob: Data, flags: UInt32 = 0) throws -> Data {
        var request = WireWriter()
        request.byte(Message.signRequest)
        request.string(blob)
        request.string(data)
        request.uint32(flags)
        let answer = try exchange(request.bytes)
        var reader = WireReader(answer)
        guard try reader.byte() == Message.signResponse else { throw Problem.refused }
        return try reader.string()
    }

    // MARK: - Transport

    /// Sends one message to the agent and returns its answer, without the
    /// length that frames it. A failure answer is `Problem.refused`.
    private func exchange(_ message: [UInt8]) throws -> Data {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Problem.unreachable(String(cString: strerror(errno))) }
        defer { close(descriptor) }

        var address = sockaddr_un()
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw Problem.unreachable("the socket path is too long")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path + [0])
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(length)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, length)
            }
        }
        guard connected == 0 else { throw Problem.unreachable(String(cString: strerror(errno))) }

        var framed = WireWriter()
        framed.uint32(UInt32(message.count))
        framed.bytes += message
        try write(framed.bytes, to: descriptor)

        let header = try read(4, from: descriptor)
        let size = Int(WireReader(Data(header)).uint32Unchecked())
        guard size > 0, size < 1 << 20 else { throw Problem.malformed }
        let answer = try read(size, from: descriptor)
        if answer.first == Message.failure { throw Problem.refused }
        return Data(answer)
    }

    private func write(_ bytes: [UInt8], to descriptor: Int32) throws {
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { throw Problem.unreachable(String(cString: strerror(errno))) }
            sent += count
        }
    }

    private func read(_ count: Int, from descriptor: Int32) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let got = bytes.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress!.advanced(by: received), count - received)
            }
            guard got > 0 else { throw Problem.unreachable("the agent closed the connection") }
            received += got
        }
        return bytes
    }
}

/// Reads SSH wire values: big-endian integers and length-prefixed strings.
struct WireReader {
    private let bytes: [UInt8]
    private var position = 0

    init(_ data: Data) { bytes = Array(data) }

    mutating func byte() throws -> UInt8 {
        guard position < bytes.count else { throw SSHAgent.Problem.malformed }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func uint32() throws -> UInt32 {
        guard position + 4 <= bytes.count else { throw SSHAgent.Problem.malformed }
        defer { position += 4 }
        return uint32Unchecked(at: position)
    }

    mutating func string() throws -> Data {
        let count = Int(try uint32())
        guard position + count <= bytes.count else { throw SSHAgent.Problem.malformed }
        defer { position += count }
        return Data(bytes[position..<position + count])
    }

    /// What has not been read yet.
    var remainder: Data {
        Data(bytes[position...])
    }

    func uint32Unchecked() -> UInt32 {
        uint32Unchecked(at: 0)
    }

    private func uint32Unchecked(at offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// Writes SSH wire values.
struct WireWriter {
    var bytes: [UInt8] = []

    mutating func byte(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func uint32(_ value: UInt32) {
        bytes += [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    mutating func string(_ value: Data) {
        uint32(UInt32(value.count))
        bytes += value
    }
}
