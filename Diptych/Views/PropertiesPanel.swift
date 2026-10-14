import SwiftUI

/// The two files' properties under their names: one line saying whether
/// anything besides the bytes differs, and what -- opened, the values side by
/// side, the different ones first and marked.
struct PropertiesPanel: View {

    let properties: PropertyComparison?
    /// Nil until somebody opens or closes it: then it opens by itself exactly
    /// when the properties are the whole story -- the content is the same and
    /// something else is not.
    @Binding var isOpen: Bool?
    var contentIsSame: Bool

    @State private var showsAll = false

    private var differing: [PropertyComparison.Row] { properties?.differing ?? [] }

    private var open: Bool { isOpen ?? (contentIsSame && !differing.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    isOpen = !open
                } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .frame(width: 10)
                }
                .buttonStyle(.borderless)
                .disabled(properties == nil)
                .help(open ? "Hide the properties" : "Show the properties side by side")
                line
                Spacer(minLength: 0)
                if open, properties != nil {
                    Toggle("Show the same ones too", isOn: $showsAll)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
            }
            if open, let properties {
                table(properties)
            }
        }
    }

    @ViewBuilder
    private var line: some View {
        if let properties {
            if differing.isEmpty {
                Text("Same permissions, owner, flags, dates, access control list and "
                     + "extended attributes.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Properties that differ: \(properties.summary)")
                    .font(.caption).foregroundStyle(.orange)
                    .lineLimit(1).truncationMode(.tail)
                    .help(properties.summary)
            }
        } else {
            Text("Reading the properties\u{2026}").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func table(_ properties: PropertyComparison) -> some View {
        let rows = showsAll ? properties.differing + properties.rows.filter { !$0.differs }
            : properties.differing
        return ScrollView(.vertical) {
            if rows.isEmpty {
                Text("Nothing differs.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(rows) { row in
                        GridRow {
                            Text(row.name)
                                .foregroundStyle(row.differs ? Color.orange : Color.secondary)
                                .gridColumnAlignment(.trailing)
                            value(row.left)
                            value(row.right)
                        }
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private func value(_ text: String?) -> some View {
        Text(text ?? "\u{2014} not there \u{2014}")
            .foregroundStyle(text == nil ? Color.secondary : Color.primary)
            .lineLimit(6)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(text ?? "")
    }
}

/// For a popover of one pair's properties.
extension DiffPair: Identifiable {
    var id: Self { self }
}
