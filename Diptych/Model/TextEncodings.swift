import Foundation

/// What a text file's bytes are in, worked out the same way everywhere a file
/// is read as text: Text Edit, comparisons, Quick Look and the conversion
/// windows.
///
/// In order, and the first that answers wins:
/// 1. a byte-order mark -- which also lets a UTF-16 or UTF-32 file through,
///    though it is full of NUL bytes;
/// 2. NUL bytes early on: UTF-16 or UTF-32 without a mark when they fall in
///    that pattern -- every other byte, or three in four -- and the text reads
///    cleanly so; otherwise not text at all;
/// 3. UTF-8, when every byte is valid UTF-8 (plain ASCII is);
/// 4. the encoding the file says it is in, in its `com.apple.TextEncoding`
///    attribute, as TextEdit records it;
/// 5. once there are enough bytes beyond ASCII to tell, the system's
///    statistical guess among the encodings text on a Mac is commonly in --
///    taken only when the bytes really are valid in it and the text reads as
///    well as in any other; otherwise the encoding in which the text reads
///    best: letters inside words, no control characters, no symbols in the
///    middle of a word, no word mixing Latin, Greek and Cyrillic;
/// 6. the caller's fallback, for a file too short to tell.
enum TextEncodings {

    /// The answer: the encoding, and how many bytes at the start are a
    /// byte-order mark rather than text.
    struct Reading: Equatable, Sendable {
        var encoding: String.Encoding
        var bomLength: Int = 0
        /// Worked out by the statistics, or by the fallback -- shown as a guess.
        var guessed = false

        var hasBOM: Bool { bomLength > 0 }
    }

    /// Bytes beyond ASCII needed before the statistics are trusted: a single
    /// accented letter fits a dozen encodings equally well.
    static let enoughForAGuess = 8

    // MARK: - Byte-order marks

    /// The byte-order mark `data` starts with, if any. UTF-32 LE is looked for
    /// before UTF-16 LE, whose mark is its first half.
    static func bom(of data: Data) -> Reading? {
        let head = [UInt8](data.prefix(4))
        func starts(_ bytes: [UInt8]) -> Bool { head.starts(with: bytes) }
        if starts([0xEF, 0xBB, 0xBF]) { return Reading(encoding: .utf8, bomLength: 3) }
        if starts([0xFF, 0xFE, 0x00, 0x00]) { return Reading(encoding: .utf32LittleEndian, bomLength: 4) }
        if starts([0x00, 0x00, 0xFE, 0xFF]) { return Reading(encoding: .utf32BigEndian, bomLength: 4) }
        if starts([0xFF, 0xFE]) { return Reading(encoding: .utf16LittleEndian, bomLength: 2) }
        if starts([0xFE, 0xFF]) { return Reading(encoding: .utf16BigEndian, bomLength: 2) }
        return nil
    }

    /// The mark written at the start of a file in `encoding`, or nothing for
    /// an encoding that has none.
    static func bomBytes(for encoding: String.Encoding) -> Data {
        switch encoding {
        case .utf8: Data([0xEF, 0xBB, 0xBF])
        case .utf16LittleEndian: Data([0xFF, 0xFE])
        case .utf16BigEndian, .utf16: Data([0xFE, 0xFF])
        case .utf32LittleEndian: Data([0xFF, 0xFE, 0x00, 0x00])
        case .utf32BigEndian, .utf32: Data([0x00, 0x00, 0xFE, 0xFF])
        default: Data()
        }
    }

    static func isUnicode(_ encoding: String.Encoding) -> Bool {
        [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian,
         .utf32, .utf32LittleEndian, .utf32BigEndian].contains(encoding)
    }

    // MARK: - Reading

    /// What `data` is in, or nil when it is not text. `url` is where it came
    /// from, for the attribute that may name its encoding.
    static func reading(of data: Data, at url: URL? = nil,
                        fallback: String.Encoding) -> Reading? {
        if let marked = bom(of: data) { return marked }
        if data.prefix(8000).contains(0) {
            return unmarkedWide(data).map { Reading(encoding: $0, guessed: true) }
        }
        if String(data: data, encoding: .utf8) != nil {
            // Seven-bit, so valid UTF-8 -- but its escapes switch to Japanese.
            if isISO2022JP(data) { return Reading(encoding: .iso2022JP, guessed: true) }
            return Reading(encoding: .utf8)
        }
        if let url, let recorded = recordedEncoding(of: url),
           String(data: data, encoding: recorded) != nil {
            return Reading(encoding: recorded)
        }
        if data.lazy.filter({ $0 >= 0x80 }).count >= enoughForAGuess,
           let guessed = bestReading(data) {
            return Reading(encoding: guessed, guessed: true)
        }
        return Reading(encoding: fallback, guessed: true)
    }

