import Foundation

/// Undo and Redo for what Diptych does to files: copy, move, rename, create,
/// link, and change permissions.
///
/// Not the system's `UndoManager`. An undo there runs the moment it is chosen
/// and has to register its redo on the spot -- but here every step first
/// *asks*, because undoing a copy puts files in the Trash and undoing a move
/// moves them again, and a keystroke is too cheap a way to do either unseen.
/// A question that can be answered "Cancel" has to leave the step where it
/// was, and `UndoManager` has already moved it by then.
///
/// One history for the whole application, as in Finder: the files are the
/// same files whichever window changed them. Kept in memory only -- after a
/// restart the paths it holds describe a world that may have moved on.
///
/// Every step is checked against the disk before it is offered, and nothing
/// is ever done to an item that is not the one the step recorded: a file
/// replaced by another of the same name is left alone and said to be.
/// Undoing never deletes: what undoing a copy or a new file takes away goes
/// to the Trash, and redoing it takes it back out.
@MainActor
@Observable
final class FileHistory {

    static let shared = FileHistory()
    static let depth = 50

    init() {}

    // MARK: - Steps

    /// Which file it is, independent of its name: renaming or moving it on one
    /// volume keeps it, and a different file put in its place does not have it.
    struct Identity: Equatable, Sendable {
        let device: Int
        let inode: UInt64
    }

    struct Relocation: Sendable {
        let from: URL
        let to: URL
        let identity: Identity?
        /// The operation that is being reversed overwrote something, which is
        /// gone for good and cannot come back with it.
        var replacedSomething = false
    }

    struct Removal: Sendable {
        let url: URL
        let identity: Identity?
        let modified: Date?
        var replacedSomething = false
    }

    struct PermissionChange: Sendable {
        let url: URL
        /// What it should be now, for the step to apply cleanly.
        let from: mode_t
        let to: mode_t
    }

    struct OwnershipChange: Sendable {
        let url: URL
        /// Who it should belong to now, for the step to apply cleanly. Nil
        /// where this step is not about that half of it.
        let fromOwner: String?
        let fromGroup: String?
        let toOwner: String?
        let toGroup: String?
    }

    /// What doing a step does. Undo and redo are the same three things in
    /// opposite directions.
    enum Action: Sendable {
        case relocate([Relocation])
        case trash([Removal])
        case permissions([PermissionChange])
        case ownership([OwnershipChange])
    }

    struct Entry: Sendable, Identifiable {
        /// "Move", "Copy", "Rename" -- what the menu says after Undo or Redo.
        let name: String
        /// What was done, in the past tense, as the question shows it:
        /// "draft.txt" was renamed to "final.txt" in "~/Documents".
        ///
        /// Written when it happens, not worked out from the step afterwards:
        /// at that moment both names are known and neither has to be guessed
        /// from a reversal. It is the same sentence for the undo and for the
        /// redo, because it describes the operation, not the direction.
        let told: String
        let action: Action
        let id = UUID()
    }

    private(set) var undoable: [Entry] = []
    private(set) var redoable: [Entry] = []
    private(set) var isBusy = false

    var undoName: String? { undoable.last?.name }
    var redoName: String? { redoable.last?.name }

    /// A new operation. What could be redone no longer follows from here.
    func record(_ name: String, told: String, _ action: Action) {
        guard !action.isEmpty else { return }
        undoable.append(Entry(name: name, told: told, action: action))
        if undoable.count > Self.depth { undoable.removeFirst(undoable.count - Self.depth) }
        redoable.removeAll()
    }

    func forgetEverything() {
        undoable.removeAll()
        redoable.removeAll()
    }

    // MARK: - Recording, with what undoing each needs

