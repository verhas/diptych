import Foundation
import ImageIO
import PDFKit
import AVFoundation
import CoreServices
import CoreMedia

/// What is written *inside* a file about itself: a photograph's EXIF, a PDF's
/// title and page count, a film's length and picture size, and whatever
/// Spotlight knows about everything else.
///
/// Read-only, deliberately. Reading this is free and safe; writing it is not.
/// Every one of these formats stores its metadata inside the file, so changing
/// a field means rewriting the file -- re-encoding a JPEG, or unzipping and
/// rezipping an Office document -- and a file manager that quietly re-encodes
/// somebody's photograph to correct a date has done more harm than the typo.
///
/// Each reader is asked only about the kinds of file it understands, and a
/// reader that finds nothing is left out rather than shown empty.
enum FormatDetails {

    struct Row: Identifiable, Sendable, Equatable {
        let name: String
        let value: String
        var id: String { name }
    }

    struct Section: Identifiable, Sendable, Equatable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    struct Report: Sendable, Equatable {
        var sections: [Section] = []
        /// Said when there is nothing: which is an answer, not a failure.
        var nothing: String?
        var isEmpty: Bool { sections.isEmpty }
    }

    /// Longest value worth showing. A field is a fact, not a document; an EXIF
    /// maker note can be kilobytes of binary.
    static let longestValue = 300

    /// How long the whole lot may take. Reading a film's tracks can reach for
    /// the file itself, and the Info window must not wait on a slow disk.
    static let patience: TimeInterval = 5

    static func read(_ url: URL) async -> Report {
        let answer = await withTaskGroup(of: Report?.self) { group in
            group.addTask { await gather(url) }
            group.addTask {
                try? await Task.sleep(for: .seconds(patience))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard var report = answer else {
            return Report(nothing: "Reading this file's own attributes took too long, so it "
                          + "was stopped.")
        }
        if report.isEmpty {
            report.nothing = "Nothing inside this file describes itself, and Spotlight has "
                + "nothing about it either."
        }
        return report
    }

    private static func gather(_ url: URL) async -> Report {
        var report = Report()
        report.sections += await BlockingWork.run { image(url) + pdf(url) }
        report.sections += await media(url)
        // Spotlight last, and only when nothing else answered: for a photograph
        // it would repeat in worse words what EXIF already said.
        if report.sections.isEmpty {
            report.sections += await BlockingWork.run { spotlight(url) }
        }
        return report
    }

    // MARK: - Pictures

    /// Every dictionary ImageIO offers, in the order somebody reads them.
    private static var imageDictionaries: [(CFString, String)] { [
        (kCGImagePropertyExifDictionary, "EXIF"),
        (kCGImagePropertyGPSDictionary, "Location (GPS)"),
        (kCGImagePropertyTIFFDictionary, "TIFF"),
        (kCGImagePropertyIPTCDictionary, "IPTC"),
        (kCGImagePropertyExifAuxDictionary, "EXIF (auxiliary)"),
        (kCGImagePropertyPNGDictionary, "PNG"),
        (kCGImagePropertyGIFDictionary, "GIF"),
        (kCGImagePropertyHEICSDictionary, "HEIC"),
    ] }

    nonisolated static func image(_ url: URL) -> [Section] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any] else { return [] }

        var sections: [Section] = []
        // The picture itself: size, resolution, colour, orientation.
        let plain = properties.filter { !($0.value is [CFString: Any]) && !($0.value is [String: Any]) }
        if let rows = rows(from: plain), !rows.isEmpty {
            sections.append(Section(title: "Picture", rows: rows))
        }
        for (key, title) in imageDictionaries {
            guard let nested = properties[key] as? [CFString: Any],
                  let rows = rows(from: nested), !rows.isEmpty else { continue }
            sections.append(Section(title: title, rows: rows))
        }
        return sections
    }

    // MARK: - PDF

