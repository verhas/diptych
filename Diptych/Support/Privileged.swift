import Foundation
import AppKit

/// Escalated file operations.
///
/// Only root may give a file away to another user -- a plain chown fails with
/// EPERM for everyone else, which is why changing an owner needs this path at
/// all. Changing the *group* does not: any group you belong to works directly.
@MainActor
enum Privileged {

    /// Runs chown after the system's own authentication prompt.
    /// Returns nil on success, or a message describing the failure.
    static func chown(owner: String, urls: [URL]) -> String? {
        guard !urls.isEmpty else { return nil }

        let arguments = ([owner] + urls.map(\.path)).map(Shell.quoted).joined(separator: " ")
        let command = "/usr/sbin/chown -- " + arguments

        var error: NSDictionary?
        let script = "do shell script \"\(appleScriptQuoted(command))\" with administrator privileges"
        NSAppleScript(source: script)?.executeAndReturnError(&error)

        guard let error else { return nil }
        // -128 is the user cancelling the password prompt, which is not a fault.
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return nil }
        return error[NSAppleScript.errorMessage] as? String ?? "Authentication failed."
    }

    /// ...and then escaped again to sit inside an AppleScript string literal.
    /// Backslashes first, or the escaping escapes its own escapes.
    private static func appleScriptQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
