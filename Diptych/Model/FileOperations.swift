import Foundation

/// Copy / move / trash / mkdir, all off the main thread.
actor FileOperations {

    static let shared = FileOperations()

    enum Transfer { case copy, move }

    /// Result of a batch operation: what worked, and what didn't.
    /// Partial failure is the normal case in a file manager, so it is modelled
    /// explicitly rather than thrown away on the first error.
    struct Outcome: Sendable {
        var succeeded: [URL] = []
        var failures: [(url: URL, message: String)] = []
        var isCompleteSuccess: Bool { failures.isEmpty }
    }

    /// Moves or copies one item to an exact target, which the caller has
    /// already resolved against any name clash.
    func transferOne(_ source: URL, to target: URL, kind: Transfer,
                     overwrite: Bool) -> String? {
        let fm = FileManager()
        do {
            if overwrite, fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            switch kind {
            case .copy: try fm.copyItem(at: source, to: target)
            case .move: try fm.moveItem(at: source, to: target)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    nonisolated static func exists(_ url: URL) -> Bool {
        FileManager().fileExists(atPath: url.path)
    }

    /// "report.pdf" -> "report-1.pdf", then "-2" and so on.
    ///
    /// A dash rather than a space, and starting at 1 rather than 2: a space in
    /// a generated name is a nuisance everywhere it is later typed.
    nonisolated static func uniqueURL(for url: URL) -> URL {
        let fm = FileManager()
        guard fm.fileExists(atPath: url.path) else { return url }

        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let directory = url.deletingLastPathComponent()

        for suffix in 1...9999 {
            var candidate = directory.appendingPathComponent("\(stem)-\(suffix)")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    /// Delete means *trash*, always. `removeItem` is unrecoverable and has no
    /// business being wired to a keystroke in a file manager.
    func trash(_ urls: [URL]) -> Outcome {
        let fm = FileManager()
        var outcome = Outcome()
        for url in urls {
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                outcome.succeeded.append(url)
            } catch {
                outcome.failures.append((url, error.localizedDescription))
            }
        }
        return outcome
    }

    /// Applies one absolute mode to every item. Absolute rather than relative
    /// because the editor's `+` and `-` produce a complete nine-bit picture --
    /// which is what makes editing several files at once well defined.
    func setPermissions(_ mode: mode_t, for urls: [URL]) -> Outcome {
        let fm = FileManager()
        var outcome = Outcome()
        for url in urls {
            do {
                try fm.setAttributes([.posixPermissions: NSNumber(value: mode)],
                                     ofItemAtPath: url.path)
                outcome.succeeded.append(url)
            } catch {
                outcome.failures.append((url, error.localizedDescription))
            }
        }
        return outcome
    }

    /// Applies an owner and/or a group to every item.
    func setOwnership(owner: String?, group: String?, for urls: [URL]) -> Outcome {
        let fm = FileManager()
        var attributes: [FileAttributeKey: Any] = [:]
        if let owner { attributes[.ownerAccountName] = owner }
        if let group { attributes[.groupOwnerAccountName] = group }
        guard !attributes.isEmpty else { return Outcome() }

        var outcome = Outcome()
        for url in urls {
            do {
                try fm.setAttributes(attributes, ofItemAtPath: url.path)
                outcome.succeeded.append(url)
            } catch {
                outcome.failures.append((url, error.localizedDescription))
            }
        }
        return outcome
    }

    func createDirectory(named name: String, in parent: URL) throws -> URL {
        let fm = FileManager()
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func rename(_ url: URL, to newName: String) throws -> URL {
        let fm = FileManager()
        let target = url.deletingLastPathComponent().appendingPathComponent(newName)

        // APFS is case-insensitive but case-preserving by default, so renaming
        // "notes" to "Notes" is a move onto itself and fails. Bounce through a
        // temporary name. This is the kind of thing that only shows up on a Mac.
        if url.path.compare(target.path, options: .caseInsensitive) == .orderedSame,
           url.path != target.path {
            let temp = url.deletingLastPathComponent()
                .appendingPathComponent("." + UUID().uuidString)
            try fm.moveItem(at: url, to: temp)
            try fm.moveItem(at: temp, to: target)
            return target
        }

        try fm.moveItem(at: url, to: target)
        return target
    }

}
