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
/// where the old one left off. In the `script_timing` table of
/// `LocalDatabase.records` (1.x: `~/.diptych/script-timings.json`), the
/// person's alone (0600), like the runs themselves. Only sums are kept, never
/// which files a script ran on.
@MainActor
@Observable
final class ScriptTimings {

    static let shared = ScriptTimings()

    /// One script's figures.
    nonisolated struct Entry: Codable, Equatable {
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

    private let database: LocalDatabase
    private(set) var entries: [String: Entry] = [:]

    init(database: LocalDatabase = .records) {
        self.database = database
        load()
    }

    func entry(for script: String) -> Entry? { entries[script] }

    /// A run that finished, in `seconds`, on `files` files.
    func record(_ script: String, seconds: Double, files: Int) {
        guard seconds.isFinite, seconds >= 0 else { return }
        entries[script, default: Entry()].add(seconds: seconds, files: max(0, files))
        if let entry = entries[script] {
            database.access { $0.run(Self.upsert, Self.values(script, entry)) }
        }
    }

    /// Forgets the figures of this one script.
    func reset(_ script: String) {
        guard entries.removeValue(forKey: script) != nil else { return }
        database.access { $0.run("DELETE FROM script_timing WHERE script = ?", .text(script)) }
    }

    /// How long a run on `files` files will likely take: the average per file
    /// times as many files, when the script has been run on files before;
    /// otherwise the plain average. Nil before it has ever finished.
    func estimate(for script: String, files: Int) -> Double? {
        guard let entry = entries[script] else { return nil }
        if files > 0, let perFile = entry.averagePerFile { return perFile * Double(files) }
        return entry.average
    }

    // MARK: - Kept

    nonisolated static let upsert = """
        INSERT OR REPLACE INTO script_timing (script, runs, shortest, longest, total, runs_with_files,
          shortest_per_file, longest_per_file, total_per_file) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

    nonisolated static func values(_ script: String, _ entry: Entry) -> [LocalDatabase.Value] {
        [.text(script), .int(Int64(entry.runs)), .real(entry.shortest), .real(entry.longest), .real(entry.total),
         .int(Int64(entry.runsWithFiles)), .real(entry.shortestPerFile), .real(entry.longestPerFile),
         .real(entry.totalPerFile)]
    }

    private func load() {
        let rows = database.access { connection in
            connection.rows("""
                SELECT script, runs, shortest, longest, total, runs_with_files,
                  shortest_per_file, longest_per_file, total_per_file FROM script_timing
                """) { row -> (String, Entry) in
                var entry = Entry()
                entry.runs = Int(row.int(1) ?? 0)
                entry.shortest = row.real(2) ?? 0
                entry.longest = row.real(3) ?? 0
                entry.total = row.real(4) ?? 0
                entry.runsWithFiles = Int(row.int(5) ?? 0)
                entry.shortestPerFile = row.real(6) ?? 0
                entry.longestPerFile = row.real(7) ?? 0
                entry.totalPerFile = row.real(8) ?? 0
                return (row.text(0) ?? "", entry)
            }
        }
        entries = Dictionary(rows, uniquingKeysWith: { first, _ in first })
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
