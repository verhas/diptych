import SwiftUI

/// Go ▸ Connect to Server…: an address, the servers kept and used before,
/// and -- while connecting -- a way to stop.
struct ConnectServerView: View {

    let model: AppModel
    let onClose: () -> Void

    @State private var address = ""
    /// A kept server's id, or a found one's prefixed with `found:`.
    @State private var chosen: String?
    @State private var browser = ServerBrowser()
    /// A found server being looked up, to fill in its address.
    @State private var lookingUp: String?
    @Bindable private var store = ServerStore.shared
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to Server").font(.headline)

            TextField("smb://server/share", text: $address)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($addressFocused)
                .onSubmit(connect)
                .disabled(model.connectingTo != nil)
                .onChange(of: address) { _, _ in model.connectProblem = nil }

            Text("smb:// for Windows shares and most NAS boxes, nfs:// for NFS, https:// for "
                 + "WebDAV, ftp:// (read-only). A bare name is an SMB server. macOS asks for the "
                 + "name and password itself, and can keep them in your Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let problem = model.connectProblem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            List(selection: $chosen) {
                if !store.saved.isEmpty {
                    Section("Saved") { ForEach(store.saved) { row($0) } }
                }
                if !store.recent.isEmpty {
                    Section("Recent") { ForEach(store.recent) { row($0) } }
                }
                Section("On This Network") {
                    if let problem = browser.problem {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if browser.found.isEmpty {
                        Text("Looking\u{2026}").font(.caption).foregroundStyle(.tertiary)
                    }
                    ForEach(browser.found) { foundRow($0) }
                }
            }
            .listStyle(.bordered)
            .textSelection(.disabled)   // a click chooses the row, not selects its text
            .frame(height: 240)
            .onChange(of: chosen) { _, id in
                if let server = store.servers.first(where: { $0.id == id }) {
                    address = server.address
                } else if let found = found(id) {
                    Task { if let url = await lookUp(found) { address = url.absoluteString } }
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let server = server(ids) {
                    Button("Connect") { connect(server) }
                    Button(server.saved ? "Remove from Saved" : "Save") {
                        store.setSaved(server, !server.saved)
                    }
                    Divider()
                    Button("Forget") { store.forget(server) }
                } else if let found = found(ids.first) {
                    Button("Connect") { connect(found) }
                }
            } primaryAction: { ids in
                if let server = server(ids) {
                    connect(server)
                } else if let found = found(ids.first) {
                    connect(found)
                }
            }

            HStack {
                if let name = lookingUp {
                    ProgressView().controlSize(.small)
                    Text("Looking up \(name)\u{2026}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let url = model.connectingTo {
                    ProgressView().controlSize(.small)
                    Text("Connecting to \(ServerAddress.title(of: url))\u{2026}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Cancel") {
                    if model.connectingTo != nil { model.cancelConnecting() } else { onClose() }
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.connectingTo != nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            address = store.servers.first?.address ?? ""
            addressFocused = true
            browser.start()
        }
        .onDisappear { browser.stop() }
    }

    private func row(_ server: KnownServer) -> some View {
        HStack(spacing: 8) {
            Button {
                store.setSaved(server, !server.saved)
            } label: {
                Image(systemName: server.saved ? "star.fill" : "star")
                    .foregroundStyle(server.saved ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(server.saved ? "Remove from Saved" : "Save, and show it in the sidebar")

            VStack(alignment: .leading, spacing: 1) {
                Text(server.title).lineLimit(1)
                Text(server.address)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let kind = server.url.flatMap(ServerAddress.kind(of:)) {
                Text(kind.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(server.id)
    }

    private func foundRow(_ server: ServerBrowser.Found) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(server.name).lineLimit(1)
            Spacer()
            Text(server.kind.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .tag("found:" + server.id)
    }

    private func found(_ id: String?) -> ServerBrowser.Found? {
        guard let id, id.hasPrefix("found:") else { return nil }
        return browser.found.first { "found:" + $0.id == id }
    }

    /// Its address, from what the server announces; said in the sheet when
    /// it does not answer.
    private func lookUp(_ server: ServerBrowser.Found) async -> URL? {
        lookingUp = server.name
        defer { lookingUp = nil }
        guard let url = await ServerBrowser.address(of: server) else {
            model.connectProblem = "\(server.name) did not say where it is. It may have just "
                + "gone to sleep; try again, or type its address."
            return nil
        }
        return url
    }

    private func connect(_ server: ServerBrowser.Found) {
        Task {
            guard let url = await lookUp(server) else { return }
            address = url.absoluteString
            model.connect(to: url, in: model.active)
        }
    }

    private func server(_ ids: Set<String>) -> KnownServer? {
        guard let id = ids.first else { return nil }
        return store.servers.first { $0.id == id }
    }

    private func connect() {
        model.connect(typed: address)
    }

    private func connect(_ server: KnownServer) {
        address = server.address
        model.connect(typed: server.address)
    }
}
