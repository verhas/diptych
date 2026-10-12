import AppKit

/// The tree's line numbers: beside each row, the line its node starts on in
/// the text. Nodes written on one line show the same number.
final class TreeLineGutter: NSRulerView {
    weak var tree: StructureTreeController?

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 30
        // Since macOS 14 a view draws past its bounds unless told not to, and
        // the rect AppKit asks the ruler to draw can reach above it -- the
        // separator ran up through the window's toolbar, across Save.
        clipsToBounds = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Wide enough for the last line's number.
    func updateThickness(lines: Int) {
        let sample = String(repeating: "8", count: max(2, String(lines).count)) as NSString
        let wanted = ceil(sample.size(withAttributes: [.font: Self.font]).width) + 12
        if abs(ruleThickness - wanted) > 0.5 { ruleThickness = wanted }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        MainActor.assumeIsolated {
            guard let tree else { return }
            let outline = tree.outline
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            let visible = outline.rows(in: outline.visibleRect)
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.font,
                                                              .foregroundColor: NSColor.secondaryLabelColor]
            for row in visible.location..<NSMaxRange(visible) {
                guard let item = outline.item(atRow: row) as? TreeItem, let line = tree.line(of: item) else { continue }
                let rowRect = convert(outline.rect(ofRow: row), from: outline)
                let text = String(line) as NSString
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: bounds.maxX - 6 - size.width, y: rowRect.midY - size.height / 2),
                          withAttributes: attributes)
            }
            // Within the ruler, as Text Edit's own gutter draws it.
            let area = rect.intersection(bounds)
            NSColor.separatorColor.setFill()
            NSRect(x: bounds.maxX - 1, y: area.minY, width: 1, height: area.height).fill()
        }
    }
}

/// A value over several lines -- a comment, CDATA, text, the DOCTYPE --
/// edited in a text area rather than in the row. Done or Command-Return
/// keeps it, as clicking elsewhere does; Escape or Cancel leaves it. The
/// corner drags it larger, and the next one opens that size.
@MainActor
final class TreeTextArea: NSViewController, NSPopoverDelegate {

    private let original: String
    private let font: NSFont
    private let commit: (String) -> Void
    private let area = AreaTextView()
    private var cancelled = false
    let popover = NSPopover()

    static let minimumSize = NSSize(width: 280, height: 140)
    /// The size it was last dragged to, for the next one.
    static var size = NSSize(width: 460, height: 240)

    init(text: String, font: NSFont, commit: @escaping (String) -> Void) {
        original = text
        self.font = font
        self.commit = commit
        super.init(nibName: nil, bundle: nil)
        popover.contentViewController = self
        popover.behavior = .transient
        popover.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// What is being typed, for tests.
    var text: String {
        get { area.string }
        set { area.string = newValue }
    }

    override func loadView() {
        let view = NSView(frame: NSRect(origin: .zero, size: Self.size))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        area.isRichText = false
        area.allowsUndo = true
        area.font = font
        area.isAutomaticQuoteSubstitutionEnabled = false
        area.isAutomaticDashSubstitutionEnabled = false
        area.isAutomaticTextReplacementEnabled = false
        area.isAutomaticSpellingCorrectionEnabled = false
        area.isContinuousSpellCheckingEnabled = false
        area.textContainerInset = NSSize(width: 4, height: 4)
        area.isVerticallyResizable = true
        area.isHorizontallyResizable = true
        area.autoresizingMask = [.width]
        area.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        area.textContainer?.widthTracksTextView = false
        area.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                   height: CGFloat.greatestFiniteMagnitude)
        area.string = original
        area.onCancel = { [weak self] in self?.cancel() }
        scroll.documentView = area

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        // The key on the button: Return alone is a new line here.
        let done = NSButton(title: "Done \u{2318}\u{21A9}", target: self, action: #selector(donePressed))
        done.keyEquivalent = "\r"
        done.keyEquivalentModifierMask = .command
        done.bezelColor = .controlAccentColor
        let grip = ResizeGrip()
        grip.onDrag = { [weak self] size in self?.resize(to: size) }
        grip.startSize = { [weak self] in self?.popover.contentSize ?? Self.size }
        for control in [cancel, done, grip] {
            control.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(control)
        }
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            done.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            done.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            done.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            cancel.centerYAnchor.constraint(equalTo: done.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -8),
            grip.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            grip.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -2),
            grip.widthAnchor.constraint(equalToConstant: 12),
            grip.heightAnchor.constraint(equalToConstant: 12),
        ])
        self.view = view
    }

    /// Dragged by its corner; not below what holds the buttons.
    func resize(to wanted: NSSize) {
        let size = NSSize(width: max(Self.minimumSize.width, wanted.width.rounded()),
                          height: max(Self.minimumSize.height, wanted.height.rounded()))
        popover.contentSize = size
        Self.size = size
    }

    func show(relativeTo rect: NSRect, of view: NSView) {
        popover.contentSize = Self.size
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        view.window?.makeFirstResponder(nil)
        area.window?.makeFirstResponder(area)
        area.selectAll(nil)
    }

    @objc private func donePressed() { popover.performClose(nil) }

    @objc private func cancelPressed() { cancel() }

    func cancel() {
        cancelled = true
        popover.performClose(nil)
    }

    /// Closed by Done, by a click elsewhere, or by Cancel.
    func popoverWillClose(_ notification: Notification) {
        finish()
    }

    /// Kept unless cancelled or unchanged; once.
    func finish() {
        guard !cancelled else { return }
        cancelled = true
        if area.string != original { commit(area.string) }
    }
}

