import Foundation
import AppKit
import Observation

/// Everything the Info window shows and edits for one file.
///
/// Each section applies on its own -- there is no global Save -- because the
/// underlying operations are separate syscalls that can fail independently, and
/// a half-applied Save would be worse than none.
@MainActor
@Observable
final class FileInfoModel {

    /// Broadcast after any change, so panes showing this file can refresh --
    /// a kqueue watch on the directory does not fire for attribute-only edits.
    static let didChange = Notification.Name("dev.verhas.Diptych.fileDidChange")

    private(set) var url: URL

    var location: String { url.deletingLastPathComponent().path }

    // General
    var name = ""
    private(set) var kind = ""
    private(set) var byteSize: Int64 = 0
    private(set) var isDirectory = false
    /// Permissions and ownership are the *target's* for a symlink, because that
    /// is what changing them affects.
    private(set) var isSymlink = false
    /// Where the link points, exactly as stored -- relative if that is how it
    /// was written, because rewriting a relative link as an absolute one would
    /// change what it means when the folder moves.
    var linkTarget = ""
    private(set) var linkTargetOnDisk = ""
    /// Whether what is *typed* points at something, checked against the text
    /// rather than against the link on disk.
    ///
    /// Computed, not stored: stored, it described the target the link had when
    /// the window opened, so it never moved while you edited and still claimed
    /// a freshly pasted, perfectly good path did not exist.
    var linkTargetExists: Bool {
        guard isSymlink else { return false }
        let resolved = resolvedLinkTarget
        return !resolved.isEmpty && FileManager.default.fileExists(atPath: resolved)
    }

