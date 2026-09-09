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

    /// Enumerating volumes stats every one of them, and a disk that is still
    /// spinning up answers in seconds rather than microseconds. Doing that on
    /// the main actor froze the whole window -- and it runs on every mount and
    /// unmount notification, which is exactly when a disk is least ready to
    /// answer.
    func reload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            let found = await BlockingWork.run { VolumeList.enumerate() }
            guard !Task.isCancelled else { return }
            self?.volumes = found
        }
    }

    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    private nonisolated static func enumerate() -> [SidebarEntry] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeIsBrowsableKey, .volumeIsEjectableKey,
            .volumeIsRemovableKey, .volumeIsRootFileSystemKey, .volumeIsInternalKey,
        ]
        // A private instance rather than `.default`, so this is unambiguously
        // ours to call from another thread.
        let fm = FileManager()
        let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                        options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
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
    private nonisolated static func isEjectable(_ values: URLResourceValues?) -> Bool {
        guard let values, values.volumeIsRootFileSystem != true else { return false }
        if values.volumeIsEjectable == true || values.volumeIsRemovable == true { return true }
        return values.volumeIsInternal == false
    }
}
