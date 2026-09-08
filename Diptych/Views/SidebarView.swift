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
        // Opening on selection rather than on a tap gesture: a gesture inside a
        // row competes with the list's own click handling, which is the mistake
        // that broke pane selection three times over.
        .onChange(of: model.selectedSidebarEntry) { _, id in
            guard let id,
                  let entry = (volumes.volumes + model.favourites).first(where: { $0.id == id })
            else { return }
            model.openSidebarEntry(entry)
        }
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

    private static func icon(for url: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
