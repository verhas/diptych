import Foundation

/// Opens the Release Notes window once per launch, on whichever window
/// happens to be first to ask, and only when the bundled version is not the
/// one `ReleaseNotesSeen` last recorded.
@MainActor
final class ReleaseNotesPresenter {
    static let shared = ReleaseNotesPresenter()
    private var hasChecked = false
    private init() {}

    func presentIfNeeded(open: () -> Void) {
        guard !hasChecked else { return }
        hasChecked = true
        guard ReleaseNotesSeen.shouldShow else { return }
        open()
        ReleaseNotesSeen.markShown()
    }
}
