import Foundation
import Darwin

/// Create Archive's window: what is selected, the format and its options,
/// the name, and the work while it runs.
@MainActor
@Observable
final class ArchiveWindowModel {

    static let created = Notification.Name("diptych.archiveCreated")
    nonisolated static let urlKey = "url"

    struct Item: Identifiable, Sendable {
        let url: URL
        let isDirectory: Bool
        /// Bytes of a file; nil for a folder.
        let size: Int64?
        var id: URL { url }
    }

    let request: ArchiveRequest
    let items: [Item]
    /// Not all from one folder: each row says where it is.
    let fromSeveralFolders: Bool

    var options: Archiving.Options {
        didSet { Self.remember(options) }
    }
    /// The name without its extension, which follows the format.
    var stem: String
    var intoOtherPane = false

    private(set) var isRunning = false
    /// How far it has got, read from the job four times a second.
    private(set) var progress = Archiving.Job.Snapshot()
    /// When the tool started, for the time left.
    @ObservationIgnored private var archivingSince: Date?
    private(set) var problem: String?
    /// The window closes when this is set.
    private(set) var made: URL?
    @ObservationIgnored private var job: Archiving.Job?

    init(_ request: ArchiveRequest) {
        self.request = request
        items = request.items.map { url in
            var info = stat()
            let found = lstat(url.path, &info) == 0
            let directory = found && info.st_mode & S_IFMT == S_IFDIR
            return Item(url: url, isDirectory: directory,
                        size: found && !directory ? Int64(info.st_size) : nil)
        }
        fromSeveralFolders = Set(request.items.map { $0.deletingLastPathComponent() }).count > 1
        options = Self.remembered()
        stem = Archiving.defaultStem(for: request.items)
    }

    var folder: URL {
        intoOtherPane ? (request.otherFolder ?? request.folder) : request.folder
    }

    private var cleanStem: String {
        stem.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: ":")
    }

    /// The name it will have, numbered where that is taken.
    var target: URL {
        Archiving.numbered(cleanStem.isEmpty ? "Archive" : cleanStem,
                           extension: options.fileExtension, in: folder)
    }

    var totalSize: Int64 { items.compactMap(\.size).reduce(0, +) }

    func create() {
        guard !isRunning else { return }
        let target = target
        let items = request.items
        let options = options
        let job = Archiving.Job()
        self.job = job
        isRunning = true
        problem = nil
        progress = Archiving.Job.Snapshot()
        archivingSince = nil
        Task { [weak self] in
            while let self, self.isRunning {
                self.progress = job.snapshot()
                if self.progress.phase == .archiving, self.archivingSince == nil {
                    self.archivingSince = Date()
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        Task {
            let outcome = await BlockingWork.run { () -> Archiving.Failure? in
                do throws(Archiving.Failure) {
                    try Archiving.create(items, at: target, options: options, job: job)
                    return nil
                } catch {
                    return error
                }
            }
            isRunning = false
            self.job = nil
            if let outcome {
                if !job.isCancelled { problem = outcome.message }
                return
            }
            FileHistory.shared.recordCreation(.made("Create Archive"), of: [target])
            NotificationCenter.default.post(name: Self.created, object: nil,
                                            userInfo: [Self.urlKey: target])
            made = target
        }
    }

    func stop() { job?.cancel() }

    /// "About 2 minutes left", once there is enough to go on.
    var timeLeft: String? {
        guard let since = archivingSince, let fraction = progress.fraction, fraction > 0.02 else {
            return nil
        }
        let elapsed = Date().timeIntervalSince(since)
        guard elapsed > 3 else { return nil }
        let left = elapsed / fraction - elapsed
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = left < 60 ? [.second] : left < 3600 ? [.minute] : [.hour, .minute]
        guard let text = formatter.string(from: max(left, 1).rounded()) else { return nil }
        return "about \(text) left"
    }

    // MARK: - What was chosen last

    private static let key = "archiveOptions"

    private static func remembered() -> Archiving.Options {
        guard let data = UserDefaults.standard.data(forKey: key),
              let options = try? JSONDecoder().decode(Archiving.Options.self, from: data)
        else { return Archiving.Options() }
        return options
    }

    private static func remember(_ options: Archiving.Options) {
        if let data = try? JSONEncoder().encode(options) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
