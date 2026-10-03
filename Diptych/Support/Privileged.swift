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

    /// Runs one command as root after the system's own authentication prompt.
    ///
    /// The prompt is itself the confirmation, so callers do not need to ask
    /// twice -- but they must only reach here for something the user asked for.
    static func run(_ command: String) -> Result {
        runCapturingOutput(command).result
    }

    /// `run`, keeping what the command printed -- for reading something only
    /// root may read, such as the system's provenance database.
    static func runCapturingOutput(_ command: String) -> (result: Result, output: String?) {
        var error: NSDictionary?
        let script = "do shell script \"\(appleScriptQuoted(command))\" with administrator privileges"
        let reply = NSAppleScript(source: script)?.executeAndReturnError(&error)

        guard let error else { return (.succeeded, reply?.stringValue) }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return (.cancelled, nil) }
        return (.failed(error[NSAppleScript.errorMessage] as? String ?? "Authentication failed."), nil)
    }

    /// Runs chown after the system's own authentication prompt.
    ///
    /// `group` is carried through as `owner:group`, because the fallback exists
    /// precisely when a combined owner-and-group change was refused -- dropping
    /// the group here would apply half of what was asked for and report all of
    /// it as done.
    static func chown(owner: String, group: String?, urls: [URL]) -> Result {
        chownMany([(owner: owner, group: group, urls: urls)])
    }

    /// Several owner/group changes -- each item possibly wanting a different
    /// owner or group -- in **one** authentication prompt.
    ///
    /// A batch of proposed operations can contain more than one that needs
    /// root, and asking separately for each would mean re-entering the
    /// password once per item. Every change becomes its own `chown` line in
    /// one shell script, so `run` still only ever shows the system's prompt
    /// once for the whole set.
    static func chownMany(_ changes: [(owner: String, group: String?, urls: [URL])]) -> Result {
        let commands = changes.filter { !$0.urls.isEmpty }.map { change -> String in
            let specification = change.group.map { "\(change.owner):\($0)" } ?? change.owner
            let arguments = ([specification] + change.urls.map(\.path))
                .map(Shell.quoted)
                .joined(separator: " ")
            return "/usr/sbin/chown -- " + arguments
        }
        guard !commands.isEmpty else { return .succeeded }
        // `;`, not a raw newline: this string becomes one AppleScript string
        // literal, and an embedded newline there is a parse error, not a
        // line break in the shell script it runs.
        return run(commands.joined(separator: "; "))
    }

    /// ...and then escaped again to sit inside an AppleScript string literal.
    /// Backslashes first, or the escaping escapes its own escapes.
    private static func appleScriptQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
