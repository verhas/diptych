import SwiftUI
import AppKit

/// File ▸ Previous Versions…: a file's earlier selves, read out of APFS
/// snapshots -- the hourly local ones and, when the backup disk is attached,
/// Time Machine's longer history. Pick a version to compare it with the file
/// as it is now; the comparison opens in its own window, so you come back here
/// to try another or to restore. Restoring copies the old contents over the
/// file as a normal, undoable step -- it is not a whole-volume rollback.
@MainActor
@Observable
final class FileVersionsModel {

    let file: URL
    private(set) var versions: [FileVersions.Version] = []
    private(set) var note: String?
    private(set) var loading = true
    private(set) var problem: String?
    /// Set briefly after a restore, so the window can say so before it closes.
    private(set) var restored = false

    var selection: FileVersions.Version.ID?

    init(file: URL) { self.file = file }

    var selected: FileVersions.Version? {
        versions.first { $0.id == selection }
    }

    func load() async {
        loading = true
        problem = nil
        let file = self.file
        let listing = await BlockingWork.run { FileVersions.list(for: file) }
        versions = listing.versions
        note = listing.note
        loading = false
        if selection == nil || versions.first(where: { $0.id == selection }) == nil {
            selection = versions.first(where: \.isAvailable)?.id ?? versions.first?.id
        }
    }

    /// Replaces the file's bytes with the chosen version's, recording it for
    /// Undo. True when it was done.
    func restore(_ version: FileVersions.Version) -> Bool {
        guard let source = version.url else {
            problem = "That version is not available to read just now."
            return false
        }
        do {
            let before = try FileVersions.restore(source, over: file)
            FileHistory.shared.recordContents(
                [(url: file, before: before)],
                name: "Restore",
                told: "\u{201C}\(file.lastPathComponent)\u{201D} was restored to its version "
                    + "from \(Self.when(version.date)).")
            restored = true
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    static func when(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct FileVersionsView: View {

    let request: FileVersions.Request

    @State private var model: FileVersionsModel
    @State private var confirming: FileVersions.Version?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    init(request: FileVersions.Request) {
        self.request = request
        _model = State(initialValue: FileVersionsModel(file: request.file))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            content
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            bottom
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 440)
        .navigationTitle("Previous Versions \u{2014} \(request.file.lastPathComponent)")
        .task { await model.load() }
        .alert("Restore this version?", isPresented: restoreConfirmation) {
            Button("Cancel", role: .cancel) { confirming = nil }
            Button("Restore") {
                if let version = confirming, model.restore(version) { dismiss() }
                confirming = nil
            }
        } message: {
            if let version = confirming {
                Text("\u{201C}\(request.file.lastPathComponent)\u{201D} will be replaced with its "
                     + "contents from \(FileVersionsModel.when(version.date)). The file keeps its "
                     + "name and permissions; only its contents change, and you can Undo it.")
            }
        }
    }

    private var restoreConfirmation: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    // MARK: -

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(request.file.lastPathComponent).font(.headline)
            Text(request.file.deletingLastPathComponent().path)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    @ViewBuilder private var content: some View {
        if model.loading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for earlier versions in this Mac\u{2019}s snapshots\u{2026}")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.versions.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "clock.badge.questionmark")
                    .font(.largeTitle).foregroundStyle(.secondary)
                Text(model.note ?? "No earlier versions were found.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        } else {
            versionList
        }
    }

    private var versionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let note = model.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            List(model.versions, selection: $model.selection) { version in
                row(version).tag(version.id)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func row(_ version: FileVersions.Version) -> some View {
        HStack(spacing: 10) {
            Image(systemName: version.source == .localSnapshot ? "internaldrive" : "clock.arrow.circlepath")
                .foregroundStyle(version.isAvailable ? .secondary : .tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(version.date.formatted(date: .complete, time: .shortened))
                    .foregroundStyle(version.isAvailable ? .primary : .secondary)
                HStack(spacing: 6) {
                    Text(version.source.label)
                    if let size = version.size {
                        Text("\u{00B7}")
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    if let reason = version.unavailableReason {
                        Text("\u{00B7}"); Text(reason).foregroundStyle(.orange)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .opacity(version.isAvailable ? 1 : 0.6)
    }

    private var bottom: some View {
        HStack {
            Button {
                Task { await model.load() }
            } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(model.loading)
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Compare\u{2026}") { compare() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model.selected?.isAvailable != true)
            Button("Restore\u{2026}") { confirming = model.selected }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selected?.isAvailable != true)
        }
    }

    private func compare() {
        guard let version = model.selected, let old = version.url else { return }
        // The old version on the left, the file as it is now on the right --
        // before and after, read the way they are written. The version lives
        // in a read-only snapshot, so the comparison cannot change it.
        openWindow(id: DiptychApp.diffWindowID, value: DiffPair(left: old, right: request.file))
    }
}
