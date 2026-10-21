import CryptoKit
import Foundation

/// Splitting a file into numbered parts -- `big.zip.001`, `big.zip.002`, … --
/// and joining them back into the file, the way 7-Zip and `split` do it, so the
/// parts move across a size-limited disk or mail and come back together
/// anywhere.
///
/// Alongside the parts, a split writes a small JSON *manifest* -- `big.zip`
/// becomes `big.zip.diptychsplit.json` -- listing every part with its size and
/// SHA-512. Joining with the manifest in hand notices a part that has gone
/// missing or been corrupted; the manifest is pure extra, so parts still join
/// with `cat *` on Unix, `copy /B` on Windows, or an older Diptych that never
/// wrote one.
///
/// Nothing here touches the main actor: it streams bytes and returns URLs, so
/// it runs off the main thread and is tested on its own.
enum FileSplitting {

    enum Failure: Error, LocalizedError {
        case empty
        case notAPart
        case noParts
        case unreadable(String)
        /// Parts the manifest lists, or a contiguous numbering implies, that are
        /// not on disk -- a missing part in the middle makes the join unusable.
        case missingParts([String])
        /// Parts whose bytes no longer match the SHA-512 the manifest recorded.
        case corruptParts([String])

        var errorDescription: String? {
            switch self {
            case .empty:              "The file is empty, so there is nothing to split."
            case .notAPart:           "This is not part of a split file."
            case .noParts:            "No parts were found to join."
            case .unreadable(let n):  "\u{201C}\(n)\u{201D} could not be read."
            case .missingParts(let p):
                "The join cannot go ahead: "
                + (p.count == 1 ? "a part is missing" : "\(p.count) parts are missing")
                + " -- \(p.joined(separator: ", ")). "
                + "The result would be incomplete and unusable."
            case .corruptParts(let p):
                "The join cannot go ahead: "
                + (p.count == 1 ? "a part does not match the checksum" : "\(p.count) parts do not match their checksums")
                + " recorded when the file was split -- \(p.joined(separator: ", ")). "
                + "They are damaged, so the result would be corrupt."
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

    // MARK: - The manifest

    /// The tail the manifest file's name carries, after the original name --
    /// `big.zip` → `big.zip.diptychsplit.json`.
    static let manifestSuffix = ".diptychsplit.json"

    /// What the manifest holds: enough to put the file back together and to know
    /// whether every part is present and sound.
    struct Manifest: Codable, Sendable {
        var format = "diptych-split"
        var version = 1
        /// The original file's name, so the join knows what to call the result.
        var file: String
        var totalSize: Int64
        var partSize: Int64
        var parts: [Part]

        struct Part: Codable, Sendable {
            var name: String
            var size: Int64
            var sha512: String
        }
    }

    /// Whether `url` names a split manifest.
    nonisolated static func isManifest(_ url: URL) -> Bool {
        url.lastPathComponent.hasSuffix(manifestSuffix) && url.lastPathComponent.count > manifestSuffix.count
    }

    /// The manifest that belongs beside the parts of `base` (the original file's
    /// URL -- `…/big.zip`, not a part).
    nonisolated static func manifestURL(forBase base: URL) -> URL {
        base.deletingLastPathComponent()
            .appendingPathComponent(base.lastPathComponent + manifestSuffix)
    }

    /// The original file's URL implied by `url`, whether it is a part
    /// (`big.zip.003`) or a manifest (`big.zip.diptychsplit.json`). Nil when it
    /// is neither.
    nonisolated static func base(of url: URL) -> URL? {
        if isManifest(url) {
            let name = String(url.lastPathComponent.dropLast(manifestSuffix.count))
            return url.deletingLastPathComponent().appendingPathComponent(name)
        }
        if isPart(url) { return url.deletingPathExtension() }
        return nil
    }

    // MARK: - Recognising parts

    /// Whether `url`'s extension is a part number -- all digits, at least three
    /// long (`something.003`). Any part, not only the first.
    nonisolated static func isPart(_ url: URL) -> Bool {
        let ext = url.pathExtension
        return ext.count >= 3 && ext.allSatisfy(\.isNumber) && Int(ext) != nil
    }

    /// Whether `url` is the first part -- `something.001`.
    nonisolated static func isFirstPart(_ url: URL) -> Bool {
        isPart(url) && Int(url.pathExtension) == 1
    }

    /// The first part (`…​.001`) of the set `part` belongs to, keeping the same
    /// digit width. Nil when `part` is not a part at all.
    nonisolated static func firstPart(of part: URL) -> URL? {
        guard isPart(part) else { return nil }
        let digits = part.pathExtension.count
        return part.deletingPathExtension()
            .appendingPathExtension(String(format: "%0\(digits)d", 1))
    }

    /// What to join from, given what the user selected: a single manifest, a
    /// single part, or several parts that all belong to one file. Nil when the
    /// selection is not a join -- a mix of unrelated files, or not parts at all.
    /// The returned URL is a manifest or the first part, ready for `join`.
    nonisolated static func joinSource(for urls: [URL]) -> URL? {
        guard !urls.isEmpty else { return nil }
        if urls.count == 1, isManifest(urls[0]) { return urls[0] }
        guard urls.allSatisfy(isPart) else { return nil }
        let bases = Set(urls.map { $0.deletingPathExtension().path })
        guard bases.count == 1 else { return nil }
        return firstPart(of: urls[0])
    }

    // MARK: - Splitting

    /// How many parts a file of `totalSize` bytes makes at `partSize` each.
    nonisolated static func partCount(totalSize: Int64, partSize: Int64) -> Int {
        guard partSize > 0, totalSize > 0 else { return 0 }
        return Int((totalSize + partSize - 1) / partSize)
    }

    /// The exact part and manifest URLs a split would write, worked out without
    /// touching a byte -- so the caller can refuse to overwrite any that already
    /// exist. Throws `.empty` when there is nothing to split.
    nonisolated static func plannedOutputs(file: URL, partSize: Int64,
                                           into folder: URL?) throws -> (parts: [URL], manifest: URL) {
        guard partSize > 0 else { throw Failure.empty }
        let total = fileSize(file)
        guard total > 0 else { throw Failure.empty }
        let count = partCount(totalSize: total, partSize: partSize)
        let digits = max(3, String(count).count)
        let base = (folder ?? file.deletingLastPathComponent())
            .appendingPathComponent(file.lastPathComponent)
        let parts = (1...count).map {
            base.appendingPathExtension(String(format: "%0\(digits)d", $0))
        }
        return (parts, manifestURL(forBase: base))
    }

    /// Which of a planned split's outputs are already on disk -- empty when the
    /// split would overwrite nothing.
    nonisolated static func existingOutputs(file: URL, partSize: Int64,
                                            into folder: URL?) -> [URL] {
        guard let planned = try? plannedOutputs(file: file, partSize: partSize, into: folder) else {
            return []
        }
        let fm = FileManager.default
        return (planned.parts + [planned.manifest]).filter { fm.fileExists(atPath: $0.path) }
    }

    /// Split `file` into parts of at most `partSize` bytes, written into
    /// `folder` (or beside the file when nil), plus a manifest listing them. The
    /// parts and the manifest. Existing files are **not** overwritten -- call
    /// `existingOutputs` first; here any write failure rolls the whole thing
    /// back.
    nonisolated static func split(_ file: URL, partSize: Int64,
                                  into folder: URL?) throws -> (parts: [URL], manifest: URL) {
        guard partSize > 0 else { throw Failure.empty }
        let total = fileSize(file)
        guard total > 0 else { throw Failure.empty }

        let count = partCount(totalSize: total, partSize: partSize)
        let digits = max(3, String(count).count)
        let base = (folder ?? file.deletingLastPathComponent())
            .appendingPathComponent(file.lastPathComponent)

        guard let input = try? FileHandle(forReadingFrom: file) else {
            throw Failure.unreadable(file.lastPathComponent)
        }
        defer { try? input.close() }

        let fm = FileManager.default
        var parts: [URL] = []
        var entries: [Manifest.Part] = []
        var output: FileHandle?
        var written: Int64 = 0
        var hasher = SHA512()

        // Finish the part now open: close it and record it in the manifest with
        // the bytes and the sum it ended up with.
        func closeCurrentPart() {
            guard let handle = output, let part = parts.last else { return }
            try? handle.close()
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            entries.append(Manifest.Part(name: part.lastPathComponent, size: written, sha512: hex))
            output = nil
        }

        func openNextPart() throws {
            closeCurrentPart()
            let index = parts.count + 1
            let part = base.appendingPathExtension(String(format: "%0\(digits)d", index))
            fm.createFile(atPath: part.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: part) else {
                throw Failure.unreadable(part.lastPathComponent)
            }
            output = handle
            parts.append(part)
            written = 0
            hasher = SHA512()
        }

        do {
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                var offset = 0
                while offset < chunk.count {
                    if output == nil || written >= partSize { try openNextPart() }
                    let room = Int(partSize - written)
                    let take = min(room, chunk.count - offset)
                    let slice = chunk.subdata(in: offset ..< offset + take)
                    try output?.write(contentsOf: slice)
                    hasher.update(data: slice)
                    written += Int64(take)
                    offset += take
                }
            }
            closeCurrentPart()

            let manifest = manifestURL(forBase: base)
            let value = Manifest(file: file.lastPathComponent, totalSize: total,
                                 partSize: partSize, parts: entries)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: manifest)
            return (parts, manifest)
        } catch {
            try? output?.close()
            for part in parts { try? fm.removeItem(at: part) }
            throw error
        }
    }

