import AppKit

/// What a Text Edit window's text view needs beyond typing: the gutter, the
/// folds, how the text differs from the last commit and from the last save,
/// and where it breaks its format.
///
/// Folding and the gutter are Tychedit's, brought over: nothing is taken out
/// of the text. The layout manager is asked to make no glyphs for folded
/// characters except the first, which becomes a space as wide as the badge
/// drawn over it -- so saving, undo and find all see the whole file.
@MainActor
final class TextEditController: NSObject {

    let textView: FoldingTextView
    let scrollView: NSScrollView
    private(set) var gutter: TextEditGutter!
    var document: TextEditDocument

    /// The format the file's extension says, if any.
    private(set) var format: TextFormat?
    private(set) var lineIndex = LineIndex("")
    var lineNumbers = TextLineNumbers.absolute {
        didSet { if lineNumbers != oldValue { gutter.updateThickness() } }
    }

    /// Against the last commit, and against the last save.
    private(set) var committedChanges = LineChanges.none
    private(set) var savedChanges = LineChanges.none
    private(set) var problem: SyntaxProblem?

    enum Baseline: Equatable {
        /// No version tracking, or not in a repository: no bar.
        case unavailable
        /// In a repository, not in the last commit: every line is new.
        case uncommitted
        case committed(String)
    }
    private(set) var baseline = Baseline.unavailable

    // Folding.
    private(set) var foldRegions: [FoldRegion] = []
    private(set) var regionsByFirstLine: [Int: [FoldRegion]] = [:]
    private var foldedKeys: [FoldRegion.Key: FoldedRange] = [:]
    private(set) var hiddenRanges: [NSRange] = []
    private var badgeLabels: [Int: String] = [:]
    /// While the whole text is replaced by a reload: folds come back after.
    private var replacingEverything = false

    private var analysisTask: Task<Void, Never>?
    /// Bumped on every edit, so an analysis of older text is dropped.
    private var generation = 0

