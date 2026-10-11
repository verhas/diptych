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
    /// The text, or the tree in its place.
    let view = NSView()
    private(set) var tree: StructureTreeController?
    private(set) var showsTree = false
    weak var link: EditorLink?
    /// Where a whole line is copied to; a private one in tests.
    var pasteboard = NSPasteboard.general
    private(set) var gutter: TextEditGutter!
    var document: TextEditDocument

    /// The format the file's extension says, if any.
    private(set) var format: TextFormat?
    private(set) var lineIndex = LineIndex("")
    var lineNumbers = TextLineNumbers.absolute {
        didSet {
            if lineNumbers != oldValue { gutter.updateThickness() }
            tree?.showLineNumbers(lineNumbers != .off)
        }
    }
    /// Which structure around the caret is shaded: 0 none, 1 the smallest.
    var emphasis = 0 {
        didSet { if emphasis != oldValue { textView.needsDisplay = true } }
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

    /// What the XML markup at the caret still needs, drawn in grey.
    fileprivate(set) var suggestion: String?
    private var suggestedAt = 0

    /// The colours and pairs of the text as last analysed; `colouringIsCurrent`
    /// until the text changes again.
    private(set) var colouring = SyntaxColouring.none
    private(set) var colouringIsCurrent = false
    private var matched: SyntaxColouring.Pair?

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

        view.addSubview(scrollView)
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.width, .height]

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
        applyTabWidth()
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
        colouringIsCurrent = false
        lineIndex = LineIndex(nsText)
        gutter.updateThickness()
        scheduleAnalysis()
        updateSuggestion()
        tree?.textChanged()
    }

    // MARK: - The tree

    /// The tree in place of the text, on the node the caret is in; and back,
    /// the caret on the node chosen in the tree.
    func setTreeShown(_ on: Bool) {
        guard on != showsTree else { return }
        showsTree = on
        if on {
            let tree = self.tree ?? {
                let made = StructureTreeController()
                made.controller = self
                made.container.frame = view.bounds
                made.container.autoresizingMask = [.width, .height]
                view.addSubview(made.container)
                self.tree = made
                return made
            }()
            tree.container.isHidden = false
            scrollView.isHidden = true
            tree.showLineNumbers(lineNumbers != .off)
            tree.reload()
            if let path = tree.path(containing: selectedRange.location) { tree.select(path, edit: nil) }
            view.window?.makeFirstResponder(tree.outline)
        } else {
            if let item = tree?.selectedItem {
                let node = item.node
                let at = node.keyRange?.location ?? node.valueRange?.location ?? node.range.location
                textView.setSelectedRange(NSRange(location: min(at, nsText.length), length: 0))
                revealSelection()
                textView.scrollRangeToVisible(selectedRange)
            }
            tree?.container.isHidden = true
            scrollView.isHidden = false
            view.window?.makeFirstResponder(textView)
        }
    }

    /// From the tree's Show in Text.
    func showInText(_ location: Int) {
        link?.showsTree = false
        setTreeShown(false)
        textView.setSelectedRange(NSRange(location: min(location, nsText.length), length: 0))
        revealSelection()
        textView.scrollRangeToVisible(selectedRange)
    }

    func selectionChanged() {
        revealSelection()
        updateSuggestion()
        highlightPair()
        if lineNumbers == .relative { gutter.needsDisplay = true }
        if emphasis > 0 { textView.needsDisplay = true }
    }

    /// The lines of the `emphasis`-th smallest structure the caret is in:
    /// of the folds around its line, smallest first.
    func emphasizedLines() -> ClosedRange<Int>? {
        guard emphasis > 0 else { return nil }
        let line = lineIndex.line(containing: selectedRange.location)
        let around = foldRegions
            .filter { $0.openingLine <= line && line <= $0.lastLine }
            .sorted { ($0.lastLine - $0.openingLine, -$0.openingLine) < ($1.lastLine - $1.openingLine, -$1.openingLine) }
        guard emphasis <= around.count else { return nil }
        let region = around[emphasis - 1]
        return region.openingLine ... region.lastLine
    }

    /// The emphasized lines, shaded the width of the text.
    func drawEmphasis(in dirtyRect: NSRect) {
        guard let lines = emphasizedLines(), let layout = textView.layoutManager,
              let container = textView.textContainer, lines.upperBound < lineIndex.count else { return }
        let start = lineIndex.contentRange(ofLine: lines.lowerBound).location
        let end = NSMaxRange(lineIndex.contentRange(ofLine: lines.upperBound))
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: start, length: end - start),
                                       actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.y += textView.textContainerOrigin.y
        rect.origin.x = 0
        rect.size.width = textView.bounds.width
        guard rect.intersects(dirtyRect) else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        rect.intersection(dirtyRect).fill(using: .sourceOver)
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
                () -> (StructureAnalysis, LineChanges, LineChanges, SyntaxColouring) in
                let structure = format.map { StructuredText.analyse(text, as: $0) } ?? .none
                let committed: LineChanges = switch baseline {
                case .unavailable: .none
                case .uncommitted: .allAdded(text)
                case .committed(let base): .compute(base: base, current: text)
                }
                return (structure, committed, .compute(base: saved, current: text),
                        SyntaxColouring.of(text, as: format))
            }
            guard let self, !Task.isCancelled, mine == self.generation else { return }
            self.apply(result.0, committed: result.1, saved: result.2)
            self.apply(result.3)
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

    /// The colours, over whatever was coloured before.
    private func apply(_ colouring: SyntaxColouring) {
        self.colouring = colouring
        colouringIsCurrent = true
        guard let layout = textView.layoutManager else { return }
        let all = NSRange(location: 0, length: nsText.length)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        for span in colouring.spans where NSMaxRange(span.range) <= all.length {
            layout.addTemporaryAttribute(.foregroundColor, value: span.role.colour, forCharacterRange: span.range)
        }
        matched = nil
        highlightPair()
    }

    /// The bracket or tag that goes with the one at the caret, and that one,
    /// on a tinted ground.
    func highlightPair() {
        guard let layout = textView.layoutManager else { return }
        let length = nsText.length
        if let old = matched {
            for range in [old.open, old.close] where NSMaxRange(range) <= length {
                layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            }
            matched = nil
        }
        let selection = selectedRange
        guard colouringIsCurrent, selection.length == 0,
              let pair = colouring.pair(at: selection.location) else { return }
        for range in [pair.open, pair.close] where NSMaxRange(range) <= length {
            layout.addTemporaryAttribute(.backgroundColor,
                                         value: NSColor.findHighlightColor.withAlphaComponent(0.35),
                                         forCharacterRange: range)
        }
        matched = pair
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
    /// The structure's first line: `firstLine`, or above it where its
    /// opening runs over several lines.
    var openingLine: Int

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
                                  hidden: span.hidden, label: span.label,
                                  openingLine: min(span.openingLine ?? span.firstLine, span.firstLine))
            }
    }
}

