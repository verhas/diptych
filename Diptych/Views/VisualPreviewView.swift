import SwiftUI
import AppKit

/// Two pages laid one over the other, flipping between them: the way to see
/// what a comparison by eye could only describe. What moves when they flip is
/// what differs.
///
/// A is the left file, B the right. Both are drawn the same size, so a flip
/// changes only what differs.
struct VisualPreviewView: View {

    let pair: DiffPair

    @State private var model: VisualPreviewModel

    init(pair: DiffPair) {
        self.pair = pair
        _model = State(initialValue: VisualPreviewModel(pair: pair))
    }

    /// The flip intervals offered, in seconds; nil never flips.
    static let intervals: [Double?] = [0.1, 0.2, 0.5, 1, 2, 5, 10, nil]

    @AppStorage("visualPreview.interval") private var intervalIndex = 3
    @AppStorage("visualPreview.mix") private var mix = 0.0
    @AppStorage("visualPreview.align") private var align = false
    /// Which of the two is in front: true for A.
    @State private var showingA = true
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

            Toggle("Align turn and offset", isOn: $align)
                .toggleStyle(.checkbox)
                .help("Turn and move B so it lies over A as closely as it can: for two scans of "
                      + "the same page.")
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
                    let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
                    let shown = CGSize(width: size.width * scale, height: size.height * scale)
                    // B underneath, A over it at the weight of the moment: A
                    // alone and B alone at a mix of 0, the two evenly at 50%.
                    let weightA = showingA ? 1 - mix : mix
                    ZStack {
                        Color.white
                        Image(decorative: images.right, scale: 1)
                            .resizable()
                            .rotationEffect(.radians(model.transform.angle))
                            .offset(x: model.transform.dx * shown.width, y: model.transform.dy * shown.height)
                        Image(decorative: images.left, scale: 1)
                            .resizable()
                            .opacity(weightA)
                    }
                    .frame(width: shown.width, height: shown.height)
                    .clipped()
                    .shadow(radius: 2)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
                .padding(12)
            } else if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            if let progress = model.alignProgress, model.alignIsSlow {
                VStack(spacing: 6) {
                    Text("Aligning B with A\u{2026}").font(.subheadline)
                    ProgressView(value: progress.fraction).frame(width: 260)
                    Text(Self.remaining(progress.secondsLeft)).font(.caption).foregroundStyle(.secondary)
                    Button("Stop") { align = false }
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        let weightA = showingA ? 1 - mix : mix
        return HStack(spacing: 14) {
            sideLabel("A", pair.left, weight: weightA)
            sideLabel("B", pair.right, weight: 1 - weightA)
            Spacer()
            if align, model.alignProgress == nil, model.images != nil {
                Text("B " + model.transform.description)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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

/// The pages the preview shows, and the alignment of each, worked out once.
@MainActor
@Observable
final class VisualPreviewModel {

    let pair: DiffPair
    private(set) var pageCount = 0
    private(set) var page = 0
    private(set) var images: PagePair?
    private(set) var failure: String?
    private(set) var transform = ImageAlignment.Transform.identity
    private(set) var alignProgress: ImageAlignment.Progress?
    /// Shown only once an alignment has taken two seconds: a quick one would
    /// only flash a bar.
    private(set) var alignIsSlow = false

    @ObservationIgnored private var sources: (VisualSource, VisualSource)?
    @ObservationIgnored private var rendered: [Int: PagePair] = [:]
    @ObservationIgnored private var aligned: [Int: ImageAlignment.Transform] = [:]
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
        guard page == self.page else { return }
        images = rendered[page]
        if images == nil { failure = "Page \(page + 1) could not be drawn." }
        guard align, let images else {
            transform = .identity
            return
        }
        if let known = aligned[page] {
            transform = known
            return
        }
        transform = .identity
        let cancel = CancellationFlag()
        self.cancel = cancel
        alignProgress = ImageAlignment.Progress(fraction: 0, secondsLeft: nil)
        let slow = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, !cancel.isCancelled else { return }
            self?.alignIsSlow = true
        }
        // At up to 1600 pixels: finer than that a pixel no longer shows at
        // the size the preview is drawn.
        let found = await BlockingWork.run { [weak self] () -> ImageAlignment.Transform? in
            let longSide = max(images.width, images.height)
            let scale = min(1, 1600 / Double(longSide))
            let w = max(Int(Double(images.width) * scale), 1), h = max(Int(Double(images.height) * scale), 1)
            guard let ga = GrayImage(images.left, width: w, height: h),
                  let gb = GrayImage(images.right, width: w, height: h) else { return .identity }
            return ImageAlignment.find(ga, gb, cancel: cancel) { progress in
                Task { @MainActor in
                    guard !cancel.isCancelled else { return }
                    self?.alignProgress = progress
                }
            }?.0
        }
        slow.cancel()
        guard !cancel.isCancelled, page == self.page else { return }
        alignProgress = nil
        alignIsSlow = false
        if let found {
            aligned[page] = found
            transform = found
        }
    }
}

/// Two sources handed across to the work queue together.
private struct SourcePair: @unchecked Sendable {
    let a: VisualSource
    let b: VisualSource
}
