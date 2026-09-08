import Foundation
import AppKit

/// Escalated file operations.
///
/// Only root may give a file away to another user -- a plain chown fails with
/// EPERM for everyone else, which is why changing an owner needs this path at
/// all. Changing the *group* does not: any group you belong to works directly.
@MainActor
enum Privileged {

    /// What came of an escalated operation. Cancelling is not success: reporting
    /// it as such told the user the owner had changed when nothing had.
    enum Result: Equatable {
        case succeeded
        case cancelled
        case failed(String)
    }

    /// Runs chown after the system's own authentication prompt.
    ///
    /// `group` is carried through as `owner:group`, because the fallback exists
    /// precisely when a combined owner-and-group change was refused -- dropping
    /// the group here would apply half of what was asked for and report all of
    /// it as done.
    static func chown(owner: String, group: String?, urls: [URL]) -> Result {
        guard !urls.isEmpty else { return .succeeded }

        let specification = group.map { "\(owner):\($0)" } ?? owner
        let arguments = ([specification] + urls.map(\.path))
            .map(Shell.quoted)
            .joined(separator: " ")
        let command = "/usr/sbin/chown -- " + arguments

        var error: NSDictionary?
        let script = "do shell script \"\(appleScriptQuoted(command))\" with administrator privileges"
        NSAppleScript(source: script)?.executeAndReturnError(&error)

        guard let error else { return .succeeded }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
        return .failed(error[NSAppleScript.errorMessage] as? String ?? "Authentication failed.")
    }

    /// ...and then escaped again to sit inside an AppleScript string literal.
    /// Backslashes first, or the escaping escapes its own escapes.
    private static func appleScriptQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
