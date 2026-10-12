import SwiftUI
import AppKit

/// Volumes and favourites. Clicking a row opens it in the active pane.
struct SidebarView: View {

    @Bindable var model: AppModel
    @Bindable private var volumes = VolumeList.shared
    @Bindable private var servers = ServerStore.shared

    var body: some View {
        List(selection: $model.selectedSidebarEntry) {
            Section("Volumes") {
                ForEach(volumes.volumes) { entry in
                    row(entry)
                        .contextMenu {
                            Button("Open") { model.openSidebarEntry(entry) }
                            if entry.isEjectable {
                                Divider()
                                Button("Eject") { model.eject(entry) }
                            }
                        }
                }
            }

            if !servers.saved.isEmpty {
                Section("Servers") {
                    ForEach(servers.saved) { server in
                        serverRow(server)
                            .contextMenu { serverMenu(server) }
                    }
                }
            }

            Section("Favourites") {
                if model.favourites.isEmpty {
                    Text("Drag a folder here")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                ForEach(model.favourites) { entry in
                    row(entry)
                        .contextMenu {
                            Button("Open") { model.openSidebarEntry(entry) }
                            Divider()
                            Button("Remove from Favourites") {
                                model.removeFavourite(path: entry.url.path)
                            }
                        }
                }
                // Drag a favourite up or down to reorder. Volumes are not
                // movable -- their order is the system's, not ours.
                .onMove { source, destination in
                    ConfigStore.shared.moveFavourites(from: source, to: destination)
                }
            }
        }
        .listStyle(.sidebar)
        // Opening happens in the selection's setter, not in an onChange and not
        // in a tap gesture. A gesture inside a row competes with the list's own
        // click handling -- the mistake that broke pane selection three times
        // over -- and an onChange only fires when the value differs, which is
        // exactly what fails when the row you click is the row already showing.
    }

    /// A saved server: connected or not, and connecting while it is.
    private func serverRow(_ server: KnownServer) -> some View {
        let mounted = volumes.mountPoint(of: server) != nil
        let connecting = model.connectingTo.map {
            ServerAddress.withoutPassword($0).absoluteString.lowercased() == server.id
        } ?? false
        return HStack(spacing: 6) {
            Image(systemName: "server.rack")
                .font(.system(size: 12))
                .foregroundStyle(mounted ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            Text(server.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(mounted ? .primary : .secondary)
            Spacer(minLength: 4)
            if connecting {
                ProgressView().controlSize(.mini)
            } else if mounted {
                Button {
                    model.disconnect(server)
                } label: {
                    Image(systemName: "eject.fill").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Disconnect \(server.title)")
            }
        }
        .tag("s:" + server.id)
        .help(server.address + (mounted ? "" : " \u{2014} not connected; click to connect"))
    }

    @ViewBuilder
    private func serverMenu(_ server: KnownServer) -> some View {
        let mounted = volumes.mountPoint(of: server) != nil
        Button(mounted ? "Open" : "Connect") { model.openServer(server) }
        if mounted {
            Button("Disconnect") { model.disconnect(server) }
        }
        Divider()
        Toggle("Connect When Diptych Starts", isOn: Binding(
            get: { server.openAtLogin },
            set: { servers.setOpenAtLogin(server, $0) }))
        Button("Remove from Servers") { servers.setSaved(server, false) }
    }

    private func row(_ entry: SidebarEntry) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: SidebarIcons.shared.icon(for: entry.url, isNetwork: entry.isNetwork))
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let space = entry.spaceText {
                    Text(space)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .monospacedDigit()
                }
            }

            if entry.isEjectable {
                Spacer(minLength: 4)
                Button {
                    model.eject(entry)
                } label: {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Eject \(entry.name)")
            }
        }
        .tag(entry.id)
        .help(entry.url.path)
    }

}

/// The sidebar's icons, fetched off the main thread.
///
/// A volume's icon can come off the volume itself, and a disk that has spun
/// down answers in seconds rather than milliseconds. Asking for it while
/// drawing a row froze the whole application at launch -- the sidebar is built
/// before anything else -- and with three external disks and a one-minute
/// sleep setting it froze every time. Sampling it said so plainly: the main
/// thread, inside `icon(for:)`.
///
/// So a row is drawn at once with a plain icon, the real one is fetched behind
/// it, and the row redraws when it arrives. Nothing waits for a disk.
@MainActor
@Observable
final class SidebarIcons {

    static let shared = SidebarIcons()

    private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var asking: Set<String> = []

    /// Never touches the disk: it is asked about a kind of thing, not a thing.
    @ObservationIgnored private lazy var placeholder: NSImage = {
        let image = NSWorkspace.shared.icon(for: .folder)
        image.size = NSSize(width: 16, height: 16)
        return image
    }()

    /// A server's volume: not asked for its icon at all. Over the network
    /// that is seconds for each one, for a picture of a network drive.
    @ObservationIgnored private lazy var serverIcon: NSImage = {
        let image = NSImage(systemSymbolName: "externaldrive.connected.to.line.below",
                            accessibilityDescription: "Server") ?? placeholder
        image.size = NSSize(width: 16, height: 16)
        return image
    }()

    func icon(for url: URL, isNetwork: Bool = false) -> NSImage {
        if isNetwork { return serverIcon }
        if let cached = icons[url.path] { return cached }
        fetch(url)
        return placeholder
    }

    /// One icon at a time, on a queue of their own: a few slow disks
    /// answering for their icons held every thread BlockingWork allows, and
    /// every listing waited behind them.
    private static let queue = DispatchQueue(label: "dev.verhas.Diptych.sidebarIcons",
                                             qos: .utility)

    private func fetch(_ url: URL) {
        let path = url.path
        guard !asking.contains(path) else { return }
        asking.insert(path)
        Task {
            // NSImage is not Sendable, so what crosses back is the bytes.
            let data = await withCheckedContinuation { continuation in
                Self.queue.async {
                    continuation.resume(returning:
                        NSWorkspace.shared.icon(forFile: path).tiffRepresentation)
                }
            }
            asking.remove(path)
            guard let data, let image = NSImage(data: data) else { return }
            image.size = NSSize(width: 16, height: 16)
            icons[path] = image
        }
    }
}
