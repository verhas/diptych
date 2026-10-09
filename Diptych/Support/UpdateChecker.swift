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
/// No network connection is made at startup until the person has answered
/// the startup prompt at least once. `.ask` (never yet answered) shows that
/// prompt, rate-limited the same way `.enabled`'s actual check is: at most
/// once a day, using the one timestamp both share. Diptych ▸ Check for
/// Updates… is a request in its own right, so it always goes out.
///
/// Everything it has to say goes through a window's one sheet. That sheet is
/// often taken when an answer arrives -- the startup tip claims it while the
/// request is still in flight -- so what cannot be shown at once waits, and is
/// shown as soon as that window's sheet closes. Dropping it instead is how
/// 1.3.3 checked, found 1.4.0, and said nothing.
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
    private var isChecking = false
    private var pendingRelease: PendingRelease?

    /// The window that asked, and what it could not yet be shown.
    private weak var model: AppModel?
    private var waiting: AppModel.Dialog?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// Called once at startup. Shows the consent prompt, or runs the actual
    /// check, or does nothing at all -- whichever the saved preference and
    /// the last attempt's age say to do.
    func checkIfNeeded(on model: AppModel) {
        guard !hasActedThisLaunch else { return }
        hasActedThisLaunch = true
        self.model = model

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
            present(.updateCheckConsent)
        case .enabled:
            ConfigStore.shared.configuration.lastUpdateCheckAttempt = Date()
            Task { await performCheck(interactive: false) }
        }
    }

    /// Diptych ▸ Check for Updates…: says so when there is nothing new, or
    /// when GitHub could not be reached, instead of staying silent.
    func checkNow(on model: AppModel?) {
        if let model { self.model = model }
        Task { await performCheck(interactive: true) }
    }

    /// One of the startup prompt's three buttons.
    func userChose(_ preference: Configuration.UpdateCheckPreference) {
        ConfigStore.shared.configuration.updateCheckPreference = preference
        ConfigStore.shared.configuration.lastUpdateCheckAttempt = Date()
        // "Whenever Diptych starts" means this moment counts as one of the
        // starts it meant -- the whole point of asking was to make *this*
        // check possible, not to wait a full day for the first one.
        if preference == .enabled {
            Task { await performCheck(interactive: false) }
        }
    }

    /// A window's sheet has just closed: show whatever was waiting for it.
    func sheetClosed(on model: AppModel) {
        guard let dialog = waiting, model.dialog == nil else { return }
        waiting = nil
        self.model = model
        model.dialog = dialog
    }

    private func present(_ dialog: AppModel.Dialog) {
        guard let model else {
            presentWithoutWindow(dialog)
            return
        }
        if model.dialog == nil {
            model.dialog = dialog
        } else {
            waiting = dialog
        }
    }

    /// No Diptych window to show it in -- Check for Updates… chosen with only
    /// Settings open. An alert of its own rather than nothing at all.
    private func presentWithoutWindow(_ dialog: AppModel.Dialog) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        switch dialog {
        case .updateAvailable(let version):
            alert.messageText = "Diptych \(version) Is Available"
            alert.informativeText = Self.installExplanation
            alert.addButton(withTitle: "Download and Install")
            alert.addButton(withTitle: "Later")
            if alert.runSelectable() == .alertFirstButtonReturn { installPendingRelease() }
        case .notice(let title, let text):
            alert.messageText = title
            alert.informativeText = text
            alert.runSelectable()
        default:
            break
        }
    }

    static let installExplanation =
        "Download it and open the disk image it arrives in, ready to drag "
        + "into Applications. Diptych will quit on its own once that is done."

    private func performCheck(interactive: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        if interactive {
            ConfigStore.shared.configuration.lastUpdateCheckAttempt = Date()
        }

        let release: GitHubRelease
        do {
            release = try await fetchLatestRelease()
        } catch {
            if interactive {
                present(.notice(title: "Could not check for updates",
                                text: error.localizedDescription))
            }
            return
        }

        let remoteVersion = release.tagName.hasPrefix("v")
            ? String(release.tagName.dropFirst()) : release.tagName
        guard Self.isNewer(remoteVersion, than: Self.currentVersion) else {
            if interactive, Self.isNewer(Self.currentVersion, than: remoteVersion) {
                present(.notice(title: "Ahead of the release",
                                text: "You have \(Self.currentVersion), and the newest "
                                    + "release is only \(remoteVersion). A bleeding-edge "
                                    + "build, straight off main \u{2014} like a true hacker!"))
            } else if interactive {
                present(.notice(title: "Diptych is up to date",
                                text: "You have version \(Self.currentVersion), "
                                    + "the newest there is."))
            }
            return
        }
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
            if interactive {
                present(.notice(title: "Diptych \(remoteVersion) is out",
                                text: "It has no disk image to download yet."))
            }
            return
        }

        pendingRelease = PendingRelease(version: remoteVersion, asset: asset)
        present(.updateAvailable(version: remoteVersion))
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.releaseURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
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
            alert.runSelectable()
        }
    }
}
