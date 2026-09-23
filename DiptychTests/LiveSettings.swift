import XCTest
@testable import Diptych

/// Keeps the person's own `~/.diptych/config.json` intact across a test run.
///
/// The tests deliberately work against the real `ConfigStore`: that is how
/// they show that a setting actually reaches the code that reads it, rather
/// than that a stand-in object can hold a boolean. The price is that the file
/// they write is the production one -- the same file the application running
/// in the Dock reads -- so a test that switches version tracking on switches
/// it on for the person afterwards. That happened: a run left `gitEnabled`
/// changed, and the next day tests failed for a reason nothing in them said.
///
/// Putting the value back in `tearDown` is not enough by itself, for a reason
/// worth knowing: `ConfigStore` does not write on every change, it writes
/// 300 ms after the last one. A test process usually ends before that sleep
/// finishes, so the file keeps whatever was flushed in the middle of the run
/// while the restored value only ever existed in memory.
///
/// Hence both halves here. The file is copied byte for byte the first time any
/// test asks for protection, and put back at the end of the whole bundle --
/// and the in-memory configuration is put back with it, so that a debounced
/// save still waking up afterwards writes the restored settings and not the
/// test's.
@MainActor
enum LiveSettings {

    /// The file as the person left it. `nil` inside means there was no file at
    /// all, which has to be restored as "no file" rather than as defaults.
    private static var originalFile: Data??
    private static var originalConfiguration: Configuration?
    private static let watcher = RunWatcher()

    /// Call from `setUp` in every test class that changes a setting.
    ///
    /// Only the first call in the process does anything, so the snapshot is of
    /// the person's settings and not of what an earlier test left behind.
    static func protect() {
        guard originalConfiguration == nil else { return }
        originalFile = .some(try? Data(contentsOf: ConfigStore.url))
        originalConfiguration = ConfigStore.shared.configuration
        XCTestObservationCenter.shared.addTestObserver(watcher)
    }

    /// Put the settings back, in memory and on disk. Safe to call repeatedly;
    /// `tearDown` does, and so does the end of the bundle.
    static func putBack() {
        guard let originalConfiguration, let originalFile else { return }
        ConfigStore.shared.configuration = originalConfiguration
        if let data = originalFile {
            try? data.write(to: ConfigStore.url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: ConfigStore.url)
        }
    }
}

/// Restores the settings when the bundle finishes, for the test that changed
/// one and did not put it back -- including one that failed halfway through.
private final class RunWatcher: NSObject, XCTestObservation {
    func testBundleDidFinish(_ testBundle: Bundle) {
        // XCTest calls this on the main thread in practice but does not
        // promise it, and `ConfigStore` is `@MainActor`: reaching it from
        // anywhere else would be a crash rather than a wrong setting.
        if Thread.isMainThread {
            MainActor.assumeIsolated { LiveSettings.putBack() }
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated { LiveSettings.putBack() } }
        }
    }
}