    /// The typed target as an absolute path: `~` expanded, and anything
    /// relative resolved against the folder the link sits in -- which is what
    /// the kernel does when it follows the link.
    var resolvedLinkTarget: String {
        let wanted = linkTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return "" }
        if wanted.hasPrefix("~") { return (wanted as NSString).expandingTildeInPath }
        if (wanted as NSString).isAbsolutePath { return wanted }
        return (url.deletingLastPathComponent().path as NSString)
            .appendingPathComponent(wanted)
    }

    /// What to say under the field, and whether it is good news.
    var linkTargetNote: (ok: Bool, text: String) {
        let wanted = linkTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        if wanted.isEmpty { return (false, "A link needs a target.") }
        guard linkTargetExists else { return (false, "There is nothing at that path.") }
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: resolvedLinkTarget, isDirectory: &isDirectory)
        // Worth saying which: a link to a folder and a link to a file behave
        // differently everywhere in this app.
        return (true, isDirectory.boolValue ? "Points to a folder." : "Points to a file.")
    }
    var created = Date()
    var modified = Date()
    private(set) var added: Date?
    private(set) var accessed: Date?

    // Ownership
    var owner = ""
    var group = ""
    private(set) var mode: mode_t = 0

    // Tags
    private(set) var tags: [String] = []
    var newTag = ""

    // Extended attributes
    private(set) var attributes: [ExtendedAttributes.Attribute] = []
    var newAttributeName = ""
    var newAttributeValue = ""

    // Folder icon (directories only)
    private(set) var folderIsCustomised = false
    var folderSymbol = ""

    // Access control
    var aclText = ""
    private(set) var aclOnDisk = ""

    /// One-line feedback under whichever section was last acted on.
    private(set) var status: String?
    private(set) var statusIsError = false

    init(url: URL) {
        self.url = url
        load()
    }

    // MARK: - Loading

    func load() {
        let path = url.path
        let fm = FileManager.default

        name = url.lastPathComponent
        let keys: Set<URLResourceKey> = [
            .localizedTypeDescriptionKey, .fileSizeKey, .isDirectoryKey,
            .creationDateKey, .contentModificationDateKey,
            .addedToDirectoryDateKey, .contentAccessDateKey, .tagNamesKey,
            .isSymbolicLinkKey,
        ]
        // URL caches resource values, so re-reading after a change hands back
        // what was there before -- a tag just written comes back missing, which
        // looks exactly like the write having failed.
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try? fresh.resourceValues(forKeys: keys)

        kind = values?.localizedTypeDescription ?? ""
        byteSize = Int64(values?.fileSize ?? 0)
        isDirectory = values?.isDirectory ?? false
        created = values?.creationDate ?? .now
        modified = values?.contentModificationDate ?? .now
        added = values?.addedToDirectoryDate
        accessed = values?.contentAccessDate
        tags = values?.tagNames ?? []

        isSymlink = values?.isSymbolicLink ?? false
        linkTargetOnDisk = isSymlink
            ? ((try? fm.destinationOfSymbolicLink(atPath: path)) ?? "") : ""
        linkTarget = linkTargetOnDisk
        // attributesOfItem does not follow a symlink, but setAttributes does.
        // Read what an edit would write.
        let attributePath = isSymlink ? url.resolvingSymlinksInPath().path : path
        let attributes = try? fm.attributesOfItem(atPath: attributePath)
        owner = attributes?[.ownerAccountName] as? String ?? ""
        group = attributes?[.groupOwnerAccountName] as? String ?? ""
        mode = mode_t((attributes?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0)

        folderIsCustomised = FolderIcon.isCustomised(path)
        folderSymbol = FolderIcon.symbol(of: path) ?? ""

        self.attributes = ExtendedAttributes.all(of: path)
        aclOnDisk = AccessControl.text(of: path) ?? ""
        aclText = aclOnDisk
    }

    /// Runs a metadata change through the permission ladder and reports what
    /// came of it -- including, loudly, a permission left raised.
    private func perform(_ change: MetadataWrite, success: String) {
        switch change.perform() {
        case .succeeded(let warning):
            report(nil, success: success)
            if let warning {
                status = "\(success) \(warning)"
                statusIsError = true
            }
        case .cancelled:
            report("Cancelled. Nothing was changed.", success: "")
        case .failed(let message):
            report("Could not \(change.action): \(message)", success: "")
        }
    }

    private func report(_ message: String?, success: String) {
        statusIsError = message != nil
        status = message ?? success

        // Reload everything, not just the section that changed: adding a tag
        // rewrites an extended attribute, and removing that attribute changes
        // the tags. Keeping only one of them fresh leaves the other lying.
        if message == nil {
            reloadFromDisk()
            NotificationCenter.default.post(name: Self.didChange, object: url)
        }
    }

    /// load() without clearing the status message it was called from.
    private func reloadFromDisk() {
        let keptStatus = status
        let keptError = statusIsError
        load()
        status = keptStatus
        statusIsError = keptError
    }

    // MARK: - General

    var sizeText: String {
        isDirectory ? "--" : ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    func applyRename() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != url.lastPathComponent else { return }

        Task {
            do {
                url = try await FileOperations.shared.rename(url, to: trimmed)
                report(nil, success: "Renamed.")
            } catch {
                report(error.localizedDescription, success: "")
            }
        }
    }

    /// An empty target is not a change worth offering: `applyLinkTarget` refuses
    /// it, so an enabled Apply button would promise something it will not do.
    var linkTargetHasChanges: Bool {
        let wanted = linkTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        return isSymlink && !wanted.isEmpty && wanted != linkTargetOnDisk
    }

    /// Repoints the link.
    ///
    /// A symlink's target cannot be edited in place -- there is no syscall for
    /// it -- so the link is removed and made again. Which means the old one is
    /// gone for a moment: if creating the replacement fails, the original is
    /// put back rather than left as a hole where a link used to be.
    func applyLinkTarget() {
        let wanted = linkTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSymlink, !wanted.isEmpty, wanted != linkTargetOnDisk else { return }

        let fm = FileManager.default
        let previous = linkTargetOnDisk
        do {
            try fm.removeItem(at: url)
        } catch {
            return report("The old link could not be removed: \(error.localizedDescription)",
                          success: "")
        }
        do {
            try fm.createSymbolicLink(atPath: url.path, withDestinationPath: wanted)
            report(nil, success: "Link now points to \(wanted).")
        } catch {
            try? fm.createSymbolicLink(atPath: url.path, withDestinationPath: previous)
            report("The link could not be repointed: \(error.localizedDescription)", success: "")
        }
    }

    func revertLinkTarget() {
        linkTarget = linkTargetOnDisk
    }

    func applyDates() {
        do {
            try FileManager.default.setAttributes(
                [.creationDate: created, .modificationDate: modified],
                ofItemAtPath: url.path)
            report(nil, success: "Dates updated.")
        } catch {
            report(error.localizedDescription, success: "")
        }
    }

    // MARK: - Ownership

    func applyOwnership() {
        Task {
            let outcome = await FileOperations.shared.setOwnership(owner: owner, group: group,
                                                                   for: [url])
            if outcome.isCompleteSuccess {
                report(nil, success: "Owner and group updated.")
                return
            }

            // Only root may hand a file to another user, so fall back to the
            // authenticated route rather than just reporting a refusal -- the
            // same thing the pane does. The group goes with it: the fallback
            // exists because owner *and* group were refused together.
            switch Privileged.chown(owner: owner, group: group, urls: [url]) {
            case .succeeded:
                report(nil, success: "Owner and group updated.")
            case .cancelled:
                report("Cancelled. Nothing was changed.", success: "")
            case .failed(let message):
                report(message, success: "")
            }
        }
    }

    func isSet(_ bit: mode_t) -> Bool { mode & bit != 0 }

    func toggle(_ bit: mode_t) {
        let updated = mode ^ bit
        let target = isSymlink ? url.resolvingSymlinksInPath().path : url.path
        do {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: updated)],
                                                  ofItemAtPath: target)
            mode = updated
            report(nil, success: "Permissions updated.")
        } catch {
            report(error.localizedDescription, success: "")
        }
    }

    /// Four digits once a special bit is set, as `chmod` and `stat` print it.
    var modeText: String {
        mode & 0o7000 != 0
            ? String(format: "%04o", mode & 0o7777)
            : String(format: "%03o", mode & 0o777)
    }

    // MARK: - Tags

    func toggleTag(_ tag: String) {
        var updated = tags
        if let index = updated.firstIndex(of: tag) {
            updated.remove(at: index)
        } else {
            updated.append(tag)
        }
        applyTags(updated)
    }

    func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !tags.contains(trimmed) else { return }
        newTag = ""
        applyTags(tags + [trimmed])
    }

    private func applyTags(_ updated: [String]) {
        let writes: [XattrWrite]
        do {
            writes = try FinderTag.writes(for: updated, on: url.path)
        } catch {
            report((error as? ExtendedAttributes.Failure)?.message ?? "\(error)", success: "")
            return
        }
        perform(.xattrs(writes, on: url, action: "change the tags"), success: "Tags updated.")
    }

    // MARK: - Folder icon

    /// The colour comes from the tag; this only decides whether macOS composes
    /// a tinted icon out of it, and what symbol goes on top.
    func applyFolderIcon(customised: Bool, symbol: String) {
        perform(.xattrs(FolderIcon.writes(customised: customised, symbol: symbol, on: url.path),
                        on: url,
                        action: customised ? "change the folder icon"
                                           : "restore the plain folder icon"),
                success: customised ? "Folder icon updated." : "Folder icon reset.")
    }

    // MARK: - Extended attributes

    func saveAttribute(named attributeName: String, text: String) {
        guard let data = text.data(using: .utf8) else { return }
        write(XattrWrite(name: attributeName, data: data),
              action: "save the attribute \u{201C}\(attributeName)\u{201D}",
              success: "\(attributeName) saved.")
    }

    func removeAttribute(named attributeName: String) {
        write(XattrWrite(name: attributeName, data: nil),
              action: "remove the attribute \u{201C}\(attributeName)\u{201D}",
              success: "\(attributeName) removed.")
    }

    func addAttribute() {
        let trimmed = newAttributeName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let data = newAttributeValue.data(using: .utf8) else { return }

        newAttributeName = ""
        newAttributeValue = ""
        write(XattrWrite(name: trimmed, data: data),
              action: "add the attribute \u{201C}\(trimmed)\u{201D}",
              success: "\(trimmed) added.")
    }

    private func write(_ change: XattrWrite, action: String, success: String) {
        perform(.xattrs([change], on: url, action: action), success: success)
        // The list is reloaded whatever happened: after a failure it shows that
        // nothing changed, which is the point.
        attributes = ExtendedAttributes.all(of: url.path)
    }

    // MARK: - Access control

    var aclHasChanges: Bool { aclText != aclOnDisk }

    func applyACL() {
        let wanted = aclText
        let removing = wanted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        perform(.acl(wanted, on: url,
                     action: removing ? "remove the access control list"
                                      : "change the access control list"),
                success: removing ? "Access control list removed."
                                  : "Access control list updated.")
        aclOnDisk = AccessControl.text(of: url.path) ?? ""
        aclText = aclOnDisk
    }

    func revertACL() {
        aclText = aclOnDisk
        report(nil, success: "Reverted.")
    }
}
