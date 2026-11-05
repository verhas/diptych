import AppKit
import Foundation

/// A Create Checksum the active pane could not carry out because it is
/// read-only, waiting for the answer to "put them in the other pane instead?".
struct PendingChecksum: Sendable {
    let algorithms: [Checksums.Algorithm]
    let targets: [URL]
    let into: URL
}

/// A Create Checksum stopped at checksum files that already exist with a
/// different sum, waiting for the answer to "overwrite them?".
struct PendingChecksumOverwrite: Sendable {
    let algorithms: [Checksums.Algorithm]
    let plan: Checksums.Plan
}

/// The Checksum menu: Create ▸ (a kind) writes `name.ext` beside each file;
/// Check looks first at a sum in the clipboard, then at the checksum files.
extension AppModel {

    /// The selected ordinary files -- what a checksum is of. Folders and the
    /// `..` row have none.
    var checksumTargets: [URL] {
        active.selectedItems.filter { !$0.isDirectory && !$0.isParent }.map(\.url)
    }

    var canChecksum: Bool { !checksumTargets.isEmpty }

    /// The checksum files a server's listing shows beside `targets`: read when
    /// checking, and compared with when creating, so they are fetched too.
    private func checksumCompanions(of targets: [URL]) -> [URL] {
        targets.flatMap { target in
            Checksums.Algorithm.allCases.map { target.appendingPathExtension($0.ext) }
                .filter { RemoteBrowsing.listedNode(of: $0) != nil }
        }
    }

    // MARK: - Creating

    /// Create Checksums…: the small window that lists the selected files and
    /// asks which kinds to make.
    func requestCreateChecksums() {
        let targets = checksumTargets
        guard !targets.isEmpty else { return }
        let id = ToolWindows.shared.register(.init(model: self, kind: .checksums, files: targets))
        openToolWindow?(.checksums, id)
    }

    /// A checksum file of `algorithm` beside each selected file.
    func createChecksums(_ algorithm: Checksums.Algorithm) {
        createChecksums([algorithm], of: checksumTargets)
    }

    /// A checksum file of each of `algorithms` beside each of `targets`. On
    /// read-only media the files cannot go there, so the user is asked whether
    /// to put them in the other pane instead.
    func createChecksums(_ algorithms: [Checksums.Algorithm], of targets: [URL]) {
        guard !targets.isEmpty, !algorithms.isEmpty else { return }
        // On a server: of the files' bytes, fetched first -- a placeholder's sum
        // is the sum of nothing -- and the checksum files are sent there.
        if active.isServerListing {
            whenFetched(targets + checksumCompanions(of: targets)) { [weak self] in
                self?.writeChecksums(algorithms, of: targets, into: nil)
            }
            return
        }
        if !active.isWritable {
            guard let other = otherPaneFolder, inactive.isWritable else {
                dialog = .notice(title: "This folder is read-only",
                                 text: "Checksum files cannot be created here, and the other pane "
                                     + "is not a folder they could be created in instead.")
                return
            }
            pendingChecksum = PendingChecksum(algorithms: algorithms, targets: targets, into: other)
            dialog = .checksumReadOnly
            return
        }
        writeChecksums(algorithms, of: targets, into: nil)
    }

    /// The answer to the read-only question: make them in the other pane.
    func confirmChecksumsInOtherPane() {
        guard let pending = pendingChecksum else { return }
        pendingChecksum = nil
        writeChecksums(pending.algorithms, of: pending.targets, into: pending.into)
    }

