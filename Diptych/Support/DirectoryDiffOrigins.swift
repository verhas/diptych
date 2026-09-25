import Foundation

/// Which Diptych tab a Compare Folders window was opened from, so Cmd-G can
/// send the two files back to it instead of the window only ever being able
/// to say where they are.
///
/// Weak, and keyed by the pair rather than held by the window itself: the
/// window does not need to know it is being tracked, and a tab that closes in
/// the meantime is simply gone from here too, not left dangling.
@MainActor
final class DirectoryDiffOrigins {

    static let shared = DirectoryDiffOrigins()
    private init() {}

    private final class WeakBox {
        weak var model: AppModel?
        init(_ model: AppModel) { self.model = model }
    }

    private var origins: [DirectoryDiffPair: WeakBox] = [:]

    /// `model` is nil when there is nothing to remember -- opening a folder
    /// comparison from inside another one whose own origin has already gone --
    /// in which case this is a no-op rather than recording nothing useful.
    func register(_ pair: DirectoryDiffPair, from model: AppModel?) {
        guard let model else { return }
        origins[pair] = WeakBox(model)
    }

    func origin(for pair: DirectoryDiffPair) -> AppModel? {
        origins[pair]?.model
    }
}
