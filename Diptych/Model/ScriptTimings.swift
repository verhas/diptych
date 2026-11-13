import Foundation
import Observation

/// How long each script has taken, summed up over every run that finished:
/// how many there were, the shortest, the longest and the average -- in all,
/// and per file selected, on the bold assumption that a script takes about
/// as long for each file it is given. From that, how long a run now starting
/// will likely take, for the Runs window's progress bar.
///
/// Only runs that finished count. A run that failed may have stopped at once,
/// and one that was stopped did not take as long as it would have; either
/// would make the figures say less.
///
/// Kept by the script's file name, so a new version of a script carries on
/// where the old one left off. `~/.diptych/script-timings.json`, the person's
/// alone (0600), like the runs themselves. Only sums are kept, never which
/// files a script ran on.
@MainActor
@Observable
final class ScriptTimings {

    static let shared = ScriptTimings()

    /// One script's figures.
    struct Entry: Codable, Equatable {
        /// Runs that finished.
        var runs = 0
        var shortest: Double = 0
        var longest: Double = 0
        var total: Double = 0
        /// Runs that were given at least one file -- a script may be run on none.
        var runsWithFiles = 0
        var shortestPerFile: Double = 0
        var longestPerFile: Double = 0
        var totalPerFile: Double = 0

        var average: Double? { runs > 0 ? total / Double(runs) : nil }
        var averagePerFile: Double? {
            runsWithFiles > 0 ? totalPerFile / Double(runsWithFiles) : nil
        }

        mutating func add(seconds: Double, files: Int) {
            shortest = runs == 0 ? seconds : min(shortest, seconds)
            longest = runs == 0 ? seconds : max(longest, seconds)
            total += seconds
            runs += 1
            guard files > 0 else { return }
            let perFile = seconds / Double(files)
            shortestPerFile = runsWithFiles == 0 ? perFile : min(shortestPerFile, perFile)
            longestPerFile = runsWithFiles == 0 ? perFile : max(longestPerFile, perFile)
            totalPerFile += perFile
            runsWithFiles += 1
        }
    }

    let url: URL
    private(set) var entries: [String: Entry] = [:]

    init(url: URL = StateStore.directory.appendingPathComponent("script-timings.json")) {
        self.url = url
        load()
    }

    func entry(for script: String) -> Entry? { entries[script] }

    /// A run that finished, in `seconds`, on `files` files.
    func record(_ script: String, seconds: Double, files: Int) {
        guard seconds.isFinite, seconds >= 0 else { return }
        entries[script, default: Entry()].add(seconds: seconds, files: max(0, files))
        save()
    }

    /// Forgets the figures of this one script.
    func reset(_ script: String) {
        guard entries.removeValue(forKey: script) != nil else { return }
        save()
    }

    /// How long a run on `files` files will likely take: the average per file
    /// times as many files, when the script has been run on files before;
    /// otherwise the plain average. Nil before it has ever finished.
    func estimate(for script: String, files: Int) -> Double? {
        guard let entry = entries[script] else { return nil }
        if files > 0, let perFile = entry.averagePerFile { return perFile * Double(files) }
        return entry.average
    }

    // MARK: - File

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// "0.8s", "42s", "3m 05s", "1h 02m" -- short enough for one line of figures.
    nonisolated static func duration(_ seconds: Double) -> String {
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        if whole < 3600 { return String(format: "%dm %02ds", whole / 60, whole % 60) }
        return String(format: "%dh %02dm", whole / 3600, whole % 3600 / 60)
    }
}