    func recordCopy(_ pairs: [(from: URL, to: URL)], replacing: Set<URL> = []) {
        guard let first = pairs.first else { return }
        record("Copy",
               told: pairs.count == 1
                   ? "\(quoted(first.to.lastPathComponent)) was copied to \(folder(of: first.to))."
                   : "\(pairs.count) items were copied to \(folder(of: first.to)): "
                     + "\(names(pairs.map(\.to))).",
               removals(pairs.map(\.to), replacing: replacing))
    }

    func recordMove(_ pairs: [(from: URL, to: URL)], replacing: Set<URL> = []) {
        guard let first = pairs.first else { return }
        let sameSource = pairs.allSatisfy {
            FileOperations.samePath($0.from.deletingLastPathComponent(),
                                    first.from.deletingLastPathComponent())
        }
        let where_ = sameSource ? "from \(folder(of: first.from)) " : ""
        record("Move",
               told: pairs.count == 1
                   ? "\(quoted(first.to.lastPathComponent)) was moved from "
                     + "\(folder(of: first.from)) to \(folder(of: first.to))."
                   : "\(pairs.count) items were moved \(where_)to \(folder(of: first.to)): "
                     + "\(names(pairs.map(\.to))).",
               relocations(pairs, replacing: replacing))
    }

    /// A folder's worth of renames as one step.
    ///
    /// The relocations are the applied steps in reverse, each turned round, so
    /// undoing runs them in an order where every name is free when it is
    /// wanted -- which is the same ordering problem the rename itself solved,
    /// read backwards.
    func recordRenames(_ applied: [(from: URL, to: URL)], in folder: URL, renames: Int) {
        guard !applied.isEmpty else { return }
        record("Rename Many",
               told: "\(renames) item\(renames == 1 ? "" : "s") in \(Self.folder(of: applied[0].to)) "
                   + "\(renames == 1 ? "was" : "were") renamed.",
               .relocate(applied.reversed().map {
                   Relocation(from: $0.to, to: $0.from, identity: Self.identity(of: $0.to))
               }))
    }

    func recordRename(from old: URL, to new: URL) {
        record("Rename",
               told: "\(quoted(old.lastPathComponent)) was renamed to "
                   + "\(quoted(new.lastPathComponent)) in \(folder(of: new)).",
               relocations([(old, new)]))
    }

    enum Creation: Sendable {
        case newFile, newFolder, clipboard, link

        var name: String {
            switch self {
            case .newFile:   "New File"
            case .newFolder: "New Folder"
            case .clipboard: "New from Clipboard"
            case .link:      "Link"
            }
        }

        func told(_ urls: [URL], folder: String, names: String) -> String {
            switch self {
            case .newFile, .newFolder:
                "\(names) was created in \(folder)."
            case .clipboard:
                "\(names) was created in \(folder) from the clipboard."
            case .link:
                urls.count == 1
                    ? "\(names) was linked in \(folder)."
                    : "\(urls.count) links were made in \(folder): \(names)."
            }
        }
    }

    func recordCreation(_ kind: Creation, of urls: [URL]) {
        guard let first = urls.first else { return }
        record(kind.name,
               told: kind.told(urls, folder: folder(of: first), names: names(urls)),
               removals(urls))
    }

    /// Moving to the Trash, which the Trash itself makes reversible: the item
    /// is still there, under a name macOS may have had to change.
    func recordTrash(_ moved: [(original: URL, trashed: URL)]) {
        guard let first = moved.first else { return }
        record("Move to Trash",
               told: moved.count == 1
                   ? "\(quoted(first.original.lastPathComponent)) in "
                     + "\(folder(of: first.original)) was moved to the Trash."
                   : "\(moved.count) items in \(folder(of: first.original)) were moved to "
                     + "the Trash: \(names(moved.map(\.original))).",
               .relocate(moved.map {
                   Relocation(from: $0.trashed, to: $0.original,
                              identity: Self.identity(of: $0.trashed))
               }))
    }

