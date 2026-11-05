import Foundation

/// The pattern rule OpenSSH uses for host names, in `known_hosts` and in
/// `~/.ssh/config`: `*` is any run of characters, `?` any one, and everything
/// else stands for itself, brackets included.
nonisolated enum HostPattern {

    static func matches(_ pattern: String, _ name: String) -> Bool {
        matches(Array(pattern)[...], Array(name)[...])
    }

    private static func matches(_ pattern: ArraySlice<Character>, _ name: ArraySlice<Character>) -> Bool {
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
        return (first == "?" || first == character) && matches(pattern.dropFirst(), name.dropFirst())
    }
}

/// What `~/.ssh/config` says for a host, as OpenSSH reads it: the first value
/// obtained for an option wins, and every `Host` block that matches the host
/// contributes. Read only. `Include` and `Match` are not followed yet.
nonisolated enum SSHConfig {

    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    /// `ServerAliveInterval` for `host`, in seconds; nil when the config does
    /// not set it for that host.
    static func serverAliveInterval(for host: String, file: URL = file) -> Int? {
        value(of: "serverAliveInterval", for: host, file: file).flatMap { Int($0) }
    }

    /// The first value of an option that applies to `host`.
    static func value(of keyword: String, for host: String, file: URL = file) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var applies = true   // Options before any Host line apply to every host.
        for raw in text.components(separatedBy: .newlines) {
            guard let (key, value) = split(raw) else { continue }
            switch key.lowercased() {
            case "host":
                applies = matchesHostLine(value, host)
            case "match":
                applies = false
            default:
                if applies, key.lowercased() == keyword.lowercased() { return value }
            }
        }
        return nil
    }

    /// A line's keyword and value: `Key value`, `Key=value` or `Key = value`,
    /// with comments and blank lines skipped.
    private static func split(_ line: String) -> (String, String)? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
        if let hash = trimmed.firstIndex(of: "#"), trimmed[..<hash].last == " " || trimmed[..<hash].last == "\t" {
            trimmed = String(trimmed[..<hash]).trimmingCharacters(in: .whitespaces)
        }
        let separator = trimmed.firstIndex { $0 == " " || $0 == "\t" || $0 == "=" }
        guard let separator else { return nil }
        let key = String(trimmed[..<separator])
        var rest = trimmed[separator...].drop { $0 == " " || $0 == "\t" || $0 == "=" }
        if rest.first == "\"", rest.last == "\"", rest.count >= 2 {
            rest = rest.dropFirst().dropLast()
        }
        return (key, String(rest))
    }

    /// Whether a `Host` line's patterns match `host`: any positive pattern,
    /// and no negated one.
    private static func matchesHostLine(_ patterns: String, _ host: String) -> Bool {
        var matched = false
        for pattern in patterns.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            if pattern.hasPrefix("!") {
                if HostPattern.matches(String(pattern.dropFirst()), host) { return false }
            } else if HostPattern.matches(String(pattern), host) {
                matched = true
            }
        }
        return matched
    }
}
