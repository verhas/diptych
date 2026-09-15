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

    /// The text as it is in the editor. Set by the view.
    @ObservationIgnored var currentText: () -> String = { "" }

    init(url: URL) {
        self.url = url
    }

    var isReadOnly: Bool { !(source?.isWritable ?? false) }

    /// Edited, and not merely edited and then undone back to what was saved.
    var hasUnsavedChanges: Bool { isEdited && currentText() != saved }

    func load() {
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

    func noteEdit() {
        isEdited = true
    }

    enum SaveOutcome: Equatable {
        case saved
        case nothingToDo
        case changedUnderneath
        case failed(String)
    }

    /// `overwriting` is the answer to having been told the file changed
    /// underneath: yes, write mine anyway.
    func save(overwriting: Bool = false) -> SaveOutcome {
        guard let file = source, !isReadOnly else { return .nothingToDo }
        let text = currentText()
        guard text != saved else {
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

        // The editor's lines end in "\n"; the file gets back its own ending.
        let written = file.lineEnding == "\n"
            ? text : text.replacingOccurrences(of: "\n", with: file.lineEnding)
        guard let data = written.data(using: file.encoding) else {
            return .failed("Some of the text cannot be written in this file's encoding "
                           + "(\(String.localizedName(of: file.encoding))). Take out the "
                           + "characters that were typed in, or save a copy elsewhere.")
        }

        do {
            try DiffDocument.write(data, to: url)
        } catch {
            return .failed(WriteTrouble.explaining(error, writing: url))
        }

        saved = text
        isEdited = false
        var refreshed = file
        refreshed.modified = (try? FileManager.default
            .attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        source = refreshed
        return .saved
    }

    /// "UTF-8, LF line endings" -- what saving will keep.
    var summary: String {
        guard let file = source else { return "" }
        let ending = switch file.lineEnding {
        case "\r\n": "CRLF (Windows)"
        case "\r": "CR (classic Mac)"
        default: "LF"
        }
        return "\(String.localizedName(of: file.encoding)), \(ending) line endings"
    }
}
