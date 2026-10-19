import SwiftUI

/// Image ▸ Make PDF…: a page for each picture and for each page of a TIFF,
/// in a PDF of its own or all in one.
struct MakePDFView: View {

    @Bindable var model: AppModel

    private var count: Int { model.pdfImages.count }

    private var pages: Int? {
        let counts = model.pdfImages.compactMap { model.pdfPageCounts[$0] }
        return counts.count == count ? counts.reduce(0, +) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(count == 1 ? "Make a PDF of \u{201C}\(model.pdfImages[0].lastPathComponent)\u{201D}"
                            : "Make PDFs of \(count) Images")
                .font(.headline)
            Text(pagesLine)
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                if count > 1 {
                    GridRow {
                        Text("Make")
                        Picker("", selection: $model.pdfOptions.combine) {
                            Text("One PDF for each image").tag(false)
                            Text("One PDF of them all, in the pane\u{2019}s order").tag(true)
                        }
                        .labelsHidden()
                        .frame(width: 300)
                    }
                }
                if model.pdfOptions.combine {
                    GridRow {
                        Text("Name")
                        HStack(spacing: 4) {
                            TextField("Pictures", text: $model.pdfOptions.name)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                            Text(".pdf").foregroundStyle(.secondary)
                        }
                    }
                }
                GridRow {
                    Text("Pages")
                    Picker("", selection: $model.pdfOptions.pageSize) {
                        ForEach(PDFMaking.PageSize.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .help("The picture's own size comes from its resolution: an A4 page scanned "
                          + "at 300 ppi is an A4 page. On A4 or Letter, the picture is fitted in.")
                }
                GridRow {
                    Text("Into")
                    Picker("", selection: $model.pdfOptions.folder) {
                        Text("Next to the images").tag(URL?.none)
                        if let other = model.otherPaneFolder {
                            Text("The other pane: \(other.lastPathComponent)").tag(URL?.some(other))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 260)
                }
            }

            Text("A JPEG goes in as it is, without being compressed again; other pictures "
                 + "without loss. Undo moves the PDF to the Trash.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { model.dialog = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Make PDF") { model.makePDF() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var pagesLine: String {
        guard let pages else { return "Counting the pages\u{2026}" }
        let multi = model.pdfImages.filter { (model.pdfPageCounts[$0] ?? 1) > 1 }
        var line = pages == 1 ? "1 page." : "\(pages) pages"
        if pages > 1 {
            line += multi.isEmpty ? "." : ", "
                + multi.prefix(2).map { "\u{201C}\($0.lastPathComponent)\u{201D} has "
                                        + "\(model.pdfPageCounts[$0] ?? 0)" }
                    .joined(separator: ", ")
                + (multi.count > 2 ? " and more" : "") + "."
        }
        return line
    }
}