// MARK: - XML: what is left of the markup, in grey

extension TextEditController {

    /// What `XMLCompletion` offers at the caret, in an XML file with nothing
    /// selected.
    func updateSuggestion() {
        let range = selectedRange
        let now = format?.markup == .xml && style.closeTags && range.length == 0 && !textView.hasMarkedText()
            ? XMLCompletion.suggestion(in: nsText, at: range.location) : nil
        // Drawn at the caret: moved with it, the old place is drawn again.
        guard now != suggestion || (now != nil && range.location != suggestedAt) else { return }
        suggestion = now
        suggestedAt = range.location
        textView.needsDisplay = true
    }

    /// Control-Space: the suggestion, as if typed.
    func acceptSuggestion() -> Bool {
        guard let suggestion, textView.isEditable else { return false }
        let at = selectedRange.location
        textView.insertText(suggestion, replacementRange: selectedRange)
        // An attribute's `=""`: the value is typed between the quotes.
        let caret = XMLCompletion.caret(in: suggestion)
        if caret < suggestion.utf16.count { textView.setSelectedRange(NSRange(location: at + caret, length: 0)) }
        return true
    }

    /// A `>` was typed: the end tag of the element it started, after the
    /// caret, unless something further on already closes it. An undo step of
    /// its own, so that Undo takes back only the end tag first.
    func closeElement() {
        let range = selectedRange
        guard format?.markup == .xml, style.closeTags, range.length == 0, textView.isEditable,
              let tag = XMLCompletion.endTag(in: nsText, at: range.location) else { return }
        let at = NSRange(location: range.location, length: 0)
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: at, replacementString: tag) else { return }
        textView.textStorage?.replaceCharacters(in: at, with: tag)
        textView.didChangeText()
        textView.setSelectedRange(at)
    }

    /// The suggestion, in grey right after the caret -- only where nothing
    /// follows on the line, since it would be drawn over it.
    func drawSuggestion() {
        guard let suggestion, let layout = textView.layoutManager,
              let container = textView.textContainer else { return }
        let caret = selectedRange.location
        let text = nsText
        guard caret > 0, caret <= text.length, !isHidden(caret - 1) else { return }
        if caret < text.length, ![0x0A, 0x0D].contains(text.character(at: caret)) { return }
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: caret - 1, length: 1),
                                       actualCharacterRange: nil)
        let before = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let origin = textView.textContainerOrigin
        let font = textView.font ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        (suggestion as NSString).draw(
            at: NSPoint(x: before.maxX + origin.x, y: before.minY + origin.y),
            withAttributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
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
        MainActor.assumeIsolated {
            controller?.drawEmphasis(in: rect)
            controller?.drawFoldBadges(in: rect)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        MainActor.assumeIsolated { controller?.drawSuggestion() }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let opened = MainActor.assumeIsolated { controller?.unfoldBadge(at: point) ?? false }
        if !opened { super.mouseDown(with: event) }
    }

    /// Control-Space takes what is shown in grey.
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control,
           event.charactersIgnoringModifiers == " ",
           MainActor.assumeIsolated({ controller?.acceptSuggestion() ?? false }) {
            return
        }
        super.keyDown(with: event)
    }

    /// A pair closed or stepped over; and a start tag closed by typing, or
    /// by taking the suggestion, gets its end tag.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        let handled = !hasMarkedText() && replacementRange.location == NSNotFound
            && MainActor.assumeIsolated { controller?.typed(typed) ?? false }
        if !handled { super.insertText(string, replacementRange: replacementRange) }
        if typed.hasSuffix(">") { MainActor.assumeIsolated { controller?.closeElement() } }
    }

    // MARK: Editing by lines, as IntelliJ does

    private func run(_ action: (TextEditController) -> Void) -> Bool {
        MainActor.assumeIsolated {
            guard let controller else { return false }
            action(controller)
            return true
        }
    }

    override func insertNewline(_ sender: Any?) {
        if !run({ $0.newline() }) { super.insertNewline(sender) }
    }

    override func insertTab(_ sender: Any?) {
        if !run({ $0.tab() }) { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if !run({ $0.backtab() }) { super.insertBacktab(sender) }
    }

    override func deleteBackward(_ sender: Any?) {
        let done = MainActor.assumeIsolated { controller?.deleteBackward() ?? false }
        if !done { super.deleteBackward(sender) }
    }

    /// Command-Delete: the line, not the line up to the caret.
    override func deleteToBeginningOfLine(_ sender: Any?) {
        if !run({ $0.deleteLines() }) { super.deleteToBeginningOfLine(sender) }
    }

    /// Shift-Command-Up and -Down move the lines.
    override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) {
        if !run({ $0.moveLines(up: true) }) { super.moveToBeginningOfDocumentAndModifySelection(sender) }
    }

    override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) {
        if !run({ $0.moveLines(up: false) }) { super.moveToEndOfDocumentAndModifySelection(sender) }
    }

    override func copy(_ sender: Any?) {
        let done = MainActor.assumeIsolated { () -> Bool in
            guard let controller else { return false }
            if controller.copyLine(cutting: false) { return true }
            // The editor's clipboard, which is the general one but in tests.
            guard controller.pasteboard != .general else { return false }
            controller.pasteboard.clearContents()
            return controller.pasteboard.setString(controller.nsText.substring(with: selectedRange()),
                                                   forType: .string)
        }
        if !done { super.copy(sender) }
    }

    override func cut(_ sender: Any?) {
        let done = isEditable && MainActor.assumeIsolated { controller?.copyLine(cutting: true) ?? false }
        if !done { super.cut(sender) }
    }

    override func paste(_ sender: Any?) {
        let done = isEditable && MainActor.assumeIsolated { controller?.pasteLine() ?? false }
        if !done { super.paste(sender) }
    }

    /// Format ▸ Comment Lines.
    @objc func toggleComment(_ sender: Any?) {
        _ = run { $0.toggleComment() }
    }

    /// Cut, Copy, Paste and the Format menu's items -- no fonts, spelling,
    /// services.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.allowsContextMenuPlugIns = false
        menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        // Enabled by the items themselves, as Cut and Copy are by
        // validateMenuItem.
        menu.autoenablesItems = false
        for item in menu.items { item.isEnabled = validateMenuItem(item) }
        MainActor.assumeIsolated {
            let format = controller?.formatMenuItems() ?? []
            guard !format.isEmpty else { return }
            menu.addItem(.separator())
            format.forEach(menu.addItem)
        }
        return menu
    }

    /// With nothing selected Cut and Copy take the line, so they are on.
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return string.isEmpty == false }
        if item.action == #selector(cut(_:)) { return isEditable && !string.isEmpty }
        return super.validateMenuItem(item)
    }
}
