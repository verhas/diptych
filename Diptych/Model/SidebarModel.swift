import Foundation
import AppKit
import Observation

/// One row in the sidebar.
struct SidebarEntry: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case volume, favourite }

    let kind: Kind
    let url: URL
    let name: String
    var isEjectable: Bool = false
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
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeIsBrowsableKey, .volumeIsEjectableKey,
            .volumeIsRemovableKey, .volumeIsRootFileSystemKey, .volumeIsInternalKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsBrowsable ?? true else { return nil }

            return SidebarEntry(kind: .volume,
                                url: url,
                                name: values?.volumeLocalizedName ?? url.lastPathComponent,
                                isEjectable: Self.isEjectable(values))
        }
    }

    /// External disks routinely report `volumeIsEjectable == false` -- both of
    /// this machine's are Thunderbolt APFS volumes that say so -- while still
    /// being perfectly ejectable. What actually separates them from the startup
    /// disk is being neither the root file system nor internal.
    private static func isEjectable(_ values: URLResourceValues?) -> Bool {
        guard let values, values.volumeIsRootFileSystem != true else { return false }
        if values.volumeIsEjectable == true || values.volumeIsRemovable == true { return true }
        return values.volumeIsInternal == false
    }
}
