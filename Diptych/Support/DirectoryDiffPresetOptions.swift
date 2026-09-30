import Foundation

/// Comparison options an `open_diff` MCP call asked a not-yet-created
/// Compare Folders window to start with, consulted once by
/// `DirectoryDiffModel.init` and then discarded -- reopening the same pair
/// normally afterwards goes back to the application's own defaults, exactly
/// as if this had never been asked. Keyed by pair, the same pattern
/// `DirectoryDiffOrigins` already uses for a different one-shot handoff into
/// a window that doesn't exist yet at the moment the request is made.
@MainActor
final class DirectoryDiffPresetOptions {

    static let shared = DirectoryDiffPresetOptions()
    private init() {}

    private var pending: [DirectoryDiffPair: DirectoryComparison.Options] = [:]

    func set(_ options: DirectoryComparison.Options, for pair: DirectoryDiffPair) {
        pending[pair] = options
    }

    /// Consumes (removes) the preset for this pair, if any was set.
    func take(for pair: DirectoryDiffPair) -> DirectoryComparison.Options? {
        pending.removeValue(forKey: pair)
    }
}
