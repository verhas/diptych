import SwiftUI
import AppKit

/// Archive ▸ Create Archive…: everything selected, listed, and what kind of
/// archive to make of it. The options are each format's own.
struct CreateArchiveView: View {

    let request: ArchiveRequest

    @State private var model: ArchiveWindowModel
    @Environment(\.dismiss) private var dismiss

    init(request: ArchiveRequest) {
        self.request = request
        _model = State(initialValue: ArchiveWindowModel(request))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            list
            Divider()
            settings
                .padding(16)
            Divider()
            bottom
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 560, minHeight: 520)
        .navigationTitle("Create Archive \u{2014} \(NamingTemplate.tilde(request.folder.path))")
        .onChange(of: model.made) { _, made in
            if made != nil { dismiss() }
        }
        .background(WindowAccessor { window in
            if let window {
                AppWindows.shared.register(window)
                WindowSubjects.shared.register(window, kind: "createArchive",
                                               description: request.folder.path)
            }
        })
    }

    // MARK: - What goes in

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.items.count == 1 ? "1 item" : "\(model.items.count) items")
                .font(.headline)
                + Text(model.totalSize > 0
                       ? "  \(ByteCountFormatter.string(fromByteCount: model.totalSize, countStyle: .file)) in files, folders not counted"
                       : "")
                .font(.subheadline).foregroundColor(.secondary)
            List(model.items) { item in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(item.url.lastPathComponent)
                        .lineLimit(1).truncationMode(.middle)
                    if model.fromSeveralFolders {
                        Text(NamingTemplate.tilde(item.url.deletingLastPathComponent().path))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                    Spacer()
                    Text(item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                         ?? "folder")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .listStyle(.bordered)
        }
        .padding(16)
    }

    // MARK: - How

    private var settings: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Text("Format")
                Picker("", selection: $model.options.format) {
                    ForEach(Archiving.Format.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
            }
            switch model.options.format {
            case .zip:          zipOptions
            case .tar:          tarOptions
            case .appleArchive: appleArchiveOptions
            }
            GridRow {
                Text("Name")
                HStack(spacing: 4) {
                    TextField("Archive", text: $model.stem)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                    Text("." + model.options.fileExtension)
                        .foregroundStyle(.secondary)
                }
            }
            GridRow {
                Text("Into")
                Picker("", selection: $model.intoOtherPane) {
                    Text(model.fromSeveralFolders
                         ? "This pane: \(request.folder.lastPathComponent)"
                         : "Next to the items: \(request.folder.lastPathComponent)").tag(false)
                    if let other = request.otherFolder {
                        Text("The other pane: \(other.lastPathComponent)").tag(true)
                    }
                }
                .labelsHidden()
                .frame(width: 300)
            }
        }
        .disabled(model.isRunning)
    }

    @ViewBuilder
    private var zipOptions: some View {
        GridRow {
            Text("Mac data")
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Keep it in a __MACOSX folder, as Finder does",
                       isOn: $model.options.zipMacMetadata)
                    .toggleStyle(.checkbox)
                Text(model.options.zipMacMetadata
                     ? "Extended attributes, tags, resource forks and ACLs come back when the "
                       + "archive is opened on a Mac. Elsewhere the folder shows up as clutter."
                     : "The bytes and the permissions only: tidy anywhere, but tags and other "
                       + "attributes are left out.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        GridRow {
            Text("Compression")
            Picker("", selection: $model.options.zipCompression) {
                ForEach(Archiving.ZipCompression.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 180)
        }
        GridRow {
            Text("")
            Text("A zip always records each item\u{2019}s owner and group as numbers.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var tarOptions: some View {
        GridRow {
            Text("Compression")
            Picker("", selection: $model.options.tarCompression) {
                ForEach(Archiving.TarCompression.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 180)
        }
        GridRow {
            Text("Mac data")
            Toggle("Extended attributes, ACLs and file flags", isOn: $model.options.tarMacMetadata)
                .toggleStyle(.checkbox)
        }
        GridRow {
            Text("Owners")
            Picker("", selection: $model.options.tarOwners) {
                ForEach(Archiving.TarOwners.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 260)
        }
    }

    @ViewBuilder
    private var appleArchiveOptions: some View {
        GridRow {
            Text("Compression")
            Picker("", selection: $model.options.aarCompression) {
                ForEach(Archiving.AppleArchiveCompression.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 260)
        }
        GridRow {
            Text("Keep")
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Owners and groups", isOn: $model.options.aarOwners)
                Toggle("Extended attributes", isOn: $model.options.aarExtendedAttributes)
                Toggle("Access control lists", isOn: $model.options.aarAccessControl)
            }
            .toggleStyle(.checkbox)
        }
        GridRow {
            Text("")
            Text("Opened by Archive Utility, or by aa on the command line. Not readable on "
                 + "Windows or Linux.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Below

    /// The bar, how much of how much, the time left, and the file the tool
    /// is on.
    private var running: some View {
        let progress = model.progress
        return VStack(alignment: .leading, spacing: 3) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack(spacing: 6) {
                Text(status(progress))
                    .monospacedDigit()
                if let left = model.timeLeft {
                    Text("\u{00B7} \(left)").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            Text(progress.current.map { "\u{201C}\($0)\u{201D}" } ?? " ")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func status(_ progress: Archiving.Job.Snapshot) -> String {
        let bytes = { (count: Int64) in ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
        let files = { (count: Int) in count.formatted() }
        switch progress.phase {
        case .counting:
            return "Counting what goes in\u{2026} \(files(progress.totalFiles)) files, "
                + bytes(progress.totalBytes)
        case .preparing:
            return "Putting the items together\u{2026}"
        case .finishing:
            return "Finishing \u{201C}\(model.target.lastPathComponent)\u{201D}\u{2026}"
        case .archiving:
            let amount = "\(bytes(progress.bytes)) of \(bytes(progress.totalBytes))"
            guard progress.countsFiles else { return amount }
            return amount + " \u{00B7} \(files(progress.files)) of \(files(progress.totalFiles)) files"
        }
    }

    private var bottom: some View {
        HStack(spacing: 10) {
            if model.isRunning {
                running
            } else if let problem = model.problem {
                Text(problem)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            } else {
                Text("\u{201C}\(model.target.lastPathComponent)\u{201D} in "
                     + NamingTemplate.tilde(model.folder.path))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if model.isRunning {
                Button("Stop") { model.stop() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { model.create() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
