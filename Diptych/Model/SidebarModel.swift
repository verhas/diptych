import Foundation
import AppKit
import Observation

/// One row in the sidebar.
extension VolumeList {
    /// Where a server's share is mounted, if it is.
    func mountPoint(of server: KnownServer) -> URL? {
        server.url.flatMap { ServerVolumes.mountPoint(of: $0, among: servers) }
    }

    func volume(at mountPoint: URL) -> SidebarEntry? {
        volumes.first { $0.url.path == mountPoint.path }
    }

    /// The volume a folder is on, from the paths alone -- nothing is asked
    /// of the disk, so it does not wait for one that is slow to answer.
    func volume(containing url: URL) -> SidebarEntry? {
        let path = url.path
        return volumes.filter { $0.url.path != "/" }
            .first { path == $0.url.path || path.hasPrefix($0.url.path + "/") }
    }
}

struct SidebarEntry: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case volume, favourite }

    let kind: Kind
    let url: URL
    let name: String
    var isEjectable: Bool = false
    /// On a file server: disconnected rather than ejected.
    var isNetwork: Bool = false
    /// A read-only volume cannot be written to, so its Trash is always empty --
    /// shown with a hollow bin in the sidebar.
    var isReadOnly: Bool = false
    /// A volume's size and the room left on it, in bytes, when it says.
    var capacity: Int64?
    var available: Int64?

    /// "2 TB, 340 GB free", for a volume that says both.
    var spaceText: String? {
        guard let capacity, capacity > 0 else { return nil }
        let total = ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)
        guard let available else { return total }
        return total + ", "
            + ByteCountFormatter.string(fromByteCount: available, countStyle: .file) + " free"
    }
    var id: String { "\(kind == .volume ? "v" : "f"):\(url.path)" }
}

/// Mounted volumes, kept current as disks come and go.
@MainActor
@Observable
final class VolumeList {

    static let shared = VolumeList()

    private(set) var volumes: [SidebarEntry] = []
    /// The network volumes among them, with the address each was mounted
    /// from: what tells a saved server it is connected.
    private(set) var servers: [ServerVolumes.Mounted] = []

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
        // Free space changes with no notification: looked at again each
        // minute while Diptych is in front, and whenever it comes to the front.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { VolumeList.shared.reload() }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                if NSApp?.isActive ?? false { self.reload() }
            }
        }
    }

    /// Enumerating volumes stats every one of them, and a disk that is still
    /// spinning up answers in seconds rather than microseconds. Doing that on
    /// the main actor froze the whole window -- and it runs on every mount and
    /// unmount notification, which is exactly when a disk is least ready to
    /// answer.
    ///
    /// One at a time. A look that cannot be cancelled -- a server slow to say
    /// how full it is -- would otherwise be joined by another each time
    /// Diptych came to the front, until they held every thread BlockingWork
    /// allows and everything else waited behind them. Asked again meanwhile,
    /// it looks once more when the one under way is done.
    func reload() {
        guard !enumerating else {
            again = true
            return
        }
        enumerating = true
        Task { [weak self] in
            let (found, servers) = await BlockingWork.run {
                // A connected SFTP server is a volume too, as far as the sidebar goes.
                (VolumeList.enumerate() + RemoteBrowsing.sidebarEntries(), ServerVolumes.mounted())
            }
            guard let self else { return }
            self.volumes = found
            self.servers = servers
            // Remembered, whoever mounted them, so a pane left on one can
            // bring it back after it is gone.
            for server in servers {
                ServerStore.shared.noticed(server.remount, mountPoint: server.mountPoint)
            }
            self.enumerating = false
            if self.again {
                self.again = false
                self.reload()
            }
        }
    }

    @ObservationIgnored private var enumerating = false
    @ObservationIgnored private var again = false

    private nonisolated static func enumerate() -> [SidebarEntry] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeIsBrowsableKey, .volumeIsEjectableKey,
            .volumeIsRemovableKey, .volumeIsRootFileSystemKey, .volumeIsInternalKey,
            .volumeIsLocalKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsReadOnlyKey,
        ]
        // A private instance rather than `.default`, so this is unambiguously
        // ours to call from another thread.
        let fm = FileManager()
        let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                        options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsBrowsable ?? true else { return nil }

            // What a local disk can still take counts what macOS would clear
            // to make room -- purgeable space -- as Finder does; a server only
            // says what is free.
            var available = values?.volumeAvailableCapacity.map(Int64.init)
            if values?.volumeIsLocal != false,
               let important = (try? url.resourceValues(
                   forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                   .volumeAvailableCapacityForImportantUsage, important > 0 {
                available = important
            }
            return SidebarEntry(kind: .volume,
                                url: url,
                                name: values?.volumeLocalizedName ?? url.lastPathComponent,
                                isEjectable: Self.isEjectable(values),
                                isNetwork: values?.volumeIsLocal == false,
                                isReadOnly: values?.volumeIsReadOnly == true,
                                capacity: values?.volumeTotalCapacity.map(Int64.init),
                                available: available)
        }
    }

    /// External disks routinely report `volumeIsEjectable == false` -- both of
    /// this machine's are Thunderbolt APFS volumes that say so -- while still
    /// being perfectly ejectable. What actually separates them from the startup
    /// disk is being neither the root file system nor internal.
    private nonisolated static func isEjectable(_ values: URLResourceValues?) -> Bool {
        guard let values, values.volumeIsRootFileSystem != true else { return false }
        if values.volumeIsLocal == false { return true }
        if values.volumeIsEjectable == true || values.volumeIsRemovable == true { return true }
        return values.volumeIsInternal == false
    }
}
