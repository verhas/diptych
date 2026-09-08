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
        // attributesOfItem does not follow a symlink, but setAttributes does.
        // Read what an edit would write.
        let attributePath = isSymlink ? url.resolvingSymlinksInPath().path : path
        let attributes = try? fm.attributesOfItem(atPath: attributePath)
        owner = attributes?[.ownerAccountName] as? String ?? ""
        group = attributes?[.groupOwnerAccountName] as? String ?? ""
        mode = mode_t((attributes?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0)

        self.attributes = ExtendedAttributes.all(of: path)
        aclOnDisk = AccessControl.text(of: path) ?? ""
        aclText = aclOnDisk
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
        let message = FinderTag.set(updated, on: url)
        if message == nil { tags = updated }
        report(message, success: "Tags updated.")
    }

    // MARK: - Extended attributes

    func saveAttribute(named attributeName: String, text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let message = ExtendedAttributes.set(data, name: attributeName, on: url.path)
        attributes = ExtendedAttributes.all(of: url.path)
        report(message, success: "\(attributeName) saved.")
    }

    func removeAttribute(named attributeName: String) {
        let message = ExtendedAttributes.remove(name: attributeName, from: url.path)
        attributes = ExtendedAttributes.all(of: url.path)
        report(message, success: "\(attributeName) removed.")
    }

    func addAttribute() {
        let trimmed = newAttributeName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let data = newAttributeValue.data(using: .utf8) else { return }

        let message = ExtendedAttributes.set(data, name: trimmed, on: url.path)
        newAttributeName = ""
        newAttributeValue = ""
        attributes = ExtendedAttributes.all(of: url.path)
        report(message, success: "\(trimmed) added.")
    }

    // MARK: - Access control

    var aclHasChanges: Bool { aclText != aclOnDisk }

    func applyACL() {
        let message = AccessControl.setText(aclText, on: url.path)
        aclOnDisk = AccessControl.text(of: url.path) ?? ""
        aclText = aclOnDisk
        report(message, success: aclOnDisk.isEmpty ? "Access control list removed."
                                                   : "Access control list updated.")
    }

    func revertACL() {
        aclText = aclOnDisk
        report(nil, success: "Reverted.")
    }
}
