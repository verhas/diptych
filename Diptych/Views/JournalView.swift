import AppKit
import Charts
import SwiftUI

/// Window ▸ Journal: what Diptych did, searchable, newest first. A row opens
/// up to the files it touched, each with where it was and where it went --
/// shown in a pane, never undone from here: weeks later the files have moved on.
struct JournalView: View {

    @State private var model = JournalWindowModel()
    @State private var showingStats = false

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                filters
                Divider()
                if showingStats {
                    JournalStatsView(stats: model.stats)
                } else {
                    entries
                }
            }
            .frame(minHeight: 220)
            if !showingStats {
                details
                    .frame(minHeight: 140, idealHeight: 200)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear {
            model.takePendingSearch()
            model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: JournalWindowModel.searchRequest)) { _ in
            model.takePendingSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: Journal.didChange)) { _ in
            model.refresh()
        }
        .onChange(of: model.query) { _, _ in model.refresh() }
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $showingStats) {
                    Label("Entries", systemImage: "list.bullet").tag(false)
                    Label("Statistics", systemImage: "chart.bar").tag(true)
                }
                .pickerStyle(.segmented)
                .help("The entries, or what they add up to")
            }
        }
        .searchable(text: $model.query.text, placement: .toolbar,
                    prompt: "Words, names or paths")
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Picker("When", selection: $model.period) {
                ForEach(JournalWindowModel.Period.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Picker("Of", selection: $model.category) {
                Text("Every Sort").tag(Journal.Category?.none)
                Divider()
                ForEach(Journal.Category.allCases, id: \.self) {
                    Text($0.title).tag(Journal.Category?.some($0))
                }
            }
            .fixedSize()
            Picker("What", selection: $model.kind) {
                Text("Everything").tag(String?.none)
                Divider()
                ForEach(model.kinds, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .fixedSize()
            Picker("Who", selection: $model.origin) {
                Text("Anyone").tag(Journal.Origin?.none)
                Divider()
                ForEach(Journal.Origin.allCases, id: \.self) {
                    Text($0.title).tag(Journal.Origin?.some($0))
                }
            }
            .fixedSize()
            Spacer()
            Text(model.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var entries: some View {
        if model.entries.isEmpty {
            ContentUnavailableView {
                Label(model.hasAnything ? "Nothing Found" : "Nothing Recorded Yet",
                      systemImage: "book.closed")
            } description: {
                Text(ConfigStore.shared.configuration.journalEnabled
                     ? (model.hasAnything
                        ? "Nothing in the journal matches. Any Time, Every Sort and Everything show it all."
                        : "Nothing has been recorded yet. Copies, moves, renames, runs and the "
                          + "rest are kept here from now on, as they happen.")
                     : "The journal is switched off in Settings \u{25B8} Behaviour.")
            }
        } else {
            Table(model.entries, selection: $model.selectedID) {
                TableColumn("When") { entry in
                    Text(entry.time, format: .dateTime.year().month().day().hour().minute())
                        .monospacedDigit()
                }
                .width(min: 110, ideal: 130, max: 160)
                TableColumn("What") { entry in
                    HStack(spacing: 4) {
                        if entry.outcome != "done" {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(entry.outcome == "failed" ? .red : .orange)
                                .help(entry.outcome == "failed" ? "It failed" : "Only partly done")
                        }
                        Text(entry.kind)
                    }
                }
                .width(min: 80, ideal: 120, max: 180)
                TableColumn("Of") { entry in Text(entry.category.title).foregroundStyle(.secondary) }
                    .width(min: 60, ideal: 110, max: 180)
                TableColumn("Who") { entry in Text(entry.origin.title).foregroundStyle(.secondary) }
                    .width(min: 50, ideal: 80, max: 120)
                TableColumn("Done") { entry in Text(entry.told).lineLimit(2).help(entry.told) }
            }
            .contextMenu(forSelectionType: Journal.Entry.ID.self) { ids in
                if let id = ids.first, let entry = model.entries.first(where: { $0.id == id }) {
                    Button("Copy") { JournalWindowModel.copy(entry.line) }
                }
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        if let entry = model.selected {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(entry.told)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Copy") { JournalWindowModel.copy(entry.line) }
                        }
                    Button("Copy") { JournalWindowModel.copy(entry.line) }
                        .controlSize(.small)
                        .help("Copy the whole entry as a line of text")
                }
                if let folder = entry.folder {
                    HStack {
                        Text(NamingTemplate.tilde(folder))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("Show Folder") { JournalWindowModel.show(folder) }
                            .controlSize(.small)
                            .disabled(!JournalWindowModel.canShow(folder))
                    }
                }
                List(Array(model.files.enumerated()), id: \.offset) { _, file in
                    JournalFileRow(file: file)
                }
                .listStyle(.inset)
            }
            .padding(10)
        } else {
            Text("Select an entry to see the files it touched.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct JournalFileRow: View {
    let file: Journal.File

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                if let before = file.before, before != file.after {
                    Text(NamingTemplate.tilde(before)).font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if let after = file.after {
                        Text("\u{2192} " + NamingTemplate.tilde(after)).font(.caption.monospaced())
                    } else {
                        Text("\u{2192} gone").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(NamingTemplate.tilde(file.path)).font(.caption.monospaced())
                }
            }
            .textSelection(.enabled)
            Spacer()
            if let before = file.before, before != file.after {
                Button("Where It Was") { JournalWindowModel.show(before) }
                    .controlSize(.small)
                    .disabled(!JournalWindowModel.canShow(before))
            }
            if let after = file.after {
                Button(file.before == nil || file.before == after ? "Show" : "Where It Is") {
                    JournalWindowModel.show(after)
                }
                .controlSize(.small)
                .disabled(!JournalWindowModel.canShow(after))
            }
        }
    }
}

/// What the entries add up to over the period chosen.
private struct JournalStatsView: View {
    let stats: Journal.Stats

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 28) {
                    figure("\(stats.entries)", "entries")
                    figure("\(stats.files)", "files touched")
                    if let first = stats.first {
                        figure(first.formatted(date: .abbreviated, time: .omitted), "since")
                    }
                }
                if stats.byDay.count > 1 {
                    Text("Per day").font(.headline)
                    Chart(stats.byDay, id: \.name) { day in
                        BarMark(x: .value("Day", day.name), y: .value("Entries", day.entries))
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 8))
                    }
                    .frame(height: 140)
                }
                HStack(alignment: .top, spacing: 32) {
                    table("Of", stats.byCategory.map {
                        .init(name: Journal.Category(rawValue: $0.name)?.title ?? $0.name,
                              entries: $0.entries, files: $0.files)
                    })
                    table("What", stats.byKind)
                    table("Who", stats.byOrigin.map {
                        .init(name: Journal.Origin(rawValue: $0.name)?.title ?? $0.name,
                              entries: $0.entries, files: $0.files)
                    })
                }
                table("Busiest folders", stats.folders.map {
                    .init(name: NamingTemplate.tilde($0.name), entries: $0.entries, files: $0.files)
                })
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.title2.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func table(_ title: String, _ counts: [Journal.Stats.Count]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("entries").font(.caption).foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text("files").font(.caption).foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                }
                ForEach(counts, id: \.name) { count in
                    GridRow {
                        Text(count.name).lineLimit(1).truncationMode(.middle)
                        Text("\(count.entries)").monospacedDigit()
                        Text("\(count.files)").monospacedDigit()
                    }
                }
            }
        }
    }
}