    /// The text of `data` in `reading`, its mark left out. Nil when the bytes
    /// are not valid in that encoding.
    static func decode(_ data: Data, _ reading: Reading) -> String? {
        String(data: data.dropFirst(reading.bomLength), encoding: reading.encoding)
    }

    /// Read as text -- or, in an encoding where it is not valid (UTF-8 as a
    /// last resort for a short file), with the bytes that do not fit shown as
    /// replacement characters. For looking at, never for writing back.
    static func decodeForShowing(_ data: Data, _ reading: Reading) -> String {
        if let text = decode(data, reading) { return text }
        return String(decoding: data.dropFirst(reading.bomLength), as: UTF8.self)
    }

    /// `text` as bytes in `encoding`, the mark first when asked. Nil when a
    /// character has no place in that encoding: nothing is ever replaced.
    static func encode(_ text: String, _ encoding: String.Encoding, bom: Bool) -> Data? {
        guard let body = text.data(using: encoding, allowLossyConversion: false) else { return nil }
        // Foundation's own `.utf16` and `.utf32` put a mark in by themselves.
        let own = [String.Encoding.utf16, .utf32].contains(encoding)
        if own { return bom ? body : body.dropFirst(bomBytes(for: encoding).count) }
        return bom ? bomBytes(for: encoding) + body : body
    }

    /// The characters of `text` that `encoding` cannot hold.
    static func unrepresentable(in text: String, _ encoding: String.Encoding) -> Int {
        if isUnicode(encoding) { return 0 }
        var count = 0
        for character in text where String(character).data(using: encoding,
                                                            allowLossyConversion: false) == nil {
            count += 1
        }
        return count
    }

