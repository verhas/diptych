import Foundation

/// Walks a folder and measures what is under it, as a tree of sizes -- what the
/// Disk Usage window draws as a treemap, a heat map or GrandPerspective-style
/// rectangles.
///
/// Off the main actor: it reads the file system and returns a value tree.
enum DiskUsage {

    /// One file or folder and everything under it. A value tree, so it crosses
    /// back to the main actor by copy.
    struct Node: Identifiable, Sendable {
        let id = UUID()
        let name: String
        let url: URL
        let isDirectory: Bool
        /// Bytes: a file's own, a folder's total of everything under it.
        let size: Int64
        /// Largest first; empty for a file.
        let children: [Node]

        /// Every file at or under this node, flattened -- what the
        /// GrandPerspective view lays out, one rectangle per file.
        func files(into result: inout [Node]) {
            if isDirectory {
                for child in children { child.files(into: &result) }
            } else {
                result.append(self)
            }
        }
    }

    /// Measure `folder`. `onProgress` is called now and then with the running
    /// file count. Nil when cancelled before anything was built.
    nonisolated static func scan(_ folder: URL, cancelled: CancellationFlag,
                                 onProgress: @Sendable (Int) -> Void = { _ in }) -> Node? {
        var counter = 0
        let node = measure(folder, isRoot: true, cancelled: cancelled,
                           counter: &counter, onProgress: onProgress)
        return cancelled.isCancelled ? nil : node
    }

    private nonisolated static func measure(_ url: URL, isRoot: Bool, cancelled: CancellationFlag,
                                            counter: inout Int,
                                            onProgress: @Sendable (Int) -> Void) -> Node? {
        if cancelled.isCancelled { return nil }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey,
                                      .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        let values = try? url.resourceValues(forKeys: Set(keys))
        let isDirectory = values?.isDirectory ?? false
        let isSymlink = values?.isSymbolicLink ?? false

        // A symbolic link is a leaf -- counting what it points at would count
        // the target twice and could walk out of the folder or round in a loop.
        if !isDirectory || isSymlink {
            counter += 1
            if counter % 2000 == 0 { onProgress(counter) }
            let size = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize
                             ?? values?.fileSize ?? 0)
            return Node(name: url.lastPathComponent, url: url, isDirectory: false,
                        size: size, children: [])
        }

        var children: [Node] = []
        var total: Int64 = 0
        let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                    options: [.skipsHiddenFiles])) ?? []
        for child in contents {
            if cancelled.isCancelled { break }
            if let node = measure(child, isRoot: false, cancelled: cancelled,
                                  counter: &counter, onProgress: onProgress) {
                children.append(node)
                total += node.size
            }
        }
        children.sort { $0.size > $1.size }
        return Node(name: isRoot ? url.path : url.lastPathComponent, url: url,
                    isDirectory: true, size: total, children: children)
    }
}
