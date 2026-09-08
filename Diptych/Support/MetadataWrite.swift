import Foundation
import AppKit

/// A metadata change that the file's own permissions may refuse.
///
/// `setxattr` on a file you are not allowed to write fails with EACCES, and a
/// file manager that only whispers that into a status line has, from where the
/// user sits, simply not done what it was asked. So every metadata change goes
/// through here, which
///
/// 1. always reports a refusal instead of letting it pass for a no-op,
/// 2. offers to lift the permission for the length of the change and put it
///    straight back -- done by the app rather than asked of the user, so the
///    window is a few milliseconds wide and nothing is left unlocked by
///    forgetfulness,
/// 3. and offers to do it as root when even the permission is not ours to
///    change.
///
/// The change is described twice: `apply` is the syscall we make in our own
/// process, `command` is the equivalent for the escalated path. Root needs no
/// bits raised at all -- it bypasses the check -- so escalation performs the
/// change directly rather than chmod-ing around it.
@MainActor
struct MetadataWrite {

    /// Completes "Diptych could not ..." -- e.g. "add the attribute “tint”".
    let action: String
    let url: URL
    let apply: () -> ExtendedAttributes.Failure?
    /// nil when the change has no root equivalent, which hides step 3.
    let command: String?

    enum Outcome {
        /// `warning` is set when the change went through but something around
        /// it did not -- above all a permission we raised and could not lower.
        case succeeded(warning: String?)
        case cancelled
        case failed(String)
    }

    // MARK: - Builders

    /// A set of extended-attribute changes applied as one.
    static func xattrs(_ writes: [XattrWrite], on url: URL, action: String) -> MetadataWrite {
        let path = url.path
        let parts = writes.compactMap { $0.command(for: path) }
        return MetadataWrite(
            action: action,
            url: url,
            apply: { writes.lazy.compactMap { $0.apply(to: path) }.first },
            // `&&` and not `;`: a half-applied tag change must not report as done.
            command: parts.isEmpty ? nil : parts.joined(separator: " && "))
    }

    static func acl(_ text: String, on url: URL, action: String) -> MetadataWrite {
        MetadataWrite(action: action,
                      url: url,
                      apply: { AccessControl.setText(text, on: url.path) },
                      command: AccessControl.command(setting: text, on: url.path))
    }

    // MARK: - Running it

    func perform() -> Outcome {
        guard let failure = apply() else { return .succeeded(warning: nil) }
        guard failure.isPermissionDenied else { return .failed(failure.message) }
        return recover(from: failure)
    }

    private enum Choice { case unlock, authenticate, cancel }

    private func recover(from failure: ExtendedAttributes.Failure) -> Outcome {
        // Only the owner may chmod, so offer the temporary unlock only when it
        // could actually work; otherwise the ladder starts at authentication.
        let unlockable = isOwner ? try? FileOperations.currentMode(of: url) : nil

        switch ask(canUnlock: unlockable != nil, reason: failure.message) {
        case .cancel:
            return .cancelled
        case .authenticate:
            return escalate()
        case .unlock:
            guard let mode = unlockable else { return .cancelled }
            let outcome = unlockedWrite(restoring: mode)
            // Unlocking is not always enough -- a read-only volume, an
            // immutable flag, or a protected path refuses either way. Offer the
            // last rung rather than ending on a failure the user cannot act on.
            if case .failed = outcome, command != nil,
               ask(canUnlock: false, reason: "Unlocking the file was not enough.") == .authenticate {
                return escalate()
            }
            return outcome
        }
    }

    /// Raise the owner write bit, make the change, put the mode back.
    ///
    /// Deliberately one straight line with no early exits: the restore must run
    /// on every path through this function, including the failing ones. Not
    /// private, because that guarantee is what the tests are for.
    func unlockedWrite(restoring mode: mode_t) -> Outcome {
        do {
            try setMode(mode | S_IWUSR)
        } catch {
            return .failed("The permissions could not be changed: \(error.localizedDescription)")
        }

        let failure = apply()

        var warning: String?
        do {
            try setMode(mode)
        } catch {
            warning = "\(url.lastPathComponent) has been left writable -- restoring "
                    + "\(FileOperations.rwxString(mode)) failed: \(error.localizedDescription)"
        }

        guard let failure else { return .succeeded(warning: warning) }
        return .failed([failure.message, warning].compactMap { $0 }.joined(separator: ". "))
    }

    private func escalate() -> Outcome {
        guard let command else { return .failed("There is no privileged equivalent of this change.") }
        switch Privileged.run(command) {
        case .succeeded:            return .succeeded(warning: nil)
        case .cancelled:            return .cancelled
        case .failed(let message):  return .failed(message)
        }
    }

    // MARK: - Asking

    private func ask(canUnlock: Bool, reason: String) -> Choice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Diptych could not \(action)."
        alert.informativeText = """
            \(url.lastPathComponent) does not allow it: \(reason).

            Diptych can make the item writable, apply the change and restore the \
            original permissions immediately afterwards, so it is unprotected \
            only for the moment the change takes.
            """

        var choices: [Choice] = []
        if canUnlock {
            alert.addButton(withTitle: "Unlock, Change, Restore")
            choices.append(.unlock)
        }
        if command != nil {
            alert.addButton(withTitle: "Authenticate\u{2026}")
            choices.append(.authenticate)
        }
        alert.addButton(withTitle: "Cancel")
        choices.append(.cancel)

        // Cancel is the safe default, so nothing happens on a stray Return.
        alert.buttons.last?.keyEquivalent = "\r"
        if choices.count > 1 { alert.buttons.first?.keyEquivalent = "" }

        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(index) ? choices[index] : .cancel
    }

    /// chmod is the owner's privilege; anyone else is refused before trying.
    private var isOwner: Bool {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return false }
        return info.st_uid == getuid() || getuid() == 0
    }

    private func setMode(_ mode: mode_t) throws {
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)],
                                              ofItemAtPath: url.path)
    }
}