    func recordPermissions(_ changes: [(url: URL, before: mode_t, after: mode_t)]) {
        let real = changes.filter { $0.before & 0o7777 != $0.after & 0o7777 }
        guard let first = real.first else { return }
        let told = real.count == 1
            ? "The permissions of \(quoted(first.url.lastPathComponent)) in "
              + "\(folder(of: first.url)) were changed from "
              + "\(FileOperations.rwxString(first.before)) to "
              + "\(FileOperations.rwxString(first.after))."
            : "The permissions of \(real.count) items in \(folder(of: first.url)) were "
              + "changed to \(FileOperations.rwxString(first.after)): "
              + "\(names(real.map(\.url)))."
        record("Permission Change", told: told, .permissions(real.map {
            PermissionChange(url: $0.url, from: $0.after, to: $0.before)
        }))
    }

    /// Owner or group, or both at once.
    ///
    /// Undoing one can be refused where making it was allowed: handing a file
    /// to somebody else can put it beyond reach of the person who did it. That
    /// is reported when it happens and stops nothing else.
    func recordOwnership(_ changes: [(url: URL, beforeOwner: String?, beforeGroup: String?,
                                      afterOwner: String?, afterGroup: String?)]) {
        let real = changes.filter {
            ($0.afterOwner != nil && $0.afterOwner != $0.beforeOwner)
                || ($0.afterGroup != nil && $0.afterGroup != $0.beforeGroup)
        }
        guard let first = real.first else { return }
        let what: String
        let name: String
        if first.afterOwner != nil, first.afterGroup != nil {
            what = "owner and group"
            name = "Owner Change"
        } else if first.afterOwner != nil {
            what = "owner"
            name = "Owner Change"
        } else {
            what = "group"
            name = "Group Change"
        }
        let to = [first.afterOwner, first.afterGroup].compactMap { $0 }.joined(separator: ":")
        let from = [first.afterOwner == nil ? nil : first.beforeOwner,
                    first.afterGroup == nil ? nil : first.beforeGroup]
            .compactMap { $0 }.joined(separator: ":")
        let told = real.count == 1
            ? "The \(what) of \(quoted(first.url.lastPathComponent)) in "
              + "\(folder(of: first.url)) was changed"
              + (from.isEmpty ? "" : " from \(quoted(from))") + " to \(quoted(to))."
            : "The \(what) of \(real.count) items in \(folder(of: first.url)) was changed "
              + "to \(quoted(to)): \(names(real.map(\.url)))."
        record(name, told: told, .ownership(real.map {
            OwnershipChange(url: $0.url,
                            fromOwner: $0.afterOwner, fromGroup: $0.afterGroup,
                            toOwner: $0.afterOwner == nil ? nil : $0.beforeOwner,
                            toGroup: $0.afterGroup == nil ? nil : $0.beforeGroup)
        }))
    }

    private func removals(_ urls: [URL], replacing: Set<URL> = []) -> Action {
        .trash(urls.map {
            Removal(url: $0, identity: Self.identity(of: $0), modified: Self.modified($0),
                    replacedSomething: replacing.contains($0))
        })
    }

    private func relocations(_ pairs: [(from: URL, to: URL)],
                             replacing: Set<URL> = []) -> Action {
        .relocate(pairs.map {
            Relocation(from: $0.to, to: $0.from, identity: Self.identity(of: $0.to),
                       replacedSomething: replacing.contains($0.to))
        })
    }

    private func quoted(_ text: String) -> String { Self.quoted(text) }
    private func folder(of url: URL) -> String { Self.folder(of: url) }
    private func names(_ urls: [URL]) -> String { Plan.names(urls) }

    // MARK: - Undo and redo

    enum Direction: Sendable { case undo, redo }

    /// What a step would do right now: the parts that can be done, and why the
    /// rest cannot. `Sendable`, so tests and the question can look at it.
    struct Plan: Sendable {
        let direction: Direction
        let entry: Entry
        /// The step reduced to what can still be done.
        let doable: Action
        /// Why some of it cannot be done. Left exactly as it is.
        let problems: [String]
        /// Things worth knowing that do not stop it.
        let warnings: [String]

