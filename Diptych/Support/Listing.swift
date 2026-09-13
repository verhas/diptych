import Foundation

/// What is inside a folder or an archive, for the preview panel.
///
/// Reading either can be slow -- a folder on a sleeping disk, an archive that
/// has to be decompressed from end to end -- so nothing here runs on the main
/// thread and everything here is bounded. A preview that makes the application
/// wait is worse than no preview.
enum Listing {

    struct Entry: Sendable, Equatable {
        var name: String
        var isDirectory: Bool
        /// Nil where the source does not say, which for a folder means the
        /// size could not be read.
        var size: Int64?
        var modified: Date?
    }

    struct Result: Sendable, Equatable {
        var entries: [Entry] = []
        /// How many were left unread once the cap was reached.
        var omitted = 0
        /// Said plainly in the preview when something went wrong.
        var trouble: String?
    }

    /// Long enough to be useful, short enough that building the page and
    /// scrolling it stay instant. A folder of a hundred thousand files is not
    /// something to read in a preview panel.
    static let mostEntries = 1000

    /// A listing nobody is going to wait longer than this for.
    static let patience: TimeInterval = 10

    // MARK: - Folders

    static func folder(at url: URL) -> Result {
        var result = Result()
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let all = try? FileManager().contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants]) else {
            result.trouble = "This folder could not be read."
            return result
        }

        for child in all.prefix(mostEntries) {
            let values = try? child.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            result.entries.append(Entry(name: child.lastPathComponent,
                                        isDirectory: isDirectory,
                                        size: isDirectory ? nil
                                            : values?.fileSize.map(Int64.init),
                                        modified: values?.contentModificationDate))
        }
        result.omitted = max(all.count - mostEntries, 0)
        // Folders first, then by name, as the panes do.
        result.entries.sort {
            $0.isDirectory == $1.isDirectory
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.isDirectory
        }
        return result
    }

    // MARK: - Archives

    /// Every archive this understands, which is every archive one tool
    /// understands.
    ///
    /// `/usr/bin/tar` is libarchive, and it reads zip, tar and tar compressed
    /// with gzip, bzip2, xz or the old compress -- all through the same switch,
    /// detected from the bytes rather than the name. One subprocess covers what
    /// would otherwise be five decompressors, three of which Foundation does
    /// not have.
    static let archiveExtensions: Set<String> = [
        "zip", "tar", "tgz", "tbz", "tbz2", "txz", "taz", "jar", "war", "ipa",
        "gz", "bz2", "xz", "z",
    ]

    static func isArchive(_ url: URL) -> Bool {
        archiveExtensions.contains(url.pathExtension.lowercased())
    }

    /// An absolute path, never `$PATH`: the same rule the Git tool follows, and
    /// for the same reason.
    private static let tar = "/usr/bin/tar"

    static func archive(at url: URL) -> Result {
        var result = Result()
        guard FileManager().isExecutableFile(atPath: tar) else {
            result.trouble = "The system's tar program is not where it should be."
            return result
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: tar)
        task.arguments = ["-tvf", url.path]
        let output = Pipe()
        let errors = Pipe()
        task.standardOutput = output
        task.standardError = errors

        do { try task.run() } catch {
            result.trouble = "This archive could not be read. \(error.localizedDescription)"
            return result
        }
        // The child has its own copy now, and holding ours open means the
        // reader never sees the end of the file.
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()

        let collected = Collected()
        let finished = DispatchSemaphore(value: 0)
        let reading = output.fileHandleForReading

        // Read as it arrives rather than polling for it. An empty read *inside*
        // this handler means the end of the file; an empty read from a poll
        // means only that nothing has arrived yet -- and bzip2, xz and compress
        // all think for a while before saying anything, so polling called them
        // finished when they had not started.
        reading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty || !collected.append(chunk) {
                handle.readabilityHandler = nil
                finished.signal()
            }
        }

        let ranOut = finished.wait(timeout: .now() + patience) == .timedOut
        if ranOut {
            task.terminate()
            _ = finished.wait(timeout: .now() + 2)
            reading.readabilityHandler = nil
        }
        task.waitUntilExit()

        let text = collected.text
        let complaint = String(decoding: errors.fileHandleForReading.availableData,
                               as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if ranOut {
            result.trouble = "This archive is taking too long to read. "
                           + "What was read before it was stopped is below."
        } else if task.terminationStatus != 0 {
            result.trouble = complaint.isEmpty
                ? "This does not look like an archive tar can read."
                : complaint
        }

        let lines = text.split(separator: "\n")
        for line in lines.prefix(mostEntries) {
            if let entry = parse(String(line)) { result.entries.append(entry) }
        }
        result.omitted = max(lines.count - mostEntries, 0)
        return result
    }

    /// What has been read so far, from whichever thread is reading it.
    private final class Collected: @unchecked Sendable {

        private let lock = NSLock()
        private var data = Data()

        /// False once there is more than any preview could want, which stops a
        /// listing of a million files being held in memory to show a thousand.
        @discardableResult
        func append(_ chunk: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            data.append(chunk)
            return data.count < 4_000_000
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// One line of `tar -tvf`:
    /// `-rw-r--r--  0 verhasp wheel  6 Sep 13 11:38 src/a.txt`
    ///
    /// Split from the left for the fixed columns and taken whole from the date
    /// onwards, because a name may contain spaces and a date always occupies
    /// three fields.
    static func parse(_ line: String) -> Entry? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 8 else { return nil }

        let mode = String(fields[0])
        let size = Int64(fields[4])

        // The name is everything after the three date fields.
        var remainder = Substring(line)
        var seen = 0
        while seen < 8, let space = remainder.firstIndex(of: " ") {
            remainder = remainder[remainder.index(after: space)...]
            while remainder.first == " " { remainder = remainder.dropFirst() }
            seen += 1
        }
        var name = String(remainder)
        // A link is written "name -> target"; the name is the half that is it.
        if let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
        guard !name.isEmpty else { return nil }

        let isDirectory = mode.hasPrefix("d") || name.hasSuffix("/")
        return Entry(name: name, isDirectory: isDirectory,
                     size: isDirectory ? nil : size, modified: nil)
    }
}
