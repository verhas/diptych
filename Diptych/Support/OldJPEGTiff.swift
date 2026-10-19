import Foundation
import ImageIO

/// TIFF files whose pages are "old-style JPEG", compression 6.
///
/// Scanners and Microsoft Office Document Imaging wrote them in the 1990s and
/// 2000s, and ImageIO has never decoded them: Quick Look shows the small
/// thumbnail stored beside each page and then nothing. Each page's directory
/// does say where a complete JPEG of it sits in the file -- the
/// `JPEGInterchangeFormat` tag -- so the pages can be taken out as they are,
/// without decoding the TIFF at all, and shown as JPEGs.
enum OldJPEGTiff {

    struct Page: Equatable, Sendable {
        let width: Int
        let height: Int
        let jpeg: Data
    }

    /// The largest file read: a page is a few hundred kilobytes.
    static let maximumSize = 200 << 20

    /// The pages, when the file is a TIFF with old-style JPEG pages; nil for
    /// any other file, which ImageIO shows well enough.
    static func pages(of data: Data) -> [Page]? {
        guard data.count > 8 else { return nil }
        let little: Bool
        switch (data[0], data[1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return nil
        }
        func integer(_ offset: Int, _ size: Int) -> Int? {
            guard offset >= 0, offset + size <= data.count else { return nil }
            var value = 0
            for index in 0..<size {
                let byte = Int(data[data.startIndex + offset + (little ? size - 1 - index : index)])
                value = value << 8 | byte
            }
            return value
        }
        guard integer(2, 2) == 42, var directory = integer(4, 4) else { return nil }

        var pages: [Page] = []
        var oldStyle = false
        var seen: Set<Int> = []
        while directory != 0, !seen.contains(directory), seen.count < 10_000 {
            seen.insert(directory)
            guard let count = integer(directory, 2) else { break }
            var tags: [Int: Int] = [:]
            for entry in 0..<count {
                let at = directory + 2 + entry * 12
                guard let tag = integer(at, 2), let type = integer(at + 2, 2) else { break }
                // SHORT values sit in the first two bytes of the field.
                let value = type == 3 ? integer(at + 8, 2) : integer(at + 8, 4)
                if let value { tags[tag] = value }
            }
            if tags[259] == 6 {
                oldStyle = true
                if let start = tags[513], let length = tags[514], length > 0,
                   start + length <= data.count {
                    let jpeg = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + length))
                    // Only a real JPEG: the tag is sometimes there and wrong.
                    if jpeg.starts(with: [0xFF, 0xD8]) {
                        pages.append(Page(width: tags[256] ?? 0, height: tags[257] ?? 0, jpeg: jpeg))
                    }
                }
            }
            guard let next = integer(directory + 2 + count * 12, 4) else { break }
            directory = next
        }
        return oldStyle && !pages.isEmpty ? pages : nil
    }

    /// The Quick Look page: every page of the file, one under the other.
    static func html(for pages: [Page], name: String, path: String) -> String {
        var body = "<h1>\(ListingReport.escape(name))</h1>"
        body += "<p class=lead>TIFF with old-style JPEG pages, "
            + (pages.count == 1 ? "1 page" : "\(pages.count) pages")
            + ". macOS cannot draw this kind of TIFF; the pages are shown from the JPEG "
            + "each one carries.</p>"
        body += "<p class=meta>\(ListingReport.escape(path))</p>"
        for (index, page) in pages.enumerated() {
            body += "<figure style=\"margin: 16px 0\">"
                + "<img style=\"max-width: 100%; height: auto; box-shadow: 0 1px 4px rgba(0,0,0,.3)\" "
                + "src=\"data:image/jpeg;base64,\(page.jpeg.base64EncodedString())\">"
                + "<figcaption class=meta>Page \(index + 1) of \(pages.count) \u{2014} "
                + "\(page.width) \u{00D7} \(page.height)</figcaption></figure>"
        }
        return ListingReport.page(title: name, body: body)
    }
}
