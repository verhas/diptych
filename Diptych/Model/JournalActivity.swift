import AppKit

/// What the journal keeps beside what was done to files and what was looked
/// at: how the files were shown, settings changed, windows opened and closed,
/// Diptych starting and quitting, and what agents and Siri/Shortcuts asked.
///
/// What changes by the keystroke -- a filter typed, a slider dragged, the
/// keyboard going from pane to pane -- is recorded once it has settled, as
/// where it ended up: typing a filter of ten letters is one entry, not ten.
@MainActor
enum JournalActivity {

    // MARK: - Navigation

    private static var settling: [String: Task<Void, Never>] = [:]
    private static var lastSettled: [String: String] = [:]

    /// How a pane shows its folder changed. With `settleKey`, recorded only
    /// once nothing more has changed under that key for a moment, and not at
    /// all when it ended where the last entry for it did.
    static func navigated(_ kind: String, _ told: String, folder: String? = nil,
                          settleKey: String? = nil) {
        guard Journal.isRecording(.navigation) else { return }
        guard let settleKey else {
            record(kind, told, folder: folder)
            return
        }
        settling[settleKey]?.cancel()
        settling[settleKey] = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            settling[settleKey] = nil
            guard lastSettled[settleKey] != told else { return }
            lastSettled[settleKey] = told
            record(kind, told, folder: folder)
        }
    }

    private static func record(_ kind: String, _ told: String, folder: String?) {
        Journal.shared.record(
            kind: kind, category: .navigation, told: told,
            files: folder.map { [Journal.File(before: $0, after: $0)] } ?? [], folder: folder)
    }

    /// "the left pane, in ~/Documents", for a sentence.
    static func describe(_ pane: PaneModel) -> String {
        let side = pane.owner.map { $0.left === pane ? "left" : "right" } ?? "a"
        return "the \(side) pane, in \(NamingTemplate.tilde(RemoteBrowsing.journalPath(pane.directory)))"
    }

    static func folder(of pane: PaneModel) -> String {
        RemoteBrowsing.journalPath(pane.directory)
    }

    // MARK: - Settings

    /// Kept with the settings, but set by Diptych itself, not by anybody.
    private static let bookkeeping: Set<String> = ["lastUpdateCheckAttempt"]

    private static var settingsBefore: Configuration?
    private static var settingsTask: Task<Void, Never>?

    /// A setting changed. Recorded once the settings have stood still for a
    /// moment, as each one that differs from before: from what, to what.
    static func settingsChanged(from old: Configuration, to new: Configuration) {
        // Switching the journal off is the one change it records while off.
        if old.journalEnabled != new.journalEnabled {
            Journal.shared.write(
                kind: "Setting", category: .settings,
                told: "The journal was switched \(new.journalEnabled ? "on" : "off").",
                files: [], origin: Journal.origin)
        }
        if settingsBefore == nil { settingsBefore = old }
        settingsTask?.cancel()
        settingsTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let before = settingsBefore else { return }
            settingsBefore = nil
            settingsTask = nil
            let after = ConfigStore.shared.configuration
            for (key, from, to) in differences(before, after)
            where key != "journalEnabled" && !bookkeeping.contains(key) {
                Journal.shared.record(kind: "Setting", category: .settings,
                                      told: "The setting \(key) was changed from \(from) to \(to).")
            }
        }
    }

    /// Each top-level setting that differs, with its value before and after,
    /// shortened to be read.
    static func differences(_ old: Configuration, _ new: Configuration) -> [(String, String, String)] {
        func dictionary(_ configuration: Configuration) -> [String: Any] {
            guard let data = try? JSONEncoder().encode(configuration),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return object
        }
        func text(_ value: Any?) -> String {
            guard let value, !(value is NSNull) else { return "nothing" }
            let written: String
            if let string = value as? String {
                written = "\u{201C}\(string)\u{201D}"
            } else if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) {
                written = String(decoding: data, as: UTF8.self)
            } else {
                written = "\(value)"
            }
            return written.count > 120 ? String(written.prefix(119)) + "\u{2026}" : written
        }
        // A setting that is itself a table of settings -- the column widths --
        // is told by the entries in it that changed, not as the whole table.
        func compare(_ before: [String: Any], _ after: [String: Any], prefix: String) -> [(String, String, String)] {
            Set(before.keys).union(after.keys).sorted().flatMap { key -> [(String, String, String)] in
                let name = prefix + key
                if let inner = before[key] as? [String: Any], let innerAfter = after[key] as? [String: Any] {
                    return compare(inner, innerAfter, prefix: name + ".")
                }
                let from = text(before[key]), to = text(after[key])
                return from == to ? [] : [(name, from, to)]
            }
        }
        return compare(dictionary(old), dictionary(new), prefix: "")
    }

    // MARK: - Windows

    private static var seen: Set<ObjectIdentifier> = []
    private static var observers: [NSObjectProtocol] = []

    /// Every window that opens and closes, by its title. Panels -- Quick
    /// Look, an open dialog -- and sheets are not windows of Diptych's own.
    static func watchWindows() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                            queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { windowOpened(window) }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                            queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { windowClosed(window) }
        })
    }

    private static func counts(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.sheetParent == nil && !window.title.isEmpty
    }

    private static func windowOpened(_ window: NSWindow) {
        guard counts(window), seen.insert(ObjectIdentifier(window)).inserted,
              Journal.isRecording(.window) else { return }
        Journal.shared.record(kind: "Open Window", category: .window,
                              told: "The window \u{201C}\(window.title)\u{201D} was opened.")
    }

    private static func windowClosed(_ window: NSWindow) {
        guard seen.remove(ObjectIdentifier(window)) != nil, counts(window),
              Journal.isRecording(.window) else { return }
        Journal.shared.record(kind: "Close Window", category: .window,
                              told: "The window \u{201C}\(window.title)\u{201D} was closed.")
    }

    // MARK: - Diptych itself

    static func started() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        Journal.shared.record(kind: "Start", category: .app,
                              told: "Diptych \(version) (\(build)) started.")
        watchWindows()
    }

    /// Written before the process goes: the journal's queue is waited for.
    static func quitting() {
        Journal.shared.record(kind: "Quit", category: .app, told: "Diptych quit.")
        Journal.shared.flush()
    }

    // MARK: - Requests

    /// An agent's tool call, or a Siri/Shortcuts action, arrived -- or was
    /// turned away.
    static func requested(_ summary: String, detail: String?, refused: Bool) {
        let fromShortcuts = summary.hasPrefix("Siri/Shortcuts: ")
        let name = fromShortcuts ? String(summary.dropFirst("Siri/Shortcuts: ".count)) : summary
        let who = fromShortcuts ? "Siri/Shortcuts" : "An agent"
        let what = detail.map { $0.count > 300 ? String($0.prefix(299)) + "\u{2026}" : $0 }
        Journal.shared.record(
            kind: name, category: .request,
            told: "\(who) asked for \(name)" + (what.map { " (\($0))" } ?? "")
                + (refused ? ", and was refused." : "."),
            origin: fromShortcuts ? .shortcuts : .agent, outcome: refused ? "failed" : "done")
    }
}

extension String {
    /// The first letter in capitals, for a phrase starting a sentence.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
