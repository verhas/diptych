import SwiftUI
import AppKit

/// Two pages laid one over the other, flipping between them: the way to see
/// what a comparison by eye could only describe. What moves when they flip is
/// what differs.
///
/// A is the left file, B the right. Both are drawn the same size, so a flip
/// changes only what differs. The two can be zoomed into and moved about
/// together, to look at one spot.
struct VisualPreviewView: View {

    let pair: DiffPair

    @State private var model: VisualPreviewModel

    init(pair: DiffPair) {
        self.pair = pair
        _model = State(initialValue: VisualPreviewModel(pair: pair))
    }

    /// The flip intervals offered, in seconds; nil never flips.
    static let intervals: [Double?] = [0.1, 0.2, 0.5, 1, 2, 5, 10, nil]
    static let zoomRange: ClosedRange<CGFloat> = 1...32

    @AppStorage("visualPreview.interval") private var intervalIndex = 3
    @AppStorage("visualPreview.mix") private var mix = 0.0
    @AppStorage("visualPreview.align") private var align = false
    /// Which of the two is in front: true for A.
    @State private var showingA = true
    /// How far in, 1 for the whole page fitted into the window.
    @State private var zoom: CGFloat = 1
    /// How far the page has been moved from the middle, in points.
    @State private var pan: CGSize = .zero
    @FocusState private var focused: Bool

