import Foundation

/// Splitting a file into numbered parts -- `big.zip.001`, `big.zip.002`, … --
/// and joining them back into the file, the way 7-Zip and `split` do it, so the
/// parts move across a size-limited disk or mail and come back together
/// anywhere.
///
/// Nothing here touches the main actor: it streams bytes and returns URLs, so
/// it runs off the main thread and is tested on its own.
enum FileSplitting {

    enum Failure: Error, LocalizedError {
        case empty
        case notAPart
        case noParts
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .empty:              "The file is empty, so there is nothing to split."
            case .notAPart:           "This is not the first part of a split file."
            case .noParts:            "No parts were found to join."
            case .unreadable(let n):  "\u{201C}\(n)\u{201D} could not be read."
            }
        }
    }

    /// The size a part is measured in, as people think of it.
    enum SizeUnit: String, CaseIterable, Identifiable, Sendable {
        case kilobytes = "KB"
        case megabytes = "MB"
        case gigabytes = "GB"

        var id: String { rawValue }

        /// 1024-based, so a part fits under a power-of-two limit -- a 4 GB part
        /// is under the 4 GiB a FAT volume stops at.
        var multiplier: Int64 {
            switch self {
            case .kilobytes: 1024
            case .megabytes: 1024 * 1024
            case .gigabytes: 1024 * 1024 * 1024
            }
        }
    }

    // MARK: - Splitting

    /// Split `file` into parts of at most `partSize` bytes, written into
    /// `folder` (or beside the file when nil). The parts, in order.
    nonisolated static func split(_ file: URL, partSize: Int64, into folder: URL?) throws -> [URL] {
        guard partSize > 0 else { throw Failure.empty }
        let total = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard total > 0 else { throw Failure.empty }

        let count = Int((total + partSize - 1) / partSize)
        let digits = max(3, String(count).count)
        let base = (folder ?? file.deletingLastPathComponent())
            .appendingPathComponent(file.lastPathComponent)

        guard let input = try? FileHandle(forReadingFrom: file) else {
            throw Failure.unreadable(file.lastPathComponent)
        }
        defer { try? input.close() }

        let fm = FileManager.default
        var parts: [URL] = []
        var output: FileHandle?
        var written: Int64 = 0
        var index = 0

        func openNextPart() throws {
            try? output?.close()
            index += 1
            let part = base.appendingPathExtension(String(format: "%0\(digits)d", index))
            fm.createFile(atPath: part.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: part) else {
                throw Failure.unreadable(part.lastPathComponent)
            }
            output = handle
            parts.append(part)
            written = 0
        }

        do {
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                var offset = 0
                while offset < chunk.count {
                    if output == nil || written >= partSize { try openNextPart() }
                    let room = Int(partSize - written)
                    let take = min(room, chunk.count - offset)
                    try output?.write(contentsOf: chunk.subdata(in: offset ..< offset + take))
                    written += Int64(take)
                    offset += take
                }
            }
            try? output?.close()
            return parts
        } catch {
            try? output?.close()
            for part in parts { try? fm.removeItem(at: part) }
            throw error
        }
    }

    // MARK: - Joining

    /// Whether `url` names the first part of a split file -- an all-digit
    /// extension, at least three long, reading as 1 (`something.001`).
    nonisolated static func isFirstPart(_ url: URL) -> Bool {
        let ext = url.pathExtension
        return ext.count >= 3 && ext.allSatisfy(\.isNumber) && Int(ext) == 1
    }

    /// The parts that follow `first`, in order, for as far as they run without
    /// a gap -- `.001`, `.002`, … until one is missing.
    nonisolated static func parts(firstPart first: URL) -> [URL] {
        guard isFirstPart(first) else { return [] }
        let digits = first.pathExtension.count
        let base = first.deletingPathExtension()
        let fm = FileManager.default
        var result: [URL] = []
        var index = 1
        while true {
            let part = base.appendingPathExtension(String(format: "%0\(digits)d", index))
            guard fm.fileExists(atPath: part.path) else { break }
            result.append(part)
            index += 1
        }
        return result
    }

    /// Join the parts following `first` back into the file they came from,
    /// written into `folder` (or beside the parts when nil). A name already
    /// taken is stepped past rather than overwritten. The file written.
    nonisolated static func join(firstPart first: URL, into folder: URL?) throws -> URL {
        guard isFirstPart(first) else { throw Failure.notAPart }
        let pieces = parts(firstPart: first)
        guard !pieces.isEmpty else { throw Failure.noParts }

        let destinationFolder = folder ?? first.deletingLastPathComponent()
        let wanted = first.deletingPathExtension().lastPathComponent
        let destination = freeName(wanted, in: destinationFolder)

        let fm = FileManager.default
        fm.createFile(atPath: destination.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: destination) else {
            throw Failure.unreadable(destination.lastPathComponent)
        }
        defer { try? output.close() }

        do {
            for piece in pieces {
                guard let input = try? FileHandle(forReadingFrom: piece) else {
                    throw Failure.unreadable(piece.lastPathComponent)
                }
                while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                }
                try? input.close()
            }
            return destination
        } catch {
            try? output.close()
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    /// `name`, or `name (2)`, `name (3)`… -- the first that is not already
    /// taken in `folder`, so joining never overwrites a file that is there.
    nonisolated static func freeName(_ name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        let candidate = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while true {
            let stem = "\(base) (\(n))"
            let next = folder.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
            if !fm.fileExists(atPath: next.path) { return next }
            n += 1
        }
    }
}
