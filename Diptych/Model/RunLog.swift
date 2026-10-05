import Foundation

/// Every recent run, on disk: what ran, where, how it ended, and
/// what it printed -- so a run can still be looked at, by the person or by an
/// agent through MCP, after its tab is closed or Diptych has quit.
///
/// `~/.diptych/runs/<id>.json` holds the record, written when the run starts
/// and again when it ends; `<id>.log` holds the output, written once, when the
/// program exits. Both are the person's alone (0600): output can hold
/// anything, tokens included. Runs are kept as long as Settings ▸ Behaviour
/// says -- a day unless changed -- then purged, record and output together:
/// at launch, whenever a run starts, and every quarter of an hour, so a
/// Diptych left open for a week does not keep a week of builds.
@MainActor
final class RunLog {

    static let shared = RunLog()

    struct Record: Codable, Equatable {
        var id: UUID
        var program: String
        var arguments: String
        var commandLine: String
        var directory: String
        var startedAt: Date
        var endedAt: Date?
        /// running, finished, failed, stopped -- or interrupted: Diptych quit
        /// while it ran, so how it ended was never seen.
        var state: String
        var exitCode: Int32?
        var userSeconds: Double?
        var systemSeconds: Double?
        var timing: String?
        /// The Diptych that started it, and when that Diptych started -- an id
        /// alone is reused after a restart. Absent in records from before.
        var diptychPID: Int32?
        var diptychStartedAt: Date?

        /// Started by the Diptych that is running now.
        var isThisSession: Bool {
            diptychPID == DiptychProcess.pid
                && diptychStartedAt.map { abs($0.timeIntervalSince(DiptychProcess.startedAt)) < 1 } == true
        }
    }

    /// From Settings; nil keeps runs until they are deleted.
    static var keepingPeriod: TimeInterval? {
        let hours = ConfigStore.shared.configuration.runKeepHours
        return hours > 0 ? TimeInterval(hours) * 3600 : nil
    }

    let directory: URL
    private(set) var records: [Record] = []
    private var timer: Timer?

    init(directory: URL = StateStore.directory.appendingPathComponent("runs")) {
        self.directory = directory
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.purge() }
        }
    }

    // MARK: - Writing

    func started(_ run: CommandRun) {
        purge()
        let record = Self.record(of: run)
        records.removeAll { $0.id == run.id }
        records.append(record)
        write(record)
    }

    /// The program has exited: its record, and all it printed, to disk.
    func finished(_ run: CommandRun) {
        let record = Self.record(of: run)
        if let index = records.firstIndex(where: { $0.id == run.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        write(record)
        writePrivately(Data(run.outputText.utf8), to: logURL(run.id))
    }

    private static func record(of run: CommandRun) -> Record {
        Record(id: run.id, program: run.program.path, arguments: run.arguments,
               commandLine: run.commandLine, directory: run.directory.path,
               startedAt: run.startedAt, endedAt: run.endedAt, state: run.state,
               exitCode: run.exitCode, userSeconds: run.cpu?.user,
               systemSeconds: run.cpu?.system,
               timing: run.isRunning ? nil : run.timingLine,
               diptychPID: DiptychProcess.pid, diptychStartedAt: DiptychProcess.startedAt)
    }

    // MARK: - Reading

    /// Newest first: index 0 here is "the last run".
    var newestFirst: [Record] { records.sorted { $0.startedAt > $1.startedAt } }

    func record(_ id: UUID) -> Record? { records.first { $0.id == id } }

    /// What a finished run printed, from disk.
    func savedOutput(_ id: UUID) -> String? {
        try? String(contentsOf: logURL(id), encoding: .utf8)
    }

    // MARK: - Files

    private func recordURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func logURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("log")
    }

    private func write(_ record: Record) {
        guard let data = try? Self.encoder.encode(record) else { return }
        writePrivately(data, to: recordURL(record.id))
    }

    private func writePrivately(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// At launch: what is on disk. A record still saying "running" is from a
    /// Diptych that quit -- or crashed -- while it ran.
    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        records = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  var record = try? Self.decoder.decode(Record.self, from: data) else { return nil }
            if record.state == "running" { record.state = "interrupted" }
            return record
        }
        purge()
    }

    /// Runs that ended -- or started, if they never ended -- longer ago than
    /// they are kept go, with their output. Never one still running, or whose
    /// tab is open.
    func purge(now: Date = Date(), keptFor: TimeInterval? = RunLog.keepingPeriod) {
        guard let keptFor else { return }
        let live = Set(CommandRuns.shared.all.map(\.id))
        let old = records.filter {
            !live.contains($0.id) && now.timeIntervalSince($0.endedAt ?? $0.startedAt) > keptFor
        }
        remove(old)
    }

    /// Settings ▸ Delete All Kept Runs: everything but the runs whose tab is
    /// open or that are still running.
    func deleteAll() {
        let live = Set(CommandRuns.shared.all.map(\.id))
        remove(records.filter { !live.contains($0.id) })
    }

    private func remove(_ old: [Record]) {
        for record in old {
            try? FileManager.default.removeItem(at: recordURL(record.id))
            try? FileManager.default.removeItem(at: logURL(record.id))
        }
        let gone = Set(old.map(\.id))
        records.removeAll { gone.contains($0.id) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
