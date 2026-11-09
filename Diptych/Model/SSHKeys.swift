import Foundation

/// What OpenSSH would use to sign in to a host, as `ssh -G` resolves it from
/// the configuration. Asking `ssh` means its own rules apply, `Include` and
/// `Match` among them.
nonisolated struct SSHHostSettings: Equatable, Sendable {

    /// The private keys `IdentityFile` names, in the order OpenSSH tries them.
    var identityFiles: [URL]
    var addKeysToAgent: Bool
    /// Only the keys `IdentityFile` names are offered, not others in the agent.
    var identitiesOnly: Bool
    /// `UseKeychain`: Apple's addition, which `ssh -G` does not print.
    var useKeychain: Bool

    /// The settings for one connection. When `ssh` cannot say, the usual key
    /// files are still tried.
    static func resolve(host: String, port: Int, username: String) -> SSHHostSettings {
        let arguments = ["-G", "-l", username, "-p", String(port), "--", host]
        var settings = output(of: "/usr/bin/ssh", arguments).map { parse($0, home: NSHomeDirectory()) }
            ?? SSHHostSettings(identityFiles: SFTPLogin.keyFilesInSSHFolder, addKeysToAgent: false,
                               identitiesOnly: false, useKeychain: false)
        settings.identityFiles = settings.identityFiles.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        settings.useKeychain = SSHConfig.value(of: "UseKeychain", for: host)?.lowercased() == "yes"
        return settings
    }

    /// Reads what `ssh -G` prints: one `keyword value` a line. `ask` and
    /// `confirm` for AddKeysToAgent need a question Diptych cannot have the
    /// agent put, so only a plain yes counts.
    static func parse(_ text: String, home: String) -> SSHHostSettings {
        var settings = SSHHostSettings(identityFiles: [], addKeysToAgent: false,
                                       identitiesOnly: false, useKeychain: false)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "identityfile":
                settings.identityFiles.append(URL(fileURLWithPath: expand(parts[1], home: home)))
            case "addkeystoagent":
                settings.addKeysToAgent = ["true", "yes"].contains(parts[1].lowercased())
            case "identitiesonly":
                settings.identitiesOnly = ["true", "yes"].contains(parts[1].lowercased())
            default:
                break
            }
        }
        return settings
    }

    private static func expand(_ path: String, home: String) -> String {
        if path.hasPrefix("~/") { return home + path.dropFirst() }
        if path.hasPrefix("%d/") { return home + path.dropFirst(2) }
        return path
    }

    /// The agent's keys in the order OpenSSH offers them: those `IdentityFile`
    /// names first, then the others unless `IdentitiesOnly` says not to.
    /// `named` holds the public halves of the identity files.
    func offerOrder(_ identities: [SSHAgent.Identity], named: [Data]) -> [SSHAgent.Identity] {
        let first = named.compactMap { blob in identities.first { $0.blob == blob } }
        if identitiesOnly { return first }
        return first + identities.filter { !named.contains($0.blob) }
    }

    /// What a tool printed, when it succeeded.
    private static func output(of tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

/// What came of asking `ssh-add` to put a key in the agent.
nonisolated enum SSHKeyLoad: Equatable, Sendable {
    case added
    /// The key wants a passphrase: none was at hand, or the one given was wrong.
    case needsPassphrase
    case failed(String)
}

extension SSHAgent {

    /// The public half of a private key file, from the `.pub` beside it, in
    /// the wire form the agent lists.
    static func publicBlob(of key: URL) -> Data? {
        guard let text = try? String(contentsOfFile: key.path + ".pub", encoding: .utf8) else { return nil }
        let fields = text.split(whereSeparator: \.isWhitespace)
        return fields.count >= 2 ? Data(base64Encoded: String(fields[1])) : nil
    }

    /// Whether the agent already holds the key in this file.
    func holds(_ key: URL) -> Bool {
        guard let blob = Self.publicBlob(of: key), let identities = try? identities() else { return false }
        return identities.contains { $0.blob == blob }
    }

    /// Adds a key file to this agent with `ssh-add`, as `ssh` does for
    /// `AddKeysToAgent`. With `useKeychain` it takes a saved passphrase from
    /// the Keychain, and saves one given here that works.
    ///
    /// There is no terminal to ask on, so `ssh-add` is sent to an askpass
    /// program that only repeats its own input, which is `ssh-add`'s input,
    /// inherited. The passphrase goes down that pipe, never onto a command line
    /// or into the environment; with none given, the empty answer makes
    /// `ssh-add` give up at once. Blocking.
    func load(_ key: URL, useKeychain: Bool, passphrase: String? = nil) -> SSHKeyLoad {
        let askpass = FileManager.default.temporaryDirectory
            .appendingPathComponent("diptych-askpass-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: askpass) }
        do {
            try "#!/bin/sh\nexec /bin/cat\n".write(to: askpass, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
        } catch {
            return .failed(error.localizedDescription)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        process.arguments = (useKeychain ? ["--apple-use-keychain"] : []) + [key.path]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "SSH_AUTH_SOCK": socketPath,
            "SSH_ASKPASS": askpass.path,
            "SSH_ASKPASS_REQUIRE": "force",
        ]) { $1 }
        let input = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return .failed(error.localizedDescription)
        }
        if let passphrase {
            try? input.fileHandleForWriting.write(contentsOf: Data((passphrase + "\n").utf8))
        }
        try? input.fileHandleForWriting.close()
        let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()

        if process.terminationStatus == 0 { return .added }
        // It says why for anything but a passphrase it did not get.
        return said.isEmpty ? .needsPassphrase : .failed(said)
    }
}
