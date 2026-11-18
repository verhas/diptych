import Foundation
import MCP

/// The MCP side of Diptych's commands: how their answers (`DiptychData`) go
/// back to an agent, and settings values in the protocol's own `Value`.
enum MCPModels {

    struct SettingSummary: Codable, Sendable {
        var key: String
        var kind: String
        var description: String
        var allowedValues: [String]?
        var value: Value
    }

    struct SettingsList: Codable, Sendable {
        var settings: [SettingSummary]
    }

    static func value(_ setting: DiptychSettings.Value) -> Value {
        switch setting {
        case .bool(let on): .bool(on)
        case .string(let text): .string(text)
        }
    }

    /// A value an agent sent, as a setting takes it: a boolean, or text --
    /// which a boolean setting also accepts as "true" or "false", as some
    /// clients send them.
    static func setting(_ value: Value) -> DiptychSettings.Value? {
        if let on = value.boolValue { return .bool(on) }
        if let text = value.stringValue { return .string(text) }
        return nil
    }

    /// Wraps any of the DTOs above as a tool result: the same value both as
    /// `structuredContent`, for a client that reads it, and as pretty JSON
    /// text, for one that only renders `content`.
    static func result<T: Codable>(for value: T) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(data: try encoder.encode(value), encoding: .utf8) ?? "{}"
        return try CallTool.Result(content: [.text(text: json, annotations: nil, _meta: nil)],
                                    structuredContent: value)
    }
}
