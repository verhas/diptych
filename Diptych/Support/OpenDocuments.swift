import Foundation

/// Where an already-open Text Edit, Diff or Compare Folders window's model
/// lives, so a fresh request to open the same thing again can refresh it
/// directly -- rather than trusting that the window or view SwiftUI hands
/// back is one whose state has actually been reset.
///
/// `WindowGroup(for:)` can keep a "closed" window's scene alive underneath,
/// which is also what let Option-Tab cycle back to a window the user had
/// already closed (see `AppWindows`). Reloading here, at the moment the user
/// asks to open the file or pair again, does not depend on any of that: it
/// is called from `AppModel` itself, which always runs when the request is
/// made, whatever AppKit and SwiftUI go on to do with the window.
@MainActor
final class OpenTextDocuments {
    static let shared = OpenTextDocuments()
    private init() {}

    private struct WeakDocument { weak var document: TextEditDocument? }
    private var documents: [String: WeakDocument] = [:]

    func register(_ document: TextEditDocument, for url: URL) {
        documents[FileOperations.canonicalPath(url)] = WeakDocument(document: document)
    }

    /// If a document for this file already exists anywhere -- its window
    /// visibly open, or merely still alive behind a "closed" one -- reload it
    /// from disk right now, before that window is asked to come forward.
    func refreshIfOpen(_ url: URL) {
        let key = FileOperations.canonicalPath(url)
        guard let document = documents[key]?.document else {
            documents.removeValue(forKey: key)
            return
        }
        document.load()
    }
}

@MainActor
final class OpenDiffDocuments {
    static let shared = OpenDiffDocuments()
    private init() {}

    private struct WeakDocument { weak var document: DiffDocument? }
    private var documents: [DiffPair: WeakDocument] = [:]

    func register(_ document: DiffDocument, for pair: DiffPair) {
        documents[pair] = WeakDocument(document: document)
    }

    func refreshIfOpen(_ pair: DiffPair) {
        guard let document = documents[pair]?.document else {
            documents.removeValue(forKey: pair)
            return
        }
        Task { await document.load() }
    }
}

@MainActor
final class OpenDirectoryDiffModels {
    static let shared = OpenDirectoryDiffModels()
    private init() {}

    private struct WeakModel { weak var model: DirectoryDiffModel? }
    private var models: [DirectoryDiffPair: WeakModel] = [:]

    func register(_ model: DirectoryDiffModel, for pair: DirectoryDiffPair) {
        models[pair] = WeakModel(model: model)
    }

    /// The live model for an already-open window on this pair, if there is
    /// one -- for a caller that needs to change something about it directly
    /// (e.g. an MCP `open_diff` call asked for different comparison options)
    /// rather than only being able to ask it to reload.
    func model(for pair: DirectoryDiffPair) -> DirectoryDiffModel? {
        models[pair]?.model
    }

    func refreshIfOpen(_ pair: DirectoryDiffPair) {
        guard let model = models[pair]?.model else {
            models.removeValue(forKey: pair)
            return
        }
        Task { await model.load() }
    }
}
