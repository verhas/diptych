import Foundation
import Observation

/// The scripts in `~/.diptych/scripts`, and whether each may be run.
///
/// Read once when Diptych starts, on purpose. A script is a program somebody
/// put on this Mac; re-reading the folder while the application runs would mean
/// a script could change between being approved and being run. Developer mode
/// adds a command to read them again for whoever is writing them.
@MainActor
@Observable
final class ScriptCatalogue {

    static let shared = ScriptCatalogue()

    static var folder: URL { StateStore.directory.appendingPathComponent("scripts") }
    private static var approvalsFile: URL {
        StateStore.directory.appendingPathComponent("scripts-approved.json")
    }

    private(set) var scripts: [ScriptDefinition] = []
    private(set) var problems: [ScriptProblem] = []
    /// Hashes of the scripts the user has said yes to.
    @ObservationIgnored private var approved: Set<String> = []

    private init() {}

    var isEnabled: Bool { ConfigStore.shared.configuration.scriptsEnabled }
    var isDeveloperMode: Bool { ConfigStore.shared.configuration.scriptsDeveloperMode }

    // MARK: - Reading the folder

    func reload() {
        reload(from: Self.folder, checkingTheSetting: true)
    }

    /// Split out so a test can point it at a folder of its own; the folder is
    /// otherwise always `~/.diptych/scripts`.
    func reload(from folder: URL, checkingTheSetting: Bool = true) {
        scripts = []
        problems = []
        approved = Self.readApprovals()
        if checkingTheSetting { guard isEnabled else { return } }

        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return }

        for name in names.sorted() where !name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isFolder),
                  !isFolder.boolValue else { continue }

            if let refusal = refusal(for: url) {
                problems.append(ScriptProblem(file: name, line: nil, message: refusal))
                continue
            }
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                problems.append(ScriptProblem(file: name, line: nil,
                                              message: "This file is not text Diptych can read."))
                continue
            }
            let (definition, found) = ScriptDefinition.read(url, contents: contents)
            problems.append(contentsOf: found)
            if let definition { scripts.append(definition) }
        }
    }

    /// Why a file in the scripts folder will not be run at all.
    ///
    /// These are checks on the file rather than on its contents, and they are
    /// the ones that matter: the danger this feature creates is not a
    /// dishonest expert but a script that arrived by post.
    private func refusal(for url: URL) -> String? {
        let manager = FileManager.default

        // Anything downloaded carries this, and a script that came from
        // somewhere else is the whole attack. No instructions for removing it:
        // whoever should be allowed past this already knows how.
        if getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0 {
            return "This came from outside your Mac, so Diptych will not run it."
        }

        guard let attributes = try? manager.attributesOfItem(atPath: url.path) else {
            return "Diptych cannot read this file."
        }
        if let owner = attributes[.ownerAccountID] as? NSNumber,
           owner.uint32Value != getuid() {
            return "This belongs to somebody else, so Diptych will not run it."
        }
        guard let mode = attributes[.posixPermissions] as? NSNumber else { return nil }
        let bits = String(mode.uint16Value & 0o777, radix: 8)

        // Stricter than the usual "not writable by others": a download lands
        // as rw-r--r--, so requiring no write bit at all makes installing a
        // script a deliberate act rather than something that can happen by
        // accident. It also means an approved script cannot quietly change
        // afterwards.
        //
        // Nothing lifts this, developer mode included. A check anybody can
        // switch off is not a check, and a script written under a relaxed rule
        // is first tried under the real one on the day it matters. Making a
        // script editable and read-only again is what the two scripts in the
        // folder are for.
        if mode.uint16Value & 0o222 != 0 {
            return "Anything that can be written to can change after you have agreed to it. "
                 + "This one is \(bits); nobody may be able to write to it. Diptych's "
                 + "permission editor will do it: select the file, press Cmd-Option-P, and "
                 + "leave only the owner's R."
        }

        // And nobody else may read it either. That is a different protection
        // from the one above -- it guards what is *in* a script rather than
        // what the script is -- but a script is a fair place to keep a token,
        // a private path, or something else that is nobody else's business,
        // and this folder belongs to one person by definition. Owner-only
        // costs nothing and answers the question before it is asked.
        if mode.uint16Value & 0o077 != 0 {
            return "Only you may read a script. This one is \(bits), which lets other "
                 + "accounts on this Mac read it, and a script is a fair place to keep "
                 + "something private. Leave only the owner's R, with Cmd-Option-P."
        }
        return nil
    }

    /// Checked again at the moment of running, not only when the folder was
    /// read.
    ///
    /// Reported: unlocking a script and then running it worked, because it had
    /// been judged at startup and nothing looked again. A rule that holds only
    /// until somebody changes the file is not much of a rule -- and the moment
    /// of running is the moment it matters.
    func troubleRunning(_ script: ScriptDefinition) -> String? {
        if let refusal = refusal(for: script.url) { return refusal }
        guard let now = try? String(contentsOf: script.url, encoding: .utf8) else {
            return "\u{201C}\(script.url.lastPathComponent)\u{201D} is not there any more."
        }
        // What is in memory is what was read, checked and agreed to. If the
        // file no longer matches it, the thing in the menu is not the thing on
        // disk, and neither one should be run on the strength of the other.
        guard now == script.contents else {
            return "\u{201C}\(script.url.lastPathComponent)\u{201D} has changed since Diptych "
                 + "read it, so what is in the menu is not what is in the file.\n\n"
                 + "Start Diptych again \u{2014} or, in developer mode, use Read the Scripts "
                 + "Folder Again."
        }
        return nil
    }

    /// Drop one that has just been refused, so the menu stops offering
    /// something that is certain to fail.
    func forget(_ script: ScriptDefinition) {
        scripts.removeAll { $0.id == script.id }
    }

    // MARK: - Which apply

    func applicable(to targets: [ScriptTarget], in folder: URL,
                    checkingTheSetting: Bool = true) -> [ScriptDefinition] {
        if checkingTheSetting { guard isEnabled else { return [] } }
        // A script that takes no items is about the folder on screen, so that
        // is what its scope is judged against.
        guard !targets.isEmpty else {
            return scripts.filter { $0.fewestItems == 0 && $0.isInScope(folder) }
        }
        return scripts.filter { $0.applies(to: targets) }
    }

    // MARK: - Agreeing to one

    /// Keyed on the contents, so a script that changes is asked about again.
    nonisolated static func fingerprint(of contents: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(contents.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x1000_0000_01b3
        }
        return String(hash, radix: 16)
    }

    func isApproved(_ script: ScriptDefinition) -> Bool {
        approved.contains(Self.fingerprint(of: script.contents))
    }

    func approve(_ script: ScriptDefinition) {
        approved.insert(Self.fingerprint(of: script.contents))
        Self.write(approved)
    }

    private static func readApprovals() -> Set<String> {
        guard let data = try? Data(contentsOf: approvalsFile),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    /// Written 0600. Losing this file fails safe: the user is asked again.
    private static func write(_ approvals: Set<String>) {
        guard let data = try? JSONEncoder().encode(approvals.sorted()) else { return }
        try? FileManager.default.createDirectory(at: StateStore.directory,
                                                 withIntermediateDirectories: true)
        try? data.write(to: approvalsFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: approvalsFile.path)
    }
}
