import Foundation
import CryptoKit

/// What comparing two pictures or PDFs by what they show found: how the right
/// one lies best over the left, page by page, and the comparison's answer.
/// Found once and kept, also across launches: by the comparison in the diff
/// window and by the Visual Preview, whichever gets there first, so neither
/// looks again for what the other found.
///
/// Kept against the two files' contents -- a SHA-256 of each -- and not their
/// names or dates: a file changed in any way is a file nothing kept holds for,
/// even one saved with its old date; and a file copied or renamed, unchanged,
/// still finds what was found for it. Of two fits for one page, the one found
/// on the finer picture is kept.
@MainActor
final class AlignmentStore {

    static let shared = AlignmentStore(directory: AlignmentStore.defaultDirectory)

    /// Which two files, by what is in them, the left one first: a fit says how
    /// the right lies over the left, so the order counts.
    struct Key: Hashable, Sendable {
        var left: String
        var right: String

        /// Nil when either cannot be read. Reads both through: off the main
        /// thread, then.
        nonisolated static func of(_ pair: DiffPair) -> Key? {
            guard let left = digest(pair.left), let right = digest(pair.right) else { return nil }
            return Key(left: left, right: right)
        }

        nonisolated static func digest(_ url: URL) -> String? {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            var hash = SHA256()
            do {
                // Nil, not empty, at the end.
                while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                    hash.update(data: chunk)
                }
            } catch {
                return nil
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    private struct Entry: Codable {
        var fits: [Int: ImageAlignment.Fit] = [:]
        var comparison: VisualComparison?
    }

    /// Where the entries are kept on disk; nil keeps them in memory only.
    /// The version is that of what is kept: a change to how pages are
    /// compared or aligned starts afresh under a new one.
    private let directory: URL?
    private var entries: [Key: Entry] = [:]

    nonisolated static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Diptych/Visual/v1", isDirectory: true)
    }

    init(directory: URL? = nil) {
        self.directory = directory
    }

    func fit(_ key: Key, page: Int) -> ImageAlignment.Fit? {
        entry(key).fits[page]
    }

    /// The fits known for the first `pages` pages, by page.
    func fits(_ key: Key, pages: Int) -> [Int: ImageAlignment.Fit] {
        entry(key).fits.filter { $0.key >= 0 && $0.key < pages }
    }

    func store(_ fit: ImageAlignment.Fit, _ key: Key, page: Int) {
        var entry = entry(key)
        if let kept = entry.fits[page], kept.finest >= fit.finest { return }
        entry.fits[page] = fit
        save(entry, key)
    }

    /// What the comparison found for these two, when it has looked.
    func comparison(_ key: Key) -> VisualComparison? {
        entry(key).comparison
    }

    func store(_ comparison: VisualComparison, _ key: Key) {
        var entry = entry(key)
        entry.comparison = comparison
        for page in comparison.pages {
            if let fit = page.alignment, (entry.fits[page.number - 1]?.finest ?? -1) < fit.finest {
                entry.fits[page.number - 1] = fit
            }
        }
        save(entry, key)
    }

    // MARK: - On disk

    private func file(_ key: Key) -> URL? {
        directory?.appendingPathComponent("\(key.left)-\(key.right).json")
    }

    private func entry(_ key: Key) -> Entry {
        if let known = entries[key] { return known }
        var entry = Entry()
        if let file = file(key), let data = try? Data(contentsOf: file),
           let read = try? JSONDecoder().decode(Entry.self, from: data) {
            entry = read
        }
        entries[key] = entry
        return entry
    }

    private func save(_ entry: Entry, _ key: Key) {
        entries[key] = entry
        guard let directory, let file = file(key), let data = try? JSONEncoder().encode(entry) else { return }
        // Small, and written whole: a write lost to a quit only means looking
        // again next time.
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}
