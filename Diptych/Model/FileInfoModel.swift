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
    /// A file on a server whose bytes are not here, and whose size the server
    /// did not give: shown as `???`.
    private(set) var sizeIsUnknown = false
    private(set) var isDirectory = false
    /// A file or folder on a server: its facts are the server's, from its listing,
    /// and the changes that can be made to it are made there.
    private(set) var isOnServer = false
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
        sizeIsUnknown = false
        // A placeholder's own size is zero: the size is the server's, from its listing.
        if let placeholder = RemoteBrowsing.placeholder(url) {
            byteSize = placeholder.size ?? 0
            sizeIsUnknown = placeholder.size == nil
        }
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

        // On a server, what the server says: the copy kept here has its own mode,
        // owner and dates, none of them the server's.
        isOnServer = RemoteBrowsing.isInside(url)
        if isOnServer, let node = RemoteBrowsing.listedNode(of: url) {
            if let value = node.attribute(BrowserManifest.Attribute.mode)?.intValue {
                mode = mode_t(truncatingIfNeeded: value)
            }
            owner = node.attribute(BrowserManifest.Attribute.ownerName)?.stringValue
                ?? node.attribute(BrowserManifest.Attribute.uid)?.intValue.map { String($0) } ?? ""
            group = node.attribute(BrowserManifest.Attribute.groupName)?.stringValue
                ?? node.attribute(BrowserManifest.Attribute.gid)?.intValue.map { String($0) } ?? ""
            if let date = node.attribute(BrowserManifest.Attribute.modified)?.dateValue {
                modified = date
                created = date
            }
            tags = []
            self.attributes = []
            aclOnDisk = ""
            aclText = ""
        }
    }

    /// Refuses a change a server does not take, and says so: made to the copy
    /// kept here, it would never reach the server.
    private func refusedOnServer(_ what: String) -> Bool {
        guard isOnServer else { return false }
        report("\(what) cannot be changed on a server.", success: "")
        return true
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
        if isDirectory { return "--" }
        if sizeIsUnknown { return "???" }
        return ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    func applyRename() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != url.lastPathComponent else { return }

        if isOnServer {
            Task {
                do {
                    url = try await RemoteBrowsing.rename(url, to: trimmed)
                    report(nil, success: "Renamed on the server.")
                } catch {
                    report(error.localizedDescription, success: "")
                }
            }
            return
        }
        Task {
            do {
                let renamed = try await FileOperations.shared.rename(url, to: trimmed)
                await GitService.shared.followMove(from: url, to: renamed)
                FileHistory.shared.recordRename(from: url, to: renamed)
                url = renamed
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
        if refusedOnServer("A link") { return }

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
        // A server keeps a modification date, and no creation date.
        if isOnServer {
            Task {
                do {
                    try await RemoteBrowsing.setTimes(modified: modified, for: [url])
                    report(nil, success: "Modification date updated on the server.")
                } catch {
                    report(error.localizedDescription, success: "")
                }
            }
            return
        }
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
        // On a server, by the server's names or numbers, through sudo when needed.
        if isOnServer {
            let owner = owner.trimmingCharacters(in: .whitespaces)
            let group = group.trimmingCharacters(in: .whitespaces)
            Task {
                do {
                    try await RemoteBrowsing.setOwnership(owner: owner.isEmpty ? nil : owner,
                                                          group: group.isEmpty ? nil : group, for: [url])
                    report(nil, success: "Owner and group updated on the server.")
                } catch {
                    report(error.localizedDescription, success: "")
                }
            }
            return
        }
        Task {
            let before = await BlockingWork.run { [url] in
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                return (attributes?[.ownerAccountName] as? String,
                        attributes?[.groupOwnerAccountName] as? String)
            }
            let outcome = await FileOperations.shared.setOwnership(owner: owner, group: group,
                                                                   for: [url])
            @MainActor func remember() {
                FileHistory.shared.recordOwnership([(url, before.0, before.1, owner, group)])
            }
            if outcome.isCompleteSuccess {
                remember()
                report(nil, success: "Owner and group updated.")
                return
            }

            // Only root may hand a file to another user, so fall back to the
            // authenticated route rather than just reporting a refusal -- the
            // same thing the pane does. The group goes with it: the fallback
            // exists because owner *and* group were refused together.
            switch Privileged.chown(owner: owner, group: group, urls: [url]) {
            case .succeeded:
                remember()
                report(nil, success: "Owner and group updated.")
            case .cancelled:
                report("Cancelled. Nothing was changed.", success: "")
            case .failed(let message):
                report(message, success: "")
            }
        }
    }

    // MARK: - What the file says about itself

    private(set) var details: FormatDetails.Report?
    private(set) var isReadingDetails = false

    /// Asked when the tab is first shown. Cheap for a photograph, not always
    /// cheap for a film, so it is not part of opening the window.
    func readDetails() {
        guard !isReadingDetails, details == nil else { return }
        isReadingDetails = true
        let url = url
        Task {
            details = await FormatDetails.read(url)
            isReadingDetails = false
        }
    }

    // MARK: - What has it open

    private(set) var openBy: OpenFiles.Report?
    private(set) var isLookingForOpenBy = false

    /// Asked for, not watched: what has a file open changes from moment to
    /// moment, so an answer is a snapshot with the time on it and a button to
    /// ask again -- the same honesty the version-tracking check needs.
    func lookForOpenBy() {
        guard !isLookingForOpenBy else { return }
        isLookingForOpenBy = true
        let url = url
        Task {
            let report = await BlockingWork.run { OpenFiles.holders(of: url) }
            openBy = report
            isLookingForOpenBy = false
        }
    }

    // MARK: - Code signature and notarization

    private(set) var signing: CodeSigning.Report?
    private(set) var isReadingSigning = false

    /// Asked when the Signature tab is first shown: it runs codesign, spctl and
    /// stapler, so it is not part of opening the window.
    func readSigning() {
        guard !isReadingSigning, signing == nil else { return }
        isReadingSigning = true
        let url = url
        Task {
            signing = await BlockingWork.run { CodeSigning.report(for: url) }
            isReadingSigning = false
        }
    }

    /// The Check Again button: throw away the last answer and read it fresh.
    func recheckSigning() {
        signing = nil
        readSigning()
    }

    // MARK: - Open using

    private(set) var openWithApps: [OpenWith.App] = []
    private(set) var hasLoadedOpenWith = false

    /// Asked when the Open Using tab is first shown.
    func loadOpenWith() {
        openWithApps = OpenWith.apps(for: url)
        hasLoadedOpenWith = true
    }

    /// Open the file in `app` now, leaving the default as it was.
    func open(with app: OpenWith.App) {
        // A file on a server is fetched first: the app would get the empty
        // placeholder otherwise.
        guard RemoteBrowsing.hasPending([url]) else {
            OpenWith.open(url, with: app.url)
            statusIsError = false
            status = "Opened in \u{201C}\(app.name)\u{201D}."
            return
        }
        statusIsError = false
        status = "Fetching from the server\u{2026}"
        let url = url
        Task {
            do {
                try await RemoteBrowsing.fetch([url])
                OpenWith.open(url, with: app.url)
                statusIsError = false
                status = "Opened in \u{201C}\(app.name)\u{201D}."
            } catch {
                statusIsError = true
                status = "Could not fetch from the server: " + error.localizedDescription
            }
        }
    }

    /// Make `app` the default for this kind of file -- every file of the kind,
    /// not only this one.
    func makeDefault(_ app: OpenWith.App) {
        let url = url
        Task {
            if let problem = await OpenWith.makeDefault(app.url, for: url) {
                statusIsError = true
                status = "Could not set the default app: \(problem)"
            } else {
                loadOpenWith()
                statusIsError = false
                status = "\u{201C}\(app.name)\u{201D} is now the default for this kind of file."
            }
        }
    }

    func isSet(_ bit: mode_t) -> Bool { mode & bit != 0 }

    func toggle(_ bit: mode_t) {
        let updated = mode ^ bit
        if isOnServer {
            Task {
                do {
                    try await RemoteBrowsing.setPermissions(UInt32(updated & 0o7777), for: [url])
                    mode = updated
                    report(nil, success: "Permissions updated on the server.")
                } catch {
                    report(error.localizedDescription, success: "")
                }
            }
            return
        }
        let target = isSymlink ? url.resolvingSymlinksInPath().path : url.path
        do {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: updated)],
                                                  ofItemAtPath: target)
            FileHistory.shared.recordPermissions([(url, mode, updated)])
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
        if refusedOnServer("Tags") { return }
        var updated = tags
        if let index = updated.firstIndex(of: tag) {
            updated.remove(at: index)
        } else {
            updated.append(tag)
        }
        applyTags(updated)
    }

    func addTag() {
        if refusedOnServer("Tags") { return }
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
        if refusedOnServer("A folder icon") { return }
        perform(.xattrs(FolderIcon.writes(customised: customised, symbol: symbol, on: url.path),
                        on: url,
                        action: customised ? "change the folder icon"
                                           : "restore the plain folder icon"),
                success: customised ? "Folder icon updated." : "Folder icon reset.")
    }

    // MARK: - Extended attributes

    func saveAttribute(named attributeName: String, text: String) {
        if refusedOnServer("Extended attributes") { return }
        guard let data = text.data(using: .utf8) else { return }
        write(XattrWrite(name: attributeName, data: data),
              action: "save the attribute \u{201C}\(attributeName)\u{201D}",
              success: "\(attributeName) saved.")
    }

    func removeAttribute(named attributeName: String) {
        if refusedOnServer("Extended attributes") { return }
        write(XattrWrite(name: attributeName, data: nil),
              action: "remove the attribute \u{201C}\(attributeName)\u{201D}",
              success: "\(attributeName) removed.")
    }

    func addAttribute() {
        if refusedOnServer("Extended attributes") { return }
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
        if refusedOnServer("An access control list") { return }
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
