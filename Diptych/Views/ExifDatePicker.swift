import AppKit
import SwiftUI

/// A date, a time, or both, edited a part at a time -- year, month, day,
/// hour, minute, second -- as EXIF writes them.
///
/// Not `NSDatePicker`. Its typing starts a new number after a pause, so a
/// year typed as "202", a breath, then "6" came out as 6. Here a new number
/// starts only when a part fills up or another part is chosen: click, Tab, or
/// the arrow keys. Up and Down step the part chosen.
///
/// The text it edits has no zone, and neither has this: the parts are the
/// numbers written, not a moment moved into this Mac's time zone.
struct ExifDatePicker: View {

    enum Parts { case dateTime, date, time }

    let text: String
    let parts: Parts
    var dimmed = false
    let onChange: (String) -> Void
    /// Clicked or tabbed into.
    var onFocus: () -> Void = {}

    /// SwiftUI does not ask the view where its text sits, and took its top
    /// edge for the baseline: the label beside it rode a line high.
    var body: some View {
        DatePartsView(text: text, parts: parts, dimmed: dimmed, onChange: onChange, onFocus: onFocus)
            .alignmentGuide(.firstTextBaseline) { DatePartsField.baseline(inHeight: $0.height) }
            .alignmentGuide(.lastTextBaseline) { DatePartsField.baseline(inHeight: $0.height) }
    }
}

private struct DatePartsView: NSViewRepresentable {

    let text: String
    let parts: ExifDatePicker.Parts
    let dimmed: Bool
    let onChange: (String) -> Void
    let onFocus: () -> Void

    func makeNSView(context: Context) -> DatePartsField {
        let field = DatePartsField(parts: parts)
        field.onChange = onChange
        field.onFocus = onFocus
        field.show(text)
        field.dimmed = dimmed
        return field
    }

    func updateNSView(_ field: DatePartsField, context: Context) {
        field.onChange = onChange
        field.onFocus = onFocus
        field.dimmed = dimmed
        // Not under the typing: what is half typed is the field's own.
        if !field.isTyping { field.show(text) }
    }
}

final class DatePartsField: NSView {

    enum Part: CaseIterable {
        case year, month, day, hour, minute, second

        var width: Int { self == .year ? 4 : 2 }

        var range: ClosedRange<Int> {
            switch self {
            case .year:           1...9999
            case .month:          1...12
            case .day:            1...31
            case .hour:           0...23
            case .minute, .second: 0...59
            }
        }
    }

    let parts: [Part]
    private(set) var values: [Int]
    /// The part chosen, while the field has the keyboard.
    private var chosen: Int?
    /// Digits typed into the chosen part so far.
    private var typed = ""

    var onChange: (String) -> Void = { _ in }
    var onFocus: () -> Void = {}
    var dimmed = false { didSet { if dimmed != oldValue { needsDisplay = true } } }

    var isTyping: Bool { !typed.isEmpty }

