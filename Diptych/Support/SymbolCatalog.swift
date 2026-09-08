import AppKit

/// Symbols offered for a folder icon.
///
/// SF Symbols has thousands of names and no API that lists them, so this is a
/// hand-picked set in the shape Finder's own picker takes: a few categories of
/// things people actually label folders with. Anything not here can still be
/// typed by name -- the search field falls through to the live symbol lookup --
/// so the list is a convenience, never a limit.
///
/// Every name is checked against the running system at startup, because a
/// symbol added in a later SF Symbols release renders as nothing at all rather
/// than failing loudly.
enum SymbolCatalog {

    struct Group: Identifiable {
        let name: String
        let symbols: [String]
        var id: String { name }
    }

    static func exists(_ name: String) -> Bool {
        !name.isEmpty && NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    static let groups: [Group] = candidates
        .map { Group(name: $0.0, symbols: $0.1.filter(exists)) }
        .filter { !$0.symbols.isEmpty }

    /// Every symbol in the catalogue, for searching across groups.
    static let all: [String] = groups.flatMap(\.symbols)

    static func matches(_ query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return all }

        let hits = all.filter { $0.contains(trimmed) }
        // A name typed in full that is a real symbol but not one of ours still
        // counts -- that is how anything outside the catalogue gets chosen.
        if hits.isEmpty, exists(trimmed) { return [trimmed] }
        return hits
    }

    private static let candidates: [(String, [String])] = [
        ("Documents", [
            "folder", "tray", "tray.full", "archivebox", "shippingbox", "briefcase",
            "doc", "doc.text", "doc.richtext", "book", "books.vertical", "newspaper",
            "paperclip", "pencil", "highlighter", "note.text", "list.bullet", "checklist",
            "signature", "text.book.closed",
        ]),
        ("Marks", [
            "star", "heart", "flag", "bookmark", "tag", "bell", "bolt", "flame",
            "sparkles", "crown", "trophy", "medal", "rosette", "seal", "exclamationmark",
            "questionmark", "checkmark.seal", "xmark.seal",
        ]),
        ("Work", [
            "calendar", "clock", "timer", "hourglass", "chart.bar", "chart.pie",
            "chart.line.uptrend.xyaxis", "creditcard", "banknote", "cart", "bag",
            "building.2", "building.columns", "storefront", "graduationcap", "function",
        ]),
        ("Media", [
            "photo", "camera", "video", "film", "music.note", "headphones", "mic",
            "speaker.wave.2", "play.rectangle", "waveform", "paintbrush", "paintpalette",
            "theatermasks", "gamecontroller", "guitars", "ticket",
        ]),
        ("Making", [
            "hammer", "wrench.and.screwdriver", "gearshape", "terminal", "curlybraces",
            "chevron.left.forwardslash.chevron.right", "ladybug", "cpu", "memorychip",
            "server.rack", "externaldrive", "internaldrive", "opticaldisc", "network",
            "antenna.radiowaves.left.and.right", "wifi", "lock", "lock.shield", "key",
            "shield", "atom", "testtube.2", "scissors", "ruler", "compass.drawing",
        ]),
        ("People", [
            "person", "person.2", "person.3", "envelope", "paperplane", "bubble.left",
            "message", "phone", "at", "hand.raised", "hands.clap", "eye", "eyebrow",
            "brain.head.profile", "figure.walk", "figure.run",
        ]),
        ("Places", [
            "house", "map", "mappin", "globe", "airplane", "car", "bicycle", "bus",
            "tram", "ferry", "fuelpump", "sailboat", "tent", "mountain.2", "beach.umbrella",
        ]),
        ("Nature", [
            "leaf", "tree", "drop", "snowflake", "sun.max", "moon", "cloud", "wind",
            "tornado", "pawprint", "fish", "bird", "ant", "tortoise", "hare", "carrot",
            "cup.and.saucer", "fork.knife", "birthday.cake", "gift",
        ]),
        ("Shapes", [
            "circle", "square", "triangle", "diamond", "hexagon", "octagon", "capsule",
            "infinity", "number", "circle.grid.2x2", "square.grid.3x3", "wand.and.stars",
        ]),
    ]
}