    /// The encoding TextEdit and others record in an attribute, as
    /// `name;CFStringEncoding`.
    static func recordedEncoding(of url: URL) -> String.Encoding? {
        let name = "com.apple.TextEncoding"
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, name, &bytes, size, 0, 0) == size,
              let value = String(bytes: bytes, encoding: .utf8),
              let number = value.split(separator: ";").last.flatMap({ UInt32($0) }) else { return nil }
        let encoding = CFStringConvertEncodingToNSStringEncoding(number)
        guard encoding != UInt(kCFStringEncodingInvalidId) else { return nil }
        return String.Encoding(rawValue: encoding)
    }

    /// The recorded encoding made `encoding`, when the file has one recorded:
    /// after a conversion the old one would be wrong. None is added.
    static func updateRecorded(_ encoding: String.Encoding, on url: URL) {
        let name = "com.apple.TextEncoding"
        guard getxattr(url.path, name, nil, 0, 0, 0) > 0 else { return }
        let cf = CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)
        let iana = (CFStringConvertEncodingToIANACharSetName(cf) as String?) ?? ""
        let value = Array("\(iana);\(cf)".utf8)
        setxattr(url.path, name, value, value.count, 0, 0)
    }

    /// The escapes ISO-2022-JP switches into JIS X 0208 with, and back.
    static func isISO2022JP(_ data: Data) -> Bool {
        let escapes: [[UInt8]] = [[0x1B, 0x24, 0x42], [0x1B, 0x24, 0x40]]
        let bytes = [UInt8](data.prefix(64 * 1024))
        guard bytes.contains(0x1B),
              escapes.contains(where: { escape in
                  bytes.indices.contains { bytes[$0...].starts(with: escape) } }) else { return false }
        return String(data: data, encoding: .iso2022JP) != nil
    }

    // MARK: - UTF-16 and UTF-32 without a mark

    /// UTF-16 or UTF-32 by where the NUL bytes fall, for text mostly in the
    /// first 256 characters of Unicode -- Latin, and Greek and Cyrillic too,
    /// whose high byte is 03 or 04 but whose ASCII spaces and digits put NULs
    /// in place. Chinese or Japanese has too few NULs to be told this way.
    static func unmarkedWide(_ data: Data) -> String.Encoding? {
        let sample = [UInt8](data.prefix(8000))
        func share(_ positions: StrideTo<Int>, _ test: (Int) -> Bool) -> Double {
            let all = Array(positions)
            return all.isEmpty ? 0 : Double(all.filter(test).count) / Double(all.count)
        }
        var candidates: [String.Encoding] = []
        if data.count % 4 == 0, sample.count >= 4 {
            let groups = stride(from: 0, to: sample.count - 3, by: 4)
            if share(groups, { sample[$0] == 0 && sample[$0 + 1] == 0 && sample[$0 + 3] != 0 }) >= 0.9 {
                candidates.append(.utf32BigEndian)
            }
            if share(groups, { sample[$0 + 3] == 0 && sample[$0 + 2] == 0 && sample[$0] != 0 }) >= 0.9 {
                candidates.append(.utf32LittleEndian)
            }
        }
        if data.count % 2 == 0, sample.count >= 2 {
            let even = stride(from: 0, to: sample.count - 1, by: 2)
            let odd = stride(from: 1, to: sample.count, by: 2)
            let evenNul = share(even) { sample[$0] == 0 }
            let oddNul = share(odd) { sample[$0] == 0 }
            if evenNul >= 0.3, oddNul <= 0.02 { candidates.append(.utf16BigEndian) }
            if oddNul >= 0.3, evenNul <= 0.02 { candidates.append(.utf16LittleEndian) }
        }
        return candidates.first { encoding in
            guard let text = String(data: data, encoding: encoding) else { return false }
            return controlShare(text) < 0.02
        }
    }

    /// Of the characters, the share that are control characters other than
    /// tab and the line endings: a text has next to none.
    private static func controlShare(_ text: String) -> Double {
        var count = 0
        var controls = 0
        for scalar in text.unicodeScalars.prefix(8000) {
            count += 1
            if isControl(scalar) { controls += 1 }
        }
        return count == 0 ? 0 : Double(controls) / Double(count)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value == 0x09 || value == 0x0A || value == 0x0D || value == 0x85 { return false }
        return value < 0x20 || (0x7F...0x9F).contains(value)
    }

    // MARK: - Guessing a single- or multi-byte encoding

    /// The encoding `data` reads best in. The system's guess wins when the
    /// bytes are valid in it and its text reads nearly as well as the best:
    /// its statistics tell Latin-1 from Latin-2, and one Chinese, Japanese or
    /// Korean encoding from another, where a reading cannot -- each gives
    /// letters. It is not taken when it does not decode -- for a DOS file it
    /// can answer an encoding the bytes are not even valid in -- nor when its
    /// text reads clearly worse, as KOI8-R read as ISO Cyrillic does.
    static func bestReading(_ data: Data) -> String.Encoding? {
        let sample = data.prefix(64 * 1024)
        let scored = singleAndMultiByte.compactMap { encoding -> (String.Encoding, Double)? in
            guard let text = decodePrefix(sample, encoding, whole: sample.count == data.count) else {
                return nil
            }
            return (encoding, plausibility(text))
        }
        // The first of the best, in the list's order: the more common first.
        guard let best = scored.max(by: { $0.1 < $1.1 }) else { return nil }
        let top = scored.first { $0.1 >= best.1 - 0.001 }!
        if let guessed = statisticalGuess(data),
           let mine = scored.first(where: { $0.0 == guessed }), mine.1 >= best.1 - Self.guessMargin,
           String(data: data, encoding: guessed) != nil {
            return guessed
        }
        // The whole file has to be valid in it too, not only the sample.
        if sample.count == data.count || String(data: data, encoding: top.0) != nil { return top.0 }
        return scored.sorted { $0.1 > $1.1 }.first { String(data: data, encoding: $0.0) != nil }?.0
    }

    /// How much worse than the best the system's guess may read and still be
    /// taken.
    static let guessMargin = 0.5

    /// A sample cut off mid-character is let off its last few bytes.
    private static func decodePrefix(_ sample: Data, _ encoding: String.Encoding, whole: Bool) -> String? {
        for cut in 0...(whole ? 0 : 3) where sample.count > cut {
            if let text = String(data: sample.dropLast(cut), encoding: encoding) { return text }
        }
        return nil
    }

    private enum Script { case latin, greek, cyrillic, other }

    private static func script(of scalar: Unicode.Scalar) -> Script {
        switch scalar.value {
        case 0...0x024F, 0x1E00...0x1EFF: .latin
        case 0x0370...0x03FF, 0x1F00...0x1FFF: .greek
        case 0x0400...0x052F: .cyrillic
        default: .other
        }
    }

    /// How much the characters beyond ASCII read like text, per character:
    /// a letter in a word +2, a letter alone 0 -- no likelier than a symbol
    /// alone, as `€` read as `Ř` would be; a control character -5; a
    /// symbol between two letters -2; -3 for a letter next to one of another
    /// script; and -3 for a capital straight after a small letter, which the
    /// wrong encoding makes of an accented letter -- "GrŁŖe", "cafÄ", "ИдРЛ".
    static func plausibility(_ text: String) -> Double {
        let scalars = Array(text.unicodeScalars.prefix(20_000))
        func isLetter(_ index: Int) -> Bool {
            scalars.indices.contains(index) && scalars[index].properties.isAlphabetic
        }
        var score = 0.0
        var count = 0
        for (index, scalar) in scalars.enumerated() where !scalar.isASCII {
            count += 1
            let before = isLetter(index - 1)
            let after = isLetter(index + 1)
            if isControl(scalar) {
                score -= 5
            } else if scalar.properties.isAlphabetic {
                score += before || after ? 2 : 0
                let mine = script(of: scalar)
                if mine != .other,
                   [index - 1, index + 1].contains(where: { isLetter($0)
                       && script(of: scalars[$0]) != .other && script(of: scalars[$0]) != mine }) {
                    score -= 3
                }
                if scalar.properties.isUppercase, index > 0, scalars[index - 1].properties.isLowercase {
                    score -= 3
                }
                if scalar.properties.isLowercase, after, scalars[index + 1].properties.isUppercase,
                   scalars[index + 1].isASCII {
                    score -= 3
                }
            } else if before && after {
                score -= 2
            }
        }
        return count == 0 ? 0 : score / Double(count)
    }

    private static func statisticalGuess(_ data: Data) -> String.Encoding? {
        var converted: NSString?
        var lossy: ObjCBool = false
        let suggested = singleAndMultiByte.map { NSNumber(value: $0.rawValue) }
        let raw = NSString.stringEncoding(for: data, encodingOptions: [
            .allowLossyKey: false,
            .suggestedEncodingsKey: suggested,
            .useOnlySuggestedEncodingsKey: true,
        ], convertedString: &converted, usedLossyConversion: &lossy)
        guard raw != 0, !lossy.boolValue else { return nil }
        return String.Encoding(rawValue: raw)
    }

    // MARK: - The encodings offered

    private static func cf(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(encoding.rawValue)))
    }

    /// The encodings other than Unicode that text on a Mac is commonly in --
    /// what the guess picks from, and what the windows offer.
    static let singleAndMultiByte: [String.Encoding] = [
        .windowsCP1252, .isoLatin1, cf(.isoLatin9), .macOSRoman,
        .isoLatin2, .windowsCP1250, cf(.macCentralEurRoman),
        .windowsCP1251, cf(.isoLatinCyrillic), cf(.KOI8_R), cf(.KOI8_U), cf(.macCyrillic),
        .windowsCP1253, cf(.isoLatinGreek),
        .windowsCP1254, cf(.isoLatin5),
        cf(.windowsBalticRim), cf(.isoLatin4), cf(.isoLatin7),
        cf(.windowsHebrew), cf(.isoLatinHebrew), cf(.windowsArabic), cf(.isoLatinArabic),
        cf(.dosLatin1), cf(.dosLatinUS), cf(.dosLatin2), cf(.dosRussian),
        .shiftJIS, .japaneseEUC, .iso2022JP,
        cf(.GB_18030_2000), cf(.big5), cf(.EUC_KR),
        cf(.EBCDIC_CP037),
    ]

    /// Unicode, each byte order spelled out: a UTF-16 file without a mark has
    /// to say which it is.
    static let unicode: [String.Encoding] = [
        .utf8, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian,
    ]

    static let offered: [String.Encoding] = unicode + singleAndMultiByte

    static func name(of encoding: String.Encoding) -> String {
        switch encoding {
        case .utf8: "UTF-8"
        case .utf16LittleEndian: "UTF-16 LE"
        case .utf16BigEndian: "UTF-16 BE"
        case .utf16: "UTF-16"
        case .utf32LittleEndian: "UTF-32 LE"
        case .utf32BigEndian: "UTF-32 BE"
        case .utf32: "UTF-32"
        default: String.localizedName(of: encoding)
        }
    }
}
