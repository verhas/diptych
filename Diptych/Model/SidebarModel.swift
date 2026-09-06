import Foundation
import AppKit
import Observation

/// One row in the sidebar.
struct SidebarEntry: Identifiable, Hashable {
    enum Kind { case volume, favourite }

    let kind: Kind
    let url: URL
    let name: String
    var id: String { "\(kind == .volume ? "v" : "f"):\(url.path)" }
}

/// Mounted volumes, kept current as disks come and go.
@MainActor
@Observable
final class VolumeList {

    static let shared = VolumeList()

    private(set) var volumes: [SidebarEntry] = []

    private init() {
        reload()
        // Mounting a disk does not touch any directory we watch, so the list
        // has to be told.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { VolumeList.shared.reload() }
            }
        }
    }

    func reload() {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsBrowsable ?? true else { return nil }
            let name = values?.volumeLocalizedName ?? url.lastPathComponent
            return SidebarEntry(kind: .volume, url: url, name: name)
        }
    }
}