    init(document: TextEditDocument) {
        self.document = document
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        textView = FoldingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400),
                                   textContainer: container)
        scrollView = NSScrollView()
        super.init()

        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.controller = self
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        layout.delegate = self
        storage.delegate = self

        gutter = TextEditGutter(scrollView: scrollView, controller: self)
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
    }

    var nsText: NSString { textView.string as NSString }
    var selectedRange: NSRange { textView.selectedRange() }

    // MARK: - Loading and editing

    /// The file was read: its format, the baseline from Git, and the text
    /// analysed afresh.
    func loaded(text: String) {
        format = TextFormat.of(document.url, extensions: ConfigStore.shared.configuration.textFormats)
        replacingEverything = true
        textView.string = text
        replacingEverything = false
        textChanged()
        loadBaseline()
    }

    /// The format may have been given other extensions in Settings.
    func refreshFormat() {
        let now = TextFormat.of(document.url, extensions: ConfigStore.shared.configuration.textFormats)
        guard now != format else { return }
        format = now
        textChanged()
    }

    func textChanged() {
        lineIndex = LineIndex(nsText)
        gutter.updateThickness()
        scheduleAnalysis()
    }

    func selectionChanged() {
        revealSelection()
        if lineNumbers == .relative { gutter.needsDisplay = true }
    }

    /// Saved: the save is the new base of the thin bar.
    func saved() {
        scheduleAnalysis(after: .zero)
    }

    // MARK: - Analysis

    private func scheduleAnalysis(after delay: Duration = .milliseconds(250)) {
        generation += 1
        let mine = generation
        let text = textView.string
        let format = format
        let baseline = baseline
        let saved = document.saved
        analysisTask?.cancel()
        analysisTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let result = await BlockingWork.run {
                () -> (StructureAnalysis, LineChanges, LineChanges) in
                let structure = format.map { StructuredText.analyse(text, as: $0) } ?? .none
                let committed: LineChanges = switch baseline {
                case .unavailable: .none
                case .uncommitted: .allAdded(text)
                case .committed(let base): .compute(base: base, current: text)
                }
                return (structure, committed, .compute(base: saved, current: text))
            }
            guard let self, !Task.isCancelled, mine == self.generation else { return }
            self.apply(result.0, committed: result.1, saved: result.2)
        }
    }

    private func apply(_ structure: StructureAnalysis, committed: LineChanges, saved: LineChanges) {
        committedChanges = committed
        savedChanges = saved
        problem = structure.problem
        document.problem = structure.problem
        document.format = format
        setFoldRegions(FoldRegion.regions(structure.folds, in: nsText, lines: lineIndex))
        underlineProblem()
        gutter.needsDisplay = true
    }

    /// The place a problem is, underlined in red in the text.
    private func underlineProblem() {
        guard let layout = textView.layoutManager else { return }
        let length = nsText.length
        let all = NSRange(location: 0, length: length)
        layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: all)
        layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: all)
        guard let problem, length > 0 else { return }
        var at = min(problem.location, length - 1)
        // On a line break the mark would not show: the character before it.
        if nsText.character(at: at) == 10, at > 0 { at -= 1 }
        layout.addTemporaryAttributes([
            .underlineStyle: NSUnderlineStyle.thick.rawValue,
            .underlineColor: NSColor.systemRed,
        ], forCharacterRange: NSRange(location: at, length: 1))
    }

    /// The caret to the problem, unfolded and on screen.
    func revealProblem() {
        guard let problem else { return }
        let at = min(problem.location, nsText.length)
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: at, length: 0))
        revealSelection()
        textView.scrollRangeToVisible(NSRange(location: at, length: 0))
    }

    // MARK: - Git

    /// The file as the last commit has it -- when version tracking is on
    /// in Settings and the file is in a repository. Asked again when the
    /// window comes to the front: a commit made elsewhere moves the base.
    func loadBaseline() {
        let url = document.url
        Task { [weak self] in
            let found = await Self.baseline(for: url)
            guard let self, found != self.baseline else { return }
            self.baseline = found
            self.scheduleAnalysis(after: .zero)
        }
    }

    static func baseline(for url: URL) async -> Baseline {
        guard ConfigStore.shared.configuration.gitEnabled,
              let git = GitService.shared.tool else { return .unavailable }
        let folder = url.deletingLastPathComponent()
        guard await GitService.shared.root(for: folder) != nil else { return .unavailable }
        let name = url.lastPathComponent
        return await BlockingWork.run {
            switch GitTool.run(["show", "HEAD:./\(name)"], executable: git.url, in: folder,
                               timeout: GitService.timeout) {
            case .ok(let text): .committed(text)
            case .failed: .uncommitted
            case .timedOut, .couldNotRun: .unavailable
            }
        }
    }

    // MARK: - Folding

    func setFoldRegions(_ regions: [FoldRegion]) {
        foldRegions = regions
        regionsByFirstLine = Dictionary(grouping: regions, by: \.firstLine)
        let byKey = Dictionary(regions.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var updated: [FoldRegion.Key: FoldedRange] = [:]
        for key in foldedKeys.keys {
            if let region = byKey[key] {
                updated[key] = FoldedRange(range: region.hidden, label: region.label)
            }
        }
        applyFolds(updated)
    }

    func isFolded(_ region: FoldRegion) -> Bool { foldedKeys[region.key] != nil }

    func toggleFold(_ region: FoldRegion) {
        var folded = foldedKeys
        if isFolded(region) {
            folded[region.key] = nil
        } else {
            folded[region.key] = FoldedRange(range: region.hidden, label: region.label)
            moveCaretOutOf([region.hidden])
        }
        applyFolds(folded)
    }

    func foldAll() {
        var keys = foldedKeys
        for region in foldRegions {
            keys[region.key] = FoldedRange(range: region.hidden, label: region.label)
        }
        moveCaretOutOf(keys.values.map(\.range))
        applyFolds(keys)
    }

    func unfoldAll() { applyFolds([:]) }

    var hasFolds: Bool { !foldRegions.isEmpty }

    /// The caret must not stay inside what is hidden, or the fold would open
    /// again at once.
    private func moveCaretOutOf(_ ranges: [NSRange]) {
        let caret = selectedRange.location
        if let range = ranges.first(where: { caret > $0.location && caret <= NSMaxRange($0) }) {
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
        }
    }

    private func applyFolds(_ folded: [FoldRegion.Key: FoldedRange]) {
        let length = nsText.length
        let valid = folded.filter { NSMaxRange($0.value.range) <= length && $0.value.range.length > 0 }
        let merged = Self.merge(valid.values.map(\.range))
        var labels: [Int: String] = [:]
        for range in merged {
            labels[range.location] = valid.values
                .filter { $0.range.location == range.location }
                .max { $0.range.length < $1.range.length }?.label ?? "\u{2026}"
        }
        let changed = merged != hiddenRanges || labels != badgeLabels
        let previous = hiddenRanges
        foldedKeys = valid
        hiddenRanges = merged
        badgeLabels = labels
        guard changed, let layout = textView.layoutManager else {
            gutter.needsDisplay = true
            return
        }
        for range in Self.merge(previous + merged) {
            let start = max(0, range.location - 1)
            let end = min(length, NSMaxRange(range) + 1)
            let affected = NSRange(location: start, length: end - start)
            layout.invalidateGlyphs(forCharacterRange: affected, changeInLength: 0,
                                    actualCharacterRange: nil)
            layout.invalidateLayout(forCharacterRange: affected, actualCharacterRange: nil)
        }
        textView.needsDisplay = true
        gutter.needsDisplay = true
    }

    nonisolated static func merge(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = result.last, range.location < NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }

    func isHidden(_ index: Int) -> Bool {
        Self.range(containing: index, in: hiddenRanges) != nil
    }

    /// Binary search in sorted ranges that do not overlap.
    nonisolated static func range(containing index: Int, in sorted: [NSRange]) -> NSRange? {
        var low = 0
        var high = sorted.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = sorted[mid]
            if index < range.location {
                high = mid - 1
            } else if index >= NSMaxRange(range) {
                low = mid + 1
            } else {
                return range
            }
        }
        return nil
    }

    /// Opens the folds the selection has moved into -- Find, a problem.
    func revealSelection() {
        guard !foldedKeys.isEmpty else { return }
        let selection = selectedRange
        var keys = foldedKeys
        for (key, folded) in foldedKeys {
            let range = folded.range
            let caretInside = selection.length == 0
                && selection.location > range.location && selection.location <= NSMaxRange(range)
            let endInside = selection.length > 0
                && [selection.location, NSMaxRange(selection)].contains {
                    $0 > range.location && $0 < NSMaxRange(range)
                }
            if caretInside || endInside { keys[key] = nil }
        }
        if keys.count != foldedKeys.count { applyFolds(keys) }
    }

    // MARK: Badges

    static let badgeFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    func badgeAdvance(for label: String) -> CGFloat {
        let text = NSAttributedString(string: label, attributes: [.font: Self.badgeFont])
        return ceil(text.size().width) + 16 + 10
    }

    private func badgeRects() -> [(rect: NSRect, location: Int, label: String)] {
        guard let layout = textView.layoutManager else { return [] }
        let origin = textView.textContainerOrigin
        return hiddenRanges.compactMap { range in
            guard let label = badgeLabels[range.location] else { return nil }
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            guard glyph < layout.numberOfGlyphs else { return nil }
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let position = layout.location(forGlyphAt: glyph)
            let height = min(17, max(12, line.height - 4))
            let width = badgeAdvance(for: label) - 10
            let rect = NSRect(x: line.minX + position.x + origin.x + 5,
                              y: line.minY + origin.y + (line.height - height) / 2,
                              width: width, height: height)
            return (rect, range.location, label)
        }
    }

    func drawFoldBadges(in dirtyRect: NSRect) {
        for badge in badgeRects() where badge.rect.intersects(dirtyRect) {
            let path = NSBezierPath(roundedRect: badge.rect, xRadius: badge.rect.height / 2,
                                    yRadius: badge.rect.height / 2)
            NSColor.quaternaryLabelColor.setFill()
            path.fill()
            let text = NSAttributedString(string: badge.label, attributes: [
                .font: Self.badgeFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: badge.rect.minX + 8, y: badge.rect.midY - size.height / 2))
        }
    }

    /// A click on a badge opens what it stands for.
    func unfoldBadge(at point: NSPoint) -> Bool {
        guard let badge = badgeRects().first(where: {
            $0.rect.insetBy(dx: -3, dy: -3).contains(point)
        }) else { return false }
        let merged = Self.range(containing: badge.location, in: hiddenRanges)
        applyFolds(foldedKeys.filter { folded in
            guard let merged else { return true }
            return !(folded.value.range.location >= merged.location
                     && NSMaxRange(folded.value.range) <= NSMaxRange(merged))
        })
        return true
    }
}

