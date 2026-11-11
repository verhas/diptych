import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import Vision
import FoundationModels

/// A file name worked out from what is in the file, by the language model that
/// runs on this Mac.
///
/// On this Mac and nowhere else. The framework offers two models: the system
/// one, which runs locally, and from macOS 27 a Private Cloud Compute one,
/// which sends the request to Apple's servers. Only the first is ever used
/// here, and it is named explicitly rather than left to a default, so that
/// nothing about this feature can start talking to the network because a
/// default changed.
///
/// It suggests; it never decides. Every name it produces lands in a field the
/// user can accept, edit or throw away.
enum NameSuggester {

    // MARK: - Whether it can be used

    enum Status: Equatable, Sendable {
        case ready
        /// Below macOS 26, where the framework does not exist.
        case systemTooOld
        case macNotEligible
        case appleIntelligenceOff
        /// Switched on, but the model is still being downloaded.
        case modelDownloading
        case unavailable

        /// Said in Settings, so that a feature which is not doing anything says
        /// why rather than simply being absent.
        var explanation: String {
            switch self {
            case .ready:
                "Apple Intelligence is ready on this Mac."
            case .systemTooOld:
                "This needs macOS 26 or later."
            case .macNotEligible:
                "This Mac cannot run Apple Intelligence."
            case .appleIntelligenceOff:
                "Apple Intelligence is switched off. Turn it on in System Settings, "
                + "under Apple Intelligence & Siri."
            case .modelDownloading:
                "Apple Intelligence is still getting ready on this Mac. Try again "
                + "in a while."
            case .unavailable:
                "Apple Intelligence is not available at the moment."
            }
        }
    }

