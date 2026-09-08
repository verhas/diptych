import AppKit
import QuickLookUI
import UniformTypeIdentifiers

/// Space-bar preview, the way Finder does it.
///
/// `QLPreviewPanel` is a shared, app-wide floating panel. It normally finds its
/// controller by walking the responder chain for something that answers
/// `acceptsPreviewPanelControl` -- machinery SwiftUI gives us no hook into, so
/// this assigns itself as the panel's data source directly instead.
@MainActor
final class QuickLookController: NSObject {

    static let shared = QuickLookController()

    private var items: [URL] = []

    /// The model whose pane the panel is previewing, so arrow keys that land on
    /// the panel can be pushed back into the file list.
    private(set) weak var owner: AppModel?

    /// Space toggles: a second press closes the panel, as in Finder.
    func toggle(_ urls: [URL], owner: AppModel) {
        guard let panel = QLPreviewPanel.shared() else { return }

        if panel.isVisible {
            panel.orderOut(nil)
            clearScratch()
            return
        }
        guard !urls.isEmpty else { return }

        items = urls.map(previewable)
        self.owner = owner
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()

        // orderFront rather than makeKeyAndOrderFront -- though measurement
        // shows QLPreviewPanel makes itself key either way, so this alone does
        // not keep focus in the file list. What actually preserves Finder's
        // behaviour is previewPanel(_:handle:) below, which pushes the panel's
        // arrow keys back into the pane. Our window's first responder stays the
        // table throughout, so focus returns to it when the panel closes.
        panel.orderFront(nil)
    }

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    func close() {
        guard isVisible else { return }
        QLPreviewPanel.shared().orderOut(nil)
        clearScratch()
    }

    /// Keep the panel in step while the cursor moves, rather than making the
    /// user close and reopen it.
    func update(_ urls: [URL]) {
        guard isVisible else { return }
        items = urls.map(previewable)
        QLPreviewPanel.shared().reloadData()
    }

    // MARK: - Text fallback

    /// Files whose extension the system does not recognise get no preview at
    /// all -- Quick Look just shows a name and a size. Most of those, in a
    /// developer's home directory, are plain text: .env, .gitconfig, Dockerfile,
    /// a stray config with an invented suffix. If the bytes look like text,
    /// preview a .txt copy so you actually see the contents.
    /// Types Quick Look genuinely renders. "Is a declared type" was the old
    /// test and it was wrong: .cfg is declared as public.toml, which conforms to
    /// public.text but has no generator, so the panel showed a name and a size.
    /// public.toml and com.microsoft.ini conform to none of these -- which is
    /// exactly the distinction that matters.
    private static let renderable: [UTType] = [
        .plainText, .sourceCode, .rtf, .html, .xml, .json, .yaml, .propertyList,
        .image, .pdf, .movie, .audio, .archive, .spreadsheet, .presentation, .font,
    ]

    private func previewable(_ url: URL) -> URL {
        if url.lastPathComponent == ".DS_Store", let rendered = dsStoreReport(for: url) {
            return rendered
        }
        if let type = UTType(filenameExtension: url.pathExtension), type.isDeclared,
           Self.renderable.contains(where: { type.conforms(to: $0) }) {
            return url
        }
        guard let text = readableText(at: url) else { return url }

        let target = scratch.appendingPathComponent(url.lastPathComponent + ".txt")
        guard (try? text.write(to: target, atomically: true, encoding: .utf8)) != nil else {
            return url
        }
        return target
    }

    /// `.DS_Store` has no Quick Look generator, so the panel shows a name and a
    /// size for a file that is actually full of readable structure: where every
    /// icon sat, how the window was arranged, which columns were showing. Decode
    /// it and preview an HTML rendering instead.
    ///
    /// A failure to parse gets a page of its own rather than falling back to the
    /// empty panel -- "this is not a Bud1 file at all" is worth being told.
    private func dsStoreReport(for url: URL) -> URL? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= DSStore.maximumFileSize,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }

        let directory = url.deletingLastPathComponent().path
        let html: String
        do {
            let store = try DSStore(data: data)
            html = DSStoreReport.html(for: store, name: url.lastPathComponent, path: directory)
        } catch {
            html = DSStoreReport.html(failure: error, name: url.lastPathComponent)
        }

        // Named after the folder it describes: several .DS_Store previews in one
        // session would otherwise overwrite each other in the scratch directory.
        let stem = directory.replacingOccurrences(of: "/", with: "_")
        let target = scratch.appendingPathComponent("DS_Store\(stem).html")
        guard (try? html.write(to: target, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        return target
    }

    /// Heuristic, deliberately conservative: better to fall back to Quick Look's
    /// own "no preview" panel than to render a binary as mojibake.
    private func readableText(at url: URL) -> String? {
        let limit = 4 * 1024 * 1024
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= limit,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }

        // A NUL byte early on is the classic "this is binary" signal.
        if data.prefix(8192).contains(0) { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        // Control characters other than tab and the line endings mean it is
        // structured binary that happens to decode.
        let sample = text.prefix(8192)
        let controls = sample.unicodeScalars.filter {
            CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t"
        }.count
        return Double(controls) / Double(max(sample.count, 1)) < 0.02 ? text : nil
    }

    /// Per-process scratch directory for those .txt copies.
    private var scratch: URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiptychPreview-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func clearScratch() {
        try? FileManager.default.removeItem(at: scratch)
    }
}

extension QuickLookController: QLPreviewPanelDataSource {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        // assumeIsolated must return something Sendable, and QLPreviewItem is
        // not. A URL is, so hand that across the boundary and cast outside.
        let url: URL? = MainActor.assumeIsolated {
            items.indices.contains(index) ? items[index] : nil
        }
        return url as NSURL?
    }
}

extension QuickLookController: QLPreviewPanelDelegate {

    /// If the panel does end up with key focus -- clicking it will do that --
    /// arrow keys still drive the file list rather than dead-ending in the
    /// panel. This is the hook AppKit provides for exactly that, and it is how
    /// Finder keeps working while its preview is frontmost.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        let code = event.keyCode
        return MainActor.assumeIsolated {
            switch code {
            case 125: owner?.moveCursor(by: 1); return true    // down arrow
            case 126: owner?.moveCursor(by: -1); return true   // up arrow
            default:  return false
            }
        }
    }
}