    nonisolated static func pdf(_ url: URL) -> [Section] {
        guard url.pathExtension.lowercased() == "pdf",
              let document = PDFDocument(url: url) else { return [] }

        var rows: [Row] = []
        for (key, value) in document.documentAttributes ?? [:] {
            let name = (key as? String) ?? "\(key)"
            if let text = describe(value) {
                rows.append(Row(name: prettify(name), value: text))
            }
        }
        rows.sort { $0.name < $1.name }

        var about: [Row] = [Row(name: "Pages", value: "\(document.pageCount)")]
        if let page = document.page(at: 0) {
            let box = page.bounds(for: .mediaBox)
            // Points, as PDF measures, and the millimetres anybody thinks in.
            let width = box.width / 72 * 25.4
            let height = box.height / 72 * 25.4
            about.append(Row(name: "First page",
                             value: String(format: "%.0f \u{00D7} %.0f pt (%.0f \u{00D7} %.0f mm)",
                                           box.width, box.height, width, height)))
        }
        about.append(Row(name: "PDF version",
                         value: "\(document.majorVersion).\(document.minorVersion)"))
        about.append(Row(name: "Encrypted", value: document.isEncrypted ? "Yes" : "No"))
        if document.isEncrypted {
            about.append(Row(name: "Unlocked", value: document.isLocked ? "No" : "Yes"))
        }
        about.append(Row(name: "Printing allowed", value: document.allowsPrinting ? "Yes" : "No"))
        about.append(Row(name: "Copying allowed", value: document.allowsCopying ? "Yes" : "No"))

        var sections = [Section(title: "PDF", rows: about)]
        if !rows.isEmpty { sections.append(Section(title: "PDF document", rows: rows)) }
        return sections
    }

    // MARK: - Sound and film

    static func media(_ url: URL) async -> [Section] {
        guard let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .audiovisualContent) else { return [] }

        let asset = AVURLAsset(url: url)
        var rows: [Row] = []

        if let duration = try? await asset.load(.duration), duration.isNumeric {
            rows.append(Row(name: "Duration", value: length(of: duration.seconds)))
        }

        if let tracks = try? await asset.loadTracks(withMediaType: .video) {
            for (index, track) in tracks.enumerated() {
                let label = tracks.count == 1 ? "Picture" : "Picture \(index + 1)"
                if let size = try? await track.load(.naturalSize) {
                    rows.append(Row(name: label,
                                    value: "\(Int(size.width)) \u{00D7} \(Int(size.height))"))
                }
                if let rate = try? await track.load(.nominalFrameRate), rate > 0 {
                    rows.append(Row(name: "\(label) frame rate",
                                    value: String(format: "%.2f per second", rate)))
                }
                if let formats = try? await track.load(.formatDescriptions),
                   let first = formats.first {
                    rows.append(Row(name: "\(label) format", value: fourCharacters(first)))
                }
            }
        }

        if let tracks = try? await asset.loadTracks(withMediaType: .audio) {
            for (index, track) in tracks.enumerated() {
                let label = tracks.count == 1 ? "Sound" : "Sound \(index + 1)"
                if let formats = try? await track.load(.formatDescriptions),
                   let first = formats.first {
                    rows.append(Row(name: "\(label) format", value: fourCharacters(first)))
                    if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(first) {
                        rows.append(Row(name: "\(label) sample rate",
                                        value: "\(Int(basic.pointee.mSampleRate)) Hz"))
                        rows.append(Row(name: "\(label) channels",
                                        value: "\(basic.pointee.mChannelsPerFrame)"))
                    }
                }
            }
        }

