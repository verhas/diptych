import Foundation
import Observation

/// A short, in-memory record of MCP requests, for the status indicator's
/// console window. Not persisted -- restarting the server (or the app)
/// starts a clean log, which is the right default for something whose only
/// job is "what has an agent been asking, since I last looked."
@MainActor
@Observable
final class MCPActivityLog {

    static let shared = MCPActivityLog()
    private init() {}

    enum Kind: Sendable { case call, rejected, error }

    struct Entry: Identifiable, Sendable {
        let id = UUID()
        var date: Date
        var kind: Kind
        /// What happened, in one line: the tool name for a call, "Unauthorized"
        /// for a rejected request.
        var summary: String
        /// Arguments or an error message, kept short -- this is a glance-at
        /// console, not a request/response inspector.
        var detail: String?
    }

    private(set) var entries: [Entry] = []
    private static let capacity = 300

    /// Bumped on every entry, so the status indicator can notice new
    /// activity with a simple `onChange` rather than diffing the whole log.
    private(set) var activityToken = 0

    func record(_ kind: Kind, summary: String, detail: String? = nil) {
        entries.append(Entry(date: Date(), kind: kind, summary: summary, detail: detail))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        activityToken += 1
    }

    func clear() {
        entries.removeAll()
    }
}