    static var status: Status {
        guard #available(macOS 26, *) else { return .systemTooOld }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(.deviceNotEligible):
            return .macNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceOff
        case .unavailable(.modelNotReady):
            return .modelDownloading
        case .unavailable:
            return .unavailable
        }
    }

    // MARK: - Asking

    /// Longer than this and the answer is no longer a convenience.
    ///
    /// Measured on an M1 Max: one to three seconds for a name. Instructions
    /// that make the model work harder, or a long excerpt, can take it well
    /// past that, so the wait is shown for as long as it lasts and can be
    /// cancelled -- and this is the point past which it is better to give up
    /// than to keep somebody waiting.
    static let patience: TimeInterval = 20

    /// How a suggested name is written, from Settings.
    ///
    /// Taken as a value when the question is asked, so a setting changed while
    /// the model is thinking does not half-apply to the answer.
    struct Style: Equatable, Sendable {
        /// Put between words instead of a space. Nil keeps spaces.
        var separator: Character? = nil
        /// Letters outside plain ASCII are allowed. Off, they are spelt in it.
        var unicode = true
        /// With `unicode` off: ä, ö, ü become ae, oe, ue rather than a, o, u.
        var germanSpelling = false
        /// How much of the start of a file the model is shown.
        var excerptLength = NameSuggester.defaultExcerptLength
        /// What the model is sent, from names.tmpl or a template for the folder.
        var template = NamingTemplate.Template.builtIn
    }

    /// What came of asking.
    ///
    /// Not an optional name: "no name" has several causes, and they call for
    /// different things from the user. Reporting every one of them as "there
    /// was nothing in this file" would be wrong about most of them -- and
    /// wrong in the way that sends someone looking at the file instead of at
    /// the setting that caused it.
    enum Outcome: Equatable, Sendable {
        case name(String)
        /// A name and what else New from Clipboard asked about the content.
        case described(Description)
        /// A binary file, an empty one, a picture with nothing Vision could see.
        case nothingToGoOn
        /// More content than the model can read at once.
        case tooLong
        case tookTooLong
        /// The model answered, but with nothing usable as a file name.
        case unusable
        /// Apple's safety rules would not let the model describe it.
        case declined
        case unsupportedLanguage
        case unavailable(Status)
        case failed(String)

        var name: String? {
            switch self {
            case .name(let name): name
            case .described(let description): description.name
            default: nil
            }
        }

        var described: Description? {
            if case .described(let description) = self { description } else { nil }
        }

        /// What to tell the user when there is no name. Nil when there is one.
        var explanation: String? {
            switch self {
            case .name, .described:
                nil
            case .nothingToGoOn:
                "There was nothing in this file to suggest a name from"
            case .tooLong:
                "That is more than Apple Intelligence can read at once. Set fewer "
                + "characters in Settings, under Apple Intelligence."
            case .tookTooLong:
                "No name came back within \(Int(NameSuggester.patience)) seconds"
            case .unusable:
                "Apple Intelligence answered with nothing usable as a file name"
            case .declined:
                "Apple Intelligence would not describe this content"
            case .unsupportedLanguage:
                "Apple Intelligence does not support the language this is written in"
            case .unavailable(let status):
                status.explanation
            case .failed(let reason):
                "Apple Intelligence could not suggest a name: \(reason)"
            }
        }
    }

    /// What New from Clipboard learns about what it is saving, besides a name.
    ///
    /// A file that does not exist yet has no extension to say what it is, so
    /// the model is asked that too. Everything here went through the same
    /// tidying as a name: it was written from somebody's content.
    struct Description: Equatable, Sendable {
        /// Tidied, without an extension, like any suggested name.
        var name: String
        /// One of `contentTypes`, or nil when the answer was none of them.
        var contentType: String?
        /// One line saying what the content is.
        var summary: String?
        /// Lowercase words to file it under: "invoice", "bank transfer".
        var tags: [String] = []

        /// What the content type calls for. Nil for a picture, whose format
        /// was chosen in Settings, and for an answer that was no known type.
        var fileExtension: String? {
            contentType.flatMap(NameSuggester.fileExtension(forContentType:))
        }
    }

    /// What the model may call content, and the extension each one gets.
    ///
    /// A fixed list rather than whatever extension the model makes up: the
    /// content may be written to steer the model, and an extension decides
    /// what a double-click does. Nothing here opens as an application.
    static let contentTypes: [(name: String, fileExtension: String?)] = [
        ("plain text", "txt"), ("Markdown", "md"), ("HTML", "html"), ("XML", "xml"),
        ("JSON", "json"), ("YAML", "yaml"), ("TOML", "toml"), ("CSV", "csv"),
        ("tab-separated values", "tsv"), ("SQL", "sql"), ("CSS", "css"), ("LaTeX", "tex"),
        ("log", "log"), ("diff or patch", "diff"), ("shell script", "sh"),
        ("Python", "py"), ("Swift", "swift"), ("Java", "java"), ("Kotlin", "kt"),
        ("JavaScript", "js"), ("TypeScript", "ts"), ("C", "c"), ("C++", "cpp"),
        ("C#", "cs"), ("Go", "go"), ("Rust", "rs"), ("Ruby", "rb"), ("PHP", "php"),
        ("picture", nil),
    ]

    static let contentTypeNames: [String] = contentTypes.map(\.name)

    static func fileExtension(forContentType type: String) -> String? {
        contentTypes.first { $0.name.caseInsensitiveCompare(type) == .orderedSame }?
            .fileExtension
    }

    /// A name for this file, without its extension.
    static func suggest(forFile url: URL, style: Style = Style()) async -> Outcome {
        let length = style.excerptLength
        // The file is not read at all when the template does not ask for it.
        let reads = style.template.usesContent
        let (content, details) = await BlockingWork.run { () -> (String?, [String: String]) in
            (reads ? describe(url, length: length) : "", fileDetails(of: url))
        }
        guard let content else { return .nothingToGoOn }
        return await ask(about: content, details: details, style: style)
    }

    /// A name for what is on the clipboard. `details` describe the file it
    /// will become, since there is no file yet to read them from. `describing`
    /// asks for a `Description` as well -- what kind of content, a summary
    /// and tags -- which takes the model a little longer.
    static func suggest(forText text: String, details: [String: String] = [:],
                        style: Style = Style(), describing: Bool = false) async -> Outcome {
        let content = excerpt(of: text, length: style.excerptLength)
        guard !content.isEmpty || !style.template.usesContent else { return .nothingToGoOn }
        return await ask(about: content, details: details, style: style, describing: describing)
    }

    static func suggest(forImage image: CGImage, details: [String: String] = [:],
                        style: Style = Style()) async -> Outcome {
        let length = style.excerptLength
        let reads = style.template.usesContent
        let words = await BlockingWork.run {
            reads ? describe(SendableImage(image), length: length) : ""
        }
        return await suggest(forPictureDescribedAs: words, details: details, style: style)
    }

    /// The second half of a picture's name: what Vision said about it is
    /// already known. Separate, because that half depends on the folder and
    /// the first does not -- New from Clipboard's guess made ahead of time
    /// keeps Vision's words when the folder changes under it.
    static func suggest(forPictureDescribedAs words: String?, details: [String: String] = [:],
                        style: Style = Style(), describing: Bool = false) async -> Outcome {
        guard let words else { return .nothingToGoOn }
        return await ask(about: words, details: details, style: style, describing: describing)
    }

    private static func ask(about content: String, details: [String: String],
                            style: Style, describing: Bool = false) async -> Outcome {
        let status = status
        guard status == .ready, #available(macOS 26, *) else { return .unavailable(status) }
        let template = style.template
        let prompt = template.render(content: content, details: details)
        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                describing
                    ? await Model.describe(instructions: template.instructions, prompt: prompt)
                    : await Model.name(instructions: template.instructions, prompt: prompt)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(patience))
                return .tookTooLong
            }
            let first = await group.next() ?? .tookTooLong
            group.cancelAll()
            return first
        }
        switch outcome {
        case .name(let raw):
            return tidy(raw, style: style).map(Outcome.name) ?? .unusable
        case .described(let raw):
            guard let name = tidy(raw.name, style: style) else { return .unusable }
            let type = raw.contentType.flatMap { said in
                contentTypeNames.first { $0.caseInsensitiveCompare(said) == .orderedSame }
            }
            return .described(Description(name: name, contentType: type,
                                          summary: raw.summary.flatMap(tidyCaption),
                                          tags: tidyTags(raw.tags)))
        default:
            return outcome
        }
    }

    /// Longest tag worth keeping, and how many.
    static let longestTag = 30
    static let mostTags = 5

    /// Short, lowercase, one line each, no repeats: tags are words to file
    /// something under, and like a name they were written from content that
    /// may have been written to steer the model.
    static func tidyTags(_ raw: [String]) -> [String] {
        var tags: [String] = []
        for tag in raw {
            var tidied = tag.unicodeScalars
                .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
                .joined()
            for unwanted in unwantedInNames + ["#", ",", ";"] {
                tidied = tidied.replacingOccurrences(of: unwanted, with: " ")
            }
            tidied = tidied.replacingOccurrences(of: "_", with: " ")
                .split(whereSeparator: \.isWhitespace)
                .filter { $0.contains { $0.isLetter || $0.isNumber } }
                .joined(separator: " ")
                .lowercased()
            if tidied.count > longestTag { tidied = String(tidied.prefix(longestTag)) }
            tidied = tidied.trimmingCharacters(in: CharacterSet(charactersIn: " .-'"))
            guard !tidied.isEmpty, !tags.contains(tidied) else { continue }
            tags.append(tidied)
            if tags.count == mostTags { break }
        }
        return tags
    }

    // MARK: - A description for a photo

    /// A sentence saying what a photo shows, for its EXIF description: what
    /// Vision sees in it, put into words by the same model on this Mac. Nil
    /// when there is nothing to go on or the model is not to be had -- it is
    /// only ever a suggestion, and none is better than a wrong excuse for one.
    static func caption(forImageAt url: URL) async -> String? {
        guard status == .ready, #available(macOS 26, *) else { return nil }
        let words = await BlockingWork.run { () -> String? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 1600,
                  ] as CFDictionary) else { return nil }
            return describe(SendableImage(image))
        }
        guard let words else { return nil }
        let answer = await withTaskGroup(of: String?.self) { group in
            group.addTask { await Model.caption(of: words) }
            group.addTask {
                try? await Task.sleep(for: .seconds(patience))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return answer.flatMap(tidyCaption)
    }

    /// One line, no control characters, not a page: what came back was
    /// written from a picture, which can hold text written to steer a model.
    static func tidyCaption(_ raw: String) -> String? {
        let line = raw.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D} "))
        guard !line.isEmpty else { return nil }
        return line.count > 200 ? String(line.prefix(200)) : line
    }

    // MARK: - What is known about the file

    /// The values for a template's placeholders, other than the content.
    ///
    /// Names, folders, owners and groups come from the file system, so they are
    /// passed through the same sanitising as F1's prompt: a control character
    /// or an invisible one in a file name could otherwise hide text from the
    /// person reading the template while the model still reads it.
    static func fileDetails(of url: URL, now: Date = Date()) -> [String: String] {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        var details = details(name: url.lastPathComponent,
                              folder: url.deletingLastPathComponent(),
                              bytes: bytes, kind: kind(of: url), now: now)
        details["permissions"] = mode.map { FileOperations.rwxString(mode_t($0)) } ?? ""
        details["owner"] = safe(attributes[.ownerAccountName] as? String ?? "")
        details["group"] = safe(attributes[.groupOwnerAccountName] as? String ?? "")
        if let created = attributes[.creationDate] as? Date { details["created"] = stamp(created) }
        if let modified = attributes[.modificationDate] as? Date {
            details["modified"] = stamp(modified)
        }
        return details
    }

    /// The details of a file that does not exist yet -- New from Clipboard's.
    /// Its dates are now, and it has no permissions, owner or group to report.
    static func details(name: String, folder: URL, bytes: Int64, kind: String,
                        now: Date = Date()) -> [String: String] {
        let suffix = (name as NSString).pathExtension
        return [
            "kind": kind,
            "name": safe(name),
            "stem": safe((name as NSString).deletingPathExtension),
            "extension": safe(suffix),
            "folder": safe(NamingTemplate.tilde(folder.path)),
            "folderName": safe(folder.lastPathComponent),
            "size": ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
            "bytes": String(bytes),
            "permissions": "",
            "owner": "",
            "group": "",
            "created": stamp(now),
            "modified": stamp(now),
            "today": String(stamp(now).prefix(10)),
        ]
    }

    /// What the content placeholder will hold, judged the way `describe` reads it.
    static func kind(of url: URL) -> String {
        let suffix = url.pathExtension.lowercased()
        if suffix == "pdf" { return "PDF" }
        return isPicture(suffix) ? "picture" : "text"
    }

    private static func safe(_ value: String) -> String {
        PromptBuilder.sanitise(value).text
    }

    /// Local time, written the same everywhere: a template asking for a date in
    /// a name should not get "15. 9. 2026" on one Mac and "9/15/26" on another.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - What to show the model

    /// About a thousand tokens of a context window of four thousand, leaving
    /// room for the instructions and the answer. Settings can change it.
    static let defaultExcerptLength = 3000

    static func excerpt(of text: String, length: Int = defaultExcerptLength) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max(length, 1)))
    }

    /// Turn a file into words the model can read.
    ///
    /// Text is read as text, a PDF has its text taken out, and a picture is
    /// described by Vision -- because on macOS 26 the model reads words only.
    /// Image input arrives with macOS 27. Anything else has nothing to go on,
    /// and a guess from a file name alone would be worse than no suggestion.
    static func describe(_ url: URL, length: Int = defaultExcerptLength) -> String? {
        let suffix = url.pathExtension.lowercased()

        if suffix == "pdf", let document = PDFDocument(url: url) {
            var text = ""
            // As many pages as it takes to fill the excerpt, but not a whole
            // book's worth: a number typed into Settings should not be able to
            // make this read a thousand pages.
            for index in 0..<min(document.pageCount, 100) {
                text += document.page(at: index)?.string ?? ""
                if text.count >= length { break }
            }
            let trimmed = excerpt(of: text, length: length)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           CGImageSourceGetCount(source) > 0,
           CGImageSourceGetType(source).map({ ($0 as String).hasPrefix("public.") }) ?? false,
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: 1600,
           ] as CFDictionary),
           isPicture(suffix) {
            return describe(SendableImage(image), length: length)
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // A character is at most four bytes in UTF-8, so this is always enough
        // bytes for the characters wanted -- plus a margin, since what is cut
        // off at the start by trimming white space would otherwise be missing
        // at the end.
        let bytes = min(max(length, 1), Int.max / 8) * 4 + 1024
        guard let data = try? handle.read(upToCount: bytes), !data.isEmpty else { return nil }
        // A NUL byte in the first stretch still means "not text".
        guard !data.contains(0) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let trimmed = excerpt(of: text, length: length)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isPicture(_ suffix: String) -> Bool {
        ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]
            .contains(suffix)
    }

    /// CGImage is not Sendable, and crossing to the blocking queue needs it to
    /// be. Nothing writes to one after it is made, so wrapping it is honest.
    struct SendableImage: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    /// What Vision can say about a picture: the text written in it, then what
    /// it seems to show. Both on this Mac, with no model download of their own.
    static func describe(_ picture: SendableImage, length: Int = defaultExcerptLength) -> String? {
        let handler = VNImageRequestHandler(cgImage: picture.image)

        let reading = VNRecognizeTextRequest()
        reading.recognitionLevel = .accurate
        reading.usesLanguageCorrection = true

        let looking = VNClassifyImageRequest()

        try? handler.perform([reading, looking])

        let text = (reading.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")

        let labels = (looking.results ?? [])
            .filter { $0.confidence > 0.3 }
            .prefix(6)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }

        var parts: [String] = []
        if !labels.isEmpty { parts.append("A picture showing: " + labels.joined(separator: ", ") + ".") }
        if !text.isEmpty { parts.append("Text in the picture: " + text) }
        let description = excerpt(of: parts.joined(separator: "\n"), length: length)
        return description.isEmpty ? nil : description
    }

    // MARK: - Making it a name

    /// Longest name worth suggesting. A name is for recognising a file in a
    /// list, not for summarising it.
    static let longestName = 60

    /// A name the file system and a person can both live with.
    ///
    /// The model's answer is shaped by guided generation, so it is a name
    /// rather than a paragraph -- but the content that went in was somebody's
    /// file, and a file can contain text written to steer a model. What comes
    /// back is therefore treated like any other untrusted string: no path
    /// separators, no control characters, no leading dot to hide the file, no
    /// extension of its own, and nothing longer than a name should be.
    ///
    /// The style is applied around that. Spelling in plain letters comes first,
    /// so that every check after it sees the name as it will be written -- a
    /// conversion can turn a character that looks harmless into one that is
    /// not. The separator comes last, once the name is otherwise final, so it
    /// cannot be mistaken for anything by the checks.
    static func tidy(_ raw: String, style: Style = Style()) -> String? {
        var name = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init).joined()

        if !style.unicode {
            name = plainLetters(name, germanSpelling: style.germanSpelling)
        }

        for unwanted in unwantedInNames {
            name = name.replacingOccurrences(of: unwanted, with: " ")
        }
        // Underscores are the model's habit, not a person's: asked for a plain
        // title it still answered "Minutes_of_Budget_Meeting_12_March".
        name = name.replacingOccurrences(of: "_", with: " ")
        // A word with no letter or digit in it -- "..", "--" -- is not part of
        // a name. It is what is left of a path somebody tried to smuggle in.
        name = name.split(whereSeparator: \.isWhitespace)
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
            .joined(separator: " ")

        // An extension the model added of its own accord; the caller decides
        // what kind of file this is, not the model.
        if let dot = name.lastIndex(of: "."),
           name.distance(from: dot, to: name.endIndex) <= 6,
           name[name.index(after: dot)...].allSatisfy({ $0.isLetter || $0.isNumber }),
           dot != name.startIndex {
            name = String(name[..<dot])
        }

        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))

        if name.count > longestName {
            let cut = name.prefix(longestName)
            name = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
        }
        guard !name.isEmpty else { return nil }

        if let separator = style.separator,
           isUsableSeparator(separator, unicode: style.unicode) {
            name = name.replacingOccurrences(of: " ", with: String(separator))
        }
        return name
    }

    /// Characters that have no place in a suggested name: path separators, and
    /// the ones that mean something to a shell or to another operating system.
    static let unwantedInNames: [String] =
        ["/", ":", "\\", "\"", "\u{201C}", "\u{201D}", "`", "*", "?", "<", ">", "|"]

    /// Whether a character can stand between the words of a name.
    ///
    /// Not white space, which is what it replaces; nothing that is refused in
    /// a name anyway; and plain ASCII when names are to be plain ASCII, since
    /// a separator is in every name and would break that promise every time.
    static func isUsableSeparator(_ character: Character, unicode: Bool) -> Bool {
        guard !character.isWhitespace, !character.isNewline,
              !unwantedInNames.contains(String(character)),
              !character.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) }) else { return false }
        return unicode || character.isASCII
    }

    /// The name in plain ASCII letters.
    ///
    /// Accents are dropped (ő and ó become o) and other alphabets are spelt in
    /// Latin ones (Москва becomes Moskva), by the same ICU transliteration the
    /// system uses. Anything with no spelling in ASCII at all -- an emoji -- is
    /// left out. German spelling, when asked for, goes first: the transliterator
    /// alone would write Übersicht as Ubersicht, which a German reader takes
    /// for a misspelling rather than a plainer one.
    static func plainLetters(_ text: String, germanSpelling: Bool) -> String {
        // Composed, so that an ü typed as u plus a combining mark is found too.
        var text = text.precomposedStringWithCanonicalMapping
        if germanSpelling { text = spelledInGerman(text) }
        text = text.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"),
                                      reverse: false) ?? text
        return String(String.UnicodeScalarView(text.unicodeScalars.filter(\.isASCII)))
    }

    /// Ä, Ö and Ü written out, as German does without them.
    ///
    /// Capital as the word is: Über becomes Ueber but ÜBER becomes UEBER.
    static func spelledInGerman(_ text: String) -> String {
        let spelled: [Character: String] = ["ä": "ae", "ö": "oe", "ü": "ue",
                                             "Ä": "Ae", "Ö": "Oe", "Ü": "Ue"]
        let characters = Array(text)
        var result = ""
        for (index, character) in characters.enumerated() {
            guard let spelling = spelled[character] else {
                result.append(character)
                continue
            }
            let neighbours = [index - 1, index + 1]
                .filter { characters.indices.contains($0) && characters[$0].isLetter }
            let shouting = character.isUppercase && !neighbours.isEmpty
                && neighbours.allSatisfy { characters[$0].isUppercase }
            result += shouting ? spelling.uppercased() : spelling
        }
        return result
    }
}