        var title: String {
            "\(direction == .undo ? "Undo" : "Redo") \(entry.name)"
        }
    }

    func plan(_ direction: Direction) -> Plan? {
        guard let entry = (direction == .undo ? undoable : redoable).last else { return nil }
        return Self.plan(entry, direction: direction)
    }

    /// Undo or redo the last step, after `confirm` says yes.
    ///
    /// Returns where the items it touched now are, so the panes can select
    /// them. A step that turns out to have nothing left that can be done is
    /// dropped: it never will be doable again.
    /// What one step, or a set of them, came to.
    struct Result: Sendable {
        var touched: [URL] = []
        var carriedOut: [String] = []
        var failures: [String] = []
    }

    @discardableResult
    func perform(_ direction: Direction,
                 confirm: (Plan) async -> Bool) async -> Result {
        guard !isBusy, let plan = plan(direction) else { return Result() }
        guard await confirm(plan) else { return Result() }
        // Asked in the meantime? The plan may be about an older world.
        guard !isBusy else { return Result() }

        isBusy = true
        defer { isBusy = false }

        let index = (direction == .undo ? undoable : redoable).count - 1
        return await carryOut([(direction, index)])
    }

    /// Several steps at once, chosen by the user: the indices into `undoable`
    /// and `redoable` as they stand now.
    ///
    /// Newest first in both lists, which is the only order in which steps can
    /// build on each other. A step that cannot be carried out is reported and
    /// the rest go ahead -- one refusal must not strand everything behind it.
    func performMany(undo: Set<Int>, redo: Set<Int>) async -> Result {
        guard !isBusy else { return Result() }
        isBusy = true
        defer { isBusy = false }

        let steps = undo.sorted(by: >).map { (Direction.undo, $0) }
            + redo.sorted(by: >).map { (Direction.redo, $0) }
        return await carryOut(steps)
    }

    /// Takes the steps out by identity rather than by index, since each one
    /// carried out shifts the positions of the rest.
    private func carryOut(_ steps: [(Direction, Int)]) async -> Result {
        let chosen: [(Direction, Entry)] = steps.compactMap { direction, index in
            let list = direction == .undo ? undoable : redoable
            guard list.indices.contains(index) else { return nil }
            return (direction, list[index])
        }

        var result = Result()
        for (direction, entry) in chosen {
            let plan = Self.plan(entry, direction: direction)
            remove(entry, from: direction)

            guard !plan.doable.isEmpty else {
                result.failures += plan.problems.isEmpty
                    ? ["\(entry.name) could not be \(direction == .undo ? "undone" : "redone")."]
                    : plan.problems
                continue
            }

            let done = await Self.run(plan.doable)
            result.touched += done.touched
            result.failures += done.failures + plan.problems
            if !done.inverse.isEmpty {
                result.carriedOut.append(entry.name)
                let back = Entry(name: entry.name, told: entry.told, action: done.inverse)
                if direction == .undo { redoable.append(back) } else { undoable.append(back) }
            }
        }
        return result
    }

    private func remove(_ entry: Entry, from direction: Direction) {
        if direction == .undo {
            undoable.removeAll { $0.id == entry.id }
        } else {
            redoable.removeAll { $0.id == entry.id }
        }
    }

    // MARK: - Checking