    // MARK: - Joining

    /// The parts following `first`, in order, for as far as they run without a
    /// gap -- kept for callers that only want to count what is there.
    nonisolated static func parts(firstPart first: URL) -> [URL] {
        guard let base = base(of: first) else { return [] }
        return (try? contiguousParts(base: base)) ?? []
    }

    /// Join the parts of the file `source` belongs to -- `source` being a part
    /// or the manifest -- back into one file, written into `folder` (or beside
    /// the parts when nil). A name already taken is stepped past rather than
    /// overwritten. The file written.
    ///
    /// With a manifest present, every listed part must be on disk and match its
    /// recorded SHA-512, so a missing or corrupted part stops the join instead
    /// of producing a silently broken file. Without one, a gap in the numbering
    /// (part 11 missing from 1…15) is still caught; only a missing *trailing*
    /// part cannot be noticed, since nothing records how many there were.
    nonisolated static func join(from source: URL, into folder: URL?) throws -> URL {
        guard let base = base(of: source) else { throw Failure.notAPart }
        let pieces = try orderedParts(base: base)
        guard !pieces.isEmpty else { throw Failure.noParts }

        let destinationFolder = folder ?? base.deletingLastPathComponent()
        let destination = freeName(base.lastPathComponent, in: destinationFolder)

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

    /// The parts to join, in order -- from the manifest when one is present and
    /// readable (verifying each), otherwise from the contiguous numbering on
    /// disk.
    nonisolated static func orderedParts(base: URL) throws -> [URL] {
        let manifest = manifestURL(forBase: base)
        if let data = try? Data(contentsOf: manifest),
           let value = try? JSONDecoder().decode(Manifest.self, from: data) {
            return try verified(value, base: base)
        }
        return try contiguousParts(base: base)
    }

    /// Check a manifest against disk: every part present, every SHA-512 a match.
    /// The parts in manifest order, or a throw naming what is missing or
    /// damaged.
    private nonisolated static func verified(_ manifest: Manifest, base: URL) throws -> [URL] {
        let folder = base.deletingLastPathComponent()
        let fm = FileManager.default
        var ordered: [URL] = []
        var missing: [String] = []
        var corrupt: [String] = []
        for part in manifest.parts {
            let url = folder.appendingPathComponent(part.name)
            guard fm.fileExists(atPath: url.path) else { missing.append(part.name); continue }
            if let sum = Checksums.digest(of: url, algorithm: .sha512), sum != part.sha512 {
                corrupt.append(part.name)
            }
            ordered.append(url)
        }
        if !missing.isEmpty { throw Failure.missingParts(missing) }
        if !corrupt.isEmpty { throw Failure.corruptParts(corrupt) }
        return ordered
    }

    /// The parts on disk for `base`, 1…N, requiring no gap. A number missing in
    /// the middle throws `.missingParts`; a missing trailing part cannot be told
    /// from the set simply ending, so it is not caught here.
    private nonisolated static func contiguousParts(base: URL) throws -> [URL] {
        let folder = base.deletingLastPathComponent()
        let name = base.lastPathComponent
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: folder,
                                                   includingPropertiesForKeys: nil)) ?? []
        var byIndex: [Int: URL] = [:]
        var width = 3
        for entry in entries where entry.deletingPathExtension().lastPathComponent == name {
            let ext = entry.pathExtension
            guard ext.count >= 3, ext.allSatisfy(\.isNumber), let index = Int(ext) else { continue }
            byIndex[index] = entry
            width = ext.count
        }
        guard let highest = byIndex.keys.max() else { throw Failure.noParts }

        var result: [URL] = []
        var missing: [String] = []
        for index in 1...highest {
            if let url = byIndex[index] {
                result.append(url)
            } else {
                missing.append(name + "." + String(format: "%0\(width)d", index))
            }
        }
        if !missing.isEmpty { throw Failure.missingParts(missing) }
        return result
    }

    // MARK: - Helpers

    private nonisolated static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
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
