import SwiftUI
import AppKit

/// What each of the Tools windows shares: its title, its registration, and
/// forgetting its job once it closes. No Cancel button: the close button and
/// Command-W close it.
private struct ToolWindowFrame: ViewModifier {
    let jobId: UUID
    let title: String
    let kind: String

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor { window in
                if let window {
                    window.title = title
                    AppWindows.shared.register(window)
                    WindowSubjects.shared.register(window, kind: kind, description: title)
                }
            })
            .onDisappear { ToolWindows.shared.clear(jobId) }
    }
}

private extension View {
    func toolWindow(_ jobId: UUID, title: String, kind: String) -> some View {
        modifier(ToolWindowFrame(jobId: jobId, title: title, kind: kind))
    }
}

/// The files a window will work on, one per line, scrolling when there are many.
private struct FileNames: View {
    let urls: [URL]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(urls, id: \.self) { url in
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(url.path)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(minHeight: 40, maxHeight: 160)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
    }
}

// MARK: - Create Checksums

/// Tools ▸ Checksum ▸ Create…: which kinds, for the files listed.
struct ChecksumCreateView: View {

    let jobId: UUID

    @Environment(\.dismiss) private var dismiss
    @AppStorage("checksumCreateKinds") private var remembered = "sha256"
    @State private var chosen: Set<Checksums.Algorithm> = []
    @State private var checksumFiles: [URL] = []

    private var job: ToolWindows.Job? { ToolWindows.shared.job(for: jobId) }
    private var files: [URL] { job?.files ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(files.count == 1 ? "Create a checksum file of" : "Create checksum files of \(files.count) files")
                .font(.headline)
            FileNames(urls: files)
            if !checksumFiles.isEmpty {
                Text(warning)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 16) {
                ForEach(Checksums.Algorithm.allCases) { kind in
                    Toggle(kind.label, isOn: Binding(
                        get: { chosen.contains(kind) },
                        set: { if $0 { chosen.insert(kind) } else { chosen.remove(kind) } }))
                }
            }
            HStack {
                Spacer()
                Button("Do") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || job?.model == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .toolWindow(jobId, title: "Create Checksums", kind: "createChecksums")
        .task {
            chosen = Set(remembered.split(separator: ",").compactMap {
                Checksums.Algorithm(rawValue: String($0))
            })
            let targets = files
            let pending = Set(targets.filter { RemoteBrowsing.hasPending([$0]) })
            checksumFiles = await BlockingWork.run {
                AppModel.checksumFiles(among: targets, pending: pending)
            }
        }
    }

    private var warning: String {
        let names = checksumFiles.prefix(3).map { "\u{201C}\($0.lastPathComponent)\u{201D}" }
            .joined(separator: ", ") + (checksumFiles.count > 3 ? " and \(checksumFiles.count - 3) more" : "")
        return (checksumFiles.count == 1 ? "\(names) is itself a checksum file. "
                                         : "\(names) are themselves checksum files. ")
            + "This would make a checksum of the checksum, which is probably not what you wanted."
    }

    private func run() {
        let kinds = Checksums.Algorithm.allCases.filter(chosen.contains)
        remembered = kinds.map(\.rawValue).joined(separator: ",")
        job?.model?.createChecksums(kinds, of: files)
        dismiss()
    }
}

// MARK: - Convert Line Endings

struct LineEndingsView: View {

    let jobId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var model: LineEndingsModel

