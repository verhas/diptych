import AppKit
import Foundation

/// A disk image laid out to be installed from: one application and a link to
/// /Applications beside it, the "drag this there" window of nearly every Mac
/// download. Opened in a pane, Diptych offers to do the dragging.
enum AppInstalling {

    /// What a mounted volume offers to install.
    struct Offer: Sendable, Equatable {
        /// The image the volume is of.
        let image: URL
        let volume: URL
        /// The application on the volume.
        let app: URL
        /// Where it goes.
        var destination: URL { applications.appendingPathComponent(app.lastPathComponent) }
        var name: String { app.deletingPathExtension().lastPathComponent }
    }

    static let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)

    /// The extended attribute macOS keeps on what came from the Internet.
    static let quarantine = "com.apple.quarantine"

    /// The volume's offer, when what is on it is exactly an application and a
    /// link to /Applications -- hidden files, the background picture and the
    /// volume icon aside.
    nonisolated static func offer(on volume: URL, image: URL) -> Offer? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: volume.path) else { return nil }
        let shown = names.filter { !$0.hasPrefix(".") && $0 != "Icon\r" }
        guard shown.count == 2 else { return nil }
        var app: URL?
        var link = false
        for name in shown {
            let url = volume.appendingPathComponent(name)
            if let target = try? fm.destinationOfSymbolicLink(atPath: url.path) {
                let standard = URL(fileURLWithPath: target).standardizedFileURL.path
                if standard == applications.path { link = true }
            } else if url.pathExtension.lowercased() == "app" {
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    app = url
                }
            }
        }
        guard link, let app else { return nil }
        return Offer(image: image, volume: volume, app: app)
    }

    nonisolated static func version(of app: URL) -> String? {
        guard let info = Bundle(url: app)?.infoDictionary else { return nil }
        let short = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?) where build != short: return "\(short) (\(build))"
        case let (short?, _): return short
        case let (nil, build?): return build
        default: return nil
        }
    }

    /// Whether the application at `url` is running now: replacing it under
    /// itself is refused.
    static func isRunning(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.standardizedFileURL.path == path
        }
    }

    // MARK: - The quarantine attribute

    /// The quarantine value with the mark of the user having approved it
    /// already: Gatekeeper then opens the app without asking "it was
    /// downloaded from the Internet, open it?", as it does after the first
    /// time it was answered. Where it came from -- the agent that downloaded
    /// it, when, and the record of the download -- stays as it was.
    ///
    /// The value is `flags;time;agent;id`, the flags in hex; 0x0040 is
    /// "approved by the user".
    nonisolated static func approved(_ value: String) -> String? {
        var fields = value.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let first = fields.first, let flags = UInt32(first, radix: 16) else { return nil }
        let marked = String(flags | 0x0040, radix: 16)
        fields[0] = String(repeating: "0", count: max(0, first.count - marked.count)) + marked
        return fields.joined(separator: ";")
    }

    /// The installed copy marked approved. Read from the copy, not from the
    /// app on the volume: a quarantined image's quarantine is the volume's,
    /// and lands on what is copied off it -- the app on the volume may have
    /// none of its own to read. The copy is the person's after the install,
    /// so no password is needed. Nil when done, or nothing needed doing.
    nonisolated static func approve(_ app: URL) -> String? {
        guard let value = attribute(quarantine, of: app) else { return nil }
        guard let marked = approved(value) else {
            return "its quarantine attribute is not one Diptych can read"
        }
        guard marked != value else { return nil }
        let bytes = Array(marked.utf8)
        guard setxattr(app.path, quarantine, bytes, bytes.count, 0, XATTR_NOFOLLOW) == 0 else {
            return "it could not be marked approved: " + String(cString: strerror(errno))
        }
        return nil
    }

    nonisolated static func attribute(_ name: String, of url: URL) -> String? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, name, &bytes, size, 0, XATTR_NOFOLLOW) == size else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    // MARK: - Installing

    struct Choices: Sendable, Equatable {
        var approveQuarantine = false
        var unmount = false
        var trashImage = false
    }

    /// The commands that put the app in place, run as root after the system's
    /// one prompt. `oldInTheWay` is an old copy trashing it as the person could
    /// not move: these move it into the Trash first.
    nonisolated static func script(for offer: Offer, choices: Choices, oldInTheWay: URL?,
                                   user: uid_t = getuid()) -> String {
        let destination = shellQuoted(offer.destination.path)
        var lines: [String] = []
        if let oldInTheWay {
            let trash = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".Trash", isDirectory: true)
            let place = FileOperations.uniqueURL(for: trash.appendingPathComponent(offer.app.lastPathComponent))
            lines.append("/bin/mv \(shellQuoted(oldInTheWay.path)) \(shellQuoted(place.path))")
        }
        // ditto keeps what the bundle is: its links, attributes and signature.
        lines.append("/usr/bin/ditto \(shellQuoted(offer.app.path)) \(destination)")
        // Owned by the person, as an app dragged in by Finder is.
        lines.append("/usr/sbin/chown -R \(user):admin \(destination)")
        // One line, each step only after the last one worked: the script
        // becomes one AppleScript string, where a newline does not parse.
        return lines.joined(separator: " && ")
    }
}

