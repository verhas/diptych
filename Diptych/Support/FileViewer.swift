import AppKit
import CoreServices

/// Diptych as the app that shows files: what "Show in Finder" and "Reveal in
/// Finder" in other apps open, in place of Finder.
///
/// macOS has a setting for it, though not a documented one: `NSFileViewer` in
/// the global defaults, holding the bundle id of the app to use. Path Finder
/// and ForkLift set it the same way. Apps that ask macOS to reveal a file then
/// send the request here; apps that tell Finder directly, by name, and
/// Finder's own features are not affected. An app reads the setting when it
/// starts, so ones already running carry on using Finder until reopened.
///
/// Two requests arrive: Finder's "reveal" (open the folder, select the items)
/// and the ordinary "open these" -- answered by showing a folder, or the
/// folder a file is in with the file selected. Either may arrive before
/// Diptych has a window; it is held until one is ready.
@MainActor
final class FileViewer: NSObject {

    static let shared = FileViewer()
    private override init() {}

    private static let defaultsKey = "NSFileViewer"

    private var pending: [(urls: [URL], selecting: Bool)] = []
    /// Opens a new browser window: SwiftUI's own opener, borrowed from the
    /// first window that started, for when a request finds none open.
    private var openWindow: (() -> Void)?

    // MARK: - The system setting

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "dev.verhas.Diptych" }

    /// Whether macOS currently sends file-showing requests to this app.
    static var isSystemDefault: Bool {
        CFPreferencesCopyAppValue(defaultsKey as CFString, kCFPreferencesAnyApplication)
            as? String == bundleID
    }

    /// Sets or clears `NSFileViewer` with `defaults(1)`, the same command
    /// anyone would type: `defaults write -g NSFileViewer -string <id>`.
    /// Clearing removes it only while it names Diptych, so switching this
    /// off never undoes another app having been chosen since. Returns why it
    /// failed, if it did.
    @discardableResult
    static func setSystemDefault(_ on: Bool) -> String? {
        let arguments: [String]
        if on {
            arguments = ["write", "-g", defaultsKey, "-string", bundleID]
        } else {
            guard isSystemDefault else { return nil }
            arguments = ["delete", "-g", defaultsKey]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }
        guard process.terminationStatus == 0 else {
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                              as: UTF8.self)
            return text.isEmpty ? "defaults exited with \(process.terminationStatus)" : text
        }
        return nil
    }

    /// At launch: the setting is on in Diptych but macOS no longer says so --
    /// reset by hand, or by another app taking it over. Diptych's own choice
    /// is what Settings shows, so it is put back.
    static func reconcileAtLaunch() {
        if ConfigStore.shared.configuration.showFilesInDiptych, !isSystemDefault {
            setSystemDefault(true)
        }
    }

    // MARK: - The requests

    /// Before launch finishes, so a request that launched Diptych is not
    /// missed.
    func installHandlers() {
        let manager = NSAppleEventManager.shared()
        manager.setEventHandler(self, andSelector: #selector(reveal(_:withReply:)),
                                forEventClass: AEEventClass(kAEMiscStandards),
                                andEventID: AEEventID(kAEMakeObjectsVisible))
        manager.setEventHandler(self, andSelector: #selector(open(_:withReply:)),
                                forEventClass: AEEventClass(kCoreEventClass),
                                andEventID: AEEventID(kAEOpenDocuments))
    }

    @objc nonisolated private func reveal(_ event: NSAppleEventDescriptor,
                                          withReply reply: NSAppleEventDescriptor) {
        let urls = Self.fileURLs(in: event)
        MainActor.assumeIsolated { show(urls, selecting: true) }
    }

    @objc nonisolated private func open(_ event: NSAppleEventDescriptor,
                                        withReply reply: NSAppleEventDescriptor) {
        let urls = Self.fileURLs(in: event)
        MainActor.assumeIsolated { show(urls, selecting: false) }
    }

    /// The direct object: one file or a list of them, as aliases or URLs.
    nonisolated private static func fileURLs(in event: NSAppleEventDescriptor) -> [URL] {
        guard let object = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
        else { return [] }
        let items = object.numberOfItems > 0
            ? (1...object.numberOfItems).compactMap { object.atIndex($0) }
            : [object]
        return items.compactMap { item in
            guard let url = item.coerce(toDescriptorType: DescType(typeFileURL)),
                  let parsed = URL(dataRepresentation: url.data, relativeTo: nil),
                  parsed.isFileURL else { return nil }
            return parsed
        }
    }

    /// A browser window has started: anything that arrived before it is
    /// shown now.
    func windowReady(_ model: AppModel) {
        if openWindow == nil { openWindow = model.openNewWindow }
        let waiting = pending
        pending = []
        for request in waiting { show(request.urls, selecting: request.selecting, in: model) }
    }

    private func show(_ urls: [URL], selecting: Bool) {
        guard !urls.isEmpty else { return }
        // Only windows still open. SwiftUI keeps a closed window's model
        // alive, and showing the folder there showed it nowhere at all: with
        // every window closed, a request did nothing.
        let live = AppWindows.shared.live
        let models = KeyRouter.shared.allModels.filter { model in
            model.window.map { window in live.contains { $0 === window } } ?? false
        }
        let model = models.first { $0.window?.isKeyWindow == true }
            ?? models.first { $0.window?.isVisible == true }
            ?? models.first
        guard let model else {
            // None open: a new one is made, and shows this when it starts.
            pending.append((urls, selecting))
            openWindow?()
            return
        }
        if model.window?.isMiniaturized == true { model.window?.deminiaturize(nil) }
        show(urls, selecting: selecting, in: model)
    }

    /// One folder per request: the folder itself when it is a folder that is
    /// to be opened, otherwise the folder the first item is in, with every
    /// item from that folder selected.
    private func show(_ urls: [URL], selecting: Bool, in model: AppModel) {
        guard let first = urls.first else { return }
        let isFolder = (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let pane = model.active
        if !selecting, isFolder {
            pane.navigate(to: first)
        } else {
            let folder = first.deletingLastPathComponent()
            let here = urls.filter {
                $0.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL
            }
            pane.pendingSelection = Set(here.map(\.standardizedFileURL))
            pane.navigate(to: folder)
        }
        model.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