/// Escape cancels the text area, rather than offering completions.
final class AreaTextView: NSTextView {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { onCancel?() }
    }
}

/// The corner a text area is dragged larger by.
final class ResizeGrip: NSView {
    var onDrag: ((NSSize) -> Void)?
    var startSize: (() -> NSSize)?
    private var start: (mouse: NSPoint, size: NSSize)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
    }

    override func mouseDown(with event: NSEvent) {
        start = (NSEvent.mouseLocation, startSize?() ?? bounds.size)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let now = NSEvent.mouseLocation
        // Down the screen is taller: screen coordinates grow upwards.
        onDrag?(NSSize(width: start.size.width + now.x - start.mouse.x,
                       height: start.size.height - (now.y - start.mouse.y)))
    }

    override func mouseUp(with event: NSEvent) {
        start = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setStroke()
        let path = NSBezierPath()
        for inset in [2.0, 6.0, 10.0] {
            path.move(to: NSPoint(x: bounds.maxX - 1, y: bounds.minY + inset))
            path.line(to: NSPoint(x: bounds.maxX - inset, y: bounds.minY + 1))
        }
        path.lineWidth = 1
        path.stroke()
    }
}

/// Find in the tree, over its rows: the names and values that hold what is
/// typed, open or folded away. Return goes to the next, Shift-Return to the
/// one before, Escape closes it.
@MainActor
final class TreeFindBar: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    let count = NSTextField(labelWithString: "")
    var onChange: ((String) -> Void)?
    var onStep: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.placeholderString = "Find in names and values"
        field.sendsSearchStringImmediately = true
        field.delegate = self
        field.target = self
        field.action = #selector(changed)
        count.textColor = .secondaryLabelColor
        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let steps = NSSegmentedControl(images: [NSImage(systemSymbolName: "chevron.left",
                                                        accessibilityDescription: "Previous")!,
                                                NSImage(systemSymbolName: "chevron.right",
                                                        accessibilityDescription: "Next")!],
                                       trackingMode: .momentary, target: self, action: #selector(stepped(_:)))
        steps.setToolTip("Previous (\u{21E7}\u{21A9})", forSegment: 0)
        steps.setToolTip("Next (\u{21A9})", forSegment: 1)
        let done = NSButton(title: "Done", target: self, action: #selector(closed))
        done.bezelStyle = .rounded
        let separator = NSBox()
        separator.boxType = .separator
        for view in [field, count, steps, done, separator] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            count.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 8),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.widthAnchor.constraint(equalToConstant: 80),
            steps.leadingAnchor.constraint(equalTo: count.trailingAnchor, constant: 4),
            steps.centerYAnchor.constraint(equalTo: centerYAnchor),
            done.leadingAnchor.constraint(equalTo: steps.trailingAnchor, constant: 8),
            done.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            done.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func changed() { onChange?(field.stringValue) }
    @objc private func stepped(_ sender: NSSegmentedControl) { onStep?(sender.selectedSegment == 1) }
    @objc private func closed() { onClose?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onStep?(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
