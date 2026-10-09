import AppKit

/// The strip left of Text Edit's text, from left to right: what changed since
/// the last commit, as IntelliJ shows it -- green added, blue changed, a red
/// wedge where lines were deleted -- a thinner bar for what changed since the
/// last save -- teal added, orange changed, an orange wedge -- the line
/// numbers, and the chevrons that fold. The line with the file's syntax
/// problem has its number in red. Brought over from Tychedit.
final class TextEditGutter: NSRulerView {

    private weak var controller: TextEditController?

    static let committedX: CGFloat = 1
    static let committedWidth: CGFloat = 3
    static let savedX: CGFloat = 5.5
    static let savedWidth: CGFloat = 2
    private static let barsWidth: CGFloat = 9
    private static let chevronSlot: CGFloat = 14
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    static let legend = "Wide bar, since the last commit: green added, blue changed, a red "
        + "wedge where lines were deleted. Thin bar, since the last save: teal added, orange "
        + "changed, an orange wedge where lines were deleted. The commit bar shows when Version "
        + "Tracking is on in Settings and the file is in a repository."

    @MainActor
    init(scrollView: NSScrollView, controller: TextEditController) {
        self.controller = controller
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = controller.textView
        ruleThickness = currentThickness
        clipsToBounds = true
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    // MARK: Geometry

    @MainActor
    private var numbersWidth: CGFloat {
        guard let controller, controller.lineNumbers != .off else { return 0 }
        // Three digits at least, so a file under 1,000 lines never changes
        // the gutter's width while it is being typed.
        let digits = max(3, String(controller.lineIndex.count).count)
        let sample = NSAttributedString(string: String(repeating: "8", count: digits),
                                        attributes: [.font: Self.numberFont])
        return ceil(sample.size().width) + 6
    }

    @MainActor
    private var chevronsX: CGFloat { Self.barsWidth + numbersWidth }

    @MainActor
    private var currentThickness: CGFloat { chevronsX + Self.chevronSlot + 2 }

    @MainActor
    func updateThickness() {
        let wanted = currentThickness
        if abs(ruleThickness - wanted) > 0.5, let scrollView {
            ruleThickness = wanted
            scrollView.tile()
            scrollView.needsDisplay = true
            for view in [scrollView.contentView, scrollView.documentView].compactMap({ $0 }) {
                view.needsDisplay = true
            }
        }
        removeAllToolTips()
        addToolTip(NSRect(x: 0, y: 0, width: Self.barsWidth, height: 1_000_000),
                   owner: Self.legend as NSString, userData: nil)
        needsDisplay = true
    }

    /// One logical line on screen, and where it is in the gutter.
    private struct VisibleLine {
        let number: Int
        let top: CGFloat
        let bottom: CGFloat
        let firstFragmentBottom: CGFloat
    }

    @MainActor
    private func visibleLines() -> [VisibleLine] {
        guard let controller, let layout = controller.textView.layoutManager,
              let container = controller.textView.textContainer else { return [] }
        let textView = controller.textView
        let index = controller.lineIndex
        let length = index.length
        guard length == (textView.string as NSString).length else { return [] }
        let origin = textView.textContainerOrigin
        var visible = textView.visibleRect
        visible.origin.y -= origin.y
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        var lines: [VisibleLine] = []
        var line = index.line(containing: characters.location)
        let lastCharacter = NSMaxRange(characters)
        while line < index.count && index.starts[line] <= lastCharacter {
            let start = index.starts[line]
            defer { line += 1 }
            if start > 0 && start < length && controller.isHidden(start) { continue }
            var rect: NSRect
            var first: NSRect
            if start >= length {
                rect = layout.extraLineFragmentRect
                if rect.height == 0 { continue }
                first = rect
            } else {
                let content = index.contentRange(ofLine: line)
                let lineGlyphs = layout.glyphRange(
                    forCharacterRange: content.length > 0 ? content
                                                          : NSRange(location: start, length: 1),
                    actualCharacterRange: nil)
                first = layout.lineFragmentRect(forGlyphAt: lineGlyphs.location, effectiveRange: nil)
                rect = first
                if content.length > 0 {
                    let lastGlyph = max(lineGlyphs.location, NSMaxRange(lineGlyphs) - 1)
                    rect = rect.union(layout.lineFragmentRect(forGlyphAt: lastGlyph,
                                                               effectiveRange: nil))
                }
            }
            let top = convert(NSPoint(x: 0, y: rect.minY + origin.y), from: textView).y
            let bottom = convert(NSPoint(x: 0, y: rect.maxY + origin.y), from: textView).y
            let firstBottom = convert(NSPoint(x: 0, y: first.maxY + origin.y), from: textView).y
            lines.append(VisibleLine(number: line, top: top, bottom: bottom,
                                     firstFragmentBottom: firstBottom))
        }
        return lines
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        MainActor.assumeIsolated {
            guard let controller else { return }
            let committed = controller.committedChanges
            let saved = controller.savedChanges
            let mode = controller.lineNumbers
            let caretLine = controller.lineIndex.line(containing: controller.selectedRange.location)
            let problemLine = controller.problem.map { $0.line - 1 }
            let numbersRight = chevronsX - 4
            let lines = visibleLines()

            for line in lines where line.bottom >= rect.minY && line.top <= rect.maxY {
                let height = line.bottom - line.top
                let firstHeight = line.firstFragmentBottom - line.top
                if let change = committed.lines[line.number] {
                    (change == .added ? NSColor.systemGreen : NSColor.systemBlue).setFill()
                    NSRect(x: Self.committedX, y: line.top + 1, width: Self.committedWidth,
                           height: height - 2).fill()
                }
                if committed.deletions.contains(line.number) {
                    wedge(at: line.top, x: 0, colour: .systemRed)
                }
                if let change = saved.lines[line.number] {
                    (change == .added ? NSColor.systemTeal : NSColor.systemOrange).setFill()
                    NSRect(x: Self.savedX, y: line.top + 1, width: Self.savedWidth,
                           height: height - 2).fill()
                }
                if saved.deletions.contains(line.number) {
                    wedge(at: line.top, x: Self.savedX - 1, colour: .systemOrange)
                }

                let isProblem = line.number == problemLine
                if mode != .off {
                    let isCaretLine = line.number == caretLine
                    let value = mode == .relative && !isCaretLine
                        ? abs(line.number - caretLine) : line.number + 1
                    let text = NSAttributedString(string: String(value), attributes: [
                        .font: isProblem ? NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
                                         : Self.numberFont,
                        .foregroundColor: isProblem ? NSColor.systemRed
                            : isCaretLine ? NSColor.labelColor : NSColor.tertiaryLabelColor,
                    ])
                    let size = text.size()
                    text.draw(at: NSPoint(x: numbersRight - size.width,
                                          y: line.top + (firstHeight - size.height) / 2))
                }

                let center = NSPoint(x: chevronsX + Self.chevronSlot / 2,
                                     y: line.top + firstHeight / 2)
                if let region = controller.regionsByFirstLine[line.number]?.first {
                    chevron(folded: controller.isFolded(region), center: center)
                } else if isProblem, mode == .off {
                    // No number to colour: a red dot says which line.
                    NSColor.systemRed.setFill()
                    NSBezierPath(ovalIn: NSRect(x: center.x - 3, y: center.y - 3, width: 6,
                                                height: 6)).fill()
                }
            }
            // Deleted at the very end.
            let count = controller.lineIndex.count
            if let last = lines.last, last.number == count - 1 {
                if committed.deletions.contains(count) {
                    wedge(at: last.bottom, x: 0, colour: .systemRed)
                }
                if saved.deletions.contains(count) {
                    wedge(at: last.bottom, x: Self.savedX - 1, colour: .systemOrange)
                }
            }

            let area = rect.intersection(bounds)
            NSColor.separatorColor.withAlphaComponent(0.4).setFill()
            NSRect(x: bounds.maxX - 1, y: area.minY, width: 1, height: area.height).fill()
        }
    }

    private func wedge(at y: CGFloat, x: CGFloat, colour: NSColor) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: y - 3.5))
        path.line(to: NSPoint(x: x + 5, y: y))
        path.line(to: NSPoint(x: x, y: y + 3.5))
        path.close()
        colour.setFill()
        path.fill()
    }

    private func chevron(folded: Bool, center: NSPoint) {
        let path = NSBezierPath()
        let size: CGFloat = 4
        if folded {
            path.move(to: NSPoint(x: center.x - size / 2, y: center.y - size))
            path.line(to: NSPoint(x: center.x + size * 0.75, y: center.y))
            path.line(to: NSPoint(x: center.x - size / 2, y: center.y + size))
        } else {
            path.move(to: NSPoint(x: center.x - size, y: center.y - size / 2))
            path.line(to: NSPoint(x: center.x, y: center.y + size * 0.75))
            path.line(to: NSPoint(x: center.x + size, y: center.y - size / 2))
        }
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        (folded ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setStroke()
        path.stroke()
    }

    // MARK: Clicking

    /// A click on a chevron folds or unfolds; on the red number, the caret
    /// goes to the problem.
    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let controller else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard let line = visibleLines().first(where: {
                point.y >= $0.top && point.y < max($0.bottom, $0.top + 14)
            }) else { return }
            if point.x >= chevronsX, let region = controller.regionsByFirstLine[line.number]?.first {
                controller.toggleFold(region)
            } else if let problem = controller.problem, problem.line - 1 == line.number {
                controller.revealProblem()
            }
        }
    }
}
