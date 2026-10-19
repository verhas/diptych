import Foundation
import CoreGraphics
import Darwin

/// What Optimize File Size is opened on.
struct OptimizeRequest: Codable, Hashable, Sendable {
    var items: [URL]
}

/// The Optimize File Size window: every file with the size it would have,
/// each kind's settings, the selected one shown before and after, and the
/// replacing.
///
/// A candidate is made for each file into a folder of the window's own, again
/// whenever a setting that matters to its kind changes -- the selected file
/// first -- so the sizes and the comparison are of what would really be
/// written, not an estimate.
@MainActor
@Observable
final class OptimizeModel {

    static let optimized = Notification.Name("diptych.optimized")

    struct Row: Identifiable {
        let url: URL
        let kind: Optimizing.Kind
        let size: Int64
        /// Ticked to be replaced.
        var isIncluded = true
        /// The user ticked or unticked it: a new size no longer decides.
        var isDecided = false
        var candidate: URL?
        var newSize: Int64?
        var problem: String?
        /// The problem is only that nothing can be gained.
        var isPointless = false
        /// What a PDF holds, once read.
        var pictures: Optimizing.PDFPictures?
        /// The settings the candidate was made with.
        var madeWith: String?
        var note: String?

        var id: URL { url }

        var isWorking: Bool { candidate == nil && problem == nil }

        var saving: Double? {
            guard let newSize, size > 0 else { return nil }
            return 1 - Double(newSize) / Double(size)
        }

        /// Worth replacing: at least a little smaller.
        var helps: Bool { (saving ?? 0) > 0.01 }
    }

    let request: OptimizeRequest
    var rows: [Row]
    var selection: URL? {
        didSet { if selection != oldValue { page = 0; loadComparison() } }
    }
    var settings: Optimizing.Settings {
        didSet {
            guard settings != oldValue else { return }
            Self.remember(settings)
            scheduleCandidates()
        }
    }

    /// Of a PDF, the page compared.
    var page = 0 {
        didSet { if page != oldValue { loadComparison() } }
    }
    private(set) var pageCount = 1
    private(set) var before: CGImage?
    private(set) var after: CGImage?
    private(set) var isApplying = false
    private(set) var problems: [String] = []
    /// The window closes when set.
    private(set) var finished = false

    @ObservationIgnored private let scratch: URL
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var comparing: Task<Void, Never>?

