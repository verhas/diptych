import AppKit
import Foundation
import Observation

/// "Part 5" of `DIPTYCH_MCP_PROPOSAL.md`: a batch of file operations an agent
/// proposes, reviewed by the person in a window before anything touches disk.
///
/// Every operation kind here is backed 1:1 by an existing `FileOperations`
/// method -- this file adds the review/validate/confirm layer `FileOperations`
/// itself deliberately has none of, plus the ordering and collision checks a
/// heterogeneous batch needs that a single call to one of those methods never
/// did.
@MainActor
enum BatchOperationKind: String, CaseIterable, Sendable {
    case move, copy, rename, trash
    case deletePermanent = "delete_permanent"
    case setPermissions = "set_permissions"
    case setOwner = "set_owner"
    case createSymlink = "create_symlink"
    case createDirectory = "create_directory"
    case setXattr = "set_xattr"
    case removeXattr = "remove_xattr"
    case addTags = "add_tags"
    case removeTags = "remove_tags"
    case setTags = "set_tags"

    init?(mcpName: String) { self.init(rawValue: mcpName) }

    var displayName: String {
        switch self {
        case .move: "Move"
        case .copy: "Copy"
        case .rename: "Rename"
        case .trash: "Move to Trash"
        case .deletePermanent: "Delete Permanently"
        case .setPermissions: "Change Permissions"
        case .setOwner: "Change Owner"
        case .createSymlink: "Create Symlink"
        case .createDirectory: "Create Folder"
        case .setXattr: "Set Attribute"
        case .removeXattr: "Remove Attribute"
        case .addTags: "Add Tags"
        case .removeTags: "Remove Tags"
        case .setTags: "Set Tags"
        }
    }

    /// The tag operations: their value is a list of tag names, not bytes.
    var isTagChange: Bool { self == .addTags || self == .removeTags || self == .setTags }

    /// Everything that changes an extended attribute in place -- tags are
    /// attributes too, which is how they are written and undone.
    var isAttributeChange: Bool { isTagChange || self == .setXattr || self == .removeXattr }
}

/// How a `set_xattr` value was written in the call, and is shown for editing.
enum XattrEncoding: String, CaseIterable, Sendable {
    case text, hex, base64

    func decode(_ value: String) -> Data? {
        switch self {
        case .text:
            return Data(value.utf8)
        case .hex:
            let digits = value.filter { !$0.isWhitespace }
            guard digits.count.isMultiple(of: 2) else { return nil }
            var data = Data()
            var index = digits.startIndex
            while index < digits.endIndex {
                let next = digits.index(index, offsetBy: 2)
                guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
                data.append(byte)
                index = next
            }
            return data
        case .base64:
            return Data(base64Encoded: value.filter { !$0.isWhitespace })
        }
    }

    func encode(_ data: Data) -> String {
        switch self {
        case .text: String(decoding: data, as: UTF8.self)
        case .hex: data.map { String(format: "%02x", $0) }.joined()
        case .base64: data.base64EncodedString()
        }
    }
}

/// What an attribute holds, in words a person can read: text as text, a
/// property list as one, anything else as the start of a hex dump.
@MainActor
enum XattrDisplay {
    static func describe(_ data: Data?, name: String? = nil) -> String {
        guard let data else { return "(not set)" }
        if data.isEmpty { return "(empty)" }
        if name == Provenance.xattrName, let words = Provenance.describe(data) { return words }
        if let list = try? PropertyListSerialization.propertyList(from: data, format: nil),
           data.starts(with: Data("bplist".utf8)) {
            return "\(list)".replacingOccurrences(of: "\n", with: " ")
        }
        if let text = String(data: data, encoding: .utf8),
           !text.unicodeScalars.contains(where: { $0.value < 9 }) {
            return text
        }
        let hex = data.prefix(48).map { String(format: "%02x", $0) }.joined(separator: " ")
        return data.count > 48 ? hex + " \u{2026} (\(data.count) bytes)" : hex
    }

    /// A word on the attributes people most often meet, so the review shows
    /// what removing one actually means.
    static func meaning(of name: String) -> String? {
        switch name {
        case "com.apple.quarantine":
            "Marks a download: macOS checks it with Gatekeeper and asks before it is "
                + "first opened. Removing it skips that check."
        case FinderTag.xattrName:
            "Finder tags."
        case "com.apple.metadata:kMDItemWhereFroms":
            "Where the file was downloaded from."
        case FinderInfo.xattrName:
            "Finder flags and label colour."
        case Provenance.xattrName:
            "macOS's record of which tracked app made or last changed this file. Not "
                + "quarantine: nothing is checked or asked because of it. macOS keeps it "
                + "itself and lets no program remove it."
        default:
            nil
        }
    }
}

/// One proposed operation, editable in place before the batch runs.
///
/// Not every field applies to every `kind` -- see the table in
/// `DIPTYCH_MCP_PROPOSAL.md` Part 5 for which ones a given kind reads.
@MainActor
@Observable
final class BatchOperationRow: Identifiable {