@MainActor
@Observable
final class JournalWindowModel {

    enum Period: String, CaseIterable, Identifiable {
        case today, week, month, quarter, year, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .today: "Today"
            case .week: "Last 7 Days"
            case .month: "Last 30 Days"
            case .quarter: "Last 90 Days"
            case .year: "Last Year"
            case .all: "Any Time"
            }
        }

        func start(now: Date = Date()) -> Date? {
            let calendar = Calendar.current
            switch self {
            case .today: return calendar.startOfDay(for: now)
            case .week: return calendar.date(byAdding: .day, value: -7, to: now)
            case .month: return calendar.date(byAdding: .day, value: -30, to: now)
            case .quarter: return calendar.date(byAdding: .day, value: -90, to: now)
            case .year: return calendar.date(byAdding: .year, value: -1, to: now)
            case .all: return nil
            }
        }
    }

    var query = Journal.Query()
    var period: Period = .month { didSet { query.from = period.start() } }
    var kind: String? { didSet { query.kinds = kind.map { [$0] } ?? [] } }
    var category: Journal.Category? { didSet { query.categories = category.map { [$0] } ?? [] } }
    var origin: Journal.Origin? { didSet { query.origins = origin.map { [$0] } ?? [] } }

    private(set) var entries: [Journal.Entry] = []
    private(set) var kinds: [String] = []
    private(set) var stats = Journal.Stats()
    private(set) var files: [Journal.File] = []
    var selectedID: Journal.Entry.ID? { didSet { loadFiles() } }

    init() {
        query.from = period.start()
        query.limit = 1000
    }

    var selected: Journal.Entry? { entries.first { $0.id == selectedID } }

    /// The journal holds something, whatever the filters let through.
    private(set) var hasAnything = false

    var summary: String {
        entries.isEmpty ? ""
            : entries.count == query.limit ? "the newest \(entries.count)"
            : "\(entries.count) entr\(entries.count == 1 ? "y" : "ies")"
    }

    func refresh() {
        entries = Journal.shared.search(query)
        kinds = Journal.shared.kinds()
        stats = Journal.shared.stats(from: query.from)
        hasAnything = !entries.isEmpty || Journal.shared.stats().entries > 0
        if selected == nil { selectedID = nil } else { loadFiles() }
    }

    private func loadFiles() {
        files = selectedID.map { Journal.shared.files(of: $0) } ?? []
    }

    /// Set by the first window, which has SwiftUI's `openWindow`.
    static var openWindow: (() -> Void)?
    /// Words the window is to search for when it next appears or is
    /// already open: from Spotlight, Shortcuts.
    static let searchRequest = Notification.Name("DiptychJournalSearchRequest")
    static var pendingSearch: String?

    static func open(searching text: String = "") {
        pendingSearch = text
        openWindow?()
        NSApp.activate()
        NotificationCenter.default.post(name: searchRequest, object: nil)
    }

    /// An entry the window is to show selected: from Spotlight.
    static var pendingEntry: Int64?

    static func open(entry id: Int64) {
        pendingEntry = id
        open(searching: "")
    }

    func takePendingSearch() {
        guard let text = Self.pendingSearch else { return }
        Self.pendingSearch = nil
        query.text = text
        kind = nil
        category = nil
        origin = nil
        period = .all
        refresh()
        if let id = Self.pendingEntry {
            Self.pendingEntry = nil
            selectedID = id
        }
    }

    /// A local path that is still there; a server's is not shown from here.
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func canShow(_ path: String) -> Bool {
        path.hasPrefix("/") && FileManager.default.fileExists(atPath: path)
    }

    static func show(_ path: String) {
        guard canShow(path) else { return }
        FileViewer.shared.reveal([URL(fileURLWithPath: path)])
    }
}

extension Journal.Entry {
    /// The entry as one line of text, its columns apart by tabs -- as the
    /// table shows it, so it pastes into a message or a spreadsheet alike.
    var line: String {
        let when = time.formatted(.dateTime.year().month().day().hour().minute())
        let what = outcome == "done" ? kind : "\(kind) (\(outcome))"
        return [when, what, category.title, origin.title, told].joined(separator: "\t")
    }
}
