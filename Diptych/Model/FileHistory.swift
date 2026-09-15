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

    /// What doing a step does. Undo and redo are the same three things in
    /// opposite directions.
    enum Action: Sendable {
        case relocate([Relocation])
        case trash([Removal])
        case permissions([PermissionChange])
    }

    struct Entry: Sendable {
        /// "Move", "Copy", "Rename" -- what the menu says after Undo or Redo.
        let name: String
        let action: Action
    }

    private(set) var undoable: [Entry] = []
    private(set) var redoable: [Entry] = []
    private(set) var isBusy = false

    var undoName: String? { undoable.last?.name }
    var redoName: String? { redoable.last?.name }

    /// A new operation. What could be redone no longer follows from here.
    func record(_ name: String, _ action: Action) {
        guard !action.isEmpty else { return }
        undoable.append(Entry(name: name, action: action))
        if undoable.count > Self.depth { undoable.removeFirst(undoable.count - Self.depth) }
        redoable.removeAll()
    }

    func forgetEverything() {
        undoable.removeAll()
        redoable.removeAll()
    }

    // MARK: - Recording, with what undoing each needs

    /// Copies, new files, new folders and links: undone by the Trash.
    func recordCreation(_ name: String, of urls: [URL], replacing: Set<URL> = []) {
        record(name, .trash(urls.map {
            Removal(url: $0, identity: Self.identity(of: $0), modified: Self.modified($0),
                    replacedSomething: replacing.contains($0))
        }))
    }

    /// Moves and renames: undone by moving back.
    func recordRelocation(_ name: String, _ pairs: [(from: URL, to: URL)],
                          replacing: Set<URL> = []) {
        record(name, .relocate(pairs.map {
            Relocation(from: $0.to, to: $0.from, identity: Self.identity(of: $0.to),
                       replacedSomething: replacing.contains($0.to))
        }))
    }

    /// Permissions as they were and as they are now.
    func recordPermissions(_ changes: [(url: URL, before: mode_t, after: mode_t)]) {
        record("Permission Change", .permissions(changes.filter { $0.before != $0.after }.map {
            PermissionChange(url: $0.url, from: $0.after, to: $0.before)
        }))
    }

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
    @discardableResult
    func perform(_ direction: Direction,
                 confirm: (Plan) async -> Bool) async -> [URL] {
        guard !isBusy, let plan = plan(direction) else { return [] }
        guard await confirm(plan) else { return [] }
        // Asked in the meantime? The plan may be about an older world.
        guard !isBusy else { return [] }

        isBusy = true
        defer { isBusy = false }

        if direction == .undo { _ = undoable.popLast() } else { _ = redoable.popLast() }
        guard !plan.doable.isEmpty else { return [] }

        let (inverse, touched) = await Self.run(plan.doable)
        if !inverse.isEmpty {
            let entry = Entry(name: plan.entry.name, action: inverse)
            if direction == .undo { redoable.append(entry) } else { undoable.append(entry) }
        }
        return touched
    }

    // MARK: - Checking

    nonisolated static func plan(_ entry: Entry, direction: Direction) -> Plan {
        var problems: [String] = []
        var warnings: [String] = []
        let doable: Action

        switch entry.action {
        case .relocate(let moves):
            var ok: [Relocation] = []
            for move in moves {
                let name = "\u{201C}\(move.from.lastPathComponent)\u{201D}"
                if !exists(move.from) {
                    problems.append(isInTrash(move.from)
                                    ? "\(name) is no longer in the Trash."
                                    : "\(name) is no longer in \(folder(of: move.from)).")
                } else if let expected = move.identity, identity(of: move.from) != expected {
                    problems.append("\(name) in \(folder(of: move.from)) is a different item "
                                    + "now, so it is left alone.")
                } else if !exists(move.to.deletingLastPathComponent()) {
                    problems.append("\(folder(of: move.to)) no longer exists, so \(name) has "
                                    + "nowhere to go back to.")
                } else if exists(move.to), !FileOperations.samePath(move.from, move.to),
                          identity(of: move.to) != identity(of: move.from) {
                    problems.append("\(folder(of: move.to)) already has an item named "
                                    + "\u{201C}\(move.to.lastPathComponent)\u{201D}.")
                } else {
                    ok.append(move)
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
                let name = "\u{201C}\(removal.url.lastPathComponent)\u{201D}"
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

        case .permissions(let changes):
            var ok: [PermissionChange] = []
            for change in changes {
                let name = "\u{201C}\(change.url.lastPathComponent)\u{201D}"
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
    private static func run(_ action: Action) async -> (inverse: Action, touched: [URL]) {
        switch action {
        case .relocate(let moves):
            var done: [Relocation] = []
            for move in moves {
                let sameFolder = FileOperations.samePath(move.from.deletingLastPathComponent(),
                                                         move.to.deletingLastPathComponent())
                if sameFolder {
                    guard (try? await FileOperations.shared.rename(
                        move.from, to: move.to.lastPathComponent)) != nil else { continue }
                } else {
                    guard await FileOperations.shared.transferOne(
                        move.from, to: move.to, kind: .move, overwrite: false) == nil
                    else { continue }
                }
                await GitService.shared.followMove(from: move.from, to: move.to)
                done.append(Relocation(from: move.to, to: move.from,
                                       identity: identity(of: move.to),
                                       replacedSomething: move.replacedSomething))
            }
            return (.relocate(done), done.map(\.from))

        case .trash(let removals):
            let results = await BlockingWork.run { () -> [(Removal, URL)] in
                removals.compactMap { removal in
                    var resulting: NSURL?
                    guard (try? FileManager.default.trashItem(at: removal.url,
                                                              resultingItemURL: &resulting))
                            != nil, let trashed = resulting as URL? else { return nil }
                    return (removal, trashed)
                }
            }
            // Out of the Trash is the way back: the same item, not a new copy.
            let back = results.map { removal, trashed in
                Relocation(from: trashed, to: removal.url, identity: identity(of: trashed),
                           replacedSomething: removal.replacedSomething)
            }
            return (.relocate(back), [])

        case .permissions(let changes):
            let done = await BlockingWork.run { () -> [PermissionChange] in
                changes.compactMap { change in
                    let path = FileOperations.attributeTarget(change.url)
                    guard (try? FileManager.default.setAttributes(
                        [.posixPermissions: NSNumber(value: change.to)], ofItemAtPath: path))
                            != nil else { return nil }
                    return PermissionChange(url: change.url, from: change.to, to: change.from)
                }
            }
            return (.permissions(done), done.map(\.url))
        }
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

    nonisolated static func folder(of url: URL) -> String {
        NamingTemplate.tilde(url.deletingLastPathComponent().path)
    }
}

extension FileHistory.Action {
    var isEmpty: Bool { count == 0 }

    var count: Int {
        switch self {
        case .relocate(let moves): moves.count
        case .trash(let removals): removals.count
        case .permissions(let changes): changes.count
        }
    }
}

// MARK: - Saying what will happen

extension FileHistory.Plan {

    /// The question, in words: what will happen, then what will not.
    var explanation: String {
        var paragraphs = [happens]
        if !warnings.isEmpty {
            paragraphs.append(warnings.map { "\u{2022} \($0)" }.joined(separator: "\n"))
        }
        if !problems.isEmpty {
            paragraphs.append((doable.isEmpty ? "" : "Left as it is:\n")
                              + problems.map { "\u{2022} \($0)" }.joined(separator: "\n"))
        }
        return paragraphs.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private var happens: String {
        switch doable {
        case .relocate(let moves) where !moves.isEmpty:
            let first = moves[0]
            let names = Self.names(moves.map(\.from))
            let fromTrash = FileHistory.isInTrash(first.from)
            let sameFolders = moves.allSatisfy {
                FileOperations.samePath($0.from.deletingLastPathComponent(),
                                        first.from.deletingLastPathComponent())
                && FileOperations.samePath($0.to.deletingLastPathComponent(),
                                           first.to.deletingLastPathComponent())
            }
            let destination = FileHistory.folder(of: first.to)
            if moves.count == 1,
               FileOperations.samePath(first.from.deletingLastPathComponent(),
                                       first.to.deletingLastPathComponent()) {
                return "\u{201C}\(first.from.lastPathComponent)\u{201D} is renamed "
                    + "\u{201C}\(first.to.lastPathComponent)\u{201D}, in \(destination)."
            }
            if fromTrash {
                return "\(names) \(moves.count == 1 ? "is" : "are") taken out of the Trash "
                    + "and put back in \(destination)."
            }
            if sameFolders {
                return "\(names) \(moves.count == 1 ? "moves" : "move") from "
                    + "\(FileHistory.folder(of: first.from)) to \(destination)."
            }
            return moves.map {
                "\u{201C}\($0.from.lastPathComponent)\u{201D} moves to \(FileHistory.folder(of: $0.to))"
            }.joined(separator: "\n") + "."

        case .trash(let removals) where !removals.isEmpty:
            let names = Self.names(removals.map(\.url))
            return "\(names) in \(FileHistory.folder(of: removals[0].url)) "
                + "\(removals.count == 1 ? "goes" : "go") to the Trash."

        case .permissions(let changes) where !changes.isEmpty:
            if changes.count == 1 {
                let change = changes[0]
                return "The permissions of \u{201C}\(change.url.lastPathComponent)\u{201D} "
                    + "go back to \(FileOperations.rwxString(change.to))."
            }
            return "The permissions of \(Self.names(changes.map(\.url))) go back to what "
                + "they were."

        default:
            return ""
        }
    }

    /// Up to eight names, then how many more.
    static func names(_ urls: [URL]) -> String {
        let shown = urls.prefix(8).map { "\u{201C}\($0.lastPathComponent)\u{201D}" }
        let rest = urls.count - shown.count
        let list = shown.joined(separator: ", ")
        return rest > 0 ? "\(list) and \(rest) more" : list
    }
}
