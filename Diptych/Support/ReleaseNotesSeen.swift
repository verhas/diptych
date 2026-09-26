import Foundation

/// Which version's release notes have already been shown -- one line of
/// plain text in its own file under `~/.diptych`, deliberately apart from
/// `config.json`. It is not a preference: nothing in Settings shows it, a
/// person never edits it by hand, and `ConfigStore` rewriting or resetting
/// configuration must never touch it, or an update would show its notes
/// again every time something else in Settings is changed.
@MainActor
enum ReleaseNotesSeen {

    static let url = StateStore.directory.appendingPathComponent("release-notes-version")

    /// Empty on a build with no version at all, which only happens outside
    /// of Xcode's own synthesized Info.plist -- never in practice, but empty
    /// is the answer that shows nothing rather than showing notes forever.
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// The version last recorded, or nil the very first time Diptych has
    /// ever run on this Mac.
    private static var lastShown: String? {
        (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True the first time a version ever runs, and false again the moment
    /// `markShown()` has recorded it.
    static var shouldShow: Bool {
        let current = currentVersion
        return !current.isEmpty && lastShown != current
    }

    static func markShown() {
        let current = currentVersion
        guard !current.isEmpty else { return }
        try? FileManager.default.createDirectory(at: StateStore.directory,
                                                  withIntermediateDirectories: true)
        try? current.write(to: url, atomically: true, encoding: .utf8)
    }
}
