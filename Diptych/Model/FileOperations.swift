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

        // Onto itself. The overwrite path would delete the target -- which is
        // also the source -- and then copy something that no longer exists.
        if Self.samePath(source, target) { return nil }

        // Into its own descendant. Foundation will happily recurse a directory
        // into a copy of itself until the path is too long to extend.
        if Self.isDescendant(target, of: source) {
            return kind == .copy
                ? "A folder cannot be copied into itself."
                : "A folder cannot be moved into itself."
        }

        let targetExisted = fm.fileExists(atPath: target.path)

        guard overwrite, targetExisted else {
            do {
                switch kind {
                case .copy: try fm.copyItem(at: source, to: target)
                case .move: try fm.moveItem(at: source, to: target)
                }
                return nil
            } catch {
                // copyItem can create part of the destination before throwing.
                // Only clean up what this call created.
                if kind == .copy, !targetExisted { try? fm.removeItem(at: target) }
                return error.localizedDescription
            }
        }

        // Replacing: stage the new item beside the old one and swap atomically,
        // so a failure part-way leaves the existing item intact. Removing the
        // destination first -- the obvious implementation -- loses it for good
        // if the copy then fails on a full disk or a disconnected volume.
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".diptych-staging-\(UUID().uuidString)")

        do {
            switch kind {
            case .copy: try fm.copyItem(at: source, to: staging)
            case .move: try fm.moveItem(at: source, to: staging)
            }
        } catch {
            try? fm.removeItem(at: staging)
            return error.localizedDescription
        }

        do {
            _ = try fm.replaceItemAt(target, withItemAt: staging,
                                     options: [.usingNewMetadataOnly])
            return nil
        } catch {
            // Undo: put a moved source back, discard a staged copy.
            if kind == .move {
                try? fm.moveItem(at: staging, to: source)
            } else {
                try? fm.removeItem(at: staging)
            }
            return error.localizedDescription
        }
    }

    // MARK: - Path safety

    nonisolated static func samePath(_ a: URL, _ b: URL) -> Bool {
        canonicalPath(a) == canonicalPath(b)
    }

    /// True when `url` is `ancestor` itself or lives underneath it.
    nonisolated static func isDescendant(_ url: URL, of ancestor: URL) -> Bool {
        let base = canonicalPath(ancestor)
        let candidate = canonicalPath(url)
        return candidate == base || candidate.hasPrefix(base + "/")
    }

    /// A path both sides of a comparison can agree on.
    ///
    /// `resolvingSymlinksInPath()` cannot be used directly: it rewrites
    /// `/private/tmp/x` to `/tmp/x` only when the path exists, so an existing
    /// folder and the not-yet-created child being copied into it canonicalise
    /// differently and the descendant check silently answers false. Resolving
    /// the deepest part that does exist, then re-appending the rest, makes both
    /// comparable.
    nonisolated static func canonicalPath(_ url: URL) -> String {
        let fm = FileManager()
        let standardized = url.standardizedFileURL

        if fm.fileExists(atPath: standardized.path) {
            return standardized.resolvingSymlinksInPath().path
        }

        var trailing: [String] = []
        var probe = standardized
        while probe.pathComponents.count > 1 {
            trailing.insert(probe.lastPathComponent, at: 0)
            probe = probe.deletingLastPathComponent()

            if fm.fileExists(atPath: probe.path) {
                return trailing.reduce(probe.resolvingSymlinksInPath()) {
                    $0.appendingPathComponent($1)
                }.path
            }
        }
        return standardized.path
    }

    /// A name the user typed, turned into a URL inside `parent` -- or nil when
    /// it is not a name at all.
    ///
    /// Typed names are appended as path components, so "../escaped" would
    /// otherwise create or move the item in the *parent's* parent. Rejecting
    /// separators is not enough on its own; the result is checked to be a
    /// direct child as well.
    nonisolated static func safeChild(named name: String, in parent: URL) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty,
              trimmed != ".", trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\u{0}")
        else { return nil }

        let candidate = parent.appendingPathComponent(trimmed)
        guard candidate.deletingLastPathComponent().standardizedFileURL.path
                == parent.standardizedFileURL.path else { return nil }

        return candidate
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

    /// Applies the nine rwx bits to every item, leaving everything above them
    /// alone. Absolute rather than relative because the editor's `+` and `-`
    /// produce a complete nine-bit picture, which is what makes editing several
    /// files at once well defined.
    ///
    /// Only the low nine bits are the editor's business: writing the mode
    /// wholesale silently stripped setuid, setgid and the sticky bit, which is
    /// a security change nobody asked for.
    func setPermissions(_ bits: mode_t, mask: mode_t = 0o777, for urls: [URL]) -> Outcome {
        let fm = FileManager()
        var outcome = Outcome()

        for url in urls {
            do {
                let current = try Self.currentMode(of: url, fm: fm)
                let updated = Self.merging(bits, into: current, mask: mask)
                try fm.setAttributes([.posixPermissions: NSNumber(value: updated)],
                                     ofItemAtPath: Self.attributeTarget(url))
                outcome.succeeded.append(url)
            } catch {
                outcome.failures.append((url, error.localizedDescription))
            }
        }
        return outcome
    }

    /// setAttributes follows a symlink, so read the mode from the same place it
    /// will be written.
    nonisolated static func attributeTarget(_ url: URL) -> String {
        let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink)
            ?? false
        return isSymlink ? url.resolvingSymlinksInPath().path : url.path
    }

    nonisolated static func currentMode(of url: URL, fm: FileManager = FileManager()) throws -> mode_t {
        let attributes = try fm.attributesOfItem(atPath: attributeTarget(url))
        return mode_t((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0)
    }

    /// `bits` merged onto an existing mode, `mask` saying which are authoritative.
    ///
    /// The default mask is the nine rwx bits, so a caller that can only express
    /// those leaves setuid, setgid and sticky alone. The permission editor can
    /// express all twelve and passes 0o7777.
    nonisolated static func merging(_ bits: mode_t, into current: mode_t,
                                    mask: mode_t = 0o777) -> mode_t {
        (current & ~mask) | (bits & mask)
    }

    /// The nine characters `ls` prints, special bits included.
    ///
    /// setuid, setgid and sticky have no column of their own: they are shown by
    /// replacing the execute character of their triple -- `s`/`t` when execute
    /// is also set, `S`/`T` when it is not. Rendering a plain `x` there, as this
    /// used to, means /usr/bin/sudo displays as an ordinary executable.
    nonisolated static func rwxString(_ mode: mode_t) -> String {
        var text = ""
        let special: [mode_t] = [0o4000, 0o2000, 0o1000]      // setuid, setgid, sticky
        let markers: [Character] = ["s", "s", "t"]

        for (group, shift) in [6, 3, 0].enumerated() {
            let bits = (mode >> mode_t(shift)) & 7
            text.append(bits & 4 != 0 ? "r" : "-")
            text.append(bits & 2 != 0 ? "w" : "-")

            let executable = bits & 1 != 0
            if mode & special[group] != 0 {
                let marker = markers[group]
                text.append(executable ? marker : Character(marker.uppercased()))
            } else {
                text.append(executable ? "x" : "-")
            }
        }
        return text
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

    struct InvalidName: LocalizedError {
        let name: String
        var errorDescription: String? {
            "\u{201C}\(name)\u{201D} is not a usable name. "
                + "A name cannot be empty, contain a slash, or be \u{201C}.\u{201D} or \u{201C}..\u{201D}."
        }
    }

    /// Symbolic links to each source, in `destination`.
    ///
    /// Symbolic and not an alias: a symlink is what every other tool on the
    /// system understands, and it survives being read by a shell, a build, or
    /// anything that is not Finder. An alias would follow the original when it
    /// moves, which is the one thing an alias does better -- and the one thing
    /// that makes it opaque to everything else.
    func createLinks(to sources: [URL], in destination: URL) -> Outcome {
        let fm = FileManager()
        var outcome = Outcome()

        for source in sources {
            // A link named after its target, beside a file of that name, would
            // collide -- so the same "name-2" rule as a copy applies.
            let wanted = destination.appendingPathComponent(source.lastPathComponent)
            let target = Self.exists(wanted) ? Self.uniqueURL(for: wanted) : wanted
            do {
                try fm.createSymbolicLink(at: target, withDestinationURL: source)
                outcome.succeeded.append(target)
            } catch {
                outcome.failures.append((source, error.localizedDescription))
            }
        }
        return outcome
    }

    func createDirectory(named name: String, in parent: URL) throws -> URL {
        guard let url = Self.safeChild(named: name, in: parent) else {
            throw InvalidName(name: name)
        }
        try FileManager().createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func rename(_ url: URL, to newName: String) throws -> URL {
        let fm = FileManager()
        let parent = url.deletingLastPathComponent()
        guard let target = Self.safeChild(named: newName, in: parent) else {
            throw InvalidName(name: newName)
        }

        // APFS is case-insensitive but case-preserving by default, so renaming
        // "notes" to "Notes" is a move onto itself and fails. Bounce through a
        // temporary name. This is the kind of thing that only shows up on a Mac.
        if url.path.compare(target.path, options: .caseInsensitive) == .orderedSame,
           url.path != target.path {
            let temp = url.deletingLastPathComponent()
                .appendingPathComponent("." + UUID().uuidString)
            try fm.moveItem(at: url, to: temp)
            do {
                try fm.moveItem(at: temp, to: target)
            } catch {
                // Put it back. Without this a failure here leaves the item
                // stranded under a hidden UUID name with nothing pointing at it.
                try? fm.moveItem(at: temp, to: url)
                throw error
            }
            return target
        }

        try fm.moveItem(at: url, to: target)
        return target
    }

}
