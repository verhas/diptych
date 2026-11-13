import Foundation

/// What was looked at, for the journal: folders opened, files opened,
/// previewed and selected -- unless Settings ▸ Behaviour ▸ Journal leaves
/// contents or names and details out.
///
/// Only what was settled on. A selection is recorded once it has stood for
/// three seconds and a preview once it has been on screen for a second and a
/// half: running the arrow keys down a folder is not two hundred entries.
/// Never in Spotlight, which it would flood.
@MainActor
enum JournalViewing {

    /// A selection of more files than this is recorded as a count and the
    /// first of them.
    static let listedAtMost = 500


    // MARK: - At once

    static func openedFolder(_ url: URL) {
        guard Journal.isRecording(.attributes), url.isFileURL else { return }
        let path = RemoteBrowsing.journalPath(url)
        Journal.shared.record(kind: "Open Folder", category: .attributes, told: "\(tilde(path)) was opened.",
                              files: [Journal.File(before: path, after: path)], folder: path)
    }

    static func opened(_ urls: [URL], with app: URL? = nil) {
        guard Journal.isRecording(.content), !urls.isEmpty else { return }
        let names = FileHistory.Plan.names(urls)
        let how = app.map { " with \($0.deletingPathExtension().lastPathComponent)" } ?? ""
        Journal.shared.record(
            kind: "Open", category: .content,
            told: (urls.count == 1 ? "\(names) in \(tilde(urls[0].deletingLastPathComponent().path))"
                   : "\(urls.count) items: \(names),") + " opened\(how).",
            files: urls.map { Journal.File(before: $0.path, after: $0.path) })
    }

    // MARK: - Once settled

    private static var previewTask: Task<Void, Never>?
    private static var lastPreviewed: [URL] = []

    /// Quick Look is showing these, or nothing.
    static func previewing(_ urls: [URL]) {
        previewTask?.cancel()
        guard Journal.isRecording(.content), !urls.isEmpty, urls != lastPreviewed else { return }
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            lastPreviewed = urls
            let names = FileHistory.Plan.names(urls)
            Journal.shared.record(
                kind: "Quick Look", category: .content,
                told: "\(names) \(urls.count == 1 ? "was" : "were") looked at in Quick Look.",
                files: urls.prefix(listedAtMost).map { Journal.File(before: $0.path, after: $0.path) })
        }
    }

    static func previewClosed() {
        previewTask?.cancel()
        lastPreviewed = []
    }

    private static var selectionTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private static var lastSelected: [ObjectIdentifier: Set<URL>] = [:]

    /// A pane's selection changed; recorded if it still stands in a moment.
    static func selected(_ urls: Set<URL>, in pane: PaneModel) {
        let key = ObjectIdentifier(pane)
        selectionTasks[key]?.cancel()
        guard Journal.isRecording(.attributes), !urls.isEmpty, urls != lastSelected[key] else { return }
        selectionTasks[key] = Task { [weak pane] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let pane, pane.selection == urls else { return }
            lastSelected[key] = urls
            selectionTasks[key] = nil
            let sorted = urls.filter { !$0.lastPathComponent.isEmpty }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            guard !sorted.isEmpty else { return }
            let folder = sorted[0].deletingLastPathComponent().path
            let told = sorted.count == 1
                ? "\(FileHistory.Plan.names(sorted)) was selected in \(tilde(RemoteBrowsing.journalPath(URL(fileURLWithPath: folder))))."
                : "\(sorted.count) items were selected in \(tilde(RemoteBrowsing.journalPath(URL(fileURLWithPath: folder)))): "
                  + "\(FileHistory.Plan.names(sorted))."
            Journal.shared.record(
                kind: "Select", category: .attributes, told: told,
                files: sorted.prefix(listedAtMost).map {
                    let path = RemoteBrowsing.journalPath($0)
                    return Journal.File(before: path, after: path)
                })
        }
    }

    private static func tilde(_ path: String) -> String { NamingTemplate.tilde(path) }
}
