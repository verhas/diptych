import AppIntents
import Foundation

/// The journal, for Shortcuts and Siri: searched and summed up, never
/// written to or emptied from here -- as over MCP.
enum JournalPeriodOption: String, AppEnum {
    case today, week, month, quarter, year, all

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Period"
    static let caseDisplayRepresentations: [JournalPeriodOption: DisplayRepresentation] = [
        .today: "Today",
        .week: "Last 7 Days",
        .month: "Last 30 Days",
        .quarter: "Last 90 Days",
        .year: "Last Year",
        .all: "Any Time",
    ]

    var start: Date? { JournalWindowModel.Period(rawValue: rawValue)?.start() }
}

struct SearchJournalIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Diptych Journal"
    static let description = IntentDescription("""
        What Diptych did to files -- copies, moves, renames, trashing, changes, on this Mac \
        and on servers -- and the programs it ran, newest first, as JSON. Words find the \
        description, the kind or any path touched. Read-only.
        """)

    @Parameter(title: "Words", default: "")
    var text: String

    @Parameter(title: "Period", default: .week)
    var period: JournalPeriodOption

    @Parameter(title: "Folder", supportedContentTypes: [.folder])
    var folder: IntentFile?

    @Parameter(title: "Include Files", default: false)
    var withFiles: Bool

    @Parameter(title: "At Most", default: 50, inclusiveRange: (1, 500))
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Search the Diptych journal for \(\.$text) in \(\.$period)") {
            \.$folder
            \.$withFiles
            \.$limit
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try IntentGate.admit("Search Journal", text.isEmpty ? period.rawValue : "\(text), \(period.rawValue)")
        let found = DiptychCommands.searchJournal(
            text: text, from: period.start, to: nil, kind: nil, origin: nil,
            folder: folder?.localPath, limit: limit, withFiles: withFiles)
        guard found.journalEnabled || !found.entries.isEmpty else {
            return .result(value: IntentText.json(found),
                           dialog: "Diptych's journal is switched off in its Settings.")
        }
        guard let newest = found.entries.first else {
            return .result(value: IntentText.json(found), dialog: "Nothing in the journal matches.")
        }
        let said = "\(IntentText.count(found.entries.count, "entry", "entries"))"
            + (found.truncated ? " or more" : "") + ". The newest: \(newest.told)"
        return .result(value: IntentText.json(found), dialog: "\(said)")
    }
}

struct GetJournalStatsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Diptych Journal Statistics"
    static let description = IntentDescription("""
        What Diptych's journal adds up to over a period: entries and files touched, by \
        kind, by who did it, per day, and the busiest folders. As JSON.
        """)

    @Parameter(title: "Period", default: .week)
    var period: JournalPeriodOption

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try IntentGate.admit("Journal Statistics", period.rawValue)
        let stats = DiptychCommands.journalStats(from: period.start, to: nil)
        let top = stats.byKind.prefix(3).map { "\($0.name) \($0.entries)" }.joined(separator: ", ")
        let said = "\(IntentText.count(stats.entries, "entry", "entries")), "
            + "\(IntentText.count(stats.files, "file")) touched"
            + (top.isEmpty ? "." : ": \(top).")
        return .result(value: IntentText.json(stats), dialog: "\(said)")
    }
}

struct OpenJournalIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Diptych Journal"
    static let description = IntentDescription("""
        Opens Diptych's Journal window, searching for the words given.
        """)
    static let openAppWhenRun = true

    @Parameter(title: "Words", default: "")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult {
        try IntentGate.admit("Open Journal", text.isEmpty ? nil : text)
        JournalWindowModel.open(searching: text)
        return .result()
    }
}
