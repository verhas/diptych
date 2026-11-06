import Foundation

/// The small windows of Tools that work on a selection: what each one was
/// opened for, and the window that asked, so the result can be shown and
/// made undoable back there. Registered here and the window opened with the
/// id, as the Split File window is.
@MainActor
final class ToolWindows {

    static let shared = ToolWindows()

    enum Kind: Sendable {
        case checksums, lineEndings, encodings, install
    }

    struct Job {
        weak var model: AppModel?
        let kind: Kind
        let files: [URL]
        /// Install only: what the disk image offers to install.
        var offer: AppInstalling.Offer?
    }

    private var jobs: [UUID: Job] = [:]

    func register(_ job: Job) -> UUID {
        let id = UUID()
        jobs[id] = job
        return id
    }

    func job(for id: UUID) -> Job? { jobs[id] }
    func clear(_ id: UUID) { jobs[id] = nil }
}

/// Reading a file to convert, and writing it back in place.
enum TextConversion {

    /// Why a file read is not converted: it is not text. Such a file is left
    /// out of the list rather than shown as refused.
    nonisolated static let notText = "not a text file"

    /// "; 3 files that are not text are left out", or nothing.
    nonisolated static func leftOutNote(_ count: Int) -> String {
        count == 0 ? "" : "; \(count) file\(count == 1 ? "" : "s") that \(count == 1 ? "is" : "are") "
            + "not text \(count == 1 ? "is" : "are") left out"
    }

    /// Larger than this is not read into memory to convert.
    static let sizeLimit = 64 << 20

    /// The file's bytes, or why there are none to convert.
    nonisolated static func load(_ url: URL) -> Result<Data, Problem> {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= sizeLimit else {
            return .failure(Problem("too large to convert here (over 64 MB)"))
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failure(Problem("cannot be read"))
        }
        return .success(data)
    }

    struct Problem: Error, Equatable, Sendable {
        let text: String
        init(_ text: String) { self.text = text }
    }

    /// The new bytes into each file in place -- the same file, with its links,
    /// permissions and attributes -- each one's old bytes kept for Undo. A
    /// file on a server is sent back by the watch on its folder, and has no
    /// Undo here.
    @MainActor
    static func rewrite(_ changes: [(url: URL, data: Data)], undoName: String,
                        history: FileHistory = .shared) async -> (done: [URL], failures: [String]) {
        let outcome = await BlockingWork.run { () -> ([(url: URL, before: URL)], [URL], [String]) in
            var kept: [(url: URL, before: URL)] = []
            var done: [URL] = []
            var failures: [String] = []
            for (url, data) in changes {
                do {
                    let before = try UndoSnapshots.keep(url)
                    do {
                        let handle = try FileHandle(forWritingTo: url)
                        defer { try? handle.close() }
                        try handle.truncate(atOffset: 0)
                        try handle.write(contentsOf: data)
                    } catch {
                        try? UndoSnapshots.putBack(before, into: url)
                        try? FileManager.default.removeItem(at: before)
                        throw error
                    }
                    kept.append((url, before))
                    done.append(url)
                } catch {
                    failures.append("\u{201C}\(url.lastPathComponent)\u{201D} could not be written: "
                                    + error.localizedDescription)
                }
            }
            return (kept, done, failures)
        }
        let undoable = outcome.0.filter { !RemoteBrowsing.isInside($0.url) }
        history.recordContents(undoable, name: undoName,
                               told: undoable.count == 1
                                   ? "\u{201C}\(undoable[0].url.lastPathComponent)\u{201D} was converted."
                                   : "\(undoable.count) files were converted.")
        return (outcome.1, outcome.2)
    }

    /// A line of the text to recognise it by: the first with a letter beyond
    /// ASCII in it, where the encoding shows, or else the first that is not
    /// blank.
    nonisolated static func sample(of text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).prefix(2000)
        let line = lines.first { $0.unicodeScalars.contains { !$0.isASCII } }
            ?? lines.first { !$0.allSatisfy(\.isWhitespace) } ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 90 ? String(trimmed.prefix(90)) + "\u{2026}" : trimmed
    }
}

// MARK: - Line endings

/// Tools ▸ Convert Line Endings…: each file with what its lines end in now,
/// and one kind to make them all.
@MainActor
@Observable
final class LineEndingsModel {

    struct Row: Identifiable {
        let url: URL
        var id: URL { url }
        var name: String { url.lastPathComponent }
        var data: Data?
        var reading: TextEncodings.Reading?
        var text: String?
        var report: LineEndingReport?
        /// Why it cannot be converted at all.
        var problem: String?
    }

