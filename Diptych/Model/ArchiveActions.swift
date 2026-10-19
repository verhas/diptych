import AppKit
import Foundation

/// What Create Archive is opened on.
struct ArchiveRequest: Codable, Hashable, Sendable {
    var items: [URL]
    /// Where the archive goes unless the other pane is chosen: the items'
    /// folder, or the pane's when they come from several -- a flat view.
    var folder: URL
    var otherFolder: URL?
}

/// Extract's question about what the archive records and unpacking it did
/// not give.
struct RestoreQuestion: Equatable, Sendable {
    let archiveName: String
    let lines: [String]
    let count: Int
}

enum RestoreChoice: Sendable {
    case administrator, without, cancel
}

/// The Archive menu: Create Archive…, Extract Here, Extract to Other Pane.
extension AppModel {

    // MARK: - Creating

    var archiveSources: [URL] { active.selectedItems.map(\.url) }

    var canCreateArchive: Bool { !archiveSources.isEmpty }

    /// A window listing what is selected, with the format and its options.
    func requestCreateArchive() {
        let items = archiveSources
        guard !items.isEmpty else { return }
        let parents = Set(items.map { $0.deletingLastPathComponent() })
        let folder = parents.count == 1 ? parents.first! : active.directory
        openArchiveWindow?(ArchiveRequest(items: items, folder: folder,
                                          otherFolder: inactive.volume.isReadOnly
                                              ? nil : otherPaneFolder))
    }

    // MARK: - Extracting

    /// The selected archives Extract understands.
    var extractableSelection: [URL] {
        active.selectedItems.filter { !$0.isDirectory && Archiving.isExtractable($0.url) }
            .map(\.url)
    }

    var canExtract: Bool { !extractableSelection.isEmpty && !active.volume.isReadOnly }

    var canExtractToOtherPane: Bool {
        !extractableSelection.isEmpty && otherPaneFolder != nil && !inactive.volume.isReadOnly
    }

    /// Beside each archive.
    func extractHere() {
        guard canExtract else { return }
        extract(extractableSelection, to: nil)
    }

    func extractToOtherPane() {
        guard canExtractToOtherPane, let folder = otherPaneFolder else { return }
        extract(extractableSelection, to: folder)
    }

    /// One archive after the other: unpacked into a temporary folder as the
    /// user, the question asked when the archive records owners, groups or
    /// special permissions that this did not give, and then moved where it
    /// belongs -- as the user, or after unpacking it again as root.
    private func extract(_ archives: [URL], to folder: URL?) {
        Task {
            var made: [URL] = []
            var problems: [String] = []
            flash(archives.count == 1
                  ? "Extracting \u{201C}\(archives[0].lastPathComponent)\u{201D}\u{2026}"
                  : "Extracting \(archives.count) archives\u{2026}", error: false)
            for archive in archives {
                let destination = folder ?? archive.deletingLastPathComponent()
                switch await extractOne(archive, into: destination) {
                case .success(let urls): made += urls
                case .failure(let failure):
                    if failure.message != "Cancelled." {
                        problems.append("\u{201C}\(archive.lastPathComponent)\u{201D}: "
                                        + failure.message)
                    }
                }
            }
            if !made.isEmpty {
                FileHistory.shared.recordCreation(.made("Extract"), of: made)
                show(made, in: made[0].deletingLastPathComponent())
            }
            if !problems.isEmpty {
                dialog = .notice(title: made.isEmpty ? "Nothing was extracted"
                                                     : "Not everything was extracted",
                                 text: problems.joined(separator: "\n\n"))
            } else if !made.isEmpty {
                flash(archives.count == 1 ? "Extracted, undoable"
                                          : "\(archives.count) archives extracted, undoable",
                      error: false)
            }
        }
    }

    /// What unpacking as the user gave, before anything is moved.
    private struct Unpacked: Sendable {
        let kind: Archiving.Kind
        let scratch: URL
        let folder: URL
        let entries: [Archiving.Entry]
        let differences: [Archiving.Difference]
        let sha256: String
        let quarantine: Data?
    }

    private func extractOne(_ archive: URL, into destination: URL)
        async -> Result<[URL], Archiving.Failure> {
        let prepared = await BlockingWork.run { () -> Result<Unpacked, Archiving.Failure> in
            Result { () throws(Archiving.Failure) -> Unpacked in
                try Self.unpack(archive, for: destination)
            }
        }
        let unpacked: Unpacked
        switch prepared {
        case .failure(let failure): return .failure(failure)
        case .success(let value): unpacked = value
        }
        let placement = Archiving.placement(of: Archiving.topLevel(of: unpacked.folder),
                                            from: archive, into: destination)
        guard !placement.moves.isEmpty else {
            try? FileManager.default.removeItem(at: unpacked.scratch)
            return .failure(Archiving.Failure(message: "The archive is empty."))
        }

        var choice = RestoreChoice.without
        if !unpacked.differences.isEmpty {
            choice = await ask(RestoreQuestion(archiveName: archive.lastPathComponent,
                                               lines: Archiving.summary(unpacked.differences),
                                               count: unpacked.differences.count))
        }
        switch choice {
        case .cancel:
            try? FileManager.default.removeItem(at: unpacked.scratch)
            return .failure(Archiving.Failure(message: "Cancelled."))
        case .without:
            return await placeAsUser(unpacked, placement)
        case .administrator:
            return await placeAsAdministrator(archive, unpacked, placement,
                                              destination: destination)
        }
    }

