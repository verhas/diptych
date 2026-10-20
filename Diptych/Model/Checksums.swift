import CryptoKit
import Foundation

/// Making and checking checksum files -- the little `name.ext` files that hold
/// a file's MD5, SHA-1, SHA-256 or SHA-512 sum, the way `md5` and `shasum`
/// write them.
///
/// Nothing here touches the pasteboard, a pane or the main actor: it reads
/// files and returns values, so it runs off the main thread and is tested on
/// its own. The orchestration -- what is selected, what the clipboard holds,
/// where read-only sends the files instead -- is in ChecksumActions.
enum Checksums {

    /// The kinds Diptych makes and checks. All four are a single read of the
    /// file, so computing every one of them to check against the clipboard is
    /// cheap.
    enum Algorithm: String, CaseIterable, Sendable, Identifiable {
        case md5, sha1, sha256, sha512

        var id: String { rawValue }

        /// The file's own extension -- `photo.jpg.sha256`.
        var ext: String { rawValue }

        /// As people write it.
        var label: String {
            switch self {
            case .md5:    "MD5"
            case .sha1:   "SHA-1"
            case .sha256: "SHA-256"
            case .sha512: "SHA-512"
            }
        }

        /// How many hex digits the sum is written as -- what tells one length
        /// of hash in the clipboard from another.
        var hexLength: Int {
            switch self {
            case .md5:    32
            case .sha1:   40
            case .sha256: 64
            case .sha512: 128
            }
        }
    }

    /// The hash lengths worth looking for in a block of text.
    static let hashLengths: Set<Int> = Set(Algorithm.allCases.map(\.hexLength))

    // MARK: - Hashing

    /// One file's sum of one kind, lowercase hex, read a megabyte at a time so
    /// a huge file never loads whole.
    nonisolated static func digest(of url: URL, algorithm: Algorithm) -> String? {
        switch algorithm {
        case .md5:    return stream(Insecure.MD5(), url)
        case .sha1:   return stream(Insecure.SHA1(), url)
        case .sha256: return stream(SHA256(), url)
        case .sha512: return stream(SHA512(), url)
        }
    }