    let id = UUID()
    var kind: BatchOperationKind

    var source: URL?
    /// move/copy: destination path. create_symlink: the new link's own path.
    /// create_directory: the new folder's path.
    var targetPath: URL?
    /// rename: the new leaf name, same directory as `source`.
    var newName: String?
    var mode: mode_t?
    var owner: String?
    var group: String?
    /// create_symlink only: what the new link points to.
    var linkTarget: URL?
    /// set_xattr / remove_xattr: the attribute's name.
    var xattrName: String?
    /// set_xattr: the new value, kept as the text it is edited in, in
    /// `xattrEncoding`; `xattrValue` is that text decoded, nil when it does
    /// not decode.
    var xattrText: String?
    var xattrEncoding = XattrEncoding.text
    /// An `encoding` the call gave that is none of the three: a problem on
    /// the row until another is picked, never silently read as text.
    var unknownEncoding: String?
    var xattrValue: Data? { xattrText.flatMap(xattrEncoding.decode) }
    /// add_tags / remove_tags / set_tags: the tag names.
    var tags: [String] = []
    /// The attribute's value, or the item's tags, read at the last revalidate.
    var currentXattr: Data?
    var currentTags: [String]?
    /// The agent's stated rationale, shown to the person, never enforced.
    var reason: String?

    var included = true
    /// This row's own problems: a missing field, a source that no longer
    /// exists. Recomputed by `BatchOperationsModel.revalidate()`.
    var problems: [String] = []
    /// Whether this row's effective target already exists on disk --
    /// recomputed alongside `problems`.
    var willOverwrite = false
    /// The path the person ticked "Overwrite" (or "Delete permanently") for.
    /// Kept as the path rather than a flag so that editing the row to point
    /// somewhere else withdraws the agreement instead of carrying it over to
    /// a file nobody looked at.
    private var confirmedDestructivePath: String?
    /// set_permissions only: the mode on disk, read at the last revalidate.
    var currentMode: mode_t?

    init(kind: BatchOperationKind) {
        self.kind = kind
    }

    /// Overwriting an existing item and deleting outright both lose
    /// something for good, so both need their own tick beyond Execute.
    var needsDestructiveConfirmation: Bool { willOverwrite || kind == .deletePermanent }

    private var destructivePath: String? {
        kind == .deletePermanent ? source?.path : effectiveTarget?.path
    }

    var destructiveConfirmed: Bool {
        get { confirmedDestructivePath != nil && confirmedDestructivePath == destructivePath }
        set { confirmedDestructivePath = newValue ? destructivePath : nil }
    }

    /// A permission change to what the item already has: still ticked, so
    /// the person's choice is left alone, but it would do nothing.
    var isNoOp: Bool {
        switch kind {
        case .setPermissions:
            guard let mode, let currentMode else { return false }
            return mode & 0o7777 == currentMode & 0o7777
        case .setXattr:
            guard let value = xattrValue, source != nil else { return false }
            return currentXattr == value
        case .removeXattr:
            return source != nil && xattrName != nil && currentXattr == nil
        case .addTags, .removeTags, .setTags:
            guard let currentTags else { return false }
            return Self.sameTags(resultingTags(from: currentTags), currentTags)
        default:
            return false
        }
    }

