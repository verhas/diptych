import AppKit
import Foundation

/// The latest release GitHub reports, as much of it as matters here.
private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}

/// Checks GitHub for a newer release, asks before doing either of the two
/// things that could surprise someone -- reaching the network at all, and
/// replacing the running app -- and downloads and opens the new version's
/// disk image when told to.
///
/// No network connection is made until the person has answered the startup
/// prompt at least once. `.ask` (never yet answered) shows that prompt,
/// rate-limited the same way `.enabled`'s actual check is: at most once a
/// day, using the one timestamp both share.
@MainActor
final class UpdateChecker {

    static let shared = UpdateChecker()
    private init() {}

    private static let repository = "verhas/diptych"
    private static let checkInterval: TimeInterval = 86400
    private static let releaseURL = URL(
        string: "https://api.github.com/repos/\(repository)/releases/latest")!

    private struct PendingRelease {
        let version: String
        let asset: GitHubRelease.Asset
    }

    private var hasActedThisLaunch = false
    private var showUpdateAvailable: ((String) -> Void)?
    private var pendingRelease: PendingRelease?

    /// Called once at startup. Shows the consent prompt, or runs the actual
    /// check, or does nothing at all -- whichever the saved preference and
    /// the last attempt's age say to do.
    func checkIfNeeded(showConsent: @escaping () -> Void,
                       showUpdateAvailable: @escaping (String) -> Void) {
        guard !hasActedThisLaunch else { return }
        hasActedThisLaunch = true
        self.showUpdateAvailable = showUpdateAvailable

        let config = ConfigStore.shared.configuration
        if let last = config.lastUpdateCheckAttempt,
           Date().timeIntervalSince(last) < Self.checkInterval {
            return
        }

        switch config.updateCheckPreference {
        case .never:
            return
        case .ask:
            ConfigStore.shared.configuration.lastUpdateCheckAttempt = Date()
            showConsent()
        case .enabled:
            ConfigStore.shared.configuration.lastUpdateCheckAttempt = Date()
            Task { await performCheck() }
        }
    }

    /// One of the startup prompt's three buttons.
    func userChose(_ preference: Configuration.UpdateCheckPreference) {
        ConfigStore.shared.configuration.updateCheckPreference = preference
        ConfigStore.shared.configuration.lastUpdateCheckAttempt = Date()
        // "Whenever Diptych starts" means this moment counts as one of the
        // starts it meant -- the whole point of asking was to make *this*
        // check possible, not to wait a full day for the first one.
        if preference == .enabled {
            Task { await performCheck() }
        }
    }

    private func performCheck() async {
        guard let showUpdateAvailable,
              let release = try? await fetchLatestRelease() else { return }

        let remoteVersion = release.tagName.hasPrefix("v")
            ? String(release.tagName.dropFirst()) : release.tagName
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard Self.isNewer(remoteVersion, than: currentVersion),
              let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") })
        else { return }

        pendingRelease = PendingRelease(version: remoteVersion, asset: asset)
        showUpdateAvailable(remoteVersion)
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.releaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    /// Plain numeric semantic-version comparison: "1.3.10" is newer than
    /// "1.3.9", which comparing the strings themselves would get backwards.
    /// Not `private`, so a test can hold it to that directly.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let r = parts(remote), l = parts(local)
        for i in 0 ..< max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// The confirmation dialog's one button that does something. Downloads
    /// the new version's disk image to ~/Downloads, opens it -- which is what
    /// mounts it and shows the Finder window it arrives in -- and quits.
    ///
    /// No window of this app's own is shown from here on: `NSApp.hide` before
    /// any of it, since what follows ends in quitting anyway and a window
    /// reappearing for the few seconds a download takes would answer nothing
    /// anyone asked for.
    func installPendingRelease() {
        guard let release = pendingRelease else { return }
        NSApp.hide(nil)
        Task { await performInstall(release) }
    }

    private func performInstall(_ release: PendingRelease) async {
        do {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
                .first ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Downloads")
            let destination = downloads.appendingPathComponent(release.asset.name)

            let (downloaded, _) = try await URLSession.shared.download(from: release.asset.browserDownloadURL)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: downloaded, to: destination)

            NSWorkspace.shared.open(destination)

            // Flushed by hand: quitting this way -- deliberately, so nothing
            // can ask to confirm it -- skips the debounced saves that
            // normally happen on `willTerminateNotification`.
            ConfigStore.shared.saveNow()
            StateStore.shared.saveNow()
            exit(0)
        } catch {
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "\u{201C}\(release.asset.name)\u{201D} could not be downloaded."
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