    init(jobId: UUID) {
        self.jobId = jobId
        _model = State(initialValue: LineEndingsModel(
            jobId: jobId, files: ToolWindows.shared.job(for: jobId)?.files ?? []))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Convert the line endings of these files in place")
                .font(.headline)
            table
            HStack(alignment: .top, spacing: 24) {
                Picker("Make them", selection: $model.target) {
                    ForEach(LineEnding.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Last line has a line ending after it", isOn: $model.finalEnding)
                    Text(model.target.separates
                         ? "\(model.target.short) separates lines: usually there is none after the last."
                         : "Most tools expect one after the last line too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.failures.isEmpty {
                Text(model.failures.joined(separator: "\n")).foregroundStyle(.red)
            }
            HStack {
                Text(summary).foregroundStyle(.secondary)
                Spacer()
                Button("Convert") { Task { await model.convert() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.convertible == 0 || model.working)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 440)
        .toolWindow(jobId, title: "Convert Line Endings", kind: "lineEndings")
        .task { await model.load() }
        .onChange(of: model.finished) { _, done in if done { dismiss() } }
    }

    private var summary: String {
        guard model.loaded else { return "Reading\u{2026}" }
        let count = model.convertible
        return count == 0 ? "Nothing to change" : "\(count) file\(count == 1 ? "" : "s") will change"
    }

    private var table: some View {
        Table(model.rows) {
            TableColumn("File") { row in
                Text(row.name).lineLimit(1).truncationMode(.middle).help(row.url.path)
            }
            TableColumn("Line endings") { row in
                if let report = row.report {
                    Text(report.description)
                        .foregroundStyle(report.isMixed ? Color.orange : Color.primary)
                } else {
                    Text(row.problem ?? "\u{2026}").foregroundStyle(.red)
                }
            }
            .width(min: 120, ideal: 160)
            TableColumn("Last line") { row in
                if let report = row.report, !report.isEmpty {
                    Text(report.endsWithOne ? "ended" : "not ended")
                        .foregroundStyle(report.finalIsUnusual ? Color.orange : Color.secondary)
                        .help(report.finalIsUnusual
                              ? (report.endsWithOne ? "A file of LS or PS usually has none after its last line."
                                                    : "The last line has no line ending after it.")
                              : "")
                }
            }
            .width(min: 70, ideal: 80)
            TableColumn("Encoding") { row in
                if let reading = row.reading {
                    Text(TextEncodings.name(of: reading.encoding)).foregroundStyle(.secondary)
                }
            }
            .width(min: 80, ideal: 110)
            TableColumn("") { row in
                switch model.plan(for: row) {
                case .write: Text("will change")
                case .unchanged: Text("already so").foregroundStyle(.secondary)
                case .refused(let reason): Text(reason).foregroundStyle(.red).help(reason)
                }
            }
            .width(min: 90, ideal: 160)
        }
        .frame(minHeight: 160)
    }
}

// MARK: - Convert Character Encoding

struct EncodingsView: View {

    let jobId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var model: EncodingsModel

    init(jobId: UUID) {
        self.jobId = jobId
        _model = State(initialValue: EncodingsModel(
            jobId: jobId, files: ToolWindows.shared.job(for: jobId)?.files ?? []))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Convert the character encoding of these files in place")
                .font(.headline)
            HStack {
                Text("Read all as")
                Picker("Read all as", selection: Binding(
                    get: { model.commonPerceived?.rawValue ?? 0 },
                    set: { if $0 != 0 { model.setPerceivedForAll(String.Encoding(rawValue: $0)) } })) {
                    if model.commonPerceived == nil { Text("Various").tag(UInt(0)) }
                    encodingChoices
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                Text("Check the sample text: the guess can be a near neighbour, as Latin 1 for Latin 2.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            table
            HStack(spacing: 16) {
                Text("Write them in")
                Picker("Write them in", selection: Binding(
                    get: { model.target.rawValue },
                    set: { model.target = String.Encoding(rawValue: $0) })) {
                    encodingChoices
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                if model.targetIsUnicode {
                    Toggle("Byte-order mark (BOM) at the start", isOn: $model.bom)
                }
            }
            if !model.failures.isEmpty {
                Text(model.failures.joined(separator: "\n")).foregroundStyle(.red)
            }
            HStack {
                Text(summary).foregroundStyle(.secondary)
                Spacer()
                Button("Convert") { Task { await model.convert() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.convertible == 0 || model.working)
            }
        }
        .padding(20)
        .frame(minWidth: 780, minHeight: 440)
        .toolWindow(jobId, title: "Convert Character Encoding", kind: "encodings")
        .task { await model.load() }
        .onChange(of: model.finished) { _, done in if done { dismiss() } }
    }

    @ViewBuilder
    private var encodingChoices: some View {
        Section("Unicode") {
            ForEach(TextEncodings.unicode, id: \.rawValue) {
                Text(TextEncodings.name(of: $0)).tag($0.rawValue)
            }
        }
        Section("Other") {
            ForEach(TextEncodings.singleAndMultiByte, id: \.rawValue) {
                Text(TextEncodings.name(of: $0)).tag($0.rawValue)
            }
        }
    }

    private var summary: String {
        guard model.loaded else { return "Reading\u{2026}" }
        let count = model.convertible
        return count == 0 ? "Nothing to change" : "\(count) file\(count == 1 ? "" : "s") will change"
    }

    private var table: some View {
        Table(model.rows) {
            TableColumn("File") { row in
                Text(row.name).lineLimit(1).truncationMode(.middle).help(row.url.path)
            }
            .width(min: 120, ideal: 180)
            TableColumn("Read as") { row in
                if row.data != nil {
                    Picker("Read as", selection: Binding(
                        get: { row.perceived.rawValue },
                        set: { model.setPerceived(String.Encoding(rawValue: $0), of: row.id) })) {
                        encodingChoices
                        // One the file was found in that is not in the list.
                        if !TextEncodings.offered.contains(row.perceived) {
                            Text(TextEncodings.name(of: row.perceived)).tag(row.perceived.rawValue)
                        }
                    }
                    .labelsHidden()
                    .help(detectedHelp(row))
                } else {
                    Text(row.problem ?? "\u{2026}").foregroundStyle(.red)
                }
            }
            .width(min: 150, ideal: 190)
            TableColumn("Sample") { row in
                Text(row.text == nil && row.data != nil ? "\u{2014}" : row.sample)
                    .lineLimit(1)
                    .help(row.sample)
            }
            .width(min: 160, ideal: 260)
            TableColumn("") { row in
                switch model.plan(for: row) {
                case .write: Text("will change")
                case .unchanged: Text("already so").foregroundStyle(.secondary)
                case .refused(let reason): Text(reason).foregroundStyle(.red).help(reason)
                }
            }
            .width(min: 90, ideal: 170)
        }
        .frame(minHeight: 180)
    }

    private func detectedHelp(_ row: EncodingsModel.Row) -> String {
        guard let detected = row.detected else { return "" }
        let name = TextEncodings.name(of: detected.encoding)
        if detected.hasBOM { return "Its byte-order mark says \(name)." }
        return detected.guessed ? "Guessed: \(name)." : "Found to be \(name)."
    }
}

// MARK: - Install from a disk image

struct InstallAppView: View {

    let jobId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var choices = AppInstalling.Choices()
    @State private var working = false
    @State private var problem: String?
    @State private var newVersion: String?
    @State private var oldVersion: String?
    @State private var installed = false

    private var job: ToolWindows.Job? { ToolWindows.shared.job(for: jobId) }

    var body: some View {
        if let offer = job?.offer {
            content(offer)
        } else {
            Text("The disk image is no longer there.").padding(20)
        }
    }

    private func content(_ offer: AppInstalling.Offer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: offer.app.path))
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Install \u{201C}\(offer.name)\u{201D}\(newVersion.map { " \($0)" } ?? "") in Applications?")
                        .font(.headline)
                    Text("\u{201C}\(offer.image.lastPathComponent)\u{201D} holds this application and a "
                         + "link to Applications: it is meant to be installed by copying it there.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if installed {
                        Text("Version \(oldVersion ?? "unknown") is installed already. Installing moves it to the Trash.")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Open it without the \u{201C}downloaded from the Internet\u{201D} question",
                       isOn: $choices.approveQuarantine)
                Text("Marks it as approved, as answering the question once does. Where it was "
                     + "downloaded from stays recorded, and macOS still checks its signature.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
                Toggle("Unmount the disk image afterwards", isOn: $choices.unmount)
                Toggle("Move \u{201C}\(offer.image.lastPathComponent)\u{201D} to the Trash afterwards",
                       isOn: $choices.trashImage)
            }
            if let problem {
                Text(problem).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Copying into Applications asks for an administrator\u{2019}s password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Do NOT Install") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Install") { install(offer) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || job?.model == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .toolWindow(jobId, title: "Install \(offer.name)", kind: "installApp")
        .task {
            newVersion = AppInstalling.version(of: offer.app)
            installed = FileManager.default.fileExists(atPath: offer.destination.path)
            oldVersion = installed ? AppInstalling.version(of: offer.destination) : nil
        }
    }

    private func install(_ offer: AppInstalling.Offer) {
        guard let model = job?.model else { return }
        working = true
        problem = nil
        Task {
            let failure = await model.install(offer, choices: choices)
            working = false
            if let failure { problem = failure } else { dismiss() }
        }
    }
}
