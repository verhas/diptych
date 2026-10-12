import Foundation

/// The scripts that come with Diptych, and putting them into
/// `~/.diptych/scripts` -- File ▸ Get Scripts….
///
/// They travel inside the application, signed and notarised with it, so they
/// are trusted exactly as far as Diptych itself is and nothing is fetched from
/// anywhere. A new or changed one arrives with the next version of Diptych.
/// Fetching them from GitHub instead, and why that needs a signature on every
/// script, is written up in `script-distribution.md`.
///
/// Installing is the deliberate act the scripts folder's rules ask for: the
/// file is written by Diptych, owned by you, readable by you alone and by
/// nobody writable -- so it passes every check without a `chmod` by hand.
nonisolated enum ScriptLibrary {

    /// One script that comes with Diptych.
    struct Script: Identifiable, Equatable, Sendable {
        /// Its file name, which is also the name it is installed under.
        let fileName: String
        let name: String
        let summary: String
        let version: Int
        let contents: String
        var id: String { fileName }
    }

    /// How a script that comes with Diptych stands against the folder it
    /// would be installed in.
    enum Status: Equatable, Sendable {
        /// Nothing of that name there.
        case absent
        /// Exactly this script is there.
        case installed
        /// An earlier version of this script, untouched or not.
        case older(version: Int?)
        /// Something else under that name: your own script, this one changed
        /// by you, or a later version than this Diptych knows. Installing
        /// puts that file in the Trash first.
        case different
    }

    /// Inside the application. Flattened by Xcode into Resources, so the
    /// scripts are told apart from everything else by their extension and by
    /// declaring themselves `source: diptych`.
    static var bundledFolder: URL? { Bundle.main.resourceURL }

    /// The scripts that come with Diptych, in the order of their names.
    static func scripts(in folder: URL) -> [Script] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { $0.hasSuffix(".sh") }.sorted().compactMap { name in
            let url = folder.appendingPathComponent(name)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let (definition, problems) = ScriptDefinition.read(url, contents: contents)
            // One that does not read cleanly would be refused the moment it
            // was installed; better never offered. A test holds every bundled
            // script to this.
            guard problems.isEmpty, let definition, definition.source == "diptych",
                  let version = definition.version else { return nil }
            return Script(fileName: name, name: definition.name, summary: definition.summary,
                          version: version, contents: contents)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func status(of script: Script, in folder: URL) -> Status {
        let url = folder.appendingPathComponent(script.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return .different }
        if contents == script.contents { return .installed }
        // Only a script that says it is ours, and says it is older, is an
        // update. Anything else under that name is somebody's work.
        let (definition, _) = ScriptDefinition.read(url, contents: contents)
        let header = definition ?? headerOnly(url, contents)
        if header?.source == "diptych", let installed = header?.version, installed < script.version {
            return .older(version: installed)
        }
        if header?.source == "diptych", header?.version == nil { return .older(version: nil) }
        return .different
    }

    /// The source and version of a script that does not read cleanly as a
    /// whole -- an older one can fail on a header a later Diptych no longer
    /// takes -- by reading only those two lines.
    private static func headerOnly(_ url: URL, _ contents: String) -> ScriptDefinition? {
        var source: String?
        var version: Int?
        for line in contents.components(separatedBy: .newlines).dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard trimmed.hasPrefix("#") else { break }
            let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            if body.lowercased().hasPrefix("source:") {
                source = body.dropFirst(7).trimmingCharacters(in: .whitespaces).lowercased()
            } else if body.lowercased().hasPrefix("version:") {
                version = Int(body.dropFirst(8).trimmingCharacters(in: .whitespaces))
            }
        }
        guard source != nil else { return nil }
        return ScriptDefinition(url: url, name: "", summary: "", extensions: [], fewestItems: 1,
                                mostItems: 1, applyTo: .everything, call: [], onlyIn: [], onlyUnder: [],
                                source: source, version: version, contents: contents)
    }

    struct Outcome: Equatable, Sendable {
        var installed: [String] = []
        /// What was already there under one of those names, now in the Trash.
        var trashed: [String] = []
        var failed: [(name: String, reason: String)] = []

        static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.installed == rhs.installed && lhs.trashed == rhs.trashed
                && lhs.failed.map(\.name) == rhs.failed.map(\.name)
        }
    }

    /// Writes each script into `folder` as `r--------`, owned by whoever runs
    /// Diptych. A file already there under the same name -- an earlier
    /// version, or somebody's own -- goes to the Trash first, never
    /// overwritten, so nothing is lost that cannot be put back.
    static func install(_ scripts: [Script], into folder: URL,
                        trash: (URL) throws -> Void = { url in
                            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                        }) -> Outcome {
        var outcome = Outcome()
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        } catch {
            outcome.failed = scripts.map { ($0.fileName, error.localizedDescription) }
            return outcome
        }
        for script in scripts {
            let target = folder.appendingPathComponent(script.fileName)
            if status(of: script, in: folder) == .installed { continue }
            // Written beside it under a hidden name and then renamed into
            // place: the scripts folder never holds half a script, and the
            // file is read-only before it carries the name the menu reads.
            let temporary = folder.appendingPathComponent(".\(script.fileName).\(UUID().uuidString)")
            do {
                try Data(script.contents.utf8).write(to: temporary, options: .withoutOverwriting)
                try manager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: temporary.path)
                if manager.fileExists(atPath: target.path) {
                    try trash(target)
                    outcome.trashed.append(script.fileName)
                }
                try manager.moveItem(at: temporary, to: target)
                outcome.installed.append(script.fileName)
            } catch {
                try? manager.removeItem(at: temporary)
                outcome.failed.append((script.fileName, error.localizedDescription))
            }
        }
        return outcome
    }

    /// A copy of a script that comes with Diptych, somewhere it can be
    /// compared against the installed one. Not the file inside the
    /// application: a comparison window can unlock a side for editing, and
    /// the application's own files are not for editing.
    static func comparableCopy(of script: Script) -> URL? {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diptych-scripts-\(UUID().uuidString)")
        let url = folder.appendingPathComponent(
            "\((script.fileName as NSString).deletingPathExtension) (version \(script.version)).sh")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(script.contents.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }
}
