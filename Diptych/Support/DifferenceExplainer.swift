import Foundation
import FoundationModels

/// What two folders, or two files, differ in, said in a few sentences by the
/// language model on this Mac.
///
/// Only ever the system model, named explicitly, for the same reason as
/// `NameSuggester`: nothing about a comparison should reach the network
/// because a default changed. And only when "Use Apple Intelligence" is on
/// and the model is ready -- otherwise nothing is asked and nothing is shown.
///
/// The model reads a short text made here from the comparison: a list of what
/// differs for two folders, a diff with a little context for two files. Both
/// are cut to fit what the model can read; a request it still finds too long
/// is asked again once, with half as much.
enum DifferenceExplainer {

    /// The text the model is given, the longest first. Each further one is
    /// shorter, to try when the one before was too long for the model.
    struct Request: Equatable, Sendable {
        var instructions: String
        var prompts: [String]
    }

    @MainActor
    static var isAvailable: Bool {
        ConfigStore.shared.configuration.useAppleIntelligence && NameSuggester.status == .ready
    }

    /// Characters of comparison shown to the model. The on-device model reads
    /// about four thousand tokens in all, instructions and answer included.
    static let budget = 6_000

    // MARK: - Two folders

    static let folderInstructions = """
        You help someone who is comparing two folders, called left and right, in a file \
        manager. You are given what differs between them. In three to six short sentences, \
        say how the two folders differ: what was added, removed or changed, and any pattern \
        you see, such as one side being a newer version, a backup, or holding build output. \
        Say only what the list supports; do not invent files or reasons. Plain text, no lists.
        """

    static func folders(left: URL, right: URL, pairs: [DirectoryComparison.Pair],
                        options: DirectoryComparison.Options) -> Request? {
        let differing = pairs.filter { $0.status != .same }
        guard !differing.isEmpty else { return nil }
        return Request(instructions: folderInstructions,
                       prompts: [budget, budget / 2].map {
                           folderPrompt(left: left, right: right, pairs: pairs,
                                        options: options, budget: $0)
                       })
    }

    static func folderPrompt(left: URL, right: URL, pairs: [DirectoryComparison.Pair],
                             options: DirectoryComparison.Options, budget: Int) -> String {
        func count(_ status: DirectoryComparison.Status) -> Int {
            pairs.filter { $0.status == status }.count
        }
        var compared = ["names"]
        if options.compareContent { compared.append("content") }
        if options.comparePermissions { compared.append("permissions") }
        if options.compareAttributes { compared.append("extended attributes") }
        if options.compareACL { compared.append("access control lists") }
        if options.compareModificationDate { compared.append("modification dates") }
        if options.compareCreationDate { compared.append("creation dates") }
        if options.compareOwnership { compared.append("owner and group") }

        var head = """
            Left folder: \(left.lastPathComponent)
            Right folder: \(right.lastPathComponent)
            Compared: \(compared.joined(separator: ", "))
            Totals: \(count(.same)) the same, \(count(.differs)) differ, \
            \(count(.onlyLeft)) only on the left, \(count(.onlyRight)) only on the right.

            What differs:

            """

        // Everything inside a folder that exists on one side only says the
        // same thing as the folder itself: listed once, as the folder.
        let leftOnlyFolders = folderPaths(pairs, .onlyLeft) { $0.left }
        let rightOnlyFolders = folderPaths(pairs, .onlyRight) { $0.right }
        var lines: [String] = []
        for pair in pairs where pair.status != .same {
            switch pair.status {
            case .onlyLeft:
                guard let entry = pair.left,
                      !isInside(entry.relativePath, leftOnlyFolders) else { continue }
                lines.append("- only on the left: \(describe(entry))")
            case .onlyRight:
                guard let entry = pair.right,
                      !isInside(entry.relativePath, rightOnlyFolders) else { continue }
                lines.append("- only on the right: \(describe(entry))")
            case .differs:
                lines.append("- " + describe(pair))
            case .same:
                continue
            }
        }

        var written = 0
        for line in lines {
            guard head.count + line.count + 1 <= budget else { break }
            head += line + "\n"
            written += 1
        }
        if written < lines.count {
            head += "... and \(lines.count - written) more not listed.\n"
        }
        return head
    }