    private(set) var rows: [Row]
    /// Selected, but not text: not in the list, and not converted.
    private(set) var leftOut = 0
    private(set) var loaded = false
    var target: LineEnding = .lf {
        // LS and PS separate lines: none after the last is what they expect.
        didSet { if target != oldValue { finalEnding = !target.separates } }
    }
    var finalEnding = true
    private(set) var working = false
    private(set) var finished = false
    private(set) var failures: [String] = []

    let jobId: UUID

    init(jobId: UUID, files: [URL]) {
        self.jobId = jobId
        let text = files.filter { !AppModel.isNeverText($0) }
        rows = text.map { Row(url: $0) }
        leftOut = files.count - text.count
    }

    func load() async {
        let files = rows.map(\.url)
        let read = await BlockingWork.run { files.map(Self.read) }
        // A file that is not text is left out, not listed as refused: among
        // a project's thousands of sources, its pictures are no news.
        rows = read.filter { $0.problem != TextConversion.notText }
        leftOut += read.count - rows.count
        loaded = true
    }

    nonisolated private static func read(_ url: URL) -> Row {
        var row = Row(url: url)
        switch TextConversion.load(url) {
        case .failure(let problem): row.problem = problem.text
        case .success(let data):
            guard let reading = TextEncodings.reading(of: data, at: url, fallback: .windowsCP1252),
                  let text = TextEncodings.decode(data, reading)
                      ?? (reading.hasBOM ? nil : String(data: data, encoding: .isoLatin1)) else {
                row.problem = TextConversion.notText
                return row
            }
            row.data = data
            row.reading = TextEncodings.decode(data, reading) == nil
                ? TextEncodings.Reading(encoding: .isoLatin1, guessed: true) : reading
            row.text = text
            row.report = LineEndings.report(of: text)
        }
        return row
    }

    /// What converting `row` would write, or why it is left alone.
    enum Plan: Equatable {
        case write(Data)
        case unchanged
        case refused(String)
    }

    func plan(for row: Row) -> Plan {
        if let problem = row.problem { return .refused(problem) }
        guard let text = row.text, let reading = row.reading, let data = row.data else {
            return .refused("not read yet")
        }
        let converted = LineEndings.convert(text, to: target, finalEnding: finalEnding)
        if converted == text { return .unchanged }
        guard let body = TextEncodings.encode(converted, reading.encoding, bom: false) else {
            return .refused("\(target.short) cannot be written in "
                            + TextEncodings.name(of: reading.encoding))
        }
        let written = data.prefix(reading.bomLength) + body
        return written == data ? .unchanged : .write(written)
    }

    var convertible: Int {
        rows.filter { if case .write = plan(for: $0) { true } else { false } }.count
    }

    func convert() async {
        let changes = rows.compactMap { row -> (url: URL, data: Data)? in
            if case .write(let data) = plan(for: row) { return (row.url, data) }
            return nil
        }
        guard !changes.isEmpty else { return }
        working = true
        let result = await TextConversion.rewrite(changes, undoName: "Convert Line Endings")
        working = false
        failures = result.failures
        let job = ToolWindows.shared.job(for: jobId)
        if let model = job?.model, let first = result.done.first {
            model.show(result.done, in: first.deletingLastPathComponent())
            let skipped = rows.count - changes.count
            model.flash("Line endings of \(result.done.count) file\(result.done.count == 1 ? "" : "s") "
                        + "made \(target.short)"
                        + (skipped > 0 ? ", \(skipped) left as they were" : ""), error: false)
        }
        if failures.isEmpty { finished = true }
    }
}

// MARK: - Character encodings

/// Tools ▸ Convert Character Encoding…: each file with the encoding it is
/// taken to be in -- changeable, one by one or all at once -- and one
/// encoding to write them all in.
@MainActor
@Observable
final class EncodingsModel {

    struct Row: Identifiable {
        let url: URL
        var id: URL { url }
        var name: String { url.lastPathComponent }
        var data: Data?
        /// What the bytes told.
        var detected: TextEncodings.Reading?
        /// What it is taken to be in: the detected one, unless changed.
        var perceived: String.Encoding = .utf8
        /// Its text in `perceived`; nil when the bytes are not valid in it.
        var text: String?
        var sample = ""
        var problem: String?
    }

