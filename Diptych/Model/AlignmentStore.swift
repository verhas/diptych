import Foundation

/// How the right file of a pair lies best over the left, page by page, found
/// once and kept for as long as the app runs: by the comparison in the diff
/// window and by the Visual Preview, whichever gets there first, so neither
/// looks again for what the other found.
///
/// A fit is kept with the files' sizes and modification dates; a file saved
/// since is a file the fit no longer holds for. Of two fits for one page, the
/// one found on the finer picture is kept.
@MainActor
final class AlignmentStore {

    static let shared = AlignmentStore()

    private struct Key: Hashable {
        var left: String
        var right: String
        var page: Int
        var stamp: String
    }

    private var fits: [Key: ImageAlignment.Fit] = [:]

    func fit(_ pair: DiffPair, page: Int) -> ImageAlignment.Fit? {
        fits[Self.key(pair, page)]
    }

    /// The fits known for the first `pages` pages, by page.
    func fits(_ pair: DiffPair, pages: Int) -> [Int: ImageAlignment.Fit] {
        var known: [Int: ImageAlignment.Fit] = [:]
        for page in 0..<max(pages, 0) {
            if let fit = fit(pair, page: page) { known[page] = fit }
        }
        return known
    }

    func store(_ fit: ImageAlignment.Fit, _ pair: DiffPair, page: Int) {
        let key = Self.key(pair, page)
        if let kept = fits[key], kept.finest >= fit.finest { return }
        fits[key] = fit
    }

    private static func key(_ pair: DiffPair, _ page: Int) -> Key {
        Key(left: pair.left.path, right: pair.right.path, page: page,
            stamp: stamp(pair.left) + "|" + stamp(pair.right))
    }

    private static func stamp(_ url: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "" }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let date = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return "\(size)@\(date)"
    }
}
