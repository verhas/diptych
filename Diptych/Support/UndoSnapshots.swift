import Foundation

/// Copies of files as they were before Diptych changed their contents, for
/// Undo to put back -- EXIF edits change the bytes of a file, and no record of
/// what was changed can bring back the exact file the way a copy can.
///
/// Kept in the user's Caches folder, under one folder per running Diptych:
/// the history lives as long as the process does, and so do these. A folder
/// left by a Diptych that is no longer running is removed at the next start.
/// On the same volume the copy is a clone, which costs no space until the
/// file is changed.
enum UndoSnapshots {

    nonisolated static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Diptych")
            .appendingPathComponent("Undo")
    }

    nonisolated static var mine: URL {
        root.appendingPathComponent(String(ProcessInfo.processInfo.processIdentifier))
    }

    /// A copy of `url` as it is now.
    nonisolated static func keep(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        let copy = mine.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    /// `snapshot`'s bytes into `url`, in place: the same file, with its name,
    /// its other hard links, its permissions and its attributes, holding what
    /// it held before.
    nonisolated static func putBack(_ snapshot: URL, into url: URL) throws {
        // A piece at a time: a video can be larger than the memory there is.
        let reading = try FileHandle(forReadingFrom: snapshot)
        defer { try? reading.close() }
        let writing = try FileHandle(forWritingTo: url)
        defer { try? writing.close() }
        try writing.truncate(atOffset: 0)
        while let piece = try reading.read(upToCount: 8 << 20), !piece.isEmpty {
            try writing.write(contentsOf: piece)
        }
    }

    /// The folders of Diptychs that have quit.
    nonisolated static func removeAbandoned() {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            guard let pid = Int32(folder.lastPathComponent),
                  pid != ProcessInfo.processInfo.processIdentifier else { continue }
            // Signal 0 checks only that the process is there.
            if kill(pid, 0) != 0 && errno == ESRCH {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }
}