// MARK: - The model itself

@available(macOS 26, *)
private enum Model {

    /// The name as a list of words, not a string.
    ///
    /// Asked for a string in sentence case, the model ignored the description
    /// and answered with underscores, or with a single word -- "application"
    /// for a letter applying for a job. A list whose length the framework
    /// enforces cannot be one word, and joining it here cannot produce an
    /// underscore.
    ///
    /// The description defers to the instructions and says nothing of its own
    /// about what a good name is. It used to ("describing the content, most
    /// important first, like a document title"), and measured back to back on
    /// the same six samples that version took 8 to 17 seconds a name and
    /// overrode the instructions: told to start every name with "Scan", the
    /// model did not. Deferring, the same samples took 1 to 3 seconds, the
    /// instruction was followed, and the default names were as good. What a
    /// name should look like belongs in the instructions, which are the
    /// user's to change; this is compiled in and is not.
    @Generable
    struct Suggestion {
        @Guide(description: "The words of the file name, as the instructions ask.",
               .count(2...6))
        var words: [String]
    }

    /// A name and more, for New from Clipboard. The name comes first and is
    /// described exactly as `Suggestion`'s, so the instructions still decide
    /// it; the rest is about the content, which the instructions do not cover.
    @Generable
    struct Analysis {
        @Guide(description: "The words of the file name, as the instructions ask.",
               .count(2...6))
        var words: [String]
        @Guide(description: "What kind of content this is.",
               .anyOf(NameSuggester.contentTypeNames))
        var contentType: String
        @Guide(description: "One short sentence saying what the content is.")
        var summary: String
        @Guide(description: "Lowercase tags to file the content under, such as invoice, "
               + "bank transfer, photo or recipe.",
               .count(1...5))
        var tags: [String]
    }