    /// `folder` nil means beside each original -- each in its own folder, so a
    /// flat-view selection spread across folders still lands each sum by its
    /// file; a folder means they all go there, as the read-only detour does.
    ///
    /// A checksum file already holding the right sum is left alone; one holding
    /// a different sum stops to ask before it is overwritten. The fresh ones
    /// are written either way, so answering No to the overwrite refuses only
    /// the overwrite, not the whole command.
    private func writeChecksums(_ algorithms: [Checksums.Algorithm], of targets: [URL],
                                into folder: URL?) {
        let label = Self.label(algorithms)
        let count = targets.count * algorithms.count
        Task {
            flash(count == 1
                  ? "Computing the \(label) checksum\u{2026}"
                  : "Computing \(count) \(label) checksums\u{2026}", error: false)
            let plan = await BlockingWork.run {
                algorithms.reduce(into: Checksums.Plan()) { plan, algorithm in
                    let one = Checksums.classify(algorithm: algorithm, targets: targets, folder: folder)
                    plan.fresh += one.fresh
                    plan.mismatched += one.mismatched
                    plan.upToDate += one.upToDate
                    plan.problems += one.problems.filter { !plan.problems.contains($0) }
                }
            }
            if plan.mismatched.isEmpty {
                await finishChecksums(algorithms, plan: plan, overwriting: false)
            } else {
                pendingChecksumOverwrite = PendingChecksumOverwrite(algorithms: algorithms, plan: plan)
                dialog = .checksumOverwrite
            }
        }
    }

    /// The answer to the overwrite question: replace the stale checksum files.
    func confirmChecksumOverwrite() {
        guard let pending = pendingChecksumOverwrite else { return }
        pendingChecksumOverwrite = nil
        dialog = nil
        Task { await finishChecksums(pending.algorithms, plan: pending.plan, overwriting: true) }
    }

    /// Keep the stale checksum files; the fresh ones are still written.
    func cancelChecksumOverwrite() {
        guard let pending = pendingChecksumOverwrite else { return }
        pendingChecksumOverwrite = nil
        dialog = nil
        Task { await finishChecksums(pending.algorithms, plan: pending.plan, overwriting: false) }
    }

    /// Write the fresh checksum files -- and, when overwriting, the stale ones
    /// too -- then say what happened.
    private func finishChecksums(_ algorithms: [Checksums.Algorithm], plan: Checksums.Plan,
                                 overwriting: Bool) async {
        let label = Self.label(algorithms)
        let writes = plan.fresh + (overwriting ? plan.mismatched : [])
        let result = await BlockingWork.run { Checksums.writeAll(writes) }
        // Written in a server's folder, recording it sends it there.
        if !result.made.isEmpty {
            FileHistory.shared.recordCreation(.made("Create Checksum"), of: result.made)
            show(result.made, in: result.made[0].deletingLastPathComponent())
        }
        let problems = plan.problems + result.problems
        if !problems.isEmpty {
            dialog = .notice(title: result.made.isEmpty ? "No checksum files were created"
                                                        : "Not every checksum file was created",
                             text: problems.joined(separator: "\n\n"))
            return
        }
        let left = overwriting ? 0 : plan.mismatched.count
        var parts: [String] = []
        if result.made.count > 0 {
            parts.append("\(result.made.count) \(label) checksum"
                         + "\(result.made.count == 1 ? "" : "s") "
                         + "\(overwriting && plan.fresh.isEmpty ? "replaced" : "created")")
        }
        if plan.upToDate > 0 { parts.append("\(plan.upToDate) already up to date") }
        if left > 0 { parts.append("\(left) left unchanged") }

        if result.made.isEmpty, left == 0, plan.upToDate > 0 {
            flash(plan.upToDate == 1
                  ? "The \(label) checksum already matches \u{2014} nothing to do"
                  : "All \(plan.upToDate) \(label) checksums already match \u{2014} nothing to do",
                  error: false)
        } else if result.made.isEmpty {
            flash(parts.isEmpty ? "Nothing to do" : parts.joined(separator: ", "), error: false)
        } else {
            flash(parts.joined(separator: ", ") + ", undoable", error: false)
        }
    }