/// A folded region's place now, and its badge.
struct FoldedRange: Equatable {
    var range: NSRange
    let label: String
}

/// A fold, with what it is apart from where it is: the text of its first
/// line and how many before it share that -- so a fold survives typing above
/// it.
struct FoldRegion: Equatable {
    struct Key: Hashable {
        let firstLineText: String
        let occurrence: Int
    }

    let key: Key
    let firstLine: Int
    let lastLine: Int
    let hidden: NSRange
    let label: String

    static func regions(_ spans: [FoldSpan], in text: NSString, lines: LineIndex) -> [FoldRegion] {
        var seen: [String: Int] = [:]
        return spans.sorted { ($0.firstLine, -$0.lastLine) < ($1.firstLine, -$1.lastLine) }
            .compactMap { span in
                guard span.firstLine < lines.count, NSMaxRange(span.hidden) <= text.length
                else { return nil }
                let first = text.substring(with: lines.contentRange(ofLine: span.firstLine))
                let occurrence = seen[first, default: 0]
                seen[first] = occurrence + 1
                return FoldRegion(key: Key(firstLineText: first, occurrence: occurrence),
                                  firstLine: span.firstLine, lastLine: span.lastLine,
                                  hidden: span.hidden, label: span.label)
            }
    }
}

// MARK: - Layout: hiding folded glyphs

