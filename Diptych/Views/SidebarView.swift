import SwiftUI
import AppKit

/// Volumes and favourites. Clicking a row opens it in the active pane.
struct SidebarView: View {

    @Bindable var model: AppModel
    @Bindable private var volumes = VolumeList.shared

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

    private func row(_ entry: SidebarEntry) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: SidebarIcons.shared.icon(for: entry.url))
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)

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

    func icon(for url: URL) -> NSImage {
        if let cached = icons[url.path] { return cached }
        fetch(url)
        return placeholder
    }

    private func fetch(_ url: URL) {
        let path = url.path
        guard !asking.contains(path) else { return }
        asking.insert(path)
        Task {
            // NSImage is not Sendable, so what crosses back is the bytes.
            let data = await BlockingWork.run { () -> Data? in
                NSWorkspace.shared.icon(forFile: path).tiffRepresentation
            }
            asking.remove(path)
            guard let data, let image = NSImage(data: data) else { return }
            image.size = NSSize(width: 16, height: 16)
            icons[path] = image
        }
    }
}