    /// "SHA-256", or "MD5 and SHA-256", or "MD5, SHA-1 and SHA-256".
    static func label(_ algorithms: [Checksums.Algorithm]) -> String {
        let labels = algorithms.map(\.label)
        guard labels.count > 1 else { return labels.first ?? "" }
        return labels.dropLast().joined(separator: ", ") + " and " + labels.last!
    }

    /// Of `targets`, those that are themselves checksum files: named for a kind
    /// and holding a sum. A server's file not fetched yet goes by its name.
    nonisolated static func checksumFiles(among targets: [URL],
                                          pending: Set<URL> = []) -> [URL] {
        targets.filter { url in
            guard let kind = Checksums.Algorithm(rawValue: url.pathExtension.lowercased()) else {
                return false
            }
            if pending.contains(url) { return true }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 64 * 1024),
                  let text = String(data: data, encoding: .utf8) else { return false }
            return Checksums.hashTokens(in: text).contains { $0.count == kind.hexLength }
        }
    }

    // MARK: - Checking

    /// Check the selection. One file with a sum in the clipboard is checked
    /// against that; otherwise -- several files, or nothing copied -- against
    /// the checksum files beside each one, since a copied sum cannot be said
    /// to belong to any one of several files.
    func checkChecksums() {
        let targets = checksumTargets
        guard !targets.isEmpty else { return }
        if RemoteBrowsing.hasPending(targets + checksumCompanions(of: targets)) {
            whenFetched(targets + checksumCompanions(of: targets)) { [weak self] in self?.checkChecksums() }
            return
        }
        if targets.count == 1, let clipboard = Clipboard.plainText(),
           Checksums.hasChecksum(clipboard) {
            checkAgainstClipboard(targets[0], clipboard: clipboard)
        } else {
            checkAgainstFiles(targets)
        }
    }

    private func checkAgainstClipboard(_ file: URL, clipboard: String) {
        Task {
            flash("Checking \u{201C}\(file.lastPathComponent)\u{201D} against the clipboard\u{2026}",
                  error: false)
            let outcome = await BlockingWork.run { () -> (matched: Checksums.Algorithm?, read: Bool) in
                guard let digests = Checksums.allDigests(of: file) else { return (nil, false) }
                return (Checksums.match(digests: digests, clipboard: clipboard), true)
            }
            guard outcome.read else {
                dialog = .notice(title: "The file could not be read",
                                 text: "\u{201C}\(file.lastPathComponent)\u{201D} could not be read.")
                return
            }
            if let algorithm = outcome.matched {
                dialog = .notice(
                    title: "Checksum matches",
                    text: "The \(algorithm.label) checksum of \u{201C}\(file.lastPathComponent)\u{201D} "
                        + "matches the checksum in the clipboard.")
            } else {
                let kinds = Checksums.Algorithm.allCases.map(\.label).joined(separator: ", ")
                dialog = .notice(
                    title: "Checksum does not match",
                    text: "The checksum in the clipboard matches none of the checksums of "
                        + "\u{201C}\(file.lastPathComponent)\u{201D} (\(kinds)).")
            }
        }
    }

    private func checkAgainstFiles(_ targets: [URL]) {
        Task {
            flash("Checking against the checksum files\u{2026}", error: false)
            let report = await BlockingWork.run { Checksums.checkAgainstFiles(targets) }
            guard !report.checks.isEmpty else {
                let kinds = Checksums.Algorithm.allCases.map { "." + $0.ext }.joined(separator: ", ")
                dialog = .notice(
                    title: "No checksum files found",
                    text: targets.count == 1
                        ? "No checksum file (\(kinds)) was found beside "
                            + "\u{201C}\(targets[0].lastPathComponent)\u{201D}, and the clipboard "
                            + "holds no checksum either."
                        : "No checksum files (\(kinds)) were found beside the selected files.")
                return
            }
            let title = report.allMatched ? "Checksums match"
                      : report.anyMatched ? "Some checksums do not match"
                      :                     "Checksum does not match"
            dialog = .notice(title: title, text: report.lines.joined(separator: "\n"))
        }
    }
}
