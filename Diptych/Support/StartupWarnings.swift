import AppKit

/// Files of the user's that Diptych cannot use, said as it starts -- and,
/// for saved expressions, whenever another such file turns up.
@MainActor
enum StartupWarnings {

    static func start() {
        // ~/.diptych/exif written or merged, and read, away from the main
        // thread: the towns are thirty thousand.
        Task.detached(priority: .utility) {
            let problems = ExifDatabase.shared.problems
            _ = Places.shared
            guard !problems.isEmpty else { return }
            await MainActor.run { show(databaseProblems: problems) }
        }
        NotificationCenter.default.addObserver(
            forName: FlatFilterStore.ignoredFound, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { showIgnoredExpressions() }
        }
        DispatchQueue.main.async { showIgnoredExpressions() }
    }

    private static func showIgnoredExpressions() {
        let ignored = FlatFilterStore.shared.takeIgnored()
        guard !ignored.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = ignored.count == 1 ? "A saved expression cannot be used"
                                               : "\(ignored.count) saved expressions cannot be used"
        alert.informativeText = ignoredText(ignored)
        alert.runSelectable()
    }

    nonisolated static func ignoredText(_ ignored: [FlatFilterStore.Ignored]) -> String {
        let items = ignored.map { item in
            let what = item.name.map { "The name \u{201C}\($0)\u{201D} is not allowed. " } ?? ""
            return what + item.reason + ".\n" + item.path
        }
        return items.joined(separator: "\n\n") + "\n\n"
            + (ignored.count == 1 ? "This file is ignored." : "These files are ignored.")
            + (ignored.contains { $0.name != nil }
               ? " Change the \u{201C}name\u{201D} in the file to use it again." : "")
    }

    private static func show(databaseProblems problems: [ExifDatabase.Problem]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = problems.count == 1 ? "A list in ~/.diptych/exif cannot be read"
                                                : "Lists in ~/.diptych/exif cannot be read"
        alert.informativeText = problems.map { "\($0.path): \($0.message)." }
            .joined(separator: "\n\n")
            + "\n\nThe list that comes with Diptych is used instead, and the file is left as "
            + "it is, for you to mend."
        alert.runSelectable()
    }
}
