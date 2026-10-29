import Citadel
import Foundation
import NIOSSH

/// One attempt to connect to an SFTP server, kept while the person answers
/// a question about it. The password is kept only for that time.
nonisolated struct SFTPConnectRequest: Sendable {
    let url: URL
    let username: String
    let password: String?
}

/// What the trust dialog shows about a host whose key Diptych does not trust.
struct SFTPTrustPrompt: Equatable {
    let host: String
    let port: Int
    /// The host as Diptych files it in its own list.
    let filing: String
    let presented: NIOSSHPublicKey
    let fingerprint: String
    let keyType: String
    let standing: KnownHosts.Standing
}

/// What the login dialog shows: the server, the user name to sign in as, and
/// whether the password just tried was refused.
struct SFTPLoginPrompt: Equatable {
    let host: String
    let username: String
    let wasWrong: Bool
}

/// The outcome of one connection attempt.
private enum SFTPAttempt {
    case connected(SFTPSession)
    case hostKey(SFTPHostKeyProblem)
    case refused(Error)
}

/// Connect to Server, for an `sftp://` address: the keys in `~/.ssh` are tried
/// first, then a password the person types. An unknown host is put to the
/// person before anything is sent to it.
extension AppModel {

    /// Connects to the server at `url`, as the user named in it or the one
    /// signed in here.
    func connectSFTP(_ url: URL) {
        let username = url.user(percentEncoded: false) ?? NSUserName()
        attemptSFTP(SFTPConnectRequest(url: url, username: username, password: nil))
    }

    /// The login dialog's answer: a user name and a password.
    func answerSFTPLogin(username: String, password: String) {
        guard let request = sftpRequest else { return }
        dialog = nil
        sftpLogin = nil
        attemptSFTP(SFTPConnectRequest(url: request.url, username: username, password: password))
    }

    /// Asks how often the server at a sidebar entry is checked.
    func requestKeepAlive(_ entry: SidebarEntry) {
        guard let server = RemoteBrowsing.server(root: entry.url) else { return }
        keepAliveServer = entry.url
        let saved = ServerStore.shared.server(for: RemoteBrowsing.address(of: server))?.keepAliveSeconds
        textInput = saved.map(String.init) ?? "default"
        dialog = .keepAlive
    }

    /// What the keep-alive dialog says: what the ssh configuration says, and
    /// what Diptych is set to.
    var keepAliveHint: String {
        guard let root = keepAliveServer, let server = RemoteBrowsing.server(root: root) else { return "" }
        let sshValue = SSHConfig.serverAliveInterval(for: server.host).map { "\($0) seconds" } ?? "nothing"
        return "Checks the connection to \(server.host) this often, so that a network device does not end "
            + "it while it is idle. Type a number of seconds, 0 for never, or default. "
            + "~/.ssh/config says \(sshValue) for this host. A minute when neither says."
    }

    /// Sets the keep-alive interval the dialog asked for, for the server and for
    /// the connection as it is now. Nothing changes when the text is not understood.
    func applyKeepAlive() {
        guard let root = keepAliveServer, let server = RemoteBrowsing.server(root: root) else {
            dialog = nil
            return
        }
        let text = textInput.trimmingCharacters(in: .whitespaces).lowercased()
        let seconds: Int?
        if text == "default" {
            seconds = nil
        } else if let number = Int(text), number >= 0 {
            seconds = number
        } else {
            flash("Type a number of seconds, 0 for never, or default", error: true)
            return
        }
        dialog = nil
        keepAliveServer = nil
        ServerStore.shared.setKeepAlive(seconds, for: RemoteBrowsing.address(of: server))
        let interval = SFTPKeepAlive.interval(host: server.host, override: seconds)
        Task { await server.setKeepAlive(interval) }
        let state = interval.map { "every \($0.components.seconds) seconds" } ?? "never"
        flash("\(server.host) is checked \(state)", error: false)
    }

    func cancelSFTPLogin() {
        sftpRequest = nil
        sftpLogin = nil
        dialog = nil
    }

