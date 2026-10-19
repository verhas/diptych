import SwiftUI
import AppKit

/// File ▸ Optimize File Size…: the files and what each would become, the
/// settings of each kind present, and the selected file before and after.
struct OptimizeView: View {

    let request: OptimizeRequest

    @State private var model: OptimizeModel
    @Environment(\.dismiss) private var dismiss

    init(request: OptimizeRequest) {
        self.request = request
        _model = State(initialValue: OptimizeModel(request))
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    table
                    Divider()
                    ScrollView { settings.padding(14) }
                        .frame(minHeight: 200, idealHeight: 260)
                }
                .frame(minWidth: 460, idealWidth: 540)
                ComparisonView(model: model)
                    .frame(minWidth: 360)
            }
            Divider()
            bottom
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 900, minHeight: 600)
        .navigationTitle(model.rows.count == 1
                         ? "Optimize \u{201C}\(model.rows[0].url.lastPathComponent)\u{201D}"
                         : "Optimize \(model.rows.count) Files")
        .onAppear { model.start() }
        .onDisappear { model.close() }
        .onChange(of: model.finished) { _, done in if done { dismiss() } }
        .background(WindowAccessor { window in
            if let window {
                AppWindows.shared.register(window)
                WindowSubjects.shared.register(window, kind: "optimize",
                                               description: request.items.first?.path ?? "")
            }
        })
    }

    // MARK: - The files

    private var table: some View {
        Table(model.rows, selection: Binding(get: { model.selection },
                                             set: { model.selection = $0 })) {
            TableColumn("") { row in
                // Only what would get smaller can be chosen.
                Toggle("", isOn: Binding(get: { row.isIncluded && row.helps },
                                         set: { _ in model.toggle(row.url) }))
                    .labelsHidden()
                    .disabled(row.candidate == nil || !row.helps)
                    .help(row.problem ?? row.note ?? "")
            }
            .width(22)
            TableColumn("Name") { row in
                Text(row.url.lastPathComponent)
                    .lineLimit(1).truncationMode(.middle)
                    .help(row.problem ?? row.note ?? row.url.path)
            }
            TableColumn("Kind") { row in Text(row.kind.short).foregroundStyle(.secondary) }
                .width(44)
            TableColumn("Size") { row in
                Text(Self.bytes(row.size)).monospacedDigit()
            }
            .width(68)
            TableColumn("New size") { row in
                if let size = row.newSize {
                    Text(Self.bytes(size)).monospacedDigit()
                } else if row.isPointless {
                    Text("\u{2014}").foregroundStyle(.secondary).help(row.problem ?? "")
                } else if row.problem != nil {
                    Text("failed").foregroundStyle(.red).help(row.problem ?? "")
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .width(72)
            TableColumn("Saves") { row in
                if let saving = row.saving {
                    Text(saving.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .foregroundStyle(row.helps ? Color.primary : Color.orange)
                        .help(row.note ?? "")
                }
            }
            .width(50)
        }
    }

    // MARK: - Settings

    private static let sides = [4096, 3072, 2560, 2048, 1600, 1280]
    private static let resolutions = [300, 200, 150, 110, 72]

    @ViewBuilder
    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(model.kinds) { kind in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(kind.title) \u{2014} \(model.count(of: kind)) file"
                         + (model.count(of: kind) == 1 ? "" : "s"))
                        .font(.headline)
                    switch kind {
                    case .photo: photoSettings
                    case .png:   pngSettings
                    case .pdf:   pdfSettings
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(model.isApplying)
    }

    private var photoSettings: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Quality")
                quality($model.settings.photoQuality)
            }
            GridRow {
                Text("Size")
                Picker("", selection: $model.settings.photoLongestSide) {
                    Text("Keep the size").tag(Int?.none)
                    ForEach(Self.sides, id: \.self) { Text("Longest side \($0) px").tag(Int?.some($0)) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            GridRow {
                Text("")
                Toggle("Keep EXIF, location and the rest", isOn: $model.settings.photoKeepMetadata)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private var pngSettings: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Colours")
                Picker("", selection: $model.settings.pngColours) {
                    Text("All of them, written again without loss").tag(Int?.none)
                    ForEach([256, 128, 64, 32], id: \.self) { Text("At most \($0)").tag(Int?.some($0)) }
                }
                .labelsHidden()
                .frame(width: 260)
            }
            GridRow {
                Text("")
                Toggle("Dither, so gradients stay smooth", isOn: $model.settings.pngDither)
                    .toggleStyle(.checkbox)
                    .disabled(model.settings.pngColours == nil)
            }
            GridRow {
                Text("")
                Text("Fewer colours suits screenshots and drawings; a photo saved as PNG may band. "
                     + "A PNG with transparency keeps its colours.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pdfSettings: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Pictures")
                quality($model.settings.pdfQuality)
            }
            GridRow {
                Text("Resolution")
                Picker("", selection: $model.settings.pdfResolution) {
                    Text(model.pdfResolutionNow.map { "Keep it (\($0))" } ?? "Keep it").tag(Int?.none)
                    ForEach(Self.resolutions, id: \.self) { Text("\($0) pixels per inch").tag(Int?.some($0)) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            if let now = model.pdfResolutionNow {
                GridRow {
                    Text("")
                    Text("The pictures are now \(now), worked out from their width and the "
                         + "page\u{2019}s. A lower resolution than that is what makes it smaller.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            GridRow {
                Text("")
                Text("Only the pictures in it change; text and drawings stay sharp. Pictures are "
                     + "written as JPEG, so a black-and-white scan, one bit per pixel, is left as "
                     + "it is: it would only grow. A signed PDF "
                     + "loses its signature when it is written again.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func quality(_ value: Binding<Double>) -> some View {
        HStack {
            Slider(value: value, in: 0.2...1, step: 0.05).frame(width: 200)
            Text("\(Int((value.wrappedValue * 100).rounded())) %")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Below

    private var bottom: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                let totals = model.totals
                Text(model.included.isEmpty
                     ? (model.isWorking ? "Working out the sizes\u{2026}" : "Nothing would get smaller.")
                     : "\(model.included.count) file\(model.included.count == 1 ? "" : "s"): "
                       + "\(Self.bytes(totals.before)) \u{2192} \(Self.bytes(totals.after))"
                       + (totals.before > 0
                          ? ", saves \((1 - Double(totals.after) / Double(totals.before)).formatted(.percent.precision(.fractionLength(0))))"
                          : ""))
                    .monospacedDigit()
                ForEach(model.problems, id: \.self) {
                    Text($0).foregroundStyle(.red).font(.caption).textSelection(.enabled)
                }
            }
            Spacer()
            Toggle("Keep the modified date", isOn: $model.settings.keepModifiedDate)
                .toggleStyle(.checkbox)
            Picker("", selection: $model.settings.replaceOriginals) {
                Text("Replace the originals (Undo puts them back)").tag(true)
                Text("Save beside them as \u{201C}name (optimized)\u{201D}").tag(false)
            }
            .labelsHidden()
            .frame(width: 290)
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(model.included.count <= 1 ? "Optimize" : "Optimize \(model.included.count) Files") {
                model.apply()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.included.isEmpty || model.isApplying)
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// The selected file as it is and as it would be: one picture, the original
/// left of a line and the smaller one right of it. Dragging moves the line;
/// zoomed in, the two are compared pixel for pixel.
private struct ComparisonView: View {

    @Bindable var model: OptimizeModel
    @State private var split = 0.5
    @State private var zoom = Zoom.fit
    @Environment(\.displayScale) private var displayScale

    enum Zoom: String, CaseIterable, Identifiable {
        case fit, actual, double
        var id: String { rawValue }
        var title: String {
            switch self {
            case .fit:    "Fit"
            case .actual: "100 %"
            case .double: "200 %"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let row = model.selectedRow {
                    Text("Before \u{2014} \(OptimizeView.bytes(row.size))")
                    if let pictures = row.pictures {
                        Text(pictures.summary).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Spacer()
                    if row.kind == .pdf, model.pageCount > 1 {
                        // Down for the next page, as pages follow each other
                        // down: the stepper's increment is its up arrow.
                        Stepper("Page \(model.page + 1) of \(model.pageCount)",
                                onIncrement: { model.page = max(model.page - 1, 0) },
                                onDecrement: { model.page = min(model.page + 1, model.pageCount - 1) })
                            .fixedSize()
                        Spacer()
                    }
                    Text("After \u{2014} " + (row.newSize.map(OptimizeView.bytes) ?? "\u{2026}"))
                } else {
                    Spacer()
                }
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            picture
            Divider()
            HStack {
                Picker("", selection: $zoom) {
                    ForEach(Zoom.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                Spacer()
                Text("Drag across the picture to move the line")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var picture: some View {
        if let before = model.before {
            GeometryReader { space in
                let size = pictureSize(before, in: space.size)
                let content = wiped(before, after: model.after, size: size)
                if zoom == .fit {
                    content.frame(width: space.size.width, height: space.size.height)
                } else {
                    ScrollView([.horizontal, .vertical]) { content }
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .overlay(alignment: .top) {
                if let row = model.selectedRow, let problem = row.problem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(row.isPointless ? Color.primary : Color.red)
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(12)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if let problem = model.selectedRow?.problem {
            Text(problem).foregroundStyle(.red).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func pictureSize(_ image: CGImage, in space: CGSize) -> CGSize {
        let natural = CGSize(width: Double(image.width) / displayScale,
                             height: Double(image.height) / displayScale)
        switch zoom {
        case .fit:
            let scale = min(space.width / max(natural.width, 1), space.height / max(natural.height, 1), 1)
            return CGSize(width: natural.width * scale, height: natural.height * scale)
        case .actual: return natural
        case .double: return CGSize(width: natural.width * 2, height: natural.height * 2)
        }
    }

    private func wiped(_ before: CGImage, after: CGImage?, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let after {
                    Image(decorative: after, scale: 1).resizable().interpolation(.none)
                } else {
                    Image(decorative: before, scale: 1).resizable().interpolation(.none)
                        .opacity(model.selectedRow?.problem == nil ? 0.35 : 1)
                }
            }
            .frame(width: size.width, height: size.height)
            Image(decorative: before, scale: 1).resizable().interpolation(.none)
                .frame(width: size.width, height: size.height)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: size.width * split)
                }
            Rectangle()
                .fill(Color.white)
                .frame(width: 1.5, height: size.height)
                .shadow(color: .black.opacity(0.6), radius: 1)
                .offset(x: size.width * split - 0.75)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            split = min(max(drag.location.x / max(size.width, 1), 0), 1)
        })
    }
}
