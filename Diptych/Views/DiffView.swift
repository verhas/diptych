import SwiftUI

/// Two files side by side, which is the shape this whole application is named
/// after. Read only for now.
///
/// One scroll view holding rows of two columns, rather than two scroll views
/// kept in step: the columns cannot drift apart if they are the same row, and
/// a line that wraps simply makes its row taller on both sides. Two scrollers
/// synchronised by hand is the version of this that never quite works.
struct DiffView: View {

    let pair: DiffPair

    @State private var diff: TextDiff?
    @State private var failure: String?
    @State private var atChange = 0
    @State private var onlyChanges = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: pair) { await load() }
    }

    // MARK: - Loading

    private func load() async {
        diff = nil
        failure = nil
        let pair = pair
        let outcome: Result<TextDiff, Error> = await BlockingWork.run {
            do { return .success(try TextDiff.compare(pair.left, pair.right)) }
            catch { return .failure(error) }
        }
        switch outcome {
        case .success(let result):
            diff = result
        case .failure(let error):
            failure = (error as? TextDiff.Failure)?.message ?? error.localizedDescription
        }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                name(pair.left)
                name(pair.right)
            }
            if let diff {
                HStack(spacing: 12) {
                    Text(summary(diff))
                        .font(.subheadline)
                        .foregroundStyle(diff.isIdentical ? .secondary : .primary)
                    Spacer()
                    if !diff.isIdentical {
                        Toggle("Only what differs", isOn: $onlyChanges)
                            .toggleStyle(.checkbox)
                        Button { step(-1, in: diff) } label: { Image(systemName: "chevron.up") }
                            .help("Previous difference")
                            .keyboardShortcut(.upArrow, modifiers: .command)
                        Button { step(1, in: diff) } label: { Image(systemName: "chevron.down") }
                            .help("Next difference")
                            .keyboardShortcut(.downArrow, modifiers: .command)
                        Text("\(min(atChange + 1, diff.changeStarts.count)) of "
                             + "\(diff.changeStarts.count)")
                            .font(.caption).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func name(_ url: URL) -> some View {
        Text(url.lastPathComponent)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(url.path)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summary(_ diff: TextDiff) -> String {
        guard !diff.isIdentical else { return "These two files are the same." }
        let count = diff.changeStarts.count
        return "\(count) difference\(count == 1 ? "" : "s")"
    }

    // MARK: - The comparison

    @ViewBuilder
    private var content: some View {
        if let failure {
            message(failure)
        } else if let diff {
            if diff.isIdentical {
                message("Every line matches, including the blank ones.")
            } else {
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(shown(diff)) { row in
                                line(row).id(row.id)
                            }
                        }
                    }
                    .onChange(of: atChange) { _, index in
                        guard diff.changeStarts.indices.contains(index) else { return }
                        withAnimation { scroller.scrollTo(diff.changeStarts[index], anchor: .center) }
                    }
                }
            }
        } else {
            message("Reading\u{2026}")
        }
    }

    /// Hiding the matching lines is the difference between reading a diff and
    /// hunting through a document for the three lines that moved.
    private func shown(_ diff: TextDiff) -> [TextDiff.Row] {
        onlyChanges ? diff.rows.filter { $0.kind.isChange } : diff.rows
    }

    private func message(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func line(_ row: TextDiff.Row) -> some View {
        HStack(alignment: .top, spacing: 0) {
            half(number: row.leftNumber, text: row.left,
                 marker: row.kind == .same ? " " : (row.left == nil ? " " : "\u{2212}"),
                 tint: row.left == nil ? nil : (row.kind == .same ? nil : Color.red))
            Divider()
            half(number: row.rightNumber, text: row.right,
                 marker: row.kind == .same ? " " : (row.right == nil ? " " : "+"),
                 tint: row.right == nil ? nil : (row.kind == .same ? nil : Color.green))
        }
    }

    private func half(number: Int?, text: String?, marker: String, tint: Color?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(number.map(String.init) ?? "")
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
            // A marker as well as a colour, so the two sides are still telling
            // the reader apart when the colours are not.
            Text(marker)
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Text(text ?? "")
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Light enough to read through in either theme. A missing line is
        // shaded too, so the gap reads as part of the comparison rather than
        // as the end of the file.
        .background(tint?.opacity(0.16) ?? (text == nil ? Color.secondary.opacity(0.06) : .clear))
    }

    private func step(_ by: Int, in diff: TextDiff) {
        guard !diff.changeStarts.isEmpty else { return }
        // Wrapping, because the alternative is a button that stops working and
        // does not say why.
        atChange = (atChange + by + diff.changeStarts.count) % diff.changeStarts.count
    }
}
