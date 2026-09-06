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

    func transfer(_ urls: [URL], to destination: URL, kind: Transfer) -> Outcome {
        let fm = FileManager()
        var outcome = Outcome()

        for url in urls {
            do {
                let target = Self.nonClashingURL(for: destination.appendingPathComponent(url.lastPathComponent), fm: fm)
                switch kind {
                case .copy: try fm.copyItem(at: url, to: target)
                case .move: try fm.moveItem(at: url, to: target)
                }
                outcome.succeeded.append(target)
            } catch {
                outcome.failures.append((url, error.localizedDescription))
            }
        }
        return outcome
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

    /// "report.pdf" -> "report 2.pdf" when the destination is taken, the way
    /// Finder does it, instead of silently overwriting the user's data.
    private static func nonClashingURL(for url: URL, fm: FileManager) -> URL {
        guard fm.fileExists(atPath: url.path) else { return url }

        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()

        for n in 2...9999 {
            var candidate = dir.appendingPathComponent("\(stem) \(n)")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}
