import Foundation

/// A place a pane can browse whose listing is produced, not read from a real
/// directory: an archive now, SFTP or a process list later. One code shape for
/// all of them; version 1 implements the file-shaped ones.
///
/// The local file system is conceptually a source too -- the identity one --
/// but it stays implemented directly until expressing it here buys clarity.
protocol BrowserSource: Sendable {
    var capabilities: BrowserManifest.Capabilities { get }
    /// The children at a directory within the source; the root is "".
    func listing(of directory: String) -> [BrowserManifest.Node]
    /// A local file to open, preview or copy out, materialized if need be;
    /// nil when there is nothing to hand over.
    func localFile(for node: BrowserManifest.Node) -> URL?
}

/// Reads and writes a directory's manifest, and settles the one naming
/// question: the file is `__DIPTYCH.json`, unless a real subdirectory is
/// already called that, in which case it escalates to `__1DIPTYCH.json`,
/// `__2DIPTYCH.json`, and so on. The reader takes the `__(n)DIPTYCH.json` with
/// the largest `n` and hides exactly that one from the listing.
enum BrowserManifestStore {

    static let base = "DIPTYCH.json"

    /// `__DIPTYCH.json`, `__1DIPTYCH.json`, … in ascending order of n.
    static func name(_ n: Int) -> String { "__\(n == 0 ? "" : String(n))\(base)" }

    /// n for a manifest file name, or nil if it is not one.
    static func number(of fileName: String) -> Int? {
        guard fileName.hasPrefix("__"), fileName.hasSuffix(base) else { return nil }
        let middle = fileName.dropFirst(2).dropLast(base.count)
        if middle.isEmpty { return 0 }
        return Int(middle)
    }

    /// The manifest file name to use in a directory, given the names already
    /// taken there (its real subdirectories): the first `__(n)DIPTYCH.json`
    /// that is free.
    static func chooseName(avoiding taken: Set<String>) -> String {
        for n in 0..<10_000 where !taken.contains(name(n)) { return name(n) }
        return name(0)
    }

    /// The manifest file in `directory`: the `__(n)DIPTYCH.json` with the
    /// largest n, so an escalated one wins over a shadowed base.
    static func manifestFile(in directory: URL) -> URL? {
        let names = (try? FileManager().contentsOfDirectory(atPath: directory.path)) ?? []
        let chosen = names.compactMap { name in number(of: name).map { (name, $0) } }
            .max { $0.1 < $1.1 }?.0
        return chosen.map { directory.appendingPathComponent($0) }
    }

    static func read(in directory: URL) -> BrowserManifest? {
        guard let file = manifestFile(in: directory),
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(BrowserManifest.self, from: data)
    }

    static func write(_ manifest: BrowserManifest, named fileName: String,
                      in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: directory.appendingPathComponent(fileName))
    }
}