extension AppModel {

    /// Opened in a pane, a disk image made to install from asks whether to.
    func offerInstall(fromVolume volume: URL, image: URL) {
        Task {
            guard let offer = await BlockingWork.run({ AppInstalling.offer(on: volume, image: image) })
            else { return }
            let id = ToolWindows.shared.register(.init(model: self, kind: .install, files: [image],
                                                       offer: offer))
            openToolWindow?(.install, id)
        }
    }

    /// Installs the offered app, asking for an administrator's password, and
    /// does what was ticked after. Nil when done; otherwise what went wrong.
    func install(_ offer: AppInstalling.Offer, choices: AppInstalling.Choices) async -> String? {
        let destination = offer.destination
        let fm = FileManager.default
        var inTheWay: URL?
        var trashedOld: [(original: URL, trashed: URL)] = []
        if fm.fileExists(atPath: destination.path) {
            guard !AppInstalling.isRunning(destination) else {
                return "\u{201C}\(destination.lastPathComponent)\u{201D} is running. Quit it, then install again."
            }
            // Into the Trash as the person, so Undo and Put Back know it; what
            // only root may move goes there in the script.
            trashedOld = await FileOperations.shared.trashRecording([destination]).moved
            if trashedOld.isEmpty { inTheWay = destination }
        }
        let script = AppInstalling.script(for: offer, choices: choices, oldInTheWay: inTheWay)
        let problem: String? = switch Privileged.run(script) {
        case .cancelled: "Nothing was installed: the password was not given."
        case .failed(let message):
            "\u{201C}\(offer.app.lastPathComponent)\u{201D} could not be installed: \(message)"
        case .succeeded: nil
        }
        if let problem {
            // The old one back where it was, as if nothing had been tried.
            for (original, trashed) in trashedOld where !fm.fileExists(atPath: original.path) {
                try? fm.moveItem(at: trashed, to: original)
            }
            return problem
        }
        FileHistory.shared.recordTrash(trashedOld)

        var after: [String] = []
        if choices.approveQuarantine {
            if let trouble = await BlockingWork.run({ AppInstalling.approve(destination) }) {
                after.append(trouble)
            }
        }

        if choices.unmount || choices.trashImage {
            // A pane showing the volume goes to where the image is first.
            for pane in [left, right] where pane.directory.path.hasPrefix(offer.volume.path) {
                pane.navigate(to: offer.image.deletingLastPathComponent())
            }
        }
        if choices.unmount {
            let volume = offer.volume.path
            let detached = await BlockingWork.run { DiskImaging.detach(volume) }
            if !detached { after.append("the disk image could not be unmounted") }
        }
        if choices.trashImage {
            let trashed = await FileOperations.shared.trashRecording([offer.image])
            if trashed.moved.isEmpty {
                after.append("the disk image could not be moved to the Trash")
            } else {
                FileHistory.shared.recordTrash(trashed.moved)
            }
        }
        flash("\u{201C}\(offer.name)\u{201D} installed in Applications"
              + (after.isEmpty ? "" : "; " + after.joined(separator: ", ")), error: !after.isEmpty)
        return nil
    }
}