    nonisolated static func plan(_ entry: Entry, direction: Direction) -> Plan {
        var problems: [String] = []
        var warnings: [String] = []
        let doable: Action

        switch entry.action {
        case .relocate(let moves):
            var ok: [Relocation] = []
            // The steps run in the order they are listed, so each is checked
            // against what the ones before it will have done: reversing a
            // folder's worth of renames is a chain, where the name a step
            // wants is occupied right now and free by the time it runs, and
            // where a file that has stepped aside does not exist yet.
            var freedEarlier: Set<String> = []
            var arrivesEarlier: Set<String> = []

            for move in moves {
                let name = quoted(move.from.lastPathComponent)
                let from = FileOperations.canonicalPath(move.from)
                let to = FileOperations.canonicalPath(move.to)
                let comesFirst = arrivesEarlier.contains(from)

                if !exists(move.from), !comesFirst {
                    problems.append(isInTrash(move.from)
                                    ? "\(name) is no longer in the Trash."
                                    : "\(name) is no longer in \(folder(of: move.from)).")
                } else if let expected = move.identity, !comesFirst, exists(move.from),
                          identity(of: move.from) != expected {
                    problems.append("\(name) in \(folder(of: move.from)) is a different item "
                                    + "now, so it is left alone.")
                } else if !exists(move.to.deletingLastPathComponent()) {
                    problems.append("\(folder(of: move.to)) no longer exists, so \(name) has "
                                    + "nowhere to go back to.")
                } else if exists(move.to), !freedEarlier.contains(to),
                          !FileOperations.samePath(move.from, move.to),
                          identity(of: move.to) != identity(of: move.from) {
                    problems.append("\(folder(of: move.to)) already has an item named "
                                    + "\(quoted(move.to.lastPathComponent)).")
                } else {
                    ok.append(move)
                    freedEarlier.insert(from)
                    arrivesEarlier.insert(to)
                    if move.replacedSomething {
                        warnings.append("\(name) had replaced an item of the same name. "
                                        + "That item cannot be brought back.")
                    }
                }
            }
            doable = .relocate(ok)

        case .trash(let removals):
            var ok: [Removal] = []
            for removal in removals {
                let name = quoted(removal.url.lastPathComponent)
                if !exists(removal.url) {
                    problems.append("\(name) is no longer in \(folder(of: removal.url)).")
                } else if let expected = removal.identity, identity(of: removal.url) != expected {
                    problems.append("\(name) in \(folder(of: removal.url)) is a different item "
                                    + "now, so it is left alone.")
                } else {
                    ok.append(removal)
                    if let then = removal.modified, let now = modified(removal.url),
                       abs(now.timeIntervalSince(then)) > 1 {
                        warnings.append("\(name) has changed since. It goes to the Trash as it "
                                        + "is now, and can be taken out again from there.")
                    }
                    if removal.replacedSomething {
                        warnings.append("\(name) had replaced an item of the same name. That "
                                        + "item cannot be brought back.")
                    }
                }
            }
            doable = .trash(ok)

        case .ownership(let changes):
            var ok: [OwnershipChange] = []
            for change in changes {
                let name = quoted(change.url.lastPathComponent)
                guard let attributes = try? FileManager.default
                    .attributesOfItem(atPath: change.url.path) else {
                    problems.append("\(name) is no longer in \(folder(of: change.url)).")
                    continue
                }
                ok.append(change)
                let owner = attributes[.ownerAccountName] as? String
                let group = attributes[.groupOwnerAccountName] as? String
                if let expected = change.fromOwner, owner != expected {
                    warnings.append("\(name) belongs to \(quoted(owner ?? "somebody else")) "
                                    + "now, not \(quoted(expected)).")
                }
                if let expected = change.fromGroup, group != expected {
                    warnings.append("The group of \(name) is \(quoted(group ?? "another one")) "
                                    + "now, not \(quoted(expected)).")
                }
            }
            doable = .ownership(ok)

        case .permissions(let changes):
            var ok: [PermissionChange] = []
            for change in changes {
                let name = quoted(change.url.lastPathComponent)
                guard let current = try? FileOperations.currentMode(of: change.url) else {
                    problems.append("\(name) is no longer in \(folder(of: change.url)).")
                    continue
                }
                ok.append(change)
                if current & 0o7777 != change.from & 0o7777 {
                    warnings.append("\(name) has had its permissions changed since, to "
                                    + "\(FileOperations.rwxString(current)).")
                }
            }
            doable = .permissions(ok)
        }

        return Plan(direction: direction, entry: entry, doable: doable,
                    problems: problems, warnings: warnings)
    }

