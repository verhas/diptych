import SwiftUI
import AppKit

/// What a Split File window needs to do its work: the file, where the parts go,
/// and the window that asked -- so the result can be revealed and made undoable
/// back in that window once the split is done.
///
/// A job is registered here and the window opened with its id, the same way the
/// batch-operations window finds its model. It lives in a real, movable window
/// rather than a sheet: the person asked to be able to slide it aside and see
/// the file list underneath.
@MainActor
final class SplitStore {

    static let shared = SplitStore()

    struct Job {
        weak var model: AppModel?
        let file: URL
        let folder: URL
        let otherPane: Bool
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

struct SplitView: View {

    let jobId: UUID

    @Environment(\.dismiss) private var dismiss

    @State private var sizeText = "100"
    @State private var unit: FileSplitting.SizeUnit = .megabytes
    /// Set when the split would overwrite files, or fail: shown and the split
    /// held back.
    @State private var problem: String?
    /// A large split waiting for the person to confirm: the part count.
    @State private var confirmCount: Int?
    @State private var working = false
    @FocusState private var fieldFocused: Bool

    private var job: SplitStore.Job? { SplitStore.shared.job(for: jobId) }

    private var fileSize: Int64 {
        guard let file = job?.file else { return 0 }
        return (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    /// The typed size as bytes, or nil when it is not a positive number.
    private var partBytes: Int64? {
        let value = Double(sizeText.replacingOccurrences(of: ",", with: ".")) ?? 0
        guard value > 0 else { return nil }
        return Int64((value * Double(unit.multiplier)).rounded())
    }

    /// How many parts the typed size would make.
    private var partCount: Int {
        guard let bytes = partBytes else { return 0 }
        return FileSplitting.partCount(totalSize: fileSize, partSize: bytes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            if let count = confirmCount {
                confirmation(count: count)
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(WindowAccessor { window in
            if let window {
                window.title = "Split \u{201C}\(job?.file.lastPathComponent ?? "")\u{201D}"
                window.isMovable = true
                AppWindows.shared.register(window)
                WindowSubjects.shared.register(window, kind: "split",
                                               description: job?.file.path ?? "")
            }
        })
        .onAppear { fieldFocused = true }
    }

    // MARK: - Header: the file and its size

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(job?.file.lastPathComponent ?? "")
                .font(.headline).lineLimit(1).truncationMode(.middle)
            Text("Size: \(sizeInSelectedUnit)")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    /// The file's size in whatever unit the picker is on, so it reads against
    /// the part size the person is typing.
    private var sizeInSelectedUnit: String {
        let value = Double(fileSize) / Double(unit.multiplier)
        let number = value >= 100 ? String(format: "%.0f", value)
                   : value >= 10  ? String(format: "%.1f", value)
                                  : String(format: "%.2f", value)
        return "\(number) \(unit.rawValue) "
             + "(\(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)))"
    }

    // MARK: - The form

    @ViewBuilder
    private var form: some View {
        HStack {
            TextField("Size", text: $sizeText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                .focused($fieldFocused)
                .onSubmit(start)
            Picker("", selection: $unit) {
                ForEach(FileSplitting.SizeUnit.allCases) { unit in
                    Text(unit.rawValue).tag(unit)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
        }

        // The sizes people actually split for.
        HStack(spacing: 8) {
            preset("Email", "25", .megabytes)
            preset("CD", "700", .megabytes)
            preset("DVD", "4700", .megabytes)
            preset("FAT32", "4", .gigabytes)
        }

        Text(rangeDescription)
            .font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if let otherPane = job?.otherPane, otherPane, let folder = job?.folder {
            Label("This folder is read-only, so the parts go in the other pane:\n\(folder.path)",
                  systemImage: "arrow.right.circle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }

        HStack {
            Spacer()
            Button("Cancel") { close() }
                .keyboardShortcut(.cancelAction)
            Button("Split", action: start)
                .keyboardShortcut(.defaultAction)
                .disabled(partBytes == nil || working)
        }
    }

    /// The dynamic "001 … NNN" line: parts are numbered from the start, so the
    /// first is `.001` and the last is however many the typed size makes.
    private var rangeDescription: String {
        guard partBytes != nil, partCount > 0 else {
            return "Type a part size. Each part is named \u{2026}.001, \u{2026}.002 and so on, "
                 + "with a small manifest beside them."
        }
        let digits = max(3, String(partCount).count)
        let last = String(format: "%0\(digits)d", partCount)
        let first = String(format: "%0\(digits)d", 1)
        return partCount == 1
            ? "This makes a single part, named \u{2026}.\(first), with a manifest beside it."
            : "This makes \(partCount) parts, named \u{2026}.\(first) through \u{2026}.\(last), "
            + "with a manifest beside them. Select any of them (or the manifest) and Join Parts "
            + "puts the file back together."
    }

    private func preset(_ title: String, _ size: String,
                        _ unit: FileSplitting.SizeUnit) -> some View {
        Button(title) { sizeText = size; self.unit = unit; problem = nil }
            .buttonStyle(.bordered).controlSize(.small)
    }

    // MARK: - The "that is a lot of files" confirmation

    private func confirmation(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("That is a lot of files", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
            Text("\u{201C}\(job?.file.lastPathComponent ?? "")\u{201D} is going to be split up into "
                 + "pieces of \(sizeText) \(unit.rawValue), resulting in \(count) separate files. "
                 + "Please confirm the creation of \(count) files.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { confirmCount = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Create \(count) Files") { confirmCount = nil; perform() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Doing it

    /// The Split button: check first, then either confirm a large split or go.
    private func start() {
        guard let job, let bytes = partBytes else { return }
        problem = nil

        let existing = FileSplitting.existingOutputs(file: job.file, partSize: bytes, into: job.folder)
        if !existing.isEmpty {
            let names = existing.map(\.lastPathComponent).joined(separator: ", ")
            problem = "These files already exist and will not be overwritten: \(names). "
                    + "Move or remove them, or choose a different part size."
            return
        }

        let count = FileSplitting.partCount(totalSize: fileSize, partSize: bytes)
        let threshold = ConfigStore.shared.configuration.splitPartWarningThreshold
        if count > threshold {
            confirmCount = count
        } else {
            perform()
        }
    }

    private func perform() {
        guard let job, let bytes = partBytes else { return }
        working = true
        let file = job.file
        let folder = job.folder
        Task {
            let result = await BlockingWork.run { () -> Result<(parts: [URL], manifest: URL), Error> in
                Result { try FileSplitting.split(file, partSize: bytes, into: folder) }
            }
            working = false
            switch result {
            case .success(let output):
                job.model?.revealSplitResult(parts: output.parts, manifest: output.manifest,
                                             in: folder, otherPane: job.otherPane)
                close()
            case .failure(let error):
                problem = error.localizedDescription
            }
        }
    }

    private func close() {
        SplitStore.shared.clear(jobId)
        dismiss()
    }
}
