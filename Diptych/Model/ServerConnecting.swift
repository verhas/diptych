import AppKit
import Foundation

/// Go ▸ Connect to Server…: mounting a file server and opening it in a pane.
extension AppModel {

    func requestConnectToServer() {
        connectProblem = nil
        dialog = .connectServer
    }

    /// What was typed into the sheet.
    func connect(typed text: String) {
        switch ServerAddress.parse(text) {
        case .failure(let problem): connectProblem = problem.message
        case .success(let url): connect(to: url, in: active)
        }
    }

    /// Mounts `url` unless it is mounted already, and opens it in `pane`:
    /// `opening` when that is given and is there -- a pane coming back to
    /// where it was -- and otherwise the folder the address names.
    func connect(to url: URL, in pane: PaneModel, opening: URL? = nil) {
        guard connectingTo == nil else {
            report("Still connecting to \(ServerAddress.title(of: connectingTo!)).")
            return
        }
        // SFTP is not mounted, so NetFS has nothing to do with it: it has its
        // own connection, which asks about an unknown host before it sends anything.
        if ServerAddress.kind(of: url) == .sftp {
            connectSFTP(url)
            return
        }
        connectProblem = nil
        connectingTo = url
        let request = ServerMounter.Request()
        connectRequest = request

        Task {
            // Mounted already -- by Finder, or by an earlier connection: no
            // need to ask the server, nor the user.
            if let point = await BlockingWork.run({ ServerVolumes.mountPoint(of: url) }) {
                finishConnecting()
                arrive(url, at: point, in: pane, opening: opening)
                return
            }
            let outcome = await ServerMounter.mount(url, request: request)
            switch outcome {
            case .mounted(let points):
                finishConnecting()
                VolumeList.shared.reload()
                guard let point = points.first else { return }
                arrive(url, at: point, in: pane, opening: opening)
            case .cancelled:
                finishConnecting()
            case .failed(let problem):
                // Mounted between the look and the mount: find where.
                if let point = await BlockingWork.run({ ServerVolumes.mountPoint(of: url) }) {
                    finishConnecting()
                    arrive(url, at: point, in: pane, opening: opening)
                    return
                }
                finishConnecting()
                report(problem.message)
            }
        }
    }

    /// A saved server, from the sidebar: opened if it is connected,
    /// connected if not.
    func openServer(_ server: KnownServer) {
        guard let url = server.url else { return }
        connect(to: url, in: active)
    }

    /// Connects the server a pane is waiting for, and opens the folder it
    /// was in.
    func reconnect(_ pane: PaneModel) {
        guard let server = pane.awaitingServer, let url = server.url else { return }
        connect(to: url, in: pane, opening: pane.directory)
    }

    /// Unmounts a saved server's share, as its eject button does.
    func disconnect(_ server: KnownServer) {
        guard let point = VolumeList.shared.mountPoint(of: server),
              let volume = VolumeList.shared.volume(at: point) else { return }
        eject(volume)
    }

    /// Stops a connection that is taking too long, from the sheet's Cancel.
    func cancelConnecting() {
        connectRequest?.cancel()
        finishConnecting()
    }

    func finishConnecting() {
        connectingTo = nil
        connectRequest = nil
    }

    private func arrive(_ url: URL, at point: URL, in pane: PaneModel, opening: URL?) {
        ServerStore.shared.used(url, mountPoint: point)
        if dialog == .connectServer { dialog = nil }

        var target = point
        if let opening, opening.path.hasPrefix(point.path) {
            target = opening
        } else {
            for part in ServerAddress.inside(url) {
                target.appendPathComponent(part, isDirectory: true)
            }
        }
        // A folder inside the share that is not there opens the share.
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
            || !isDirectory.boolValue {
            target = point
        }
        pane.navigate(to: target)
    }

    /// In the sheet while it is open; otherwise as a passing message.
    func report(_ message: String) {
        if dialog == .connectServer {
            connectProblem = message
        } else {
            flash(message)
        }
    }
}

/// The saved servers marked Connect When Diptych Starts, mounted at launch
/// without opening anything. One that cannot be reached stays grey in the
/// sidebar, a click away; nothing interrupts the start for it.
@MainActor
enum ServerAutoConnect {

    /// After sleep the network takes a moment to come back; then every pane
    /// on a server is listed again, and one whose server went away while
    /// asleep asks to connect it.
    static func watchWaking() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                VolumeList.shared.reload()
                for model in KeyRouter.shared.allModels {
                    for pane in [model.left, model.right]
                    where pane.volume.isNetwork || pane.awaitingServer != nil {
                        if pane.awaitingServer != nil {
                            model.reconnect(pane)
                        } else {
                            pane.reload()
                        }
                    }
                }
            }
        }
    }

    static func start() {
        let wanted = ServerStore.shared.saved.filter(\.openAtLogin)
        guard !wanted.isEmpty else { return }
        Task {
            let mounted = await BlockingWork.run { ServerVolumes.mounted() }
            for server in wanted {
                guard let url = server.url,
                      ServerVolumes.mountPoint(of: url, among: mounted) == nil else { continue }
                // One after another: two password questions at once would
                // be one too many.
                if case .mounted(let points) = await ServerMounter.mount(url, request: .init()) {
                    ServerStore.shared.used(url, mountPoint: points.first)
                }
            }
            VolumeList.shared.reload()
        }
    }
}
