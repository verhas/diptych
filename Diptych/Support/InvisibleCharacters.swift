import Foundation

/// Characters that show nothing, or act instead of showing: control codes, a
/// byte-order mark, zero-width spaces and joiners, the marks and overrides
/// that turn text right to left, line and paragraph separators. Text Edit can
/// show each as its name in a frame, in place, where it neither acts nor hides:
/// a byte-order mark can then be seen and deleted, and a right-to-left
/// override no longer reverses what follows it.
nonisolated enum InvisibleCharacters {

    /// Tab and line feed are what text is made of; everything else here is not.
    static func isInvisible(_ value: UInt32) -> Bool {
        if value == 0x09 || value == 0x0A { return false }
        if value < 0x20 || value == 0x7F || (0x80...0x9F).contains(value) { return true }
        if value == 0x2028 || value == 0x2029 { return true }
        guard let scalar = Unicode.Scalar(value) else { return false }
        return scalar.properties.generalCategory == .format
    }

    /// The characters that change the direction of the text around them.
    static func isDirectionControl(_ value: UInt32) -> Bool {
        [0x061C, 0x200E, 0x200F].contains(value) || (0x202A...0x202E).contains(value)
            || (0x2066...0x2069).contains(value)
    }

    /// Where each invisible character is in `text`, and its scalar.
    static func positions(in text: NSString, range: NSRange? = nil) -> [(location: Int, value: UInt32)] {
        let range = range ?? NSRange(location: 0, length: text.length)
        var found: [(Int, UInt32)] = []
        var index = range.location
        let end = NSMaxRange(range)
        while index < end {
            let unit = text.character(at: index)
            var value = UInt32(unit)
            var width = 1
            if UTF16.isLeadSurrogate(unit), index + 1 < text.length {
                let next = text.character(at: index + 1)
                if UTF16.isTrailSurrogate(next) {
                    value = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(next) - 0xDC00)
                    width = 2
                }
            }
            if isInvisible(value) { found.append((index, value)) }
            index += width
        }
        return found
    }

    /// How many there are, and whether any of them changes the direction.
    static func summary(of text: NSString) -> (count: Int, directional: Bool) {
        let all = positions(in: text)
        return (all.count, all.contains { isDirectionControl($0.value) })
    }

    /// The name shown in the frame: the usual abbreviation, or the code.
    static func label(_ value: UInt32, atStart: Bool = false) -> String {
        let controls = ["NUL", "SOH", "STX", "ETX", "EOT", "ENQ", "ACK", "BEL", "BS", "TAB", "LF", "VT", "FF",
                        "CR", "SO", "SI", "DLE", "DC1", "DC2", "DC3", "DC4", "NAK", "SYN", "ETB", "CAN", "EM",
                        "SUB", "ESC", "FS", "GS", "RS", "US"]
        if value < 0x20 { return controls[Int(value)] }
        let named: [UInt32: String] = [
            0x7F: "DEL", 0x85: "NEL", 0xAD: "SHY", 0x061C: "ALM", 0x180E: "MVS",
            0x200B: "ZWSP", 0x200C: "ZWNJ", 0x200D: "ZWJ", 0x200E: "LRM", 0x200F: "RLM",
            0x2028: "LSEP", 0x2029: "PSEP",
            0x202A: "LRE", 0x202B: "RLE", 0x202C: "PDF", 0x202D: "LRO", 0x202E: "RLO",
            0x2060: "WJ", 0x2061: "FA", 0x2062: "IT", 0x2063: "IS", 0x2064: "IP",
            0x2066: "LRI", 0x2067: "RLI", 0x2068: "FSI", 0x2069: "PDI",
        ]
        if value == 0xFEFF { return atStart ? "BOM" : "ZWNBSP" }
        if let name = named[value] { return name }
        return String(format: value > 0xFFFF ? "U+%05X" : "U+%04X", value)
    }

    /// What it is, in words, for the help tag.
    static func description(_ value: UInt32, atStart: Bool = false) -> String {
        switch value {
        case 0xFEFF where atStart: "byte-order mark"
        case 0xFEFF: "zero-width no-break space"
        case 0x200B: "zero-width space"
        case 0x202E: "right-to-left override"
        case 0x202D: "left-to-right override"
        case 0x2028: "line separator"
        case 0x2029: "paragraph separator"
        case 0x0D: "carriage return"
        case 0x00: "null"
        case 0x1B: "escape"
        default: label(value, atStart: atStart)
        }
    }
}
