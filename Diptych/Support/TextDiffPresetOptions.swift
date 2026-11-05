import Foundation

/// Display options an `open_diff` MCP call asked a not-yet-created Compare
/// (text diff) window to start with, consulted once by `DiffDocument.init`
/// and then discarded. Same one-shot-handoff pattern as
/// `DirectoryDiffPresetOptions`, for the same reason: the window this needs
/// to reach doesn't exist yet at the moment the request is made.
@MainActor
final class TextDiffPresetOptions {

    static let shared = TextDiffPresetOptions()
    private init() {}

    struct Preset {
        var ignoreWhitespace: Bool
        var wraps: Bool
        /// The side unlocked once the two are read, ready to edit and save.
        var unlocked: DiffDocument.Side? = nil
        /// What the window says above the comparison, about why it is open.
        var note: String? = nil
    }

    private var pending: [DiffPair: Preset] = [:]

    func set(_ preset: Preset, for pair: DiffPair) {
        pending[pair] = preset
    }

    func take(for pair: DiffPair) -> Preset? {
        pending.removeValue(forKey: pair)
    }
}