    // MARK: - Doing

    /// Does an action and returns the one that reverses what was actually done.
    private static func run(_ action: Action) async -> Done {
        switch action {
        case .relocate(let moves):
            var done: [Relocation] = []
            var failures: [String] = []
            for move in moves {
                let sameFolder = FileOperations.samePath(move.from.deletingLastPathComponent(),
                                                         move.to.deletingLastPathComponent())
                if sameFolder {
                    do {
                        _ = try await FileOperations.shared.rename(
                            move.from, to: move.to.lastPathComponent)
                    } catch {
                        failures.append("\(quoted(move.from.lastPathComponent)) could not be "
                                        + "renamed back: \(error.localizedDescription)")
                        continue
                    }
                } else if let message = await FileOperations.shared.transferOne(
                    move.from, to: move.to, kind: .move, overwrite: false) {
                    failures.append("\(quoted(move.from.lastPathComponent)) could not be moved "
                                    + "to \(folder(of: move.to)): \(message)")
                    continue
                }
                await GitService.shared.followMove(from: move.from, to: move.to)
                done.append(Relocation(from: move.to, to: move.from,
                                       identity: identity(of: move.to),
                                       replacedSomething: move.replacedSomething))
            }
            return Done(inverse: .relocate(done), touched: done.map(\.from),
                        failures: failures)

        case .trash(let removals):
            let results = await BlockingWork.run { () -> ([(Removal, URL)], [String]) in
                var done: [(Removal, URL)] = []
                var failures: [String] = []
                for removal in removals {
                    var resulting: NSURL?
                    do {
                        try FileManager.default.trashItem(at: removal.url,
                                                          resultingItemURL: &resulting)
                        if let trashed = resulting as URL? { done.append((removal, trashed)) }
                    } catch {
                        failures.append("\(quoted(removal.url.lastPathComponent)) could not be "
                                        + "moved to the Trash: \(error.localizedDescription)")
                    }
                }
                return (done, failures)
            }
            // Out of the Trash is the way back: the same item, not a new copy.
            let back = results.0.map { removal, trashed in
                Relocation(from: trashed, to: removal.url, identity: identity(of: trashed),
                           replacedSomething: removal.replacedSomething)
            }
            return Done(inverse: .relocate(back), touched: [], failures: results.1)

        case .permissions(let changes):
            let outcome = await BlockingWork.run { () -> ([PermissionChange], [String]) in
                var done: [PermissionChange] = []
                var failures: [String] = []
                for change in changes {
                    let path = FileOperations.attributeTarget(change.url)
                    do {
                        try FileManager.default.setAttributes(
                            [.posixPermissions: NSNumber(value: change.to)], ofItemAtPath: path)
                        done.append(PermissionChange(url: change.url, from: change.to,
                                                     to: change.from))
                    } catch {
                        failures.append("The permissions of "
                                        + "\(quoted(change.url.lastPathComponent)) could not be "
                                        + "set back: \(error.localizedDescription)")
                    }
                }
                return (done, failures)
            }
            return Done(inverse: .permissions(outcome.0), touched: outcome.0.map(\.url),
                        failures: outcome.1)

        case .ownership(let changes):
            // Plain `chown` only. Handing a file to somebody else needs an
            // administrator, and putting it back may need one too -- this does
            // not ask for a password behind an undo; it says it could not.
            let outcome = await BlockingWork.run { () -> ([OwnershipChange], [String]) in
                var done: [OwnershipChange] = []
                var failures: [String] = []
                for change in changes {
                    var attributes: [FileAttributeKey: Any] = [:]
                    if let owner = change.toOwner { attributes[.ownerAccountName] = owner }
                    if let group = change.toGroup { attributes[.groupOwnerAccountName] = group }
                    guard !attributes.isEmpty else { continue }
                    do {
                        try FileManager.default.setAttributes(
                            attributes, ofItemAtPath: FileOperations.attributeTarget(change.url))
                        done.append(OwnershipChange(url: change.url,
                                                    fromOwner: change.toOwner,
                                                    fromGroup: change.toGroup,
                                                    toOwner: change.fromOwner,
                                                    toGroup: change.fromGroup))
                    } catch {
                        failures.append("\(quoted(change.url.lastPathComponent)) could not be "
                                        + "given back to \(quoted(change.toOwner ?? change.toGroup ?? "")): "
                                        + "\(error.localizedDescription). Only an administrator "
                                        + "can do that; Change Owner\u{2026} asks for a password.")
                    }
                }
                return (done, failures)
            }
            return Done(inverse: .ownership(outcome.0), touched: outcome.0.map(\.url),
                        failures: outcome.1)
        }
    }