    /// The trust dialog's answer: keep the host's key in Diptych's own list,
    /// then connect again.
    func trustSFTPHost() {
        guard let prompt = sftpTrust, prompt.standing != .differs, let request = sftpRequest else {
            return
        }
        sftpTrust = nil
        dialog = nil
        do {
            try SFTPHostKeys.standard.trust(prompt.presented, for: prompt.filing)
        } catch {
            sftpRequest = nil
            report("Could not keep the host key: \(error.localizedDescription)")
            return
        }
        attemptSFTP(request)
    }

    func declineSFTPTrust() {
        sftpTrust = nil
        sftpRequest = nil
        dialog = nil
    }

    private func attemptSFTP(_ request: SFTPConnectRequest) {
        guard connectingTo == nil else {
            report("Still connecting to \(ServerAddress.title(of: connectingTo!)).")
            return
        }
        connectProblem = nil
        connectingTo = request.url
        sftpRequest = request

        Task {
            // The agent's keys first: they are the ones the person keeps unlocked.
            // Then the key files, then the password.
            var keyLogins: [SFTPLogin] = []
            if let agent = await BlockingWork.run({ SSHAgent.usable() }) {
                keyLogins.append(.agent(agent))
            }
            keyLogins += SFTPLogin.keyFilesInSSHFolder.map { SFTPLogin.keyFile($0) }

            for login in keyLogins {
                // Any failure moves on to the next key: a key can fail to load,
                // be refused, or be encrypted, and the password is still to come.
                switch await trySFTP(request, login) {
                case .connected(let session):
                    await finishSFTP(session, request, login: login)
                    return
                case .hostKey(let problem):
                    askAboutHost(problem, request)
                    return
                case .refused:
                    continue
                }
            }

            guard let password = request.password else {
                finishConnecting()
                askForSFTPLogin(request, wasWrong: false)
                return
            }
            switch await trySFTP(request, .password(password)) {
            case .connected(let session):
                await finishSFTP(session, request, login: .password(password))
            case .hostKey(let problem):
                askAboutHost(problem, request)
            case .refused(let error):
                finishConnecting()
                if Self.isRefusedLogin(error) {
                    askForSFTPLogin(request, wasWrong: true)
                } else {
                    report("Could not connect to \(ServerAddress.title(of: request.url)): "
                           + error.localizedDescription)
                }
            }
        }
    }

    private func trySFTP(_ request: SFTPConnectRequest, _ login: SFTPLogin) async -> SFTPAttempt {
        do {
            let session = try await SFTPSession.connect(
                host: request.url.host(percentEncoded: false) ?? "",
                port: request.url.port ?? 22,
                username: request.username,
                login: login)
            return .connected(session)
        } catch let problem as SFTPHostKeyProblem {
            return .hostKey(problem)
        } catch {
            return .refused(error)
        }
    }

    /// The server did not accept the user name or the password, as opposed to
    /// not answering at all.
    private static func isRefusedLogin(_ error: Error) -> Bool {
        if error is AuthenticationFailed { return true }
        if case .allAuthenticationOptionsFailed? = error as? SSHClientError { return true }
        return false
    }