    /// Every kind at once, in a single pass over the file -- the four hashers
    /// fed the same chunks. Nil when the file cannot be read.
    nonisolated static func allDigests(of url: URL) -> [Algorithm: String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var md5 = Insecure.MD5()
        var sha1 = Insecure.SHA1()
        var sha256 = SHA256()
        var sha512 = SHA512()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            md5.update(data: chunk)
            sha1.update(data: chunk)
            sha256.update(data: chunk)
            sha512.update(data: chunk)
        }
        return [.md5: hex(md5.finalize()), .sha1: hex(sha1.finalize()),
                .sha256: hex(sha256.finalize()), .sha512: hex(sha512.finalize())]
    }

    private nonisolated static func stream<H: HashFunction>(_ hasher: H, _ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = hasher
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    private nonisolated static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The checksum file

    /// Where a file's checksum of one kind lives -- its full name plus the
    /// kind's extension, in `folder`.
    nonisolated static func checksumURL(for file: URL, in folder: URL,
                                        algorithm: Algorithm) -> URL {
        folder.appendingPathComponent(file.lastPathComponent).appendingPathExtension(algorithm.ext)
    }

    /// What goes in it: the sum, two spaces, the file's name, a newline -- the
    /// format `md5sum` and `shasum` read and write.
    nonisolated static func fileBody(hash: String, name: String) -> String {
        "\(hash)  \(name)\n"
    }

    // MARK: - Creating -- deciding what to do, then doing it

    /// One checksum file to write: its file, where it goes, and the sum.
    struct Write: Sendable {
        let target: URL
        let destination: URL
        let hash: String
    }

    /// What creating the checksums of a selection would do, worked out without
    /// writing anything -- so a checksum file that already holds the right sum
    /// is left alone, and one that holds the wrong sum can be asked about
    /// before it is overwritten.
    struct Plan: Sendable {
        /// No checksum file there yet -- written straight away.
        var fresh: [Write] = []
        /// A checksum file there already, but with a different sum -- written
        /// only once the user agrees to overwrite.
        var mismatched: [Write] = []
        /// A checksum file there already, holding the right sum -- nothing to do.
        var upToDate = 0
        /// Files that could not be read.
        var problems: [String] = []
    }

    /// Work out, for each file, whether its checksum file is missing, right or
    /// wrong -- reading the files, writing nothing.
    nonisolated static func classify(algorithm: Algorithm, targets: [URL],
                                     folder: URL?) -> Plan {
        let fm = FileManager.default
        var plan = Plan()
        for target in targets {
            let destination = checksumURL(for: target,
                                          in: folder ?? target.deletingLastPathComponent(),
                                          algorithm: algorithm)
            guard let hash = digest(of: target, algorithm: algorithm) else {
                plan.problems.append("\u{201C}\(target.lastPathComponent)\u{201D} could not be read.")
                continue
            }
            let write = Write(target: target, destination: destination, hash: hash)
            if fm.fileExists(atPath: destination.path) {
                if storedHash(in: destination, algorithm: algorithm) == hash {
                    plan.upToDate += 1
                } else {
                    plan.mismatched.append(write)
                }
            } else {
                plan.fresh.append(write)
            }
        }
        return plan
    }

    /// Actually write the checksum files. The made files, and a line for each
    /// one that could not be written.
    nonisolated static func writeAll(_ writes: [Write]) -> (made: [URL], problems: [String]) {
        var made: [URL] = []
        var problems: [String] = []
        for write in writes {
            do {
                try Data(fileBody(hash: write.hash, name: write.target.lastPathComponent).utf8)
                    .write(to: write.destination)
                made.append(write.destination)
            } catch {
                problems.append("\u{201C}\(write.destination.lastPathComponent)\u{201D}: "
                                + error.localizedDescription)
            }
        }
        return (made, problems)
    }

    /// The sum written in a checksum file, however it is laid out: the first
    /// hex run of the right length, so both the `hash  name` of coreutils and
    /// the `MD5 (name) = hash` of BSD are read.
    nonisolated static func storedHash(in url: URL, algorithm: Algorithm) -> String? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return hashTokens(in: text).first { $0.count == algorithm.hexLength }
    }

    // MARK: - Reading a checksum out of text

    /// Every run of hex digits whose length is one a hash is written in. A
    /// bare sum, a `hash  name` line, a `MD5 (name) = hash` line all give up
    /// their hash; a word or a short number gives nothing.
    nonisolated static func hashTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        func flush() {
            if hashLengths.contains(current.count) { tokens.append(current.lowercased()) }
            current = ""
        }
        for ch in text {
            if ch.isHexDigit { current.append(ch) } else { flush() }
        }
        flush()
        return tokens
    }

    /// Whether some text holds anything that could be a checksum at all -- what
    /// decides, for a single file, between checking the clipboard and looking
    /// for a file beside it.
    nonisolated static func hasChecksum(_ text: String) -> Bool {
        !hashTokens(in: text).isEmpty
    }

    /// The kind of sum in `text` that matches one of the file's sums, if any.
    /// The strongest wins when more than one is present, so a report never
    /// names MD5 where a SHA-256 also matched.
    nonisolated static func match(digests: [Algorithm: String], clipboard text: String) -> Algorithm? {
        let tokens = Set(hashTokens(in: text))
        guard !tokens.isEmpty else { return nil }
        for algorithm in [Algorithm.sha512, .sha256, .sha1, .md5] {
            if let digest = digests[algorithm], tokens.contains(digest) { return algorithm }
        }
        return nil
    }

    // MARK: - Checking against the files beside each file

    /// One checksum file weighed against its file.
    struct FileCheck: Sendable {
        let file: URL
        let checksumFile: URL
        let algorithm: Algorithm
        let matched: Bool
        /// Both the file and its checksum file could be read.
        let readable: Bool
    }

    struct FileReport: Sendable {
        var checks: [FileCheck]
        /// One line per checksum file, ready to show.
        var lines: [String]
        var allMatched: Bool
        var anyMatched: Bool
    }

    /// Every checksum file found beside each of `targets`, each compared with
    /// its file. A file with a `.md5` and a `.sha256` beside it is checked
    /// against both.
    nonisolated static func checkAgainstFiles(_ targets: [URL]) -> FileReport {
        let fm = FileManager.default
        var checks: [FileCheck] = []
        var lines: [String] = []
        for file in targets {
            for algorithm in Algorithm.allCases {
                let checksumFile = checksumURL(for: file, in: file.deletingLastPathComponent(),
                                               algorithm: algorithm)
                guard fm.fileExists(atPath: checksumFile.path) else { continue }
                guard let stored = storedHash(in: checksumFile, algorithm: algorithm) else {
                    lines.append("\u{26A0} \(checksumFile.lastPathComponent) \u{2014} "
                                 + "no \(algorithm.label) checksum could be read from it")
                    checks.append(FileCheck(file: file, checksumFile: checksumFile,
                                            algorithm: algorithm, matched: false, readable: false))
                    continue
                }
                guard let digest = digest(of: file, algorithm: algorithm) else {
                    lines.append("\u{26A0} \(file.lastPathComponent) \u{2014} could not be read")
                    checks.append(FileCheck(file: file, checksumFile: checksumFile,
                                            algorithm: algorithm, matched: false, readable: false))
                    continue
                }
                let ok = digest == stored
                lines.append("\(ok ? "\u{2713}" : "\u{2717}") \(checksumFile.lastPathComponent) "
                             + "\u{2014} \(algorithm.label) \(ok ? "matches" : "does not match")")
                checks.append(FileCheck(file: file, checksumFile: checksumFile,
                                        algorithm: algorithm, matched: ok, readable: true))
            }
        }
        let readable = checks.filter(\.readable)
        return FileReport(checks: checks, lines: lines,
                          allMatched: !checks.isEmpty && checks.allSatisfy(\.matched),
                          anyMatched: readable.contains(where: \.matched))
    }
}