    private var interval: Double? {
        Self.intervals[min(max(intervalIndex, 0), Self.intervals.count - 1)]
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            picture
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 480)
        .navigationTitle("Preview: " + pair.title)
        .task { await model.open() }
        .task(id: model.page) { await model.loadPage(align: align) }
        .onChange(of: align) { _, on in Task { await model.loadPage(align: on) } }
        .task(id: intervalIndex) { await flip() }
        .onDisappear { model.close() }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { model.step(-1); return .handled }
        .onKeyPress(.rightArrow) { model.step(1); return .handled }
        .onKeyPress(.space) { showingA.toggle(); return .handled }
    }

    /// Flips for as long as the window shows, at the chosen pace.
    private func flip() async {
        while !Task.isCancelled {
            guard let interval else { return }
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            showingA.toggle()
        }
    }

    // MARK: - The parts

    private var controls: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(model.page == 0)
                    .help("Previous page (Left Arrow)")
                Text(model.pageCount > 0 ? "Page \(model.page + 1) of \(model.pageCount)" : "\u{2014}")
                    .monospacedDigit()
                    .frame(minWidth: 90)
                Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(model.page + 1 >= model.pageCount)
                    .help("Next page (Right Arrow)")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Flip every " + Self.intervalName(interval)).font(.caption)
                Slider(value: Binding(get: { Double(intervalIndex) },
                                      set: { intervalIndex = Int($0.rounded()) }),
                       in: 0...Double(Self.intervals.count - 1), step: 1)
                    .frame(width: 170)
            }
            .help("How often the two change places. At \u{201C}never\u{201D}, Space flips them.")

            VStack(alignment: .leading, spacing: 2) {
                Text("Mix \(Int((mix * 100).rounded()))%").font(.caption).monospacedDigit()
                Slider(value: $mix, in: 0...1)
                    .frame(width: 150)
            }
            .help("How much of the other one shows through. At 0% each is shown alone; at 50% "
                  + "both are shown evenly and nothing changes when they flip.")

            Toggle("Align turn, size and offset", isOn: $align)
                .toggleStyle(.checkbox)
                .help("Turn, resize and move B so it lies over A as closely as it can: for two "
                      + "scans of the same page, or a copy scaled to fit. B moves to each better "
                      + "fit as it is found; what was found once is kept.")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var picture: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let images = model.images {
                let size = CGSize(width: images.width, height: images.height)
                GeometryReader { geometry in
                    let container = geometry.size
                    let fit = min(container.width / size.width, container.height / size.height)
                    let base = CGSize(width: size.width * fit, height: size.height * fit)
                    let shown = CGSize(width: base.width * zoom, height: base.height * zoom)
                    // B underneath, A over it at the weight of the moment: A
                    // alone and B alone at a mix of 0, the two evenly at 50%.
                    let weightA = showingA ? 1 - mix : mix
                    ZStack {
                        Color.white
                        Image(decorative: images.right, scale: 1)
                            .resizable()
                            .scaleEffect(model.pose.scale)
                            .rotationEffect(.radians(model.pose.angle))
                            .offset(x: model.pose.dx * shown.width, y: model.pose.dy * shown.height)
                            // B glides to each fit: from where it lies to one
                            // found before, and to each better one while the
                            // search runs.
                            .animation(model.glide, value: model.pose)
                        Image(decorative: images.left, scale: 1)
                            .resizable()
                            .opacity(weightA)
                    }
                    .frame(width: shown.width, height: shown.height)
                    .clipped()
                    .shadow(radius: 2)
                    .position(x: container.width / 2 + pan.width, y: container.height / 2 + pan.height)
                    // Zoomed in, the page reaches far past the window's
                    // middle. It is clipped where it is drawn, but would still
                    // take the clicks meant for the sliders above it; the
                    // surface below does all the page's handling anyway.
                    .allowsHitTesting(false)

                    ZoomPanSurface(
                        onPan: { delta in
                            pan = Self.clamped(CGSize(width: pan.width + delta.width,
                                                      height: pan.height + delta.height),
                                               shown: shown, in: container)
                        },
                        onZoom: { factor, point in zoom(by: factor, at: point, base: base, in: container) },
                        onReset: fitWhole)

                    zoomControls(base: base, sheet: images, container: container)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                .padding(12)
            } else if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            if let progress = model.alignProgress, model.alignIsSlow {
                // At the bottom, so the picture it is moving stays in sight.
                VStack(spacing: 6) {
                    Text("Aligning B with A\u{2026}").font(.subheadline)
                    ProgressView(value: progress.fraction).frame(width: 260)
                    Text(Self.remaining(progress.secondsLeft)).font(.caption).foregroundStyle(.secondary)
                    if let best = progress.best {
                        Text("Best so far: " + best.description).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Stop") { align = false }
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// −, how large, +, and back to the whole page.
    private func zoomControls(base: CGSize, sheet: PagePair, container: CGSize) -> some View {
        HStack(spacing: 4) {
            Button { zoom(by: 1 / 1.5, at: nil, base: base, in: container) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(zoom <= Self.zoomRange.lowerBound)
            .help("Zoom out (\u{2318}\u{2212})")
            Text(actualSize(base: base, sheet: sheet))
                .monospacedDigit()
                .frame(minWidth: 44)
                .help("The size shown, against the page's own: 100% is one pixel of a picture, "
                      + "or one point of a PDF, to a point on the screen.")
            Button { zoom(by: 1.5, at: nil, base: base, in: container) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(zoom >= Self.zoomRange.upperBound)
            .help("Zoom in (\u{2318}+). Pinch, or scroll with \u{2318} or \u{2325} held, zooms at the pointer; "
                  + "scrolling or dragging moves the page.")
            Button("Fit", action: fitWhole)
                .keyboardShortcut("0", modifiers: .command)
                .disabled(zoom == 1 && pan == .zero)
                .help("The whole page in the window again (\u{2318}0, or double-click)")
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    /// Each page's size on the screen against its own, as each fills its
    /// part of the sheet the two are on: one figure when they agree, both
    /// when they do not -- a 825-pixel picture and a 348-point PDF of one
    /// page do not.
    private func actualSize(base: CGSize, sheet: PagePair) -> String {
        guard sheet.width > 0 else { return "" }
        func percent(_ rect: CGRect, _ native: CGSize?) -> Int? {
            guard let native, native.width > 0 else { return nil }
            return Int((base.width * zoom * rect.width / CGFloat(sheet.width) / native.width * 100).rounded())
        }
        let a = percent(sheet.leftRect, model.nativeSize), b = percent(sheet.rightRect, model.nativeSizeB)
        switch (a, b) {
        case let (a?, b?) where abs(a - b) > 1: return "A \(a)% \u{B7} B \(b)%"
        case let (a?, _): return "\(a)%"
        default: return ""
        }
    }

    private func fitWhole() {
        withAnimation(.easeInOut(duration: 0.25)) {
            zoom = 1
            pan = .zero
        }
    }

    /// Zoomed by `factor`, keeping what is under `point` -- in the picture
    /// area, from its top left; the middle when nil -- where it is.
    private func zoom(by factor: CGFloat, at point: CGPoint?, base: CGSize, in container: CGSize) {
        let next = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        guard next != zoom else { return }
        let anchor = point ?? CGPoint(x: container.width / 2, y: container.height / 2)
        // The anchor, from the page's middle, grows with the page; the page's
        // middle moves so the anchor stays put.
        let centre = CGPoint(x: container.width / 2 + pan.width, y: container.height / 2 + pan.height)
        let k = next / zoom
        let moved = CGPoint(x: anchor.x - (anchor.x - centre.x) * k, y: anchor.y - (anchor.y - centre.y) * k)
        let shown = CGSize(width: base.width * next, height: base.height * next)
        let apply = {
            zoom = next
            pan = Self.clamped(CGSize(width: moved.x - container.width / 2, height: moved.y - container.height / 2),
                               shown: shown, in: container)
        }
        if point == nil { withAnimation(.easeInOut(duration: 0.2), apply) } else { apply() }
    }

    /// No further than keeps the page across the window: a page smaller than
    /// the window stays in its middle.
    static func clamped(_ pan: CGSize, shown: CGSize, in container: CGSize) -> CGSize {
        let x = max((shown.width - container.width) / 2, 0)
        let y = max((shown.height - container.height) / 2, 0)
        return CGSize(width: min(max(pan.width, -x), x), height: min(max(pan.height, -y), y))
    }

    private var footer: some View {
        let weightA = showingA ? 1 - mix : mix
        return HStack(spacing: 14) {
            sideLabel("A", pair.left, weight: weightA)
            sideLabel("B", pair.right, weight: 1 - weightA)
            Spacer()
            if model.images != nil {
                Text(fitDescription).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .help("How alike the two pages are, 100% for the same: how closely the ink of "
                          + "one follows the ink of the other, the paper left out.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// "They match best with B turned 6.02° anticlockwise, moved 5.9% left.
    /// Similarity is 75%."
    private var fitDescription: String {
        var text = ""
        if align {
            if let progress = model.alignProgress {
                text = "Aligning\u{2026} \(Int((progress.fraction * 100).rounded()))%."
            } else if model.transform == .identity {
                text = "B is already in place."
            } else {
                text = "They match best with B " + model.transform.description + "."
            }
        }
        if let similarity = model.similarity {
            let percent = "Similarity is \(Int((similarity * 100).rounded()))%"
            text += (text.isEmpty ? "" : " ") + percent + (model.alignProgress != nil ? " so far." : ".")
        }
        return text
    }

    private func sideLabel(_ letter: String, _ url: URL, weight: Double) -> some View {
        HStack(spacing: 5) {
            Text(letter).bold()
                .padding(.horizontal, 5)
                .background(Color.accentColor.opacity(0.15 + 0.6 * weight),
                            in: RoundedRectangle(cornerRadius: 3))
            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Text("\(Int((weight * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    static func intervalName(_ seconds: Double?) -> String {
        guard let seconds else { return ": never" }
        return seconds < 1 ? String(format: "%.1f s", seconds) : "\(Int(seconds)) s"
    }

    static func remaining(_ seconds: Double?) -> String {
        guard let seconds else { return "Working out how long\u{2026}" }
        let whole = Int(seconds.rounded(.up))
        return whole < 60 ? "About \(whole) s left" : "About \(whole / 60) min \(whole % 60) s left"
    }
}

/// The pages the preview shows, and the alignment of each: taken from the
/// store when the comparison, or an earlier preview, has found it.
@MainActor
@Observable
final class VisualPreviewModel {

    let pair: DiffPair
    private(set) var pageCount = 0
    private(set) var page = 0
    private(set) var images: PagePair?
    private(set) var failure: String?
    /// The fit, as far as it is known.
    private(set) var transform = ImageAlignment.Transform.identity
    /// How B is drawn: the fit's fine part, or on the way to it -- with a
    /// turn of its own, going from where B lies to upright.
    private(set) var pose = ImageAlignment.Transform.identity
    @ObservationIgnored private var shownPage = -1
    /// How the next change of `pose` is shown: nil for at once.
    private(set) var glide: Animation? = nil
    /// How alike the two are as shown: 0 to 1.
    private(set) var similarity: Double?
    private(set) var alignProgress: ImageAlignment.Progress?
    /// Shown only once an alignment has taken two seconds: a quick one would
    /// only flash a bar.
    private(set) var alignIsSlow = false
    /// The left page's own size: pixels for a picture, points for a PDF.
    private(set) var nativeSize: CGSize?
    /// The right one's, at the shape it is shown: turned, when it is.
    var nativeSizeB: CGSize? {
        guard let size = unturnedSizeB else { return nil }
        return shownQuarterTurns % 2 == 0 ? size : CGSize(width: size.height, height: size.width)
    }
    private(set) var unturnedSizeB: CGSize?
    /// The quarter turns `images` has B drawn with.
    private(set) var shownQuarterTurns = 0

    @ObservationIgnored private var sources: (VisualSource, VisualSource)?
    @ObservationIgnored private var rendered: [Int: PagePair] = [:]
    /// The two drawn with B turned, by page and quarter turns: on a sheet of
    /// the shape B then has, which can differ from the upright one's.
    @ObservationIgnored private var turned: [Int: [Int: PagePair]] = [:]
    @ObservationIgnored private var unaligned: [Int: Double] = [:]
    @ObservationIgnored private var cancel: CancellationFlag?

    init(pair: DiffPair) {
        self.pair = pair
    }

    func open() async {
        let pair = pair
        let opened = await BlockingWork.run { () -> SourcePair? in
            guard let a = VisualSource.open(pair.left), let b = VisualSource.open(pair.right) else { return nil }
            return SourcePair(a: a, b: b)
        }
        guard let opened else {
            failure = "These files cannot be shown as pages or pictures."
            return
        }
        sources = (opened.a, opened.b)
        guard opened.a.pageCount == opened.b.pageCount else {
            failure = "They do not have the same number of pages."
            return
        }
        pageCount = opened.a.pageCount
        await loadPage(align: UserDefaults.standard.bool(forKey: "visualPreview.align"))
    }

    func step(_ by: Int) {
        let next = page + by
        guard next >= 0, next < pageCount else { return }
        page = next
    }

    func close() {
        cancel?.cancel()
    }

    /// The current page, drawn, and aligned when asked.
    func loadPage(align: Bool) async {
        guard let (a, b) = sources, pageCount > 0 else { return }
        let page = page
        cancel?.cancel()
        let cancel = CancellationFlag()
        self.cancel = cancel
        alignProgress = nil
        alignIsSlow = false
        if rendered[page] == nil {
            let screen = NSScreen.main.map { Int(max($0.frame.width, $0.frame.height) * $0.backingScaleFactor) }
            let longSide = min(screen ?? 2400, 3000)
            let pages = SourcePair(a: a, b: b)
            rendered[page] = await BlockingWork.run {
                PagePair.render(pages.a, pages.b, page: page, longSide: longSide)
            }
        }
        func current() -> Bool { !cancel.isCancelled && page == self.page }
        guard current() else { return }
        nativeSize = a.size(of: page)
        unturnedSizeB = b.size(of: page)
        guard let upright = rendered[page] else {
            images = nil
            failure = "Page \(page + 1) could not be drawn."
            return
        }
        // A turned pair of this page stays until it has been turned back,
        // below; anything else gives way at once.
        if shownQuarterTurns == 0 || shownPage != page || images == nil {
            images = upright
            shownQuarterTurns = 0
        }
        shownPage = page
        guard align else {
            // Back to where it lies: a turned B turned back first.
            glide = .easeInOut(duration: 0.4)
            transform = .identity
            if shownQuarterTurns != 0 {
                pose = Self.lying(quarterTurns: shownQuarterTurns)
                try? await Task.sleep(for: .milliseconds(400))
                guard current() else { return }
                glide = nil
                images = upright
                shownQuarterTurns = 0
            }
            pose = .identity
            await showUnalignedSimilarity(upright, page: page, current: current)
            return
        }

        // From where it lies to the fit, which is shown, not jumped to.
        glide = nil
        transform = .identity
        pose = .identity
        images = upright
        shownQuarterTurns = 0
        similarity = nil
        // Finer than a pixel of the page itself tells nothing, and finer than
        // 1600 no longer shows at the size the preview is drawn.
        let native = a.kind == .image ? Int(max(nativeSize?.width ?? 0, nativeSize?.height ?? 0)) : 0
        let target = min(1600, native > 0 ? native : 1600, max(upright.width, upright.height))
        let pages = SourcePair(a: a, b: b)

        alignProgress = ImageAlignment.Progress(fraction: 0, secondsLeft: nil)
        let slow = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, !cancel.isCancelled else { return }
            self?.alignIsSlow = true
        }
        defer { slow.cancel() }
        var start = AlignmentStore.shared.fit(pair, page: page)
        if start == nil {
            // Which way up, on small drawings: the quarter turns are tried
            // before the search proper.
            start = await BlockingWork.run { [weak self] in
                PagePair.roughFit(pages.a, pages.b, page: page, cancel: cancel) { done in
                    Task { @MainActor in
                        guard !cancel.isCancelled, let self, self.alignProgress != nil else { return }
                        self.alignProgress = ImageAlignment.Progress(fraction: 0.2 * done, secondsLeft: nil)
                    }
                }
            }
            guard current() else { return }
        }
        guard let start else {
            alignProgress = nil
            alignIsSlow = false
            return
        }

        // B the way up the fit has it, drawn so: shown first as it lies, then
        // turned and moved into place.
        let turns = start.transform.quarterTurns
        var sheet = upright
        if turns != 0 {
            if let known = turned[page]?[turns] {
                sheet = known
            } else if let drawn = await BlockingWork.run({
                PagePair.render(pages.a, pages.b, page: page, longSide: max(upright.width, upright.height),
                                quarterTurns: turns)
            }) {
                turned[page, default: [:]][turns] = drawn
                sheet = drawn
            }
            guard current() else { return }
            images = sheet
            shownQuarterTurns = turns
            pose = Self.lying(quarterTurns: turns)
        }
        try? await Task.sleep(for: .milliseconds(60))
        guard current() else { return }
        glide = .easeInOut(duration: 0.9)
        transform = start.transform
        pose = start.transform.fine
        similarity = start.similarity
        // Found on a picture as fine as this one: nothing to add.
        if start.finest >= target {
            alignProgress = nil
            alignIsSlow = false
            return
        }
        try? await Task.sleep(for: .milliseconds(900))
        guard current() else { return }

        glide = .easeOut(duration: 0.15)
        let base = alignProgress?.fraction ?? 0
        let search = sheet
        let found = await BlockingWork.run { [weak self] () -> ImageAlignment.Fit? in
            let sheet = search
            let scale = min(1, Double(target) / Double(max(sheet.width, sheet.height)))
            let w = max(Int(Double(sheet.width) * scale), 1), h = max(Int(Double(sheet.height) * scale), 1)
            guard let ga = GrayImage(sheet.left, width: w, height: h),
                  let gb = GrayImage(sheet.right, width: w, height: h) else { return nil }
            return ImageAlignment.find(ga, gb, around: start, cancel: cancel) { progress in
                Task { @MainActor in
                    guard !cancel.isCancelled, let self, self.alignProgress != nil else { return }
                    var shown = progress
                    shown.fraction = base + (1 - base) * progress.fraction
                    self.alignProgress = shown
                    // Shown as it is found: the picture moves towards the fit.
                    if let best = progress.best {
                        self.transform = best
                        self.pose = best.fine
                    }
                    self.similarity = progress.similarity
                }
            }
        }
        guard current() else { return }
        alignProgress = nil
        alignIsSlow = false
        if let found {
            AlignmentStore.shared.store(found, pair, page: page)
            transform = found.transform
            pose = found.transform.fine
            similarity = found.similarity
        }
    }

    /// The pose that shows B, drawn `quarterTurns` round, as it lies: turned
    /// back the shorter way.
    private static func lying(quarterTurns: Int) -> ImageAlignment.Transform {
        let turns = ((quarterTurns % 4) + 4) % 4
        let back = turns == 3 ? 1.0 : -Double(turns)
        var pose = ImageAlignment.Transform(angle: back * .pi / 2, dx: 0, dy: 0)
        pose.quarterTurns = quarterTurns
        return pose
    }

    /// How alike the two are as they lie: a rough figure, so at a size that
    /// takes a moment.
    private func showUnalignedSimilarity(_ images: PagePair, page: Int, current: () -> Bool) async {
        if let known = unaligned[page] {
            similarity = known
            return
        }
        similarity = nil
        let found = await BlockingWork.run { () -> Double? in
            let scale = min(1, 800 / Double(max(images.width, images.height)))
            let w = max(Int(Double(images.width) * scale), 1), h = max(Int(Double(images.height) * scale), 1)
            guard let ga = GrayImage(images.left, width: w, height: h),
                  let gb = GrayImage(images.right, width: w, height: h) else { return nil }
            return ImageAlignment.similarity(ga, gb)
        }
        guard current() else { return }
        unaligned[page] = found
        similarity = found
    }
}

/// Two sources handed across to the work queue together.
private struct SourcePair: @unchecked Sendable {
    let a: VisualSource
    let b: VisualSource
}

/// Where the mouse and the trackpad move and zoom the preview: scrolling and
/// dragging move the page, pinching or scrolling with ⌘ or ⌥ zooms at the
/// pointer, a double-click fits the whole page again.
private struct ZoomPanSurface: NSViewRepresentable {
    var onPan: (CGSize) -> Void
    var onZoom: (CGFloat, CGPoint) -> Void
    var onReset: () -> Void

    func makeNSView(context: Context) -> Surface { Surface() }

    func updateNSView(_ view: Surface, context: Context) {
        view.onPan = onPan
        view.onZoom = onZoom
        view.onReset = onReset
    }

    final class Surface: NSView {
        var onPan: ((CGSize) -> Void)?
        var onZoom: ((CGFloat, CGPoint) -> Void)?
        var onReset: (() -> Void)?

        /// From the top left, as SwiftUI measures.
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func scrollWheel(with event: NSEvent) {
            let precise = event.hasPreciseScrollingDeltas
            if !event.modifierFlags.intersection([.command, .option]).isEmpty {
                let amount = event.scrollingDeltaY * (precise ? 0.01 : 0.1)
                onZoom?(exp(amount), convert(event.locationInWindow, from: nil))
            } else {
                // A wheel counts in lines, a trackpad in points.
                let k: CGFloat = precise ? 1 : 12
                onPan?(CGSize(width: event.scrollingDeltaX * k, height: event.scrollingDeltaY * k))
            }
        }

        override func magnify(with event: NSEvent) {
            onZoom?(1 + event.magnification, convert(event.locationInWindow, from: nil))
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onReset?() }
        }

        override func mouseDragged(with event: NSEvent) {
            onPan?(CGSize(width: event.deltaX, height: event.deltaY))
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}
