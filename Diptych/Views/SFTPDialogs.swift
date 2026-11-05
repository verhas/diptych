import SwiftUI

/// The question asked before an SFTP server is trusted for the first time:
/// the key it presented, and what ~/.ssh/known_hosts says about the same host.
struct SFTPTrustView: View {

    let prompt: SFTPTrustPrompt
    let trust: () -> Void
    let decline: () -> Void

    var body: some View {
        Text("Trust This Server?").font(.headline)

        Text("\(prompt.host), port \(prompt.port), is presenting a key that Diptych does not "
             + "trust yet.")
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 3) {
            Text("Key type: \(prompt.keyType)")
            Text("Fingerprint: \(prompt.fingerprint)")
        }
        .font(.system(.callout, design: .monospaced))
        .textSelection(.enabled)

        Divider()

        // Scrolls: the note for a host unknown to OpenSSH is the longest, and a
        // dialog that cuts it off would hide the warning it exists to give.
        ScrollView {
            Text(standingNote)
                .font(.subheadline)
                .foregroundStyle(prompt.standing == .differs ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 180)

        HStack {
            Spacer()
            Button("Cancel") { decline() }
                .keyboardShortcut(.cancelAction)
            if prompt.standing != .differs {
                Button("Trust and Connect") { trust() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// What ~/.ssh/known_hosts says, and what trusting here does and does not do.
    private var standingNote: String {
        switch prompt.standing {
        case .trusted:
            return "~/.ssh/known_hosts already trusts this host with this same key, so ssh "
                + "connects to it without asking.\n\n"
                + "Trusting it here adds the key to Diptych\u{2019}s own list, in "
                + "~/.diptych/sftp_known_hosts. Diptych does not change ~/.ssh/known_hosts."
        case .absent:
            return "~/.ssh/known_hosts does not have this host.\n\n"
                + "Trusting it here will not make the host trusted for an interactive ssh "
                + "login. Diptych keeps its own list, in ~/.diptych/sftp_known_hosts, and "
                + "does not update ~/.ssh/known_hosts. An ssh in Terminal will still ask "
                + "about this host."
        case .differs:
            return "~/.ssh/known_hosts already keeps a different key for this host, so ssh would "
                + "refuse this one too.\n\n"
                + "Diptych will not trust it. Check with whoever runs the server before you "
                + "connect."
        }
    }
}

/// Signing in to an SFTP server with a user name and a password, when the keys
/// in ~/.ssh did not do it.
struct SFTPLoginView: View {

    let prompt: SFTPLoginPrompt
    let connect: (_ username: String, _ password: String) -> Void
    let cancel: () -> Void

    @State private var username: String
    @State private var password = ""
    @FocusState private var focused: Bool

    init(prompt: SFTPLoginPrompt,
         connect: @escaping (_ username: String, _ password: String) -> Void,
         cancel: @escaping () -> Void) {
        self.prompt = prompt
        self.connect = connect
        self.cancel = cancel
        _username = State(initialValue: prompt.username)
    }

    var body: some View {
        Text("Sign In to \(prompt.host)").font(.headline)

        if prompt.wasWrong {
            Text("The server did not accept that user name and password. Try again.")
                .font(.subheadline)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(SFTPLogin.keyFilesInSSHFolder.isEmpty
                 ? "Type the password for this account."
                 : "The keys in ~/.ssh did not sign you in. Type the password for this account.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        TextField("User name", text: $username)
            .textFieldStyle(.roundedBorder)
        SecureField("Password", text: $password)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit { if canConnect { connect(username, password) } }
            .onAppear { focused = true }

        HStack {
            Spacer()
            Button("Cancel") { cancel() }
                .keyboardShortcut(.cancelAction)
            Button("Connect") { connect(username, password) }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect)
        }
    }

    private var canConnect: Bool {
        !username.isEmpty && !password.isEmpty
    }
}

/// The sudo password, for one change on a server that only root may make: the
/// command is run as root, the session stays the user's. How long the password
/// is kept is the person's choice; it is never written anywhere.
struct SudoPasswordView: View {

    let prompt: AppModel.SudoPrompt
    let answer: (SudoAnswer?) -> Void

    @State private var password = ""
    @State private var keep: SudoKeep = .once
    @FocusState private var focused: Bool

    var body: some View {
        Text("Change It as Root on \(prompt.host)?").font(.headline)

        Text("\(prompt.host) does not let \(prompt.user) make this change. With sudo, the one "
             + "command is run as root; everything else stays \(prompt.user)\u{2019}s. Type the "
             + "sudo password for \(prompt.user) on \(prompt.host).")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if prompt.wasWrong {
            Text("That password was not accepted. Try again.")
                .font(.subheadline)
                .foregroundStyle(.red)
        }

        SecureField("sudo password", text: $password)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear { focused = true }
            .onSubmit { if !password.isEmpty { answer(SudoAnswer(password: password, keep: keep)) } }

        Picker("", selection: $keep) {
            ForEach(SudoKeep.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden()

        Text("Kept in memory only, never on disk, and forgotten when the server is disconnected "
             + "or Diptych quits.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        HStack {
            Spacer()
            Button("Cancel") { answer(nil) }
                .keyboardShortcut(.cancelAction)
            Button("Run with sudo") { answer(SudoAnswer(password: password, keep: keep)) }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
        }
    }
}
