import AppKit
import UniformTypeIdentifiers

/// The apps that can open a file -- what the Info window's Open Using tab
/// lists, and the two things it does with them: open the file in one, or make
/// one the default for files of this kind.
///
/// Main-actor: it is all LaunchServices and NSWorkspace, which belong there.
@MainActor
enum OpenWith {

    struct App: Identifiable, Hashable, Sendable {
        let url: URL
        var id: URL { url }
        let name: String
        /// The current default for this file's kind.
        let isDefault: Bool
    }

    /// Every app LaunchServices knows can open `file`, the default first, then
    /// by name. The default is marked.
    static func apps(for file: URL) -> [App] {
        let workspace = NSWorkspace.shared
        let fallback = workspace.urlForApplication(toOpen: file)?.standardizedFileURL
        var seen = Set<URL>()
        let apps = workspace.urlsForApplications(toOpen: file).compactMap { url -> App? in
            let standard = url.standardizedFileURL
            guard seen.insert(standard).inserted else { return nil }
            return App(url: url,
                       name: FileManager.default.displayName(atPath: url.path),
                       isDefault: standard == fallback)
        }
        return apps.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Open `file` in `app` now, without changing what the default is.
    static func open(_ file: URL, with app: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration)
    }

    /// The file's content type -- what a default is set for, since a default is
    /// per kind, not per file.
    static func contentType(of file: URL) -> UTType? {
        (try? file.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: file.pathExtension)
    }

    /// Make `app` the default for files of `file`'s kind. Nil on success, else
    /// why it could not be done. This changes every file of the kind, not just
    /// this one.
    static func makeDefault(_ app: URL, for file: URL) async -> String? {
        guard let type = contentType(of: file) else {
            return "This file has no kind macOS can set a default app for."
        }
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