        var written: [Row] = []
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey?.rawValue,
                      let value = try? await item.load(.stringValue) ?? nil,
                      let text = describe(value) else { continue }
                written.append(Row(name: prettify(key), value: text))
            }
        }

        var sections: [Section] = []
        if !rows.isEmpty { sections.append(Section(title: "Sound and film", rows: rows)) }
        if !written.isEmpty {
            sections.append(Section(title: "Written in the file",
                                    rows: written.sorted { $0.name < $1.name }))
        }
        return sections
    }

    private static func length(of seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "unknown" }
        let whole = Int(seconds.rounded())
        let hours = whole / 3600, minutes = (whole % 3600) / 60, rest = whole % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest)
                         : String(format: "%d:%02d", minutes, rest)
    }

    private static func fourCharacters(_ format: CMFormatDescription) -> String {
        let code = CMFormatDescriptionGetMediaSubType(format)
        let characters = [24, 16, 8, 0].map { shift -> Character in
            let byte = UInt8((code >> UInt32(shift)) & 0xFF)
            let scalar = UnicodeScalar(byte)
            return byte >= 32 && byte < 127 ? Character(scalar) : "?"
        }
        return String(characters)
    }

    // MARK: - Whatever Spotlight knows

    /// For the formats nothing here parses -- a Word file, a spreadsheet, a
    /// presentation. Spotlight has already read them, so there is no reason to
    /// unzip anything. It answers nothing when the volume is not indexed, and
    /// the tab says so rather than pretending the file has no attributes.
    private static var spotlightKeys: [(CFString, String)] { [
        (kMDItemKind, "Kind"),
        (kMDItemContentType, "Content type"),
        (kMDItemTitle, "Title"),
        (kMDItemAuthors, "Authors"),
        (kMDItemCreator, "Created with"),
        (kMDItemEncodingApplications, "Written by"),
        (kMDItemSubject, "Subject"),
        (kMDItemDescription, "Description"),
        (kMDItemComment, "Comment"),
        (kMDItemCopyright, "Copyright"),
        (kMDItemKeywords, "Keywords"),
        (kMDItemNumberOfPages, "Pages"),
        (kMDItemPageWidth, "Page width"),
        (kMDItemPageHeight, "Page height"),
        (kMDItemLanguages, "Languages"),
        (kMDItemContentCreationDate, "Content created"),
        (kMDItemContentModificationDate, "Content changed"),
        (kMDItemDurationSeconds, "Duration in seconds"),
        (kMDItemPixelWidth, "Width in pixels"),
        (kMDItemPixelHeight, "Height in pixels"),
        (kMDItemWhereFroms, "Came from"),
    ] }

    nonisolated static func spotlight(_ url: URL) -> [Section] {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return [] }
        var rows: [Row] = []
        for (key, name) in spotlightKeys {
            guard let value = MDItemCopyAttribute(item, key),
                  let text = describe(value) else { continue }
            rows.append(Row(name: name, value: text))
        }
        return rows.isEmpty ? [] : [Section(title: "Spotlight", rows: rows)]
    }

    // MARK: - Turning values into text

    static func rows(from dictionary: [CFString: Any]) -> [Row]? {
        var rows: [Row] = []
        for (key, value) in dictionary {
            guard let text = describe(value) else { continue }
            rows.append(Row(name: prettify(key as String), value: text))
        }
        return rows.sorted { $0.name < $1.name }
    }

    /// Nil for anything that is not worth a line: binary, empty, or longer
    /// than a fact.
    static func describe(_ value: Any) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(longestValue))
        case let number as NSNumber:
            // Booleans arrive as numbers and read badly as 0 and 1.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "Yes" : "No"
            }
            return number.stringValue
        case let date as Date:
            return date.formatted(date: .abbreviated, time: .standard)
        case let list as [Any]:
            let parts = list.compactMap { describe($0) }
            return parts.isEmpty ? nil : String(parts.joined(separator: ", ").prefix(longestValue))
        case is Data:
            return nil
        default:
            return nil
        }
    }

    /// `ISOSpeedRatings` reads as `ISO speed ratings`: a word starts at a
    /// capital that follows a small letter, or at the last capital of a run
    /// before a small one -- so an abbreviation stays whole. Only the first
    /// word keeps its capital; an abbreviation keeps all of them.
    static func prettify(_ key: String) -> String {
        let characters = Array(key)
        var words: [String] = []
        var current = ""

        for (index, character) in characters.enumerated() {
            if character == "_" || character == " " {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let startsWord = character.isUppercase
                && (previous?.isLowercase == true
                    || (previous?.isUppercase == true && next?.isLowercase == true))
            if startsWord, !current.isEmpty {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        guard !words.isEmpty else { return key }

        let joined = words.enumerated().map { index, word -> String in
            let abbreviation = word.count > 1 && word.allSatisfy { !$0.isLowercase }
            return index == 0 || abbreviation ? word : word.lowercased()
        }.joined(separator: " ")
        return joined
    }
}