    private static func folderPaths(_ pairs: [DirectoryComparison.Pair],
                                    _ status: DirectoryComparison.Status,
                                    _ side: (DirectoryComparison.Pair) -> DirectoryComparison.Entry?)
        -> [String] {
        pairs.filter { $0.status == status }.compactMap(side)
            .filter(\.isDirectory).map(\.relativePath)
    }

    private static func isInside(_ path: String, _ folders: [String]) -> Bool {
        folders.contains { path.hasPrefix($0 + "/") }
    }

    private static func describe(_ entry: DirectoryComparison.Entry) -> String {
        entry.isDirectory ? entry.relativePath + "/ (folder)"
            : "\(entry.relativePath) (\(size(entry.byteSize)))"
    }

    private static func describe(_ pair: DirectoryComparison.Pair) -> String {
        guard let left = pair.left, let right = pair.right else { return "" }
        var text = pair.isRename
            ? "renamed or moved: \(left.relativePath) -> \(right.relativePath)"
            : "differs: \(left.relativePath)"
        text += " (in \(pair.differences.summary)"
        if !left.isDirectory, !right.isDirectory, left.byteSize != right.byteSize {
            text += "; \(size(left.byteSize)) -> \(size(right.byteSize))"
        }
        switch pair.newerSide {
        case .left: text += "; the left one is newer"
        case .right: text += "; the right one is newer"
        case nil: break
        }
        return text + ")"
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Two files

    static let fileInstructions = """
        You help someone who is comparing two versions of a text file, called left and \
        right. You are given a diff: a line starting with "-" is only in the left file, a \
        line starting with "+" only in the right one, and a line starting with a space is \
        the same in both. In two to six short sentences, explain what changed and what it \
        means -- a value changed from one thing to another, a function renamed, a section \
        added -- rather than repeating the lines. Say only what the diff shows; do not \
        invent changes. Plain text, no lists.
        """

    static func files(leftName: String, rightName: String, diff: TextDiff) -> Request? {
        guard !diff.isIdentical else { return nil }
        return Request(instructions: fileInstructions,
                       prompts: [budget, budget / 2].map {
                           filePrompt(leftName: leftName, rightName: rightName,
                                      diff: diff, budget: $0)
                       })
    }

    /// Lines of unchanged text shown around each change.
    static let context = 2
    /// A line longer than this is cut: what it is about shows in its start.
    static let lineLength = 200

    static func filePrompt(leftName: String, rightName: String, diff: TextDiff,
                           budget: Int) -> String {
        var text = """
            Left file: \(leftName)
            Right file: \(rightName)
            \(diff.changeStarts.count) difference\(diff.changeStarts.count == 1 ? "" : "s").

            """
        let rows = diff.rows
        var shown = 0
        for start in diff.changeStarts {
            var end = start
            while end + 1 < rows.count, rows[end + 1].kind.isChange { end += 1 }
            let from = max(start - context, 0)
            let to = min(end + context, rows.count - 1)

            let leftLine = rows[from...to].lazy.compactMap(\.leftNumber).first
            let rightLine = rows[from...to].lazy.compactMap(\.rightNumber).first
            var hunk = ["@@ left line \(leftLine.map(String.init) ?? "-"), "
                        + "right line \(rightLine.map(String.init) ?? "-") @@"]
            for row in rows[from...to] {
                switch row.kind {
                case .same:
                    hunk.append(" " + cut(row.left ?? ""))
                case .removed:
                    hunk.append("-" + cut(row.left ?? ""))
                case .added:
                    hunk.append("+" + cut(row.right ?? ""))
                case .changed:
                    hunk.append("-" + cut(row.left ?? ""))
                    hunk.append("+" + cut(row.right ?? ""))
                }
            }
            let whole = hunk.joined(separator: "\n") + "\n"
            if text.count + whole.count <= budget {
                text += whole
                shown += 1
                continue
            }
            // Too big to show whole. The first one is shown as far as it
            // fits -- a file rewritten from top to bottom is one change, and
            // the model must still see some of it. Later ones are left out.
            if shown == 0 {
                for line in hunk where text.count + line.count + 1 <= budget {
                    text += line + "\n"
                }
                text += "... the rest of this change is not shown.\n"
                shown = 1
            }
            break
        }
        if shown < diff.changeStarts.count {
            text += "... and \(diff.changeStarts.count - shown) more differences not shown.\n"
        }
        return text
    }

    private static func cut(_ line: String) -> String {
        line.count <= lineLength ? line : String(line.prefix(lineLength)) + "..."
    }

    // MARK: - Asking

    enum Outcome: Equatable, Sendable {
        case explained(String)
        case failed(String)
    }

    static func explain(_ request: Request) async -> Outcome {
        guard #available(macOS 26, *) else {
            return .failed(NameSuggester.Status.systemTooOld.explanation)
        }
        for prompt in request.prompts {
            switch await Asking.respond(instructions: request.instructions, prompt: prompt) {
            case .tooLong: continue
            case .answer(let text): return .explained(text)
            case .failed(let why): return .failed(why)
            }
        }
        return .failed("The differences are too long for Apple Intelligence to read.")
    }
}

