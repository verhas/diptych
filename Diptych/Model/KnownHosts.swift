import CryptoKit
import Foundation
import NIOSSH

/// What `~/.ssh/known_hosts` says about a server, so the trust dialog can tell
/// the person whether OpenSSH already trusts it.
///
/// Read only. Diptych never writes this file: it belongs to OpenSSH, and a
/// host trusted here is trusted by Diptych alone.
nonisolated enum KnownHosts {

    enum Standing: Equatable, Sendable {
        /// The file keeps this very key for the host.
        case trusted
        /// The file keeps other keys for the host, and not this one.
        case differs
        /// The file has nothing for the host.
        case absent
    }

    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts")
    }

    /// Where `key` stands in the file for `host` on `port`.
    static func standing(host: String, port: Int, key: NIOSSHPublicKey,
                         file: URL = file) -> Standing {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return .absent }
        let name = (port == 22 ? host : "[\(host)]:\(port)").lowercased()
        var matched = false
        for line in text.split(separator: "\n") {
            guard let entry = Entry(line: String(line)), entry.covers(name) else { continue }
            matched = true
            if entry.key == key { return .trusted }
        }
        return matched ? .differs : .absent
    }

    /// The SHA-256 fingerprint OpenSSH prints for a key, as `ssh-keygen -lf`
    /// does: `SHA256:` and the digest in base64, without its padding.
    static func fingerprint(of key: NIOSSHPublicKey) -> String {
        let fields = String(openSSHPublicKey: key).split(separator: " ")
        guard fields.count == 2, let blob = Data(base64Encoded: String(fields[1])) else { return "" }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    /// One line of the file: which hosts it is for, and the key it keeps.
    private struct Entry {
        /// Patterns, comma-separated in the file, or one hashed name.
        let hosts: [String]
        let key: NIOSSHPublicKey

        /// Marker lines (`@revoked`, `@cert-authority`) are skipped: a
        /// revoked key is not trusted, and a CA is not a host.
        init?(line: String) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, !fields[0].hasPrefix("@") else { return nil }
            // Names are case-blind, but a hashed name is base64 and must keep its case.
            hosts = fields[0].split(separator: ",").map {
                $0.hasPrefix("|") ? String($0) : $0.lowercased()
            }
            guard let key = try? NIOSSHPublicKey(openSSHPublicKey: "\(fields[1]) \(fields[2])")
            else { return nil }
            self.key = key
        }

        func covers(_ name: String) -> Bool {
            if hosts.count == 1, hosts[0].hasPrefix("|1|") {
                return hashedCovers(name)
            }
            var covered = false
            for pattern in hosts {
                if pattern.hasPrefix("!") {
                    // A negated pattern wins over any positive one, as in OpenSSH.
                    if Self.matches(String(pattern.dropFirst()), name) { return false }
                } else if Self.matches(pattern, name) {
                    covered = true
                }
            }
            return covered
        }

        /// OpenSSH's own rule: `*` is any run of characters and `?` any one.
        /// Everything else stands for itself, brackets included -- `fnmatch`
        /// would read `[nas]:2222` as a character class and never match it.
        private static func matches(_ pattern: String, _ name: String) -> Bool {
            matches(Array(pattern)[...], Array(name)[...])
        }

        private static func matches(_ pattern: ArraySlice<Character>,
                                    _ name: ArraySlice<Character>) -> Bool {
            guard let first = pattern.first else { return name.isEmpty }
            if first == "*" {
                var rest = name
                while true {
                    if matches(pattern.dropFirst(), rest) { return true }
                    if rest.isEmpty { return false }
                    rest = rest.dropFirst()
                }
            }
            guard let character = name.first else { return false }
            return (first == "?" || first == character)
                && matches(pattern.dropFirst(), name.dropFirst())
        }

        /// `|1|salt|hash`: the hash is HMAC-SHA1 of the name, keyed by the salt.
        private func hashedCovers(_ name: String) -> Bool {
            let parts = hosts[0].split(separator: "|")
            guard parts.count == 3,
                  let salt = Data(base64Encoded: String(parts[1])),
                  let hash = Data(base64Encoded: String(parts[2])) else { return false }
            let code = HMAC<Insecure.SHA1>.authenticationCode(
                for: Data(name.utf8), using: SymmetricKey(data: salt))
            return Data(code) == hash
        }
    }
}
