import Foundation

/// Shows the "Did You Know?" dialog once per launch, on whichever window
/// happens to be first to ask -- not once per window or per tab opened
/// afterward, and not at all once the setting to skip it is off.
@MainActor
final class StartupTips {
    static let shared = StartupTips()
    private var hasShown = false
    private init() {}

    func presentIfNeeded(on model: AppModel) {
        guard !hasShown, ConfigStore.shared.configuration.showTipsAtStartup,
              // Something else -- the update-check consent prompt, on the same
              // launch -- may already have claimed the one sheet a window can
              // show at a time. Tips are the lower priority of the two.
              model.dialog == nil
        else { return }
        hasShown = true
        model.dialog = .tips
    }
}