    /// Unpacked next to where it goes, so moving it there is a rename. The
    /// archive is read twice, before and after, and must not have changed
    /// in between: what root unpacks later is checked against the same sum.
    nonisolated private static func unpack(_ archive: URL, for destination: URL)
        throws(Archiving.Failure) -> Unpacked {
        guard let kind = Archiving.kind(of: archive) else {
            throw Archiving.Failure(message: "This is not an archive Diptych can extract.")
        }
        guard let before = Archiving.sha256(of: archive) else {
            throw Archiving.Failure(message: "The archive could not be read.")
        }
        let manager = FileManager()
        let scratch: URL
        do {
            scratch = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                      appropriateFor: destination, create: true)
        } catch {
            scratch = manager.temporaryDirectory
                .appendingPathComponent("Diptych-extract-\(UUID().uuidString)")
            do { try manager.createDirectory(at: scratch, withIntermediateDirectories: true) }
            catch { throw Archiving.Failure(message: error.localizedDescription) }
        }
        let folder = scratch.appendingPathComponent("x")
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: false)
            let entries = try Archiving.entries(of: archive, kind: kind)
            try Archiving.unpack(archive, kind: kind, into: folder)
            guard Archiving.sha256(of: archive) == before else {
                throw Archiving.Failure(message: "The archive changed while it was being read.")
            }
            return Unpacked(kind: kind, scratch: scratch, folder: folder, entries: entries,
                            differences: Archiving.differences(entries, in: folder),
                            sha256: before, quarantine: Archiving.quarantine(of: archive))
        } catch let failure as Archiving.Failure {
            try? manager.removeItem(at: scratch)
            throw failure
        } catch {
            try? manager.removeItem(at: scratch)
            throw Archiving.Failure(message: error.localizedDescription)
        }
    }

    private func ask(_ question: RestoreQuestion) async -> RestoreChoice {
        await withCheckedContinuation { continuation in
            restoreAnswer = continuation
            restoreQuestion = question
            dialog = .restoreFromArchive
        }
    }

    /// The question's buttons.
    func answerRestore(_ choice: RestoreChoice) {
        dialog = nil
        restoreQuestion = nil
        let answer = restoreAnswer
        restoreAnswer = nil
        answer?.resume(returning: choice)
    }

    private func placeAsUser(_ unpacked: Unpacked, _ placement: Archiving.Placement)
        async -> Result<[URL], Archiving.Failure> {
        await BlockingWork.run { () -> Result<[URL], Archiving.Failure> in
            defer { try? FileManager().removeItem(at: unpacked.scratch) }
            if let mark = unpacked.quarantine { Archiving.markQuarantined(unpacked.folder, with: mark) }
            do throws(Archiving.Failure) {
                try Archiving.place(from: unpacked.folder, placement)
                return .success(placement.results)
            } catch {
                return .failure(error)
            }
        }
    }

    /// One administrator prompt, for a script that unpacks the archive again
    /// as root and gives each item what the archive records. The wrapper
    /// folder, when there is one, is made as the user first, so it is theirs.
    private func placeAsAdministrator(_ archive: URL, _ unpacked: Unpacked,
                                      _ placement: Archiving.Placement, destination: URL)
        async -> Result<[URL], Archiving.Failure> {
        if let wrapper = placement.wrapper {
            do { try FileManager.default.createDirectory(at: wrapper,
                                                         withIntermediateDirectories: false) }
            catch {
                try? FileManager.default.removeItem(at: unpacked.scratch)
                return .failure(Archiving.Failure(message: error.localizedDescription))
            }
        }
        let script = Archiving.restoreScript(archive: archive, sha256: unpacked.sha256,
                                             kind: unpacked.kind,
                                             differences: unpacked.differences,
                                             placement: placement, destination: destination,
                                             quarantine: unpacked.quarantine)
        switch Privileged.run(script) {
        case .succeeded:
            try? FileManager.default.removeItem(at: unpacked.scratch)
            let left = Archiving.remaining(unpacked.entries, placement)
            if left > 0 {
                flash("\(left) item\(left == 1 ? "" : "s") still differ\(left == 1 ? "s" : "") "
                      + "from what the archive records, even as administrator")
            }
            return .success(placement.results)
        case .cancelled:
            // Not authenticated: extracted as the user, as if asked so.
            if let wrapper = placement.wrapper { try? FileManager.default.removeItem(at: wrapper) }
            return await placeAsUser(unpacked, placement)
        case .failed(let message):
            try? FileManager.default.removeItem(at: unpacked.scratch)
            if let wrapper = placement.wrapper,
               (try? FileManager.default.contentsOfDirectory(atPath: wrapper.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: wrapper)
            }
            return .failure(Archiving.Failure(message: "As administrator: \(message)"))
        }
    }

    // MARK: - Optimizing

    /// The selected photos, PNGs and PDFs.
    var optimizableSelection: [URL] {
        active.selectedItems.filter { !$0.isDirectory && Optimizing.kind(of: $0.url) != nil }
            .map(\.url)
    }

    var canOptimize: Bool { !optimizableSelection.isEmpty && !active.volume.isReadOnly }

    /// A window with every one of them, before and after.
    func requestOptimize() {
        guard canOptimize else { return }
        openOptimizeWindow?(OptimizeRequest(items: optimizableSelection))
    }

    // MARK: - Showing

    /// The new items selected in whichever pane shows their folder.
    func show(_ urls: [URL], in folder: URL) {
        for pane in [left, right] where !pane.isFlat
            && pane.directory.standardizedFileURL == folder.standardizedFileURL {
            pane.pendingSelection = Set(urls)
            pane.reload()
        }
    }
}
