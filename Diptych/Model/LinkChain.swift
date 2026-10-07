import Foundation

/// A symbolic link followed to its end: through every link it leads to, until
/// something that is not a link, a name with nothing behind it, or a link
/// already passed.
///
/// One step at a time rather than `realpath`, which only says "it worked" or
/// "it did not": a link to a link to nothing and a link that ends up pointing
/// back at itself both fail, and they are different troubles to fix.
struct LinkChain: Hashable, Sendable {

    /// One link on the way: the link itself, and what it says, as stored.
    struct Step: Hashable, Sendable {
        let link: URL
        let destination: String
    }

    enum End: Hashable, Sendable {
        /// Something that is not a link: the file or folder the chain is for.
        case target(URL)
        /// A name the last link points to, with nothing there.
        case missing(URL)
        /// Back to a link already passed -- it would go round for ever.
        case loop(URL)
    }

    /// Every link followed, the first being the one the chain started from.
    let steps: [Step]
    let end: End

    /// The kernel gives up after 32 links (MAXSYMLINKS); so does this, as a
    /// loop, in case a loop slips past the comparison of names.
    static let mostSteps = 32

    /// `nil` when `link` is not a symbolic link.
    nonisolated static func follow(_ link: URL) -> LinkChain? {
        var steps: [Step] = []
        var seen: Set<String> = []
        // The link's own folder resolved, so that two spellings of one place
        // -- a relative hop up and back down -- count as the same link.
        var current = canonical(link) ?? link.standardizedFileURL

        while true {
            guard isLink(current) else {
                guard !steps.isEmpty else { return nil }
                return LinkChain(steps: steps,
                                 end: exists(current) ? .target(current) : .missing(current))
            }
            guard !seen.contains(current.path), steps.count < mostSteps else {
                return LinkChain(steps: steps, end: .loop(current))
            }
            seen.insert(current.path)
            guard let destination = try? FileManager.default
                    .destinationOfSymbolicLink(atPath: current.path) else {
                return steps.isEmpty ? nil : LinkChain(steps: steps, end: .missing(current))
            }
            steps.append(Step(link: current, destination: destination))

            let next = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : current.deletingLastPathComponent().appendingPathComponent(destination)
            // A folder on the way that is itself a link going round: reading
            // the name fails with ELOOP, and that is a loop too.
            if lstatError(next) == ELOOP { return LinkChain(steps: steps, end: .loop(next)) }
            current = canonical(next) ?? next.standardizedFileURL
        }
    }

    /// The links followed before the end: 1 for a link straight to its target.
    var length: Int { steps.count }

    /// Through more than one link, to something that is there.
    var finalTarget: URL? {
        guard case .target(let url) = end else { return nil }
        return url
    }

    /// How many links it takes to find a missing name, or `nil` if none is
    /// missing. 1 means the link itself points to nothing.
    var brokenAfter: Int? {
        guard case .missing = end else { return nil }
        return steps.count
    }

    /// For a loop, how many links can be followed before one comes round
    /// again: x5 -> x4 -> x3 -> x2 -> x1 -> x3 is 4, a link to itself 0.
    var stepsBeforeLoop: Int? {
        guard isLoop else { return nil }
        return max(steps.count - 1, 0)
    }

    var isLoop: Bool {
        if case .loop = end { return true }
        return false
    }

    // MARK: - Names

    /// The folder resolved, the last name kept as it is -- a link must stay the
    /// link, not become what it points to.
    private static func canonical(_ url: URL) -> URL? {
        let standard = url.standardizedFileURL
        let folder = standard.deletingLastPathComponent()
        guard let resolved = realpath(folder.path, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent(standard.lastPathComponent)
    }

    private static func isLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func lstatError(_ url: URL) -> Int32 {
        var info = stat()
        return lstat(url.path, &info) == 0 ? 0 : errno
    }
}
