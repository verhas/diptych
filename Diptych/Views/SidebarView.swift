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
            Image(nsImage: Self.icon(for: entry.url))
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

    /// Cached, because this runs for every row on every redraw and a volume
    /// root's icon can come off the disk itself -- a sleeping one answers
    /// slowly, and the sidebar redraws while it is waking.
    @MainActor private static var icons: [String: NSImage] = [:]

    private static func icon(for url: URL) -> NSImage {
        if let cached = icons[url.path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        icons[url.path] = image
        return image
    }
}