extension TextEditController: @preconcurrency NSLayoutManagerDelegate {

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes: UnsafePointer<Int>,
                       font: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard !hiddenRanges.isEmpty else { return 0 }
        var adjusted: [NSLayoutManager.GlyphProperty]?
        for i in 0..<glyphRange.length {
            let index = characterIndexes[i]
            guard let range = Self.range(containing: index, in: hiddenRanges) else { continue }
            if adjusted == nil {
                adjusted = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
            }
            // The first folded character is the space the badge sits in.
            adjusted![i] = index == range.location ? .controlCharacter : .null
        }
        guard let adjusted else { return 0 }
        adjusted.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(glyphs, properties: buffer.baseAddress!,
                                    characterIndexes: characterIndexes, font: font,
                                    forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let range = Self.range(containing: charIndex, in: hiddenRanges) else { return action }
        return charIndex == range.location ? .whitespace : .zeroAdvancement
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int,
                       for textContainer: NSTextContainer, proposedLineFragment proposedRect: NSRect,
                       glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let width = badgeLabels[charIndex].map { badgeAdvance(for: $0) } ?? 0
        return NSRect(x: glyphPosition.x, y: glyphPosition.y, width: width,
                      height: proposedRect.height)
    }

    /// The gutter follows the text: whenever layout finishes, it draws again.
    func layoutManager(_ layoutManager: NSLayoutManager,
                       didCompleteLayoutFor textContainer: NSTextContainer?,
                       atEnd layoutFinishedFlag: Bool) {
        gutter?.needsDisplay = true
    }
}

// MARK: - Storage: folds keep their place while typing

extension TextEditController: @preconcurrency NSTextStorageDelegate {

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !foldedKeys.isEmpty else { return }
        if replacingEverything {
            hiddenRanges = []
            return
        }
        let old = NSRange(location: editedRange.location, length: editedRange.length - delta)
        var updated: [FoldRegion.Key: FoldedRange] = [:]
        for (key, folded) in foldedKeys {
            let range = folded.range
            if NSMaxRange(old) <= range.location {
                updated[key] = FoldedRange(range: NSRange(location: range.location + delta,
                                                          length: range.length),
                                           label: folded.label)
            } else if old.location >= NSMaxRange(range) {
                updated[key] = folded
            }
            // An edit inside a fold opens it.
        }
        foldedKeys = updated
        hiddenRanges = Self.merge(updated.values.map(\.range))
        badgeLabels = Dictionary(updated.values.map { ($0.range.location, $0.label) },
                                 uniquingKeysWith: { first, _ in first })
    }
}

/// The text view: draws the fold badges and opens one when it is clicked.
final class FoldingTextView: NSTextView {
    weak var controller: TextEditController?

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        MainActor.assumeIsolated { controller?.drawFoldBadges(in: rect) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let opened = MainActor.assumeIsolated { controller?.unfoldBadge(at: point) ?? false }
        if !opened { super.mouseDown(with: event) }
    }
}
