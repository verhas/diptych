import Foundation
import ImageIO

/// Edit ▸ Paste Special: one property of the file that was copied, made the
/// same on every selected item -- its permissions, attributes, dates, owner,
/// EXIF -- to bring a set of files in line with one of them.
///
/// The copied file is the one file URL on the clipboard, put there by Copy
/// here or in Finder. Every paste is one step in Undo, whatever it takes in.
enum PasteSpecial {

    enum Part: String, CaseIterable, Identifiable, Sendable {
        case permissions, attributes, acl, modified, created, owner, group, location, exif, all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .permissions: "Permissions"
            case .attributes: "Extended Attributes"
            case .acl: "Access Control List"
            case .modified: "Modified Date"
            case .created: "Created Date"
            case .owner: "Owner"
            case .group: "Group"
            case .location: "Location"
            case .exif: "EXIF"
            case .all: "All of the Above"
            }
        }

        /// In the sentence Undo shows: "the permissions of ... were made".
        var phrase: String {
            switch self {
            case .permissions: "permissions"
            case .attributes: "extended attributes"
            case .acl: "access control list"
            case .modified: "modification date"
            case .created: "creation date"
            case .owner: "owner"
            case .group: "group"
            case .location: "location"
            case .exif: "EXIF"
            case .all: "permissions, attributes, access control list, dates, owner, group "
                + "and EXIF"
            }
        }

        /// The menu, in groups between dividers.
        static let menu: [[Part]] = [
            [.permissions, .attributes, .acl],
            [.modified, .created],
            [.owner, .group],
            [.location, .exif],
            [.all],
        ]
    }

    /// The copied file, as far as the menu has to know it.
    struct Source: Equatable, Sendable {
        let url: URL
        let hasExif: Bool
        let hasLocation: Bool

        /// Read now, for the menu: only the image's header, and only of a
        /// kind whose EXIF can be written anyway.
        static func read(_ url: URL) -> Source {
            let values = canTakeExif(url) ? ExifWrite.values(of: url) : nil
            return Source(url: url,
                          hasExif: values.map { !exifKeys(in: $0, locationOnly: false).isEmpty }
                              ?? false,
                          hasLocation: values.map(hasCoordinates) ?? false)
        }
    }

    /// A JPEG or HEIC file of its own -- not a folder, not a link.
    static func canTakeExif(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
            && ExifFields.canEdit(url)
    }

    /// Location and EXIF only when the copied file has them and every
    /// selected file can take them; the rest whenever something is copied
    /// and something else selected.
    static func isAvailable(_ part: Part, source: Source?, targets: [URL]) -> Bool {
        guard let source else { return false }
        let others = targets.filter { !FileOperations.samePath($0, source.url) }
        guard !others.isEmpty else { return false }
        switch part {
        case .exif: return source.hasExif && others.allSatisfy(canTakeExif)
        case .location: return source.hasLocation && others.allSatisfy(canTakeExif)
        default: return true
        }
    }

    // MARK: - Pasting

    struct Result: Sendable {
        var changed: [URL] = []
        var failures: [String] = []
    }

    /// Done, and recorded as one step in Undo. A file already the same is
    /// left alone and not counted.
    @MainActor
    static func paste(_ part: Part, from source: URL, to targets: [URL],
                      history: FileHistory = .shared) async -> Result {
        let targets = targets.filter { !FileOperations.samePath($0, source) }
        var result = Result()
        guard !targets.isEmpty else { return result }

        // The bytes first: rewriting a file's EXIF sets its modification
        // date, which a date pasted after it then puts right.
        var rewritten: [(url: URL, before: URL)] = []
        let exif: Bool? = switch part {
        case .exif: false
        case .location: true
        case .all: Source.read(source).hasExif ? false : nil
        default: nil
        }
        if let locationOnly = exif {
            let values = ExifWrite.values(of: source) ?? [:]
            let box = ValuesBox(values)
            let saved = await ExifEditorModel.rewriteInPlace(targets.filter(canTakeExif)) {
                data, name throws(ExifWrite.Failure) in
                try rewrite(data, name: name, from: box.values, locationOnly: locationOnly)
            }
            rewritten = saved.done
            result.failures += saved.failures
        }

        let steps = await BlockingWork.run { () -> [Step] in
            switch part {
            case .permissions: [permissions(from: source, to: targets)]
            case .attributes: [attributes(from: source, to: targets)]
            case .acl: [acl(from: source, to: targets)]
            case .modified: [dates([.modified], from: source, to: targets)]
            case .created: [dates([.created], from: source, to: targets)]
            case .owner: [ownership(owner: true, group: false, from: source, to: targets)]
            case .group: [ownership(owner: false, group: true, from: source, to: targets)]
            case .location, .exif: []
            case .all: [
                attributes(from: source, to: targets),
                acl(from: source, to: targets),
                permissions(from: source, to: targets),
                ownership(owner: true, group: true, from: source, to: targets),
                dates([.modified, .created], from: source, to: targets),
            ]
            }
        }

        var actions: [FileHistory.Action] = []
        if !rewritten.isEmpty {
            // Read now, after everything: what Undo finds has to be what the
            // paste left, dates included.
            actions.append(.contents(rewritten.map {
                FileHistory.ContentChange(url: $0.url, identity: FileHistory.identity(of: $0.url),
                                          modified: FileHistory.modified($0.url),
                                          snapshot: $0.before)
            }))
            result.changed += rewritten.map(\.url)
        }
        for step in steps {
            if !step.undo.isEmpty { actions.append(step.undo) }
            result.changed += step.changed
            result.failures += step.failures
        }
        result.changed = Array(NSOrderedSet(array: result.changed)) as? [URL] ?? result.changed

        if !actions.isEmpty {
            history.record(part == .all ? "Paste Special" : "Paste \(part.title)",
                                      told: told(part, from: source, to: result.changed),
                                      actions.count == 1 ? actions[0] : .several(actions))
        }
        return result
    }

    private static func told(_ part: Part, from source: URL, to changed: [URL]) -> String {
        let from = FileHistory.quoted(source.lastPathComponent)
        guard let first = changed.first else { return "" }
        return changed.count == 1
            ? "The \(part.phrase) of \(FileHistory.quoted(first.lastPathComponent)) in "
              + "\(FileHistory.folder(of: first)) were made those of \(from)."
            : "The \(part.phrase) of \(changed.count) items in \(FileHistory.folder(of: first)) "
              + "were made those of \(from): \(FileHistory.Plan.names(changed))."
    }

    /// What one kind of change did, and the action that undoes it.
    struct Step: Sendable {
        var undo: FileHistory.Action
        var changed: [URL] = []
        var failures: [String] = []
    }

    private final class ValuesBox: @unchecked Sendable {
        let values: [ExifKey: Any]
        init(_ values: [ExifKey: Any]) { self.values = values }
    }

    private static func name(_ url: URL) -> String { FileHistory.quoted(url.lastPathComponent) }

    // MARK: - Each kind

    nonisolated static func permissions(from source: URL, to targets: [URL]) -> Step {
        var step = Step(undo: .permissions([]))
        guard let wanted = try? FileOperations.currentMode(of: source) else {
            step.failures.append("The permissions of \(name(source)) could not be read.")
            return step
        }
        let mode = wanted & 0o7777
        var changes: [FileHistory.PermissionChange] = []
        for target in targets {
            guard let before = try? FileOperations.currentMode(of: target) else {
                step.failures.append("The permissions of \(name(target)) could not be read.")
                continue
            }
            guard before & 0o7777 != mode else { continue }
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: mode)],
                    ofItemAtPath: FileOperations.attributeTarget(target))
                changes.append(.init(url: target, from: mode, to: before & 0o7777))
            } catch {
                step.failures.append("The permissions of \(name(target)) could not be set: "
                                     + error.localizedDescription)
            }
        }
        step.undo = .permissions(changes)
        step.changed = changes.map(\.url)
        return step
    }

    /// Made the same as the copied file's: its attributes set, the ones it
    /// does not have taken away. What macOS keeps for itself is left, and so
    /// is a value no program may read.
    nonisolated static func attributes(from source: URL, to targets: [URL]) -> Step {
        let wanted = Dictionary(ExtendedAttributes.all(of: source.path).map { ($0.name, $0.data) },
                                uniquingKeysWith: { a, _ in a })
        var changes: [FileHistory.AttributeChange] = []
        var failures: [String] = []
        for target in targets {
            let have = Dictionary(ExtendedAttributes.all(of: target.path).map { ($0.name, $0.data) },
                                  uniquingKeysWith: { a, _ in a })
            let names = Set(wanted.keys).union(have.keys)
                .filter { ExtendedAttributes.protectedReason(for: $0) == nil }
                .sorted()
            for attribute in names {
                // There and unreadable, on either side: not ours to touch.
                if let value = wanted[attribute], value == nil { continue }
                if let value = have[attribute], value == nil { continue }
                let want = wanted[attribute] ?? nil
                let had = have[attribute] ?? nil
                guard want != had else { continue }
                if let failure = XattrWrite(name: attribute, data: want).apply(to: target.path) {
                    failures.append("\(FileHistory.quoted(attribute)) on \(name(target)) could not "
                                    + "be \(want == nil ? "removed" : "set"): \(failure.message)")
                } else {
                    changes.append(.init(url: target, name: attribute, from: want, to: had))
                }
            }
        }
        return Step(undo: .attributes(changes),
                    changed: Array(NSOrderedSet(array: changes.map(\.url))) as? [URL] ?? [],
                    failures: failures)
    }

    /// None on the copied file takes it off the others.
    nonisolated static func acl(from source: URL, to targets: [URL]) -> Step {
        let wanted = AccessControl.text(of: FileOperations.attributeTarget(source))
        var changes: [FileHistory.ACLChange] = []
        var failures: [String] = []
        for target in targets {
            let path = FileOperations.attributeTarget(target)
            let before = AccessControl.text(of: path)
            guard before != wanted else { continue }
            if let failure = AccessControl.setText(wanted ?? "", on: path) {
                failures.append("The access control list of \(name(target)) could not be set: "
                                + failure.message)
            } else {
                changes.append(.init(url: target, from: wanted, to: before))
            }
        }
        return Step(undo: .acls(changes), changed: changes.map(\.url), failures: failures)
    }

    /// To the nanosecond: the dates are the file system's, not `Date`'s.
    nonisolated static func dates(_ which: [FileHistory.DateChange.Which], from source: URL,
                                  to targets: [URL]) -> Step {
        var changes: [FileHistory.DateChange] = []
        var failures: [String] = []
        for kind in which {
            guard let wanted = FileHistory.exactDate(kind, of: source) else {
                failures.append("The \(kind == .created ? "creation" : "modification") date of "
                                + "\(name(source)) could not be read.")
                continue
            }
            for target in targets {
                guard let before = FileHistory.exactDate(kind, of: target), before != wanted else {
                    continue
                }
                let born = FileHistory.exactDate(.created, of: target)
                do {
                    try FileHistory.setDate(kind, wanted, of: target)
                    changes.append(.init(url: target, which: kind, from: wanted.date,
                                         to: before.date, exactTo: before))
                    // A modification date before the creation date takes the
                    // creation date back with it -- macOS has no file made
                    // after it was last changed. Undo puts that back too,
                    // after the modification date.
                    if kind == .modified, let born,
                       let now = FileHistory.exactDate(.created, of: target), now != born {
                        changes.append(.init(url: target, which: .created, from: now.date,
                                             to: born.date, exactTo: born))
                    }
                } catch {
                    failures.append("The date of \(name(target)) could not be set: "
                                    + error.localizedDescription)
                }
            }
        }
        return Step(undo: .dates(changes),
                    changed: Array(NSOrderedSet(array: changes.map(\.url))) as? [URL] ?? [],
                    failures: failures)
    }

    /// Plain `chown`: giving a file to somebody else takes an administrator,
    /// and that is said rather than asked for, once per file.
    nonisolated static func ownership(owner: Bool, group: Bool, from source: URL,
                                      to targets: [URL]) -> Step {
        var step = Step(undo: .ownership([]))
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: FileOperations.attributeTarget(source)) else {
            step.failures.append("The owner of \(name(source)) could not be read.")
            return step
        }
        let wantedOwner = owner ? attributes[.ownerAccountName] as? String : nil
        let wantedGroup = group ? attributes[.groupOwnerAccountName] as? String : nil
        var changes: [FileHistory.OwnershipChange] = []
        for target in targets {
            let path = FileOperations.attributeTarget(target)
            guard let now = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
            let hadOwner = now[.ownerAccountName] as? String
            let hadGroup = now[.groupOwnerAccountName] as? String
            var set: [FileAttributeKey: Any] = [:]
            if let wantedOwner, wantedOwner != hadOwner { set[.ownerAccountName] = wantedOwner }
            if let wantedGroup, wantedGroup != hadGroup { set[.groupOwnerAccountName] = wantedGroup }
            guard !set.isEmpty else { continue }
            do {
                try FileManager.default.setAttributes(set, ofItemAtPath: path)
                let ownerChanged = set[.ownerAccountName] != nil
                let groupChanged = set[.groupOwnerAccountName] != nil
                changes.append(.init(url: target,
                                     fromOwner: ownerChanged ? wantedOwner : nil,
                                     fromGroup: groupChanged ? wantedGroup : nil,
                                     toOwner: ownerChanged ? hadOwner : nil,
                                     toGroup: groupChanged ? hadGroup : nil))
            } catch {
                step.failures.append("\(name(target)) could not be given to "
                                     + "\(FileHistory.quoted([wantedOwner, wantedGroup].compactMap { $0 }.joined(separator: ":"))): "
                                     + "\(error.localizedDescription). Only an administrator can "
                                     + "do that; Get Info\u{2019}s Change Owner\u{2026} asks for a password.")
            }
        }
        step.undo = .ownership(changes)
        step.changed = changes.map(\.url)
        return step
    }

    // MARK: - EXIF

    /// What a picture says about itself and no other: which way up it is
    /// and how big. Never copied.
    nonisolated static let ownFields: Set<String> = [
        kCGImagePropertyTIFFOrientation as String,
        kCGImagePropertyExifPixelXDimension as String,
        kCGImagePropertyExifPixelYDimension as String,
    ]

    /// The fields that are copied, of those `values` has: every one that
    /// can be written, or with `catalogueOnly` only the ones the EXIF editor
    /// knows.
    nonisolated static func exifKeys(in values: [ExifKey: Any], locationOnly: Bool,
                                     catalogueOnly: Bool = false) -> Set<ExifKey> {
        let known = Set(ExifFields.catalogue.map(\.key))
        return Set(values.compactMap { key, value -> ExifKey? in
            guard !locationOnly || key.group == .gps,
                  !ownFields.contains(key.name), !ExifFields.computed.contains(key.name),
                  ExifFields.kind(of: value) != .readOnly,
                  !catalogueOnly || known.contains(key) else { return nil }
            return key
        })
    }

    nonisolated static func hasCoordinates(_ values: [ExifKey: Any]) -> Bool {
        values[ExifKey(group: .gps, name: kCGImagePropertyGPSLatitude as String)] != nil
            && values[ExifKey(group: .gps, name: kCGImagePropertyGPSLongitude as String)] != nil
    }

    /// The changes making a picture's EXIF -- or only its location -- the
    /// copied one's: its fields set, the ones it lacks taken out.
    nonisolated static func exifChanges(from source: [ExifKey: Any], to target: [ExifKey: Any],
                                        locationOnly: Bool, catalogueOnly: Bool = false)
        -> [ExifKey: ExifWrite.Change] {
        var changes: [ExifKey: ExifWrite.Change] = [:]
        let wanted = exifKeys(in: source, locationOnly: locationOnly, catalogueOnly: catalogueOnly)
        for key in wanted {
            guard let value = source[key] else { continue }
            if let had = target[key], ExifFields.same(had, value) { continue }
            changes[key] = .set(value)
        }
        for key in exifKeys(in: target, locationOnly: locationOnly, catalogueOnly: catalogueOnly)
        where source[key] == nil {
            changes[key] = .remove
        }
        return changes
    }

    /// One picture's bytes with the copied EXIF; nil when it has it already.
    /// A field ImageIO will not take back makes the whole rewrite fail, so
    /// a second try copies only the fields the EXIF editor knows.
    nonisolated static func rewrite(_ data: Data, name: String, from source: [ExifKey: Any],
                                    locationOnly: Bool) throws(ExifWrite.Failure) -> Data? {
        guard let image = CGImageSourceCreateWithData(data as CFData, nil),
              let target = ExifWrite.values(in: image) else {
            throw ExifWrite.Failure(message: "\u{201C}\(name)\u{201D} could not be read as an image.")
        }
        let changes = exifChanges(from: source, to: target, locationOnly: locationOnly)
        guard !changes.isEmpty else { return nil }
        do {
            return try ExifWrite.rewrite(data, name: name, changes: changes)
        } catch {
            let known = exifChanges(from: source, to: target, locationOnly: locationOnly,
                                    catalogueOnly: true)
            guard !known.isEmpty, known.count < changes.count else { throw error }
            return try ExifWrite.rewrite(data, name: name, changes: known)
        }
    }
}
