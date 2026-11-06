import Foundation
import UniformTypeIdentifiers

/// Edit, and the conversions of Tools.
extension AppModel {

    // MARK: - Edit

    /// Edit: Text Edit for a text file, Bin Edit for anything else. Bin Edit
    /// can be asked for by itself; Text Edit refuses what is not text anyway.
    func editSelection() {
        guard let item = singleSelection("edit", includingParent: false) else { return }
        guard !item.isDirectory else {
            flash("\(item.name) is a folder. Edit opens files.", error: true)
            return
        }
        // A server's file is looked at once it is here: a placeholder is empty.
        whenFetched([item.url]) { [weak self] in
            guard let self else { return }
            // A binary property list too: Text Edit shows it as XML.
            let plist = TextFormat.of(item.url, extensions: ConfigStore.shared.configuration.textFormats) == .plist
            if plist || Self.editsAsText(item.url) { showTextEditor() } else { showBinaryView() }
        }
    }

    /// Text, by the same test Text Edit reads it with: no NUL byte early on,
    /// unless a byte-order mark says UTF-16 or UTF-32.
    nonisolated static func editsAsText(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8000)) ?? Data()
        return TextEncodings.reading(of: head, fallback: .windowsCP1252) != nil
    }

    // MARK: - Line endings and encodings

    /// A file the conversions work on: one Text Edit would open as text. A
    /// picture, a movie, an archive, a PDF or a program is told by its type
    /// without being read; anything else by its first bytes.
    nonisolated static func convertsAsText(_ url: URL) -> Bool {
        !isNeverText(url) && editsAsText(url)
    }

    /// Not text by its type alone, nothing read.
    nonisolated static func isNeverText(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return [.image, .audiovisualContent, .archive, .pdf, .executable, .font, .diskImage]
            .contains(where: { type.conforms(to: $0) })
    }

    /// Whether the conversions are offered for these files: when any of them
    /// is text -- they then convert the text ones and leave the rest out. The
    /// menu cannot afford to read thousands of files, so it reads until it
    /// finds one that is text, at most `reads` of them; past that, with more
    /// left that may be, they are offered and the window sorts them out.
    nonisolated static func offersConversion(_ urls: [URL], reads: Int = 50) -> Bool {
        let candidates = urls.lazy.filter { !isNeverText($0) }
        var read = 0
        for url in candidates {
            if read == reads { return true }
            if editsAsText(url) { return true }
            read += 1
        }
        return false
    }

    /// The selected ordinary files: what the conversions work on.
    var conversionTargets: [URL] {
        active.selectedItems.filter { !$0.isDirectory && !$0.isParent }.map(\.url)
    }

    var canConvertText: Bool { !conversionTargets.isEmpty && active.isWritable }

    func requestConvertLineEndings() { openConversion(.lineEndings) }

    func requestConvertEncoding() { openConversion(.encodings) }

    /// In place, so on a writable folder only. A server's files are fetched
    /// first -- the window reads them -- and what is written is sent back.
    private func openConversion(_ kind: ToolWindows.Kind) {
        let targets = conversionTargets
        guard !targets.isEmpty else { return }
        guard active.isWritable else {
            flash("This folder is read-only: its files cannot be converted in place")
            return
        }
        // Only what may be text is fetched: the pictures among a server's
        // sources are left out unread.
        whenFetched(targets.filter { !Self.isNeverText($0) }) { [weak self] in
            guard let self else { return }
            let id = ToolWindows.shared.register(.init(model: self, kind: kind, files: targets))
            openToolWindow?(kind, id)
        }
    }
}