    /// The item's tags once this row has run, from the tags it has.
    /// Compared without regard to case, as Finder does, so "red" does not
    /// become a second Red.
    func resultingTags(from current: [String]) -> [String] {
        func has(_ list: [String], _ tag: String) -> Bool {
            list.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
        switch kind {
        case .addTags:
            var result = current
            for tag in tags where !has(result, tag) { result.append(tag) }
            return result
        case .removeTags:
            return current.filter { !has(tags, $0) }
        case .setTags:
            var result: [String] = []
            for tag in tags where !has(result, tag) { result.append(tag) }
            return result
        default:
            return current
        }
    }

    static func sameTags(_ a: [String], _ b: [String]) -> Bool {
        Set(a.map { $0.lowercased() }) == Set(b.map { $0.lowercased() })
    }

    /// The tags an item has now. A fresh URL, so nothing cached from before
    /// the last change is read back.
    static func tags(of url: URL) -> [String] {
        let fresh = URL(fileURLWithPath: url.path)
        return (try? fresh.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    /// The path this row reads from and, other than for copy, vacates --
    /// what a later row landing here would collide with. `nil` for the two
    /// kinds that only ever create something new.
    var effectiveSource: URL? {
        switch kind {
        case .move, .copy, .rename, .trash, .deletePermanent, .setPermissions, .setOwner,
             .setXattr, .removeXattr, .addTags, .removeTags, .setTags:
            return source
        case .createSymlink, .createDirectory:
            return nil
        }
    }

    /// The path this row places something at -- what a later row reading
    /// from here depends on, and what two rows landing on the same path
    /// collide over. `nil` for the kinds that only ever act in place.
    var effectiveTarget: URL? {
        switch kind {
        case .move, .copy:
            return targetPath
        case .rename:
            guard let source, let newName else { return nil }
            return source.deletingLastPathComponent().appendingPathComponent(newName)
        case .createSymlink, .createDirectory:
            return targetPath
        case .trash, .deletePermanent, .setPermissions, .setOwner,
             .setXattr, .removeXattr, .addTags, .removeTags, .setTags:
            return nil
        }
    }

    var shortDescription: String {
        let name = (source ?? targetPath)?.lastPathComponent ?? "(unnamed)"
        return "\(kind.displayName) \(name)"
    }

    /// What's wrong with this row on its own, independent of the rest of the
    /// batch -- a missing field, or a source that has vanished since it was
    /// proposed.
    func computeProblems() -> [String] {
        var problems: [String] = []
        switch kind {
        case .move, .copy:
            if source == nil { problems.append("source is required.") }
            if targetPath == nil { problems.append("target is required.") }
        case .rename:
            if source == nil { problems.append("source is required.") }
            if let newName {
                if newName.isEmpty || newName.contains("/") {
                    problems.append("target must be a non-empty name with no \"/\".")
                }
            } else {
                problems.append("target (new name) is required.")
            }
        case .trash, .deletePermanent:
            if source == nil { problems.append("source is required.") }
        case .setPermissions:
            if source == nil { problems.append("source is required.") }
            if mode == nil { problems.append("A valid permission value is required.") }
        case .setOwner:
            if source == nil { problems.append("source is required.") }
            if owner == nil, group == nil {
                problems.append("An owner, a group, or both are required.")
            }
        case .createSymlink:
            if targetPath == nil { problems.append("target (new link path) is required.") }
            if linkTarget == nil { problems.append("linkTarget (what it points to) is required.") }
        case .createDirectory:
            if targetPath == nil { problems.append("target (new directory path) is required.") }
        case .setXattr, .removeXattr:
            if source == nil { problems.append("source is required.") }
            if (xattrName ?? "").isEmpty {
                problems.append("name (the attribute's name) is required.")
            } else if let name = xattrName,
                      let reason = ExtendedAttributes.protectedReason(for: name) {
                problems.append(reason.prefix(1).uppercased() + reason.dropFirst() + ".")
            }
            if kind == .setXattr {
                if let unknownEncoding {
                    problems.append("encoding \"\(unknownEncoding)\" is not one of text, hex, "
                                    + "base64 -- choose how the value is written.")
                } else if xattrText == nil {
                    problems.append("value is required.")
                } else if xattrValue == nil {
                    problems.append("value is not valid \(xattrEncoding.rawValue).")
                }
            }
        case .addTags, .removeTags, .setTags:
            if source == nil { problems.append("source is required.") }
            if kind != .setTags, tags.isEmpty {
                problems.append("tags must name at least one tag.")
            }
            if tags.contains(where: { $0.isEmpty || $0.contains("\n") }) {
                problems.append("A tag name cannot be empty or span lines.")
            }
        }
        if let source, !FileOperations.exists(source) {
            problems.append("\(source.path) does not exist.")
        }
        return problems
    }
}

/// One proposed batch: the rows an agent's `propose_file_operations` call
/// built, live in a review window until the person cancels or executes it.
@MainActor
@Observable
final class BatchOperationsModel {

    let batchId: UUID
    private(set) var rows: [BatchOperationRow]

    enum Status: Sendable { case reviewing, executing, finished, cancelled }
    private(set) var status: Status = .reviewing
    /// Row id -> what happened to it, filled in once `execute()` has run.
    private(set) var rowResults: [UUID: String] = [:]
    /// Rows that failed or were skipped because something they depended on
    /// failed. Kept apart from `rowResults`: the messages come from the
    /// system in whatever words it chooses, so they cannot be read to tell
    /// a failure from a success.
    private(set) var failedRows: Set<UUID> = []

    private(set) var batchProblems: [String] = []
    /// Included rows in dependency order, followed by the excluded ones
    /// (untouched by `execute()`, kept so every row is accounted for).
    private(set) var executionOrder: [BatchOperationRow] = []
    /// row id -> the ids of included rows it must run after, because this
    /// row's source is that row's target.
    private var dependencies: [UUID: Set<UUID>] = [:]

    init(batchId: UUID = UUID(), rows: [BatchOperationRow]) {
        self.batchId = batchId
        self.rows = rows
        revalidate()
    }

    func toggleAll(_ included: Bool) {
        for row in rows { row.included = included }
        revalidate()
    }

    /// Recomputes every row's `problems`/`willOverwrite`, the batch-wide
    /// collision/cycle checks, and the order execution would run in. Called
    /// once at proposal time and again after any edit -- there is no
    /// automatic reactivity from a row's own fields to these derived values.
    func revalidate() {
        for row in rows {
            row.problems = row.computeProblems()
            if let target = row.effectiveTarget {
                let isNoOp = row.effectiveSource.map { FileOperations.samePath($0, target) } ?? false
                row.willOverwrite = !isNoOp && FileOperations.exists(target)
            } else {
                row.willOverwrite = false
            }
            if row.kind == .setPermissions, let source = row.source {
                row.currentMode = try? FileOperations.currentMode(of: source)
            }
            if let source = row.source, row.kind == .setXattr || row.kind == .removeXattr,
               let name = row.xattrName {
                row.currentXattr = ExtendedAttributes.data(of: source.path, name: name)
            }
            if let source = row.source, row.kind.isTagChange {
                row.currentTags = FileOperations.exists(source)
                    ? BatchOperationRow.tags(of: source) : nil
            }
        }

        let included = rows.filter(\.included)
        var problems: [String] = []

        var targetOwners: [String: [BatchOperationRow]] = [:]
        for row in included {
            guard let target = row.effectiveTarget else { continue }
            targetOwners[target.path, default: []].append(row)
        }
        for (path, owners) in targetOwners.sorted(by: { $0.key < $1.key }) where owners.count > 1 {
            let names = owners.map(\.shortDescription).joined(separator: ", ")
            problems.append("More than one operation targets \(path): \(names).")
        }

        var dependencies: [UUID: Set<UUID>] = [:]
        for a in included {
            guard let aSource = a.effectiveSource else { continue }
            for b in included where b.id != a.id {
                guard let bTarget = b.effectiveTarget else { continue }
                if FileOperations.samePath(aSource, bTarget) {
                    dependencies[a.id, default: []].insert(b.id)
                }
            }
        }

        var order: [BatchOperationRow] = []
        var remaining = included
        var placed: Set<UUID> = []
        while !remaining.isEmpty {
            guard let next = remaining.first(where: { (dependencies[$0.id] ?? []).isSubset(of: placed) })
            else {
                let names = remaining.map(\.shortDescription).joined(separator: ", ")
                problems.append("These operations depend on each other in a cycle and cannot "
                                 + "be ordered: \(names).")
                order += remaining
                break
            }
            order.append(next)
            placed.insert(next.id)
            remaining.removeAll { $0.id == next.id }
        }
        order += rows.filter { !$0.included }

        self.batchProblems = problems
        self.executionOrder = order
        self.dependencies = dependencies
    }

    /// Included rows that would overwrite something or delete it outright
    /// and have not had their own "Overwrite"/"Delete permanently" tick --
    /// Execute alone must not be able to trigger either.
    var rowsNeedingOverwriteConfirmation: [BatchOperationRow] {
        rows.filter { $0.included && $0.needsDestructiveConfirmation && !$0.destructiveConfirmed }
    }

    /// Everything `canExecute` checks except the status -- `execute()` needs
    /// this on its own, since by the time it re-checks after starting,
    /// `status` is deliberately no longer `.reviewing` and `canExecute`
    /// itself would always read false there.
    private var isContentReadyToRun: Bool {
        rows.contains(where: \.included)
            && batchProblems.isEmpty
            && rows.allSatisfy { !$0.included || $0.problems.isEmpty }
            && rowsNeedingOverwriteConfirmation.isEmpty
    }

    var canExecute: Bool {
        status == .reviewing && isContentReadyToRun
    }

    func cancel() {
        status = .cancelled
    }

    /// Runs `executionOrder` (included rows only). A row whose dependency
    /// failed is skipped, not attempted -- most rows in a heterogeneous
    /// batch are independent, so one failure must not strand the rest, the
    /// way it would for a same-kind `RenameManyModel` batch. Successes are
    /// grouped by kind into one `FileHistory.record*` call each, since one
    /// undo entry cannot mix different `Action` cases.
    func execute() async {
        guard canExecute else { return }
        status = .executing
        revalidate()
        guard isContentReadyToRun else { status = .reviewing; return }

        var failed: Set<UUID> = []
        var moveRecords: [(from: URL, to: URL)] = []
        var copyRecords: [(from: URL, to: URL)] = []
        var renameRecords: [(from: URL, to: URL)] = []
        var trashRecords: [(original: URL, trashed: URL)] = []
        var permissionRecords: [(url: URL, before: mode_t, after: mode_t)] = []
        var ownerRecords: [(url: URL, beforeOwner: String?, beforeGroup: String?,
                            afterOwner: String?, afterGroup: String?)] = []
        var symlinksCreated: [URL] = []
        var directoriesCreated: [URL] = []
        var tagRecords: [(url: URL, name: String, before: Data?, after: Data?)] = []
        var xattrRecords: [(url: URL, name: String, before: Data?, after: Data?)] = []
        // Attribute changes refused because the item is read-only, settled
        // together after the loop with one question rather than one per row.
        var refusedAttributeRows: [RefusedAttributeWrite] = []
        // A plain chown to a different owner is refused for everyone but
        // root. Rather than asking for the administrator password once per
        // row, every row that hits this is collected here and settled in
        // one combined prompt after the loop -- see the comment there.
        var pendingPrivilegedOwnerRows: [(row: BatchOperationRow, owner: String, group: String?,
                                          source: URL, beforeOwner: String?, beforeGroup: String?)] = []

        for row in executionOrder where row.included {
            if let deps = dependencies[row.id], !deps.isDisjoint(with: failed) {
                rowResults[row.id] = "Skipped: depends on another row that failed."
                failed.insert(row.id)
                continue
            }

            switch row.kind {
            case .move:
                guard let source = row.source, let target = row.targetPath else { continue }
                if let error = await FileOperations.shared.transferOne(
                    source, to: target, kind: .move, overwrite: true) {
                    rowResults[row.id] = error
                    failed.insert(row.id)
                } else {
                    rowResults[row.id] = "Moved."
                    moveRecords.append((source, target))
                }

            case .copy:
                guard let source = row.source, let target = row.targetPath else { continue }
                if let error = await FileOperations.shared.transferOne(
                    source, to: target, kind: .copy, overwrite: true) {
                    rowResults[row.id] = error
                    failed.insert(row.id)
                } else {
                    rowResults[row.id] = "Copied."
                    copyRecords.append((source, target))
                }

            case .rename:
                guard let source = row.source, let newName = row.newName else { continue }
                do {
                    let result = try await FileOperations.shared.rename(source, to: newName)
                    rowResults[row.id] = "Renamed."
                    renameRecords.append((source, result))
                } catch {
                    rowResults[row.id] = error.localizedDescription
                    failed.insert(row.id)
                }

            case .trash:
                guard let source = row.source else { continue }
                let (outcome, moved) = await FileOperations.shared.trashRecording([source])
                if let first = moved.first, outcome.isCompleteSuccess {
                    rowResults[row.id] = "Moved to Trash."
                    trashRecords.append(first)
                } else {
                    rowResults[row.id] = outcome.failures.first?.message ?? "Could not move to Trash."
                    failed.insert(row.id)
                }

            case .deletePermanent:
                guard let source = row.source else { continue }
                let outcome = await FileOperations.shared.deleteOutright([source])
                if outcome.isCompleteSuccess {
                    rowResults[row.id] = "Deleted."
                } else {
                    rowResults[row.id] = outcome.failures.first?.message ?? "Could not delete."
                    failed.insert(row.id)
                }

            case .setPermissions:
                guard let source = row.source, let mode = row.mode else { continue }
                let before = (try? FileOperations.currentMode(of: source)) ?? 0
                if before & 0o7777 == mode & 0o7777 {
                    rowResults[row.id] = "Unchanged: already \(FileOperations.rwxString(mode))."
                    continue
                }
                let outcome = await FileOperations.shared.setPermissions(mode, mask: 0o7777, for: [source])
                if outcome.isCompleteSuccess {
                    rowResults[row.id] = "Permissions set."
                    permissionRecords.append((source, before, mode))
                } else {
                    rowResults[row.id] = outcome.failures.first?.message ?? "Could not set permissions."
                    failed.insert(row.id)
                }

            case .setOwner:
                guard let source = row.source else { continue }
                let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
                let beforeOwner = attributes?[.ownerAccountName] as? String
                let beforeGroup = attributes?[.groupOwnerAccountName] as? String
                let outcome = await FileOperations.shared.setOwnership(
                    owner: row.owner, group: row.group, for: [source])
                if outcome.isCompleteSuccess {
                    rowResults[row.id] = "Owner/group set."
                    ownerRecords.append((source, beforeOwner, beforeGroup, row.owner, row.group))
                } else if let owner = row.owner {
                    // Changing the owner is the half that needs root; a
                    // group-only change that fails this way genuinely means
                    // "you don't belong to that group," which no amount of
                    // retrying fixes, so only an owner change is queued here.
                    pendingPrivilegedOwnerRows.append(
                        (row, owner, row.group, source, beforeOwner, beforeGroup))
                } else {
                    rowResults[row.id] = outcome.failures.first?.message ?? "Could not set owner/group."
                    failed.insert(row.id)
                }

            case .createSymlink:
                guard let target = row.targetPath, let linkTarget = row.linkTarget else { continue }
                do {
                    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: linkTarget)
                    rowResults[row.id] = "Link created."
                    symlinksCreated.append(target)
                } catch {
                    rowResults[row.id] = error.localizedDescription
                    failed.insert(row.id)
                }

            case .createDirectory:
                guard let target = row.targetPath else { continue }
                do {
                    let created = try await FileOperations.shared.createDirectory(
                        named: target.lastPathComponent, in: target.deletingLastPathComponent())
                    rowResults[row.id] = "Folder created."
                    directoriesCreated.append(created)
                } catch {
                    rowResults[row.id] = error.localizedDescription
                    failed.insert(row.id)
                }

            case .setXattr, .removeXattr, .addTags, .removeTags, .setTags:
                guard let source = row.source else { continue }
                let writes: [XattrWrite]
                do {
                    writes = try row.attributeWrites(on: source)
                } catch {
                    rowResults[row.id] = (error as? ExtendedAttributes.Failure)?.message
                        ?? error.localizedDescription
                    failed.insert(row.id)
                    continue
                }
                guard !writes.isEmpty else {
                    rowResults[row.id] = "Unchanged: already so."
                    continue
                }
                let path = source.path
                let before = writes.map { ExtendedAttributes.data(of: path, name: $0.name) }
                if let failure = writes.lazy.compactMap({ $0.apply(to: path) }).first {
                    if failure.isPermissionDenied {
                        refusedAttributeRows.append(
                            RefusedAttributeWrite(row: row, url: source, writes: writes, before: before))
                    } else {
                        rowResults[row.id] = failure.message
                        failed.insert(row.id)
                    }
                    continue
                }
                rowResults[row.id] = row.kind.isTagChange ? "Tags set." : "Attribute set."
                if row.kind == .removeXattr { rowResults[row.id] = "Attribute removed." }
                let records = zip(writes, before).map {
                    (url: source, name: $0.name, before: $1,
                     after: ExtendedAttributes.data(of: path, name: $0.name))
                }
                if row.kind.isTagChange { tagRecords += records } else { xattrRecords += records }
            }
        }

        for settled in settleRefusedAttributeWrites(refusedAttributeRows) {
            rowResults[settled.item.row.id] = settled.message
            guard settled.succeeded else {
                failed.insert(settled.item.row.id)
                continue
            }
            let path = settled.item.url.path
            let records = zip(settled.item.writes, settled.item.before).map {
                (url: settled.item.url, name: $0.name, before: $1,
                 after: ExtendedAttributes.data(of: path, name: $0.name))
            }
            if settled.item.row.kind.isTagChange { tagRecords += records } else { xattrRecords += records }
        }

        // One administrator prompt for every owner change that needed root,
        // whatever owner or group each one asked for -- not one prompt per
        // row. The system's own prompt is the confirmation; nothing here
        // asks again first, matching how a single such change already works
        // from the Info window.
        if !pendingPrivilegedOwnerRows.isEmpty {
            let changes = pendingPrivilegedOwnerRows.map {
                (owner: $0.owner, group: $0.group, urls: [$0.source])
            }
            switch Privileged.chownMany(changes) {
            case .succeeded:
                for item in pendingPrivilegedOwnerRows {
                    rowResults[item.row.id] = "Owner/group set (administrator)."
                    ownerRecords.append((item.source, item.beforeOwner, item.beforeGroup,
                                        item.owner, item.group))
                }
            case .cancelled:
                for item in pendingPrivilegedOwnerRows {
                    rowResults[item.row.id] = "Cancelled: administrator authentication was not completed."
                    failed.insert(item.row.id)
                }
            case .failed(let message):
                for item in pendingPrivilegedOwnerRows {
                    rowResults[item.row.id] = message
                    failed.insert(item.row.id)
                }
            }
        }

        if !moveRecords.isEmpty { FileHistory.shared.recordMove(moveRecords) }
        if !copyRecords.isEmpty { FileHistory.shared.recordCopy(copyRecords) }
        if !renameRecords.isEmpty {
            FileHistory.shared.recordRenames(
                renameRecords, in: renameRecords[0].to.deletingLastPathComponent(),
                renames: renameRecords.count)
        }
        if !trashRecords.isEmpty { FileHistory.shared.recordTrash(trashRecords) }
        if !permissionRecords.isEmpty { FileHistory.shared.recordPermissions(permissionRecords) }
        if !ownerRecords.isEmpty { FileHistory.shared.recordOwnership(ownerRecords) }
        if !symlinksCreated.isEmpty { FileHistory.shared.recordCreation(.link, of: symlinksCreated) }
        if !directoriesCreated.isEmpty { FileHistory.shared.recordCreation(.newFolder, of: directoriesCreated) }
        if !tagRecords.isEmpty {
            let items = Set(tagRecords.map(\.url)).count
            FileHistory.shared.recordAttributes(
                tagRecords, name: "Tag Change",
                told: "The tags of \(items) item\(items == 1 ? "" : "s") were changed.")
        }
        if !xattrRecords.isEmpty {
            let items = Set(xattrRecords.map(\.url)).count
            FileHistory.shared.recordAttributes(
                xattrRecords, name: "Attribute Change",
                told: "Extended attributes of \(items) item\(items == 1 ? "" : "s") were changed.")
        }

        failedRows = failed
        status = .finished
    }
}

/// An attribute change a read-only item refused, waiting for the one
/// question that settles all of them.
struct RefusedAttributeWrite {
    let row: BatchOperationRow
    let url: URL
    let writes: [XattrWrite]
    /// The values before, for undo.
    let before: [Data?]
}

extension BatchOperationsModel {

    /// One question for every attribute change a read-only item refused --
    /// not one per row, which for a few hundred locked files would be a few
    /// hundred alerts. The answers are the Info window's, made for all of
    /// them at once: make the ones the person owns writable for the moment
    /// the change takes and restore their permissions straight after, or do
    /// the lot as an administrator, or leave them.
    func settleRefusedAttributeWrites(
        _ refused: [RefusedAttributeWrite]
    ) -> [(item: RefusedAttributeWrite, succeeded: Bool, message: String)] {
        guard !refused.isEmpty else { return [] }

        func ownedMode(_ url: URL) -> mode_t? {
            var info = stat()
            guard stat(url.path, &info) == 0, info.st_uid == getuid() else { return nil }
            return info.st_mode
        }
        let owned = refused.filter { ownedMode($0.url) != nil }

        let alert = NSAlert()
        alert.alertStyle = .warning
        let count = refused.count
        alert.messageText = count == 1
            ? "\u{201C}\(refused[0].url.lastPathComponent)\u{201D} does not allow its attributes to be changed."
            : "\(count) items do not allow their attributes to be changed."
        alert.informativeText = """
            They are read-only. Diptych can make the ones you own writable for the moment \
            the change takes and restore their permissions straight afterwards, or make \
            every change as an administrator.
            """
        enum Choice { case unlock, authenticate, skip }
        var choices: [Choice] = []
        if !owned.isEmpty {
            alert.addButton(withTitle: owned.count == count
                            ? "Unlock, Change, Restore"
                            : "Unlock the \(owned.count) I Own")
            choices.append(.unlock)
        }
        alert.addButton(withTitle: "Authenticate\u{2026}")
        choices.append(.authenticate)
        alert.addButton(withTitle: "Skip Them")
        choices.append(.skip)
        // Skipping is the safe default, so a stray Return changes nothing.
        alert.buttons.last?.keyEquivalent = "\r"
        alert.buttons.first?.keyEquivalent = ""
        let index = alert.runSelectable().rawValue
            - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let choice = choices.indices.contains(index) ? choices[index] : .skip

        switch choice {
        case .skip:
            return refused.map { ($0, false, "Skipped: the item is read-only.") }

        case .unlock:
            return refused.map { item in
                guard let mode = ownedMode(item.url) else {
                    return (item, false, "Skipped: read-only and not yours to unlock -- "
                                         + "Authenticate\u{2026} would have done it.")
                }
                let write = MetadataWrite.xattrs(item.writes, on: item.url,
                                                 action: "change its attributes")
                switch write.unlockedWrite(restoring: mode) {
                case .succeeded(let warning):
                    return (item, true, warning ?? "Changed (unlocked and restored).")
                case .cancelled:
                    return (item, false, "Cancelled.")
                case .failed(let message):
                    return (item, false, message)
                }
            }

        case .authenticate:
            let commands = refused.flatMap { item in
                item.writes.compactMap { $0.command(for: item.url.path) }
            }
            guard !commands.isEmpty else {
                return refused.map { ($0, true, "Unchanged: already so.") }
            }
            switch Privileged.run(commands.joined(separator: " && ")) {
            case .succeeded:
                // Read back here too: root is told "done" for an attribute
                // macOS keeps for itself, exactly as anyone else is.
                return refused.map { item in
                    let path = item.url.path
                    guard item.writes.allSatisfy({ $0.isInEffect(on: path) }) else {
                        let name = item.writes.first { !$0.isInEffect(on: path) }?.name ?? ""
                        return (item, false, ExtendedAttributes.protectedReason(for: name)
                                ?? "Reported as done, but the attribute is unchanged.")
                    }
                    return (item, true, "Changed (administrator).")
                }
            case .cancelled:
                return refused.map { ($0, false, "Cancelled: administrator authentication was not completed.") }
            case .failed(let message):
                return refused.map { ($0, false, message) }
            }
        }
    }
}

extension BatchOperationRow {

    /// The attribute writes this row comes to, worked out from the item as
    /// it is at this moment -- tags added to the tags it has now, not to the
    /// ones it had when the batch was proposed. Empty when there is nothing
    /// to do.
    func attributeWrites(on url: URL) throws -> [XattrWrite] {
        let path = url.path
        switch kind {
        case .setXattr:
            guard let name = xattrName, let value = xattrValue,
                  ExtendedAttributes.data(of: path, name: name) != value else { return [] }
            return [XattrWrite(name: name, data: value)]
        case .removeXattr:
            guard let name = xattrName,
                  ExtendedAttributes.data(of: path, name: name) != nil else { return [] }
            return [XattrWrite(name: name, data: nil)]
        case .addTags, .removeTags, .setTags:
            let current = Self.tags(of: url)
            let result = resultingTags(from: current)
            guard !Self.sameTags(result, current) else { return [] }
            return try FinderTag.writes(for: result, on: path)
        default:
            return []
        }
    }
}

/// Every `BatchOperationsModel` proposed this run, by id -- so a
/// `get_batch_status` call can find one after its window has been closed,
/// and so the `WindowGroup(for: UUID.self)` scene can look one up from just
/// the id SwiftUI hands it.
@MainActor
final class BatchOperationsStore {
    static let shared = BatchOperationsStore()
    private var models: [UUID: BatchOperationsModel] = [:]
    private init() {}

    func register(_ model: BatchOperationsModel) { models[model.batchId] = model }
    func model(for id: UUID) -> BatchOperationsModel? { models[id] }
}

// MARK: - Building rows from an MCP call

extension BatchOperationRow {

    /// "rwxr-xr-x" or octal ("755", "0755", "04755"). Only direction the
    /// project didn't already have -- `FileOperations.rwxString` goes the
    /// other way.
    static func parseMode(_ text: String) -> mode_t? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count == 9 {
            let c = Array(trimmed)
            guard c[0] == "r" || c[0] == "-", c[1] == "w" || c[1] == "-", "xsS-".contains(c[2]),
                  c[3] == "r" || c[3] == "-", c[4] == "w" || c[4] == "-", "xsS-".contains(c[5]),
                  c[6] == "r" || c[6] == "-", c[7] == "w" || c[7] == "-", "xtT-".contains(c[8])
            else { return nil }

            var mode: mode_t = 0
            if c[0] == "r" { mode |= 0o400 }
            if c[1] == "w" { mode |= 0o200 }
            switch c[2] {
            case "x": mode |= 0o100
            case "s": mode |= 0o100 | 0o4000
            case "S": mode |= 0o4000
            default: break
            }
            if c[3] == "r" { mode |= 0o040 }
            if c[4] == "w" { mode |= 0o020 }
            switch c[5] {
            case "x": mode |= 0o010
            case "s": mode |= 0o010 | 0o2000
            case "S": mode |= 0o2000
            default: break
            }
            if c[6] == "r" { mode |= 0o004 }
            if c[7] == "w" { mode |= 0o002 }
            switch c[8] {
            case "x": mode |= 0o001
            case "t": mode |= 0o001 | 0o1000
            case "T": mode |= 0o1000
            default: break
            }
            return mode
        }

        var octal = trimmed
        if octal.hasPrefix("0o") { octal.removeFirst(2) }
        guard !octal.isEmpty, octal.allSatisfy(\.isNumber) else { return nil }
        return mode_t(octal, radix: 8)
    }

    enum BuildResult { case unknownOp(String), row(BatchOperationRow) }

    /// One row from `propose_file_operations`' arguments. An unrecognized
    /// `op` fails the whole call (handled by the caller); anything else
    /// becomes a row, flagged in `problems` when a field is missing or
    /// unparseable rather than refusing the call outright -- fixable inline
    /// in the review window instead of round-tripping back to the agent.
    static func build(op: String, source: String?, target: String?,
                      linkTarget: String?, reason: String?,
                      name: String? = nil, value: String? = nil, encoding: String? = nil,
                      tags: [String]? = nil) -> BuildResult {
        guard let kind = BatchOperationKind(mcpName: op) else { return .unknownOp(op) }
        let row = BatchOperationRow(kind: kind)
        row.reason = reason
        let sourceURL = source.map { URL(fileURLWithPath: $0) }
        let targetURL = target.map { URL(fileURLWithPath: $0) }
        row.linkTarget = linkTarget.map { URL(fileURLWithPath: $0) }

        switch kind {
        case .move, .copy:
            row.source = sourceURL
            row.targetPath = targetURL
        case .rename:
            row.source = sourceURL
            if let target, !target.isEmpty, !target.contains("/") { row.newName = target }
        case .trash, .deletePermanent:
            row.source = sourceURL
        case .setPermissions:
            row.source = sourceURL
            row.mode = target.flatMap(Self.parseMode)
        case .setOwner:
            row.source = sourceURL
            if let target, !target.isEmpty {
                let parts = target.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let owner = parts.first.map(String.init) ?? ""
                let group = parts.count > 1 ? String(parts[1]) : ""
                row.owner = owner.isEmpty ? nil : owner
                row.group = group.isEmpty ? nil : group
            }
        case .createSymlink, .createDirectory:
            row.targetPath = targetURL
        case .setXattr, .removeXattr:
            row.source = sourceURL
            row.xattrName = name
            if kind == .setXattr {
                row.xattrText = value
                if let encoding {
                    if let known = XattrEncoding(rawValue: encoding.lowercased()) {
                        row.xattrEncoding = known
                    } else {
                        // A problem on the row rather than a refused call:
                        // fixable in the review window by picking one.
                        row.unknownEncoding = encoding
                    }
                }
            }
        case .addTags, .removeTags, .setTags:
            row.source = sourceURL
            row.tags = (tags ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
        }

        row.problems = row.computeProblems()
        return .row(row)
    }
}
