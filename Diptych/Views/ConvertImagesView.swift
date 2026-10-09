import SwiftUI

/// Convert… and Resize…: the format, the quality, the size, the metadata,
/// and where the new images go. The originals are never touched.
struct ConvertImagesView: View {

    @Bindable var model: AppModel

    private static let sides = [4096, 3072, 2048, 1600, 1280, 1024, 800, 640]

    private var count: Int { model.convertingImages.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(count == 1 ? "Convert \u{201C}\(model.convertingImages[0].lastPathComponent)\u{201D}"
                            : "Convert \(count) Images")
                .font(.headline)
            Text("New images are made; the originals stay as they are. Undo moves the new "
                 + "ones to the Trash.")
                .font(.subheadline).foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Format")
                    Picker("", selection: $model.convertOptions.format) {
                        ForEach(ImageMaking.Format.allCases.filter(\.isWritable)) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                GridRow {
                    Text("Quality")
                    HStack {
                        Slider(value: $model.convertOptions.quality, in: 0.3...1, step: 0.05)
                            .frame(width: 180)
                        Text("\(Int((model.convertOptions.quality * 100).rounded())) %")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .disabled(!qualityMatters)
                }
                GridRow {
                    Text("Size")
                    Picker("", selection: $model.convertOptions.longestSide) {
                        Text("Keep the size").tag(Int?.none)
                        ForEach(Self.sides, id: \.self) { side in
                            Text("Longest side \(side) px").tag(Int?.some(side))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .help("An image already smaller is not made larger")
                }
                GridRow {
                    Text("Metadata")
                    Toggle("Keep EXIF, location and the rest", isOn: $model.convertOptions.keepMetadata)
                        .toggleStyle(.checkbox)
                }
                GridRow {
                    Text("Into")
                    Picker("", selection: $model.convertOptions.folder) {
                        Text("Next to the originals").tag(URL?.none)
                        if let other = model.otherPaneFolder {
                            Text("The other pane: \(other.lastPathComponent)").tag(URL?.some(other))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 260)
                }
            }

            Text(namesHint)
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { model.dialog = nil }
                    .keyboardShortcut(.cancelAction)
                Button(model.convertOptions.longestSide != nil
                       && model.convertOptions.format == .same ? "Resize" : "Convert") {
                    model.convertImages()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.convertOptions.changesNothing)
            }
        }
    }

    private var qualityMatters: Bool {
        let format = model.convertOptions.format
        if format.isLossy { return true }
        // Keeping the format: only where the images are JPEG or HEIC.
        return format == .same && model.convertingImages.contains {
            ["jpg", "jpeg", "heic", "heif"].contains($0.pathExtension.lowercased())
        }
    }

    /// What the first new image will be called.
    private var namesHint: String {
        guard let first = model.convertingImages.first else { return "" }
        let options = model.convertOptions
        if options.changesNothing { return "Choose another format, or a size." }
        let ext = ImageMaking.fileExtension(of: first, format: options.format)
        let label = options.longestSide.map { " (\($0))" } ?? ""
        return "\(first.lastPathComponent) \u{2192} "
            + "\(first.deletingPathExtension().lastPathComponent)\(label).\(ext)"
            + " \u{2014} a number is added where the name is taken."
    }
}