@available(macOS 26, *)
private enum Asking {

    enum Reply { case answer(String), tooLong, failed(String) }

    static func respond(instructions: String, prompt: String) async -> Reply {
        // The system model, by name. Never the Private Cloud Compute one.
        let session = LanguageModelSession(model: SystemLanguageModel.default,
                                           instructions: instructions)
        do {
            let reply = try await session.respond(
                to: prompt, options: GenerationOptions(samplingMode: .greedy))
            let text = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .failed("Apple Intelligence gave no answer.") : .answer(text)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return .tooLong
            case .guardrailViolation, .refusal:
                return .failed("Apple Intelligence declined to explain these differences.")
            case .unsupportedLanguageOrLocale:
                return .failed("Apple Intelligence does not support the language of these files.")
            default: return .failed(error.localizedDescription)
            }
        } catch {
            if #available(macOS 27, *), let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded: return .tooLong
                case .guardrailViolation, .refusal:
                    return .failed("Apple Intelligence declined to explain these differences.")
                case .unsupportedLanguageOrLocale:
                    return .failed("Apple Intelligence does not support the language of these files.")
                default: return .failed(error.localizedDescription)
                }
            }
            return .failed(error.localizedDescription)
        }
    }
}

/// One window's explanation: asked in the background, shown when it comes.
///
/// A new comparison replaces the question in flight rather than queueing
/// behind it, and the same comparison asked again is not asked twice.
@MainActor
@Observable
final class DifferenceExplanation {

    enum State: Equatable {
        /// Nothing to explain, or Apple Intelligence is not in use.
        case idle
        case working
        case done(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var asked: DifferenceExplainer.Request?

    /// Explain `request`, after `delay` -- a pause while somebody is still
    /// typing, so each keystroke does not become a question. Nil clears.
    func explain(_ request: DifferenceExplainer.Request?, after delay: Duration = .zero) {
        guard let request, DifferenceExplainer.isAvailable else {
            clear()
            return
        }
        guard request != asked else { return }
        task?.cancel()
        asked = request
        state = .working
        task = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            let outcome = await DifferenceExplainer.explain(request)
            guard !Task.isCancelled, let self else { return }
            switch outcome {
            case .explained(let text): self.state = .done(text)
            case .failed(let why): self.state = .failed(why)
            }
            self.task = nil
        }
    }

    func clear() {
        task?.cancel()
        task = nil
        asked = nil
        state = .idle
    }
}