    private nonisolated static var font: NSFont {
        .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    private var font: NSFont { Self.font }

    init(parts: ExifDatePicker.Parts) {
        switch parts {
        case .dateTime: self.parts = Part.allCases
        case .date:     self.parts = [.year, .month, .day]
        case .time:     self.parts = [.hour, .minute, .second]
        }
        values = self.parts.map { $0.range.lowerBound }
        super.init(frame: .zero)
        focusRingType = .exterior
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - The text

    /// `2024:06:30 18:45:00`, `2024:06:30` or `16:45:00`.
    func show(_ text: String) {
        let numbers = text.split(whereSeparator: { $0 == ":" || $0 == " " }).compactMap { Int($0) }
        guard numbers.count == parts.count else { return }
        if numbers != values {
            values = numbers
            needsDisplay = true
        }
    }

    var exifText: String {
        func two(_ value: Int) -> String { String(format: "%02d", value) }
        let pieces = zip(parts, values).map { part, value in
            part == .year ? String(format: "%04d", value) : two(value)
        }
        switch parts.count {
        case 6:
            return pieces[0..<3].joined(separator: ":") + " " + pieces[3..<6].joined(separator: ":")
        default:
            return pieces.joined(separator: ":")
        }
    }

    /// What is drawn: the part being typed shows what was typed so far.
    private var pieces: [(text: String, part: Int?)] {
        var result: [(String, Int?)] = []
        for (index, part) in parts.enumerated() {
            if index > 0 {
                let between = parts[index - 1] == .day ? "  " : part.rawSeparator
                result.append((between, nil))
            }
            let shown = index == chosen && !typed.isEmpty
                ? typed.padding(toLength: part.width, withPad: "\u{2007}", startingAt: 0)
                : String(format: part == .year ? "%04d" : "%02d", values[index])
            result.append((shown, index))
        }
        return result
    }

    // MARK: - Drawing

    private static let inset = NSSize(width: 6, height: 3)

    override var intrinsicContentSize: NSSize {
        let width = pieces.map { size(of: $0.text).width }.reduce(0, +)
        return NSSize(width: ceil(width) + Self.inset.width * 2,
                      height: ceil(font.ascender - font.descender) + Self.inset.height * 2 + 2)
    }

    /// Where the text sits, so that a label beside it lines up with it.
    override var firstBaselineOffsetFromTop: CGFloat {
        Self.baseline(inHeight: bounds.height > 0 ? bounds.height : intrinsicContentSize.height)
    }

    override var lastBaselineOffsetFromBottom: CGFloat {
        let height = bounds.height > 0 ? bounds.height : intrinsicContentSize.height
        return height - Self.baseline(inHeight: height)
    }

    nonisolated static func baseline(inHeight height: CGFloat) -> CGFloat {
        textTop(in: height) + font.ascender
    }

    private nonisolated static func textTop(in height: CGFloat) -> CGFloat {
        (height - (font.ascender - font.descender)) / 2
    }

    private func size(of text: String) -> NSSize {
        (text as NSString).size(withAttributes: [.font: font])
    }

    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        let box = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
        NSColor.textBackgroundColor.setFill()
        box.fill()
        NSColor.separatorColor.setStroke()
        box.stroke()

        var x = Self.inset.width
        let baseline = Self.textTop(in: bounds.height)
        let focused = window?.firstResponder === self
        for piece in pieces {
            let width = size(of: piece.text).width
            let rect = NSRect(x: x, y: baseline, width: width,
                              height: font.ascender - font.descender)
            var colour: NSColor = dimmed ? .secondaryLabelColor : .labelColor
            if focused, let part = piece.part, part == chosen {
                NSColor.selectedTextBackgroundColor.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: 0), xRadius: 2, yRadius: 2).fill()
                colour = .selectedTextColor
            } else if piece.part == nil {
                colour = .secondaryLabelColor
            }
            (piece.text as NSString).draw(at: NSPoint(x: x, y: baseline),
                                          withAttributes: [.font: font, .foregroundColor: colour])
            x += width
        }
    }

    override var isFlipped: Bool { true }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    // MARK: - The keyboard and the mouse

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        if chosen == nil { chosen = 0 }
        needsDisplay = true
        onFocus()
        return true
    }

    override func resignFirstResponder() -> Bool {
        finishTyping()
        chosen = nil
        needsDisplay = true
        return true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let part = self.part(at: point.x)
        if window?.firstResponder !== self {
            chosen = part
            window?.makeFirstResponder(self)
        } else {
            choose(part)
        }
    }

    private func part(at x: CGFloat) -> Int {
        var left = Self.inset.width
        var nearest = 0
        for piece in pieces {
            let width = size(of: piece.text).width
            if let part = piece.part {
                nearest = part
                if x < left + width { return part }
            }
            left += width
        }
        return nearest
    }

    override func keyDown(with event: NSEvent) {
        guard let chosen else { return super.keyDown(with: event) }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 123: choose(chosen - 1)                          // left
        case 124: choose(chosen + 1)                          // right
        case 126: step(by: 1)                                 // up
        case 125: step(by: -1)                                // down
        case 48:                                              // tab
            if shift ? chosen == 0 : chosen == parts.count - 1 {
                finishTyping()
                shift ? window?.selectPreviousKeyView(self) : window?.selectNextKeyView(self)
            } else {
                choose(chosen + (shift ? -1 : 1))
            }
        case 51:                                              // delete
            // A part already complete is taken up again, less its last
            // digit: 1976, delete, 7 is 1977.
            if typed.isEmpty {
                typed = String(format: parts[chosen] == .year ? "%04d" : "%02d", values[chosen])
            }
            typed.removeLast()
            needsDisplay = true
        case 36, 76:                                          // return, enter
            finishTyping()
            nextResponder?.keyDown(with: event)
        default:
            guard let characters = event.characters, characters.count == 1,
                  let digit = characters.first, digit.isASCII, digit.isNumber else {
                return super.keyDown(with: event)
            }
            type(digit)
        }
    }

    /// Another part: whatever was typed into this one is taken as it stands.
    private func choose(_ index: Int) {
        finishTyping()
        chosen = min(max(index, 0), parts.count - 1)
        needsDisplay = true
    }

    /// A digit into the chosen part. Once the part is complete -- all its
    /// digits typed, or a digit no other can follow -- the next digit starts
    /// it again; nothing else does, not a pause, however long.
    private func type(_ digit: Character) {
        guard let chosen else { return }
        let part = parts[chosen]
        typed.append(digit)
        let value = Int(typed)!

        if typed.count == part.width {
            if part.range.contains(value) {
                complete(value, at: chosen)
            } else {
                // 13 is no month: the 3 starts a new one.
                typed = String(digit)
                take(Int(typed)!, at: chosen)
            }
        } else {
            take(value, at: chosen)
        }
        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    /// A part's digits so far: complete when no digit could follow -- a 4 in
    /// a month is April -- and otherwise left for the next one.
    private func take(_ value: Int, at index: Int) {
        let part = parts[index]
        if part.width == 2, typed.count == 1, value * 10 > part.range.upperBound,
           part.range.contains(value) {
            complete(value, at: index)
        }
    }

    private func complete(_ value: Int, at index: Int) {
        typed = ""
        set(value, at: index)
    }

    /// What was typed, taken: a year left at "202" is the year 202.
    private func finishTyping() {
        guard let chosen, !typed.isEmpty else { return }
        let value = Int(typed) ?? values[chosen]
        typed = ""
        if parts[chosen].range.contains(value) { set(value, at: chosen) }
        needsDisplay = true
    }

    private func step(by amount: Int) {
        guard let chosen else { return }
        finishTyping()
        let range = parts[chosen].range
        var value = values[chosen] + amount
        if parts[chosen] != .year {
            let count = range.count
            value = (value - range.lowerBound + count) % count + range.lowerBound
        }
        set(min(max(value, range.lowerBound), range.upperBound), at: chosen)
    }

    private func set(_ value: Int, at index: Int) {
        values[index] = value
        // The 31st of a month with 30 days is its last day.
        if let year = parts.firstIndex(of: .year), let month = parts.firstIndex(of: .month),
           let day = parts.firstIndex(of: .day) {
            var components = DateComponents(year: values[year], month: values[month])
            components.calendar = Calendar(identifier: .gregorian)
            if let date = components.date,
               let days = components.calendar?.range(of: .day, in: .month, for: date)?.count {
                values[day] = min(values[day], days)
            }
        }
        needsDisplay = true
        onChange(exifText)
    }
}

private extension DatePartsField.Part {
    /// Between this part and the one before it.
    var rawSeparator: String {
        switch self {
        case .month, .day:              "-"
        case .minute, .second:          ":"
        case .year, .hour:              ""
        }
    }
}
