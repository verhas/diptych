import Foundation

/// One file open in Text Edit.
///
/// Read with the same loader as a comparison, and written with the same
/// careful save, so the invisible things survive an edit: the line ending the
/// file arrived with, whether it ended in a newline, the encoding it had to be
/// read as, and its permissions, owner and extended attributes.
///
/// The text itself lives in the text view, not here. Copying a large file out
/// of the view on every keystroke to keep a Swift string in step would make
/// typing slower the bigger the file; so this holds what was last saved, is
/// told *that* something changed, and asks for the text only when it needs it.
@MainActor
@Observable
final class TextEditDocument {

    let url: URL

    /// The text as last read or saved, with "\n" between lines.
    private(set) var saved = ""
    private(set) var source: SourceFile?
    /// Why the file could not be opened, in words for the window.
    private(set) var failure: String?
    /// Something was typed since the last save. Cheap to keep; checked against
    /// the real text before anything is asked about it.
    private(set) var isEdited = false
    /// Bumped when the text is read from disk, so the view knows to replace
    /// what it shows -- and knows not to on any other update.
    private(set) var revision = 0

    /// The format the extension says, and where the text breaks it -- set by
    /// the editor as it analyses what is typed.
    var format: TextFormat?
    var problem: SyntaxProblem?

    /// A property list's encoding on disk: shown and edited as XML either
    /// way, and saved back the way it came unless asked otherwise.
    enum PlistEncoding: Equatable {
        case xml, binary

        var title: String { self == .xml ? "XML" : "Binary" }
        var other: PlistEncoding { self == .xml ? .binary : .xml }
    }
    private(set) var plistEncoding: PlistEncoding?

    /// The text as it is in the editor. Set by the view.
    @ObservationIgnored var currentText: () -> String = { "" }

    init(url: URL) {
        self.url = url
    }

    var isReadOnly: Bool { !(source?.isWritable ?? false) }
    /// The volume, quoted, when the file is read-only because that is
    /// mounted read-only rather than because of its own permissions.
    private(set) var readOnlyVolume: String?

    /// Edited, and not merely edited and then undone back to what was saved.
    var hasUnsavedChanges: Bool { isEdited && currentText() != saved }

    /// The server a file is being fetched from while the window waits for it.
    private(set) var waitingFor: String?
    /// Whether this window holds the file against being fetched again: it has
    /// changes not saved, which a newer version from the server would wipe out.
    private var holdsFile = false

    private func hold(_ held: Bool) {
        guard held != holdsFile, RemoteBrowsing.isInside(url) else { return }
        holdsFile = held
        if held { EditedHere.hold(url) } else { EditedHere.release(url) }
    }

    /// The window is closing.
    func close() {
        hold(false)
    }

    func load() {
        // A file on a server whose bytes are not here, or are of an older
        // version: the window opens at once and fills when they have arrived.
        if RemoteBrowsing.hasPending([url]) {
            waitingFor = RemoteBrowsing.server(of: url)?.host ?? "the server"
            Task {
                do {
                    try await RemoteBrowsing.download(url)
                    waitingFor = nil
                    load()
                } catch {
                    waitingFor = nil
                    failure = "\(url.lastPathComponent) could not be fetched from the server: "
                        + error.localizedDescription
                }
            }
            return
        }
        hold(false)
        readOnlyVolume = WriteTrouble.readOnlyVolume(of: url)
        let isPlist = TextFormat.of(url, extensions: ConfigStore.shared.configuration.textFormats) == .plist
        plistEncoding = isPlist ? .xml : nil
        if isPlist, let data = try? Data(contentsOf: url), data.starts(with: Array("bplist".utf8)) {
            loadBinaryPlist(data)
            isEdited = false
            revision += 1
            return
        }
        do {
            let file = try TextDiff.load(url)
            source = file
            saved = file.lines.joined(separator: "\n")
                + (file.hasFinalNewline && !file.lines.isEmpty ? "\n" : "")
            failure = nil
        } catch let failure as TextDiff.Failure {
            self.failure = failure.message
        } catch {
            failure = error.localizedDescription
        }
        isEdited = false
        revision += 1
    }

    /// A binary property list, shown as the XML it stands for.
    private func loadBinaryPlist(_ data: Data) {
        do {
            let object = try PropertyListSerialization.propertyList(from: data, format: nil)
            let xml = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
            let text = String(decoding: xml, as: UTF8.self)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            source = SourceFile(lines: TextDiff.lines(of: text), lineEnding: "\n",
                                hasFinalNewline: text.hasSuffix("\n"), encoding: .utf8,
                                modified: attributes?[.modificationDate] as? Date,
                                isWritable: FileManager.default.isWritableFile(atPath: url.path))
            saved = text
            plistEncoding = .binary
            failure = nil
        } catch {
            failure = "\(url.lastPathComponent) starts as a binary property list, but cannot be read as one: "
                + error.localizedDescription
        }
    }

    func noteEdit() {
        isEdited = true
        hold(true)
    }

    enum SaveOutcome: Equatable {
        case saved
        case nothingToDo
        case changedUnderneath
        case failed(String)
    }

    /// `overwriting` is the answer to having been told the file changed
    /// underneath: yes, write mine anyway.
    ///
    /// `as` a plist encoding other than the one it has converts it: the
    /// file is written even when nothing was typed, and is that from then on.
    func save(overwriting: Bool = false, as wanted: PlistEncoding? = nil) -> SaveOutcome {
        guard let file = source, !isReadOnly else { return .nothingToDo }
        let text = currentText()
        let converting = wanted != nil && wanted != plistEncoding
        guard text != saved || converting else {
            isEdited = false
            return .nothingToDo
        }

        // Somebody else may have written it since it was opened -- Get the
        // Latest, a comparison window, another editor. Saving over that
        // without a word would throw their work away.
        let now = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
        if !overwriting, let stamped = file.modified, let now = now as? Date,
           abs(now.timeIntervalSince(stamped)) > 1 {
            return .changedUnderneath
        }

        let data: Data
        if (wanted ?? plistEncoding) == .binary {
            // Binary only from a property list that reads as one.
            do {
                let object = try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)
                data = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
            } catch {
                return .failed("The text is not a property list that can be written as binary: "
                               + error.localizedDescription)
            }
        } else {
            // The editor's lines end in "\n"; the file gets back its own ending.
            let written = file.lineEnding == "\n"
                ? text : text.replacingOccurrences(of: "\n", with: file.lineEnding)
            guard let encoded = written.data(using: file.encoding) else {
                return .failed("Some of the text cannot be written in this file's encoding "
                               + "(\(String.localizedName(of: file.encoding))). Take out the "
                               + "characters that were typed in, or save a copy elsewhere.")
            }
            data = encoded
        }

        do {
            try DiffDocument.write(data, to: url)
        } catch {
            return .failed(WriteTrouble.explaining(error, writing: url))
        }

        saved = text
        isEdited = false
        hold(false)
        if let wanted, plistEncoding != nil { plistEncoding = wanted }
        var refreshed = file
        refreshed.modified = (try? FileManager.default
            .attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        source = refreshed
        return .saved
    }

    /// "UTF-8, LF line endings" -- what saving will keep.
    var summary: String {
        guard let file = source else { return "" }
        if plistEncoding == .binary { return "Binary property list, shown as XML" }
        let ending = switch file.lineEnding {
        case "\r\n": "CRLF (Windows)"
        case "\r": "CR (classic Mac)"
        default: "LF"
        }
        return "\(String.localizedName(of: file.encoding)), \(ending) line endings"
    }
}