    @Generable
    struct Caption {
        @Guide(description: "One short sentence saying what the photo shows.")
        var sentence: String
    }

    /// The system model, as for a name; nil on any refusal or failure, since
    /// a description is only offered, never needed.
    static func caption(of words: String) async -> String? {
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: "You write the description stored in a photo's EXIF data. From "
                + "what you are told the photo shows, write one short, plain sentence, as a "
                + "caption. Describe only what is listed; do not guess who people are, where "
                + "it was taken, or when.")
        do {
            let reply = try await session.respond(
                to: words, generating: Caption.self,
                options: GenerationOptions(samplingMode: .greedy))
            return reply.content.sentence
        } catch {
            return nil
        }
    }

    /// Both halves are the user's template, filled in: nothing is added to
    /// what they wrote, so what they read in the file is what the model gets.
    static func name(instructions: String, prompt: String) async -> NameSuggester.Outcome {
        await respond(instructions: instructions, prompt: prompt, generating: Suggestion.self) {
            .name($0.words.joined(separator: " "))
        }
    }

    /// The same question, with the content type, summary and tags as well.
    static func describe(instructions: String, prompt: String) async -> NameSuggester.Outcome {
        await respond(instructions: instructions, prompt: prompt, generating: Analysis.self) {
            .described(NameSuggester.Description(
                name: $0.words.joined(separator: " "), contentType: $0.contentType,
                summary: $0.summary, tags: $0.tags))
        }
    }

    private static func respond<Content: Generable>(
        instructions: String, prompt: String, generating type: Content.Type,
        making outcome: (Content) -> NameSuggester.Outcome
    ) async -> NameSuggester.Outcome {
        // The system model, by name. Never the Private Cloud Compute one.
        let session = instructions.isEmpty
            ? LanguageModelSession(model: SystemLanguageModel.default)
            : LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        do {
            let reply = try await session.respond(
                to: prompt,
                generating: type,
                // Greedy, so the same file is given the same name every time
                // rather than a different guess on each press.
                options: GenerationOptions(samplingMode: .greedy))
            return outcome(reply.content)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return .tooLong
            case .guardrailViolation, .refusal: return .declined
            case .unsupportedLanguageOrLocale: return .unsupportedLanguage
            default: return .failed(error.localizedDescription)
            }
        } catch {
            // macOS 27 reports the same refusals through a new error type:
            // asking for more than the model can read now arrives as
            // LanguageModelError.contextSizeExceeded, and without this it was
            // shown as an unexplained failure with Apple's wording instead of
            // "set fewer characters in Settings".
            if #available(macOS 27, *), let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded: return .tooLong
                case .guardrailViolation, .refusal: return .declined
                case .unsupportedLanguageOrLocale: return .unsupportedLanguage
                default: return .failed(error.localizedDescription)
                }
            }
            return .failed(error.localizedDescription)
        }
    }
}