    init(_ request: OptimizeRequest) {
        self.request = request
        rows = request.items.compactMap { url in
            guard let kind = Optimizing.kind(of: url), let size = Optimizing.size(of: url) else {
                return nil
            }
            return Row(url: url, kind: kind, size: size)
        }
        settings = Self.remembered()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("Diptych-optimize-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        selection = rows.first?.url
    }

    /// Kinds present, in the order their settings are shown.
    var kinds: [Optimizing.Kind] {
        Optimizing.Kind.allCases.filter { kind in rows.contains { $0.kind == kind } }
    }

    func count(of kind: Optimizing.Kind) -> Int { rows.filter { $0.kind == kind }.count }

    var selectedRow: Row? { rows.first { $0.url == selection } }

    var included: [Row] { rows.filter { $0.isIncluded && $0.candidate != nil && $0.helps } }

    var isWorking: Bool { rows.contains(where: \.isWorking) }

    var totals: (before: Int64, after: Int64) {
        let chosen = included
        return (chosen.reduce(0) { $0 + $1.size }, chosen.reduce(0) { $0 + ($1.newSize ?? $1.size) })
    }

    func start() {
        scheduleCandidates(after: .zero)
        loadComparison()
        loadPictures()
    }

    /// What each PDF holds, for its resolution and whether it can shrink.
    private func loadPictures() {
        let pdfs = rows.filter { $0.kind == .pdf }.map(\.url)
        guard !pdfs.isEmpty else { return }
        Task { [weak self] in
            for url in pdfs {
                let pictures = await BlockingWork.run { Optimizing.pictures(in: url) }
                guard let self, let index = self.rows.firstIndex(where: { $0.url == url }) else { return }
                self.rows[index].pictures = pictures
            }
        }
    }

    /// The resolution of the PDFs' pictures, for the settings: the selected
    /// one's when it is a PDF.
    var pdfResolutionNow: String? {
        if let row = selectedRow, row.kind == .pdf { return row.pictures?.resolution }
        let all = rows.compactMap(\.pictures)
        guard let low = all.compactMap(\.lowestResolution).min(),
              let high = all.compactMap(\.highestResolution).max() else { return nil }
        return high - low < 10 ? "about \(high) ppi" : "\(low) to \(high) ppi"
    }

    func toggle(_ url: URL) {
        guard let index = rows.firstIndex(where: { $0.url == url }),
              rows[index].helps else { return }
        rows[index].isIncluded.toggle()
        rows[index].isDecided = true
    }

    /// Nothing left behind when the window goes.
    func close() {
        work?.cancel()
        comparing?.cancel()
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Candidates

    /// Made again after a pause, so a slider being dragged does not start a
    /// hundred rounds.
    private func scheduleCandidates(after delay: Duration = .milliseconds(400)) {
        generation += 1
        let generation = generation
        let settings = settings
        work?.cancel()
        // The rows whose kind's settings changed lose their candidate now,
        // so no stale size is shown.
        for index in rows.indices where rows[index].madeWith != settings.key(for: rows[index].kind) {
            rows[index].candidate = nil
            rows[index].newSize = nil
            rows[index].problem = nil
            rows[index].isPointless = false
        }
        work = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.makeCandidates(generation: generation, settings: settings)
        }
    }

    private func makeCandidates(generation: Int, settings: Optimizing.Settings) async {
        // The one being looked at first.
        var order = rows.indices.filter { rows[$0].madeWith != settings.key(for: rows[$0].kind) }
        if let selected = rows.firstIndex(where: { $0.url == selection }),
           let at = order.firstIndex(of: selected) {
            order.remove(at: at)
            order.insert(selected, at: 0)
        }
        let scratch = scratch
        let snapshot = rows
        await withTaskGroup(of: (Int, Result<Made, Optimizing.Failure>).self) { group in
            var next = 0
            func add() {
                guard next < order.count else { return }
                let index = order[next]
                next += 1
                let row = snapshot[index]
                group.addTask {
                    let output = scratch.appendingPathComponent(
                        "\(UUID().uuidString).\(row.url.pathExtension)")
                    let result = await BlockingWork.run { () -> Result<Made, Optimizing.Failure> in
                        do throws(Optimizing.Failure) {
                            try Optimizing.optimize(row.url, kind: row.kind, settings: settings,
                                                    to: output)
                            let kept = row.kind == .png && settings.pngColours != nil
                                && !Optimizing.isOpaque(row.url)
                            return .success(Made(url: output, size: Optimizing.size(of: output) ?? 0,
                                                 keptColours: kept))
                        } catch {
                            return .failure(error)
                        }
                    }
                    return (index, result)
                }
            }
            for _ in 0..<4 { add() }
            for await (index, result) in group {
                guard generation == self.generation, !Task.isCancelled else {
                    if case .success(let made) = result { try? FileManager.default.removeItem(at: made.url) }
                    continue
                }
                place(result, at: index, settings: settings)
                add()
            }
        }
    }

    /// A candidate made.
    private struct Made: Sendable {
        let url: URL
        let size: Int64
        /// A PNG with transparency, whose colours could not be reduced.
        let keptColours: Bool
    }

    private func place(_ result: Result<Made, Optimizing.Failure>, at index: Int,
                       settings: Optimizing.Settings) {
        var row = rows[index]
        if let old = row.candidate { try? FileManager.default.removeItem(at: old) }
        row.madeWith = settings.key(for: row.kind)
        switch result {
        case .success(let made):
            row.candidate = made.url
            row.newSize = made.size
            row.problem = nil
            row.isPointless = false
            row.note = row.helps ? nil : "would not get smaller with these settings"
            if made.keptColours {
                row.note = (row.note.map { $0 + "; " } ?? "")
                    + "has transparency, so its colours were kept"
            }
            if !row.isDecided { row.isIncluded = row.helps }
        case .failure(let failure):
            row.candidate = nil
            row.newSize = nil
            row.problem = failure.message
            row.isPointless = failure.pointless
            row.isIncluded = false
        }
        rows[index] = row
        if row.url == selection { loadComparison() }
    }

    // MARK: - Before and after

    private func loadComparison() {
        comparing?.cancel()
        guard let row = selectedRow else {
            before = nil
            after = nil
            return
        }
        let page = page
        comparing = Task { [weak self] in
            let images = await BlockingWork.run { () -> (CGImage?, CGImage?, Int) in
                let count = row.kind == .pdf ? Optimizing.pageCount(of: row.url) : 1
                let before = Optimizing.preview(of: row.url, kind: row.kind, page: page)
                let after = row.candidate.flatMap {
                    Optimizing.preview(of: $0, kind: row.kind, page: page)
                }
                return (before, after, count)
            }
            guard !Task.isCancelled, let self, self.selection == row.url else { return }
            self.before = images.0
            self.after = images.1
            self.pageCount = images.2
        }
    }

    // MARK: - Doing it

    func apply() {
        let chosen = included
        guard !chosen.isEmpty, !isApplying else { return }
        isApplying = true
        let settings = settings
        Task {
            let outcome = await Self.apply(chosen.map { ($0.url, $0.candidate!) },
                                           settings: settings)
            isApplying = false
            problems = outcome.failures
            if !outcome.done.isEmpty {
                NotificationCenter.default.post(name: Self.optimized, object: nil,
                                                userInfo: ["urls": outcome.done])
            }
            if outcome.failures.isEmpty { finished = true }
        }
    }

    /// The candidates put in place: into the originals, which stay the same
    /// files -- their links, permissions and attributes with them -- or
    /// beside them. One step of Undo either way.
    static func apply(_ pairs: [(original: URL, candidate: URL)],
                      settings: Optimizing.Settings,
                      history: FileHistory = .shared) async -> (done: [URL], failures: [String]) {
        let outcome = await BlockingWork.run { () -> ([(URL, URL)], [URL], [String]) in
            var replaced: [(URL, URL)] = []
            var made: [URL] = []
            var failures: [String] = []
            for (original, candidate) in pairs {
                let name = original.lastPathComponent
                let modified = FileHistory.exactDate(.modified, of: original)
                do {
                    let target: URL
                    if settings.replaceOriginals {
                        let before = try UndoSnapshots.keep(original)
                        do {
                            try UndoSnapshots.putBack(candidate, into: original)
                        } catch {
                            try? UndoSnapshots.putBack(before, into: original)
                            try? FileManager.default.removeItem(at: before)
                            throw error
                        }
                        replaced.append((original, before))
                        target = original
                    } else {
                        let stem = original.deletingPathExtension().lastPathComponent
                        target = FileOperations.uniqueURL(
                            for: original.deletingLastPathComponent()
                                .appendingPathComponent("\(stem) (optimized)")
                                .appendingPathExtension(original.pathExtension))
                        try FileManager.default.copyItem(at: candidate, to: target)
                        made.append(target)
                    }
                    if settings.keepModifiedDate, let modified {
                        try? FileHistory.setDate(.modified, modified, of: target)
                    }
                } catch {
                    failures.append("\u{201C}\(name)\u{201D} could not be written: "
                                    + error.localizedDescription)
                }
            }
            return (replaced, made, failures)
        }
        let replaced = outcome.0.map { (url: $0.0, before: $0.1) }
        history.recordContents(replaced, name: "Optimize",
                                     told: replaced.count == 1
                                         ? "\u{201C}\(replaced[0].url.lastPathComponent)\u{201D} was made smaller."
                                         : "\(replaced.count) files were made smaller.")
        history.recordCreation(.made("Optimize"), of: outcome.1)
        return (outcome.0.map(\.0) + outcome.1, outcome.2)
    }

    // MARK: - What was chosen last

    private static let key = "optimizeSettings"

    private static func remembered() -> Optimizing.Settings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(Optimizing.Settings.self, from: data)
        else { return Optimizing.Settings() }
        return settings
    }

    private static func remember(_ settings: Optimizing.Settings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
