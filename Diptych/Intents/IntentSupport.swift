import AppIntents
import Foundation

/// What every intent goes through before it does anything: the switch in
/// Settings ▸ Agents, and the activity console.
///
/// The same rules as MCP. Off unless the person switched it on; every call
/// shown in the activity console, under "Siri/Shortcuts"; the switch itself
/// out of reach of what it lets in; files never changed from here, only
/// proposed for review in a window; nothing run, and no file read. MCP's
/// bearer token has no counterpart: macOS itself decides who may call an
/// app's intents -- the person, through Siri, Shortcuts or Spotlight.
@MainActor
enum IntentGate {

    static func admit(_ name: String, _ detail: String? = nil) throws {
        guard ConfigStore.shared.configuration.appIntentsEnabled else {
            MCPActivityLog.shared.record(.rejected, summary: "Siri/Shortcuts: \(name)",
                                         detail: "Switched off in Settings")
            throw DiptychIntentError.switchedOff
        }
        MCPActivityLog.shared.record(.call, summary: "Siri/Shortcuts: \(name)", detail: detail)
    }
}

enum DiptychIntentError: Error, CustomLocalizedStringResourceConvertible {
    case switchedOff
    case noWindow
    case noComparison(String)
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .switchedOff:
            "Siri and Shortcuts are switched off in Diptych. Turn them on in Settings, under Agents."
        case .noWindow:
            "No Diptych window is open."
        case .noComparison(let kind):
            "No \(kind) window is open in Diptych."
        case .failed(let message):
            "\(message)"
        }
    }
}

/// Which pane: the one with the keyboard, unless said.
enum PaneOption: String, AppEnum {
    case active, left, right

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Pane"
    static let caseDisplayRepresentations: [PaneOption: DisplayRepresentation] = [
        .active: "Active Pane",
        .left: "Left Pane",
        .right: "Right Pane",
    ]
}

/// Left or right, where "active" means nothing.
enum SideOption: String, AppEnum {
    case left, right

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Side"
    static let caseDisplayRepresentations: [SideOption: DisplayRepresentation] = [
        .left: "Left Pane",
        .right: "Right Pane",
    ]
}

enum PaneViewOption: String, AppEnum {
    case icons, placedIcons, list

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "View"
    static let caseDisplayRepresentations: [PaneViewOption: DisplayRepresentation] = [
        .icons: "Icons",
        .placedIcons: "Placed Icons",
        .list: "List",
    ]
}

/// Answers as text a shortcut can take apart: the same JSON an agent gets
/// over MCP, so a shortcut and an agent read the same fields.
enum IntentText {
    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A path as people read it: the home folder as ~.
    static func tilde(_ path: String) -> String { NamingTemplate.tilde(path) }

    /// The files of these entries that are on this Mac, as files a shortcut
    /// can pass on. A server's file is only an address here, not a file.
    static func files(_ entries: [DiptychData.FileEntry]) -> [IntentFile] {
        entries.filter { $0.path.hasPrefix("/") }.map {
            IntentFile(fileURL: URL(fileURLWithPath: $0.path), filename: $0.name)
        }
    }

    static func count(_ number: Int, _ one: String, _ many: String? = nil) -> String {
        "\(number) \(number == 1 ? one : (many ?? one + "s"))"
    }
}

extension IntentFile {
    /// The path of a file a shortcut handed over; nil for something that is
    /// not a file on this Mac.
    var localPath: String? { fileURL.flatMap { $0.isFileURL ? $0.path : nil } }
}