    /// What doing an action actually achieved.
    struct Done: Sendable {
        var inverse: Action
        var touched: [URL]
        /// What could not be done, in words, each naming its item and reason.
        /// A step that fails is reported and dropped: it stops nothing else in
        /// the history from being undone.
        var failures: [String] = []
    }

    // MARK: - Looking at the disk

    /// Without following a symbolic link: a link is the item, not what it
    /// points at.
    nonisolated static func identity(of url: URL) -> Identity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = (attributes[.systemNumber] as? NSNumber)?.intValue,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else { return nil }
        return Identity(device: device, inode: inode)
    }

    nonisolated static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    nonisolated static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    nonisolated static func isInTrash(_ url: URL) -> Bool {
        url.pathComponents.contains(".Trash") || url.pathComponents.contains(".Trashes")
    }

    /// One kind of quotation mark everywhere a name or a folder is named, so
    /// a sentence made of both does not mix two styles.
    nonisolated static func quoted(_ text: String) -> String {
        "\u{201C}\(text)\u{201D}"
    }

    nonisolated static func folder(of url: URL) -> String {
        quoted(NamingTemplate.tilde(url.deletingLastPathComponent().path))
    }
}

extension FileHistory.Action {
    var isEmpty: Bool { count == 0 }

    var count: Int {
        switch self {
        case .relocate(let moves): moves.count
        case .trash(let removals): removals.count
        case .permissions(let changes): changes.count
        case .ownership(let changes): changes.count
        }
    }
}

// MARK: - Saying what will happen

extension FileHistory.Plan {

    /// The question, in words: what was done, then anything worth knowing
    /// about putting it back.
    ///
    /// What was *done* rather than what undoing will do, because that is the
    /// thing the reader recognises -- and with the button saying "Undo Move"
    /// there is no doubt which way round it goes. Working the sentence out
    /// from the reversal instead read backwards, and split one rename over two
    /// lines with no clue which name came first.
    var explanation: String {
        var paragraphs = [entry.told
                          + (direction == .redo ? " That was undone." : "")]
        if !warnings.isEmpty {
            paragraphs.append(warnings.map { "\u{2022} \($0)" }.joined(separator: "\n"))
        }
        if !problems.isEmpty {
            paragraphs.append((doable.isEmpty ? "" : "Left as it is:\n")
                              + problems.map { "\u{2022} \($0)" }.joined(separator: "\n"))
        }
        return paragraphs.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// What is left of the step, for the sheet to show under the sentence.
    var scope: String {
        let count = doable.count
        guard count > 1 else { return "" }
        return "\(count) items"
    }

    /// Up to eight names, then how many more.
    static func names(_ urls: [URL]) -> String {
        let shown = urls.prefix(8).map { "\u{201C}\($0.lastPathComponent)\u{201D}" }
        let rest = urls.count - shown.count
        let list = shown.joined(separator: ", ")
        return rest > 0 ? "\(list) and \(rest) more" : list
    }
}