    private(set) var rows: [Row]
    /// Selected, but not text: not in the list, and not converted.
    private(set) var leftOut = 0
    private(set) var loaded = false
    var target: String.Encoding = .utf8 {
        // A mark is the only way to tell UTF-16 or UTF-32 by its bytes; UTF-8
        // needs none, and many programs stumble over one.
        didSet { if target != oldValue { bom = target != .utf8 && TextEncodings.isUnicode(target) } }
    }
    var bom = false
    private(set) var working = false
    private(set) var finished = false
    private(set) var failures: [String] = []

    let jobId: UUID

    init(jobId: UUID, files: [URL]) {
        self.jobId = jobId
        let text = files.filter { !AppModel.isNeverText($0) }
        rows = text.map { Row(url: $0) }
        leftOut = files.count - text.count
    }

    var targetIsUnicode: Bool { TextEncodings.isUnicode(target) }

    func load() async {
        let files = rows.map(\.url)
        let read = await BlockingWork.run { files.map(Self.read) }
        // A file that is not text is left out, not listed as refused: among
        // a project's thousands of sources, its pictures are no news.
        rows = read.filter { $0.problem != TextConversion.notText }
        leftOut += read.count - rows.count
        loaded = true
    }

    nonisolated private static func read(_ url: URL) -> Row {
        var row = Row(url: url)
        switch TextConversion.load(url) {
        case .failure(let problem): row.problem = problem.text
        case .success(let data):
            guard let reading = TextEncodings.reading(of: data, at: url, fallback: .windowsCP1252) else {
                row.problem = TextConversion.notText
                return row
            }
            row.data = data
            row.detected = reading
            row.perceived = reading.encoding
            decode(&row)
        }
        return row
    }

    /// The mark is taken off only when the file is read in the encoding the
    /// mark is of: read as anything else, its bytes are part of the text.
    nonisolated private static func decode(_ row: inout Row) {
        guard let data = row.data else { return }
        let strip = row.detected.map { $0.encoding == row.perceived ? $0.bomLength : 0 } ?? 0
        row.text = TextEncodings.decode(data, .init(encoding: row.perceived, bomLength: strip))
        row.sample = row.text.map(TextConversion.sample) ?? ""
    }

    func setPerceived(_ encoding: String.Encoding, of id: URL) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].perceived = encoding
        Self.decode(&rows[index])
    }

    func setPerceivedForAll(_ encoding: String.Encoding) {
        for index in rows.indices where rows[index].data != nil {
            rows[index].perceived = encoding
            Self.decode(&rows[index])
        }
    }

    /// The encoding every readable file is taken to be in, when it is one.
    var commonPerceived: String.Encoding? {
        let all = Set(rows.filter { $0.data != nil }.map(\.perceived.rawValue))
        return all.count == 1 ? all.first.map(String.Encoding.init(rawValue:)) : nil
    }

    enum Plan: Equatable {
        case write(Data)
        case unchanged
        case refused(String)
    }

    func plan(for row: Row) -> Plan {
        if let problem = row.problem { return .refused(problem) }
        guard let data = row.data else { return .refused("not read yet") }
        guard let text = row.text else {
            return .refused("not valid \(TextEncodings.name(of: row.perceived))")
        }
        guard let written = TextEncodings.encode(text, target, bom: targetIsUnicode && bom) else {
            let missing = TextEncodings.unrepresentable(in: text, target)
            return .refused("\(missing) character\(missing == 1 ? "" : "s") not in "
                            + TextEncodings.name(of: target))
        }
        return written == data ? .unchanged : .write(written)
    }

    var convertible: Int {
        rows.filter { if case .write = plan(for: $0) { true } else { false } }.count
    }

    func convert() async {
        let changes = rows.compactMap { row -> (url: URL, data: Data)? in
            if case .write(let data) = plan(for: row) { return (row.url, data) }
            return nil
        }
        guard !changes.isEmpty else { return }
        working = true
        let result = await TextConversion.rewrite(changes, undoName: "Convert Character Encoding")
        working = false
        failures = result.failures
        if !result.done.isEmpty {
            // An encoding the file recorded for itself would now be wrong.
            for url in result.done { TextEncodings.updateRecorded(target, on: url) }
        }
        if let model = ToolWindows.shared.job(for: jobId)?.model, let first = result.done.first {
            model.show(result.done, in: first.deletingLastPathComponent())
            let skipped = rows.count - changes.count
            model.flash("\(result.done.count) file\(result.done.count == 1 ? "" : "s") converted to "
                        + TextEncodings.name(of: target)
                        + (skipped > 0 ? ", \(skipped) left as they were" : ""), error: false)
        }
        if failures.isEmpty { finished = true }
    }
}