    /// Signed in: the server is registered, and the pane goes to the folder
    /// the address names, or to the home folder when it names none.
    /// `login` is how the session signed in: the same way, it is signed in again
    /// when the connection is lost.
    private func finishSFTP(_ session: SFTPSession, _ request: SFTPConnectRequest,
                            login: SFTPLogin) async {
        finishConnecting()
        sftpRequest = nil
        let pane = active
        let host = request.url.host(percentEncoded: false) ?? ""
        let port = request.url.port ?? 22
        let typed = request.url.path(percentEncoded: false)
        let target: String
        if typed.isEmpty {
            target = (try? await session.homeDirectory()) ?? "/"
        } else {
            target = typed
        }

        let root = RemoteBrowsing.shadowRoot(user: request.username, host: host, port: port)
        // The shadow reads through a connection that is kept alive, and signed in
        // again when it is lost, as the same login.
        // The sign-in is kept only while the connection is: it is forgotten when the
        // server is disconnected, and with it the password.
        let username = request.username
        let credential = SFTPCredential(login)
        let remote = ReconnectingRemote(link: .over(session), open: {
            guard let login = credential.login else { throw SFTPLoginError.signInForgotten }
            return .over(try await SFTPSession.connect(host: host, port: port, username: username, login: login))
        }, interval: SFTPKeepAlive.interval(
            host: host, override: ServerStore.shared.server(for: request.url)?.keepAliveSeconds))
        await remote.startKeepingAlive()
        let mirror = SFTPMirror(root: root, remote: remote, host: host)
        let server = RemoteBrowsing.Server(
            user: request.username, host: host, port: port, root: root, mirror: mirror,
            close: {
                credential.forget()
                await remote.close()
            },
            setKeepAlive: { await remote.setKeepAlive($0) })
        do {
            try await mirror.populate(target)
        } catch {
            await remote.close()
            dialog = .message("Could not list \(target) on \(host): \(error.localizedDescription)")
            return
        }
        RemoteBrowsing.add(server)
        // Recorded as a recent server, with the user it signed in as.
        var address = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        address?.user = request.username
        address?.password = nil
        if let address = address?.url {
            ServerStore.shared.used(address, mountPoint: nil)
        }
        if dialog == .connectServer { dialog = nil }
        VolumeList.shared.reload()
        pane.navigate(to: RemoteBrowsing.localURL(on: server, remote: target))
    }

    private func askAboutHost(_ problem: SFTPHostKeyProblem, _ request: SFTPConnectRequest) {
        finishConnecting()
        switch problem {
        case .unknown(let filing, let presented):
            guard let key = try? NIOSSHPublicKey(openSSHPublicKey: presented),
                  let host = request.url.host(percentEncoded: false) else {
                report("The server presented a host key that could not be read.")
                return
            }
            let port = request.url.port ?? 22
            sftpRequest = request
            sftpTrust = SFTPTrustPrompt(
                host: host,
                port: port,
                filing: filing,
                presented: key,
                fingerprint: KnownHosts.fingerprint(of: key),
                keyType: presented.split(separator: " ").first.map(String.init) ?? "",
                standing: KnownHosts.standing(host: host, port: port, key: key))
            dialog = .sftpTrust

        case .changed(let filing, _):
            sftpRequest = nil
            dialog = .notice(title: "The Host Key for \(filing) Has Changed",
                             text: Self.changedKeyText(filing: filing))
        }
    }

    /// Why a changed key is refused, and exactly which lines to delete for the
    /// person to trust the server again.
    static func changedKeyText(filing: String) -> String {
        let keys = SFTPHostKeys.standard
        let path = "~/.diptych/sftp_known_hosts"
        let entries = keys.entries(for: filing)
        var text = "Diptych keeps a different key for this server, and the server is now presenting "
            + "another. An impostor would present a different key too, so Diptych has not "
            + "connected and has not trusted the new key.\n\n"
        if entries.isEmpty {
            text += "Diptych\u{2019}s list of keys has no line for \(filing) any more. Connect "
                + "again to be asked about the key.\n\n"
        } else {
            text += "If the server was rebuilt or its key was renewed on purpose, edit \(path) "
                + "and delete the \(entries.count == 1 ? "line" : "lines") kept for "
                + "\(filing), then connect again:\n"
            for entry in entries {
                text += "  line \(entry.line): \(entry.text)\n"
            }
            text += "\nLeave the other lines as they are. Delete these only if you expected the "
                + "key to change."
        }
        return text
    }

    private func askForSFTPLogin(_ request: SFTPConnectRequest, wasWrong: Bool) {
        sftpRequest = request
        sftpLogin = SFTPLoginPrompt(host: request.url.host(percentEncoded: false) ?? "",
                                    username: request.username, wasWrong: wasWrong)
        dialog = .sftpLogin
    }
}
