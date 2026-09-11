import SwiftUI

/// One cell. A single view type for every column, because `TableColumnForEach`
/// requires the whole dynamic column set to share one content type.
struct CellView: View {

    let column: FileColumn
    let item: FileItem
    @Bindable var pane: PaneModel
    let model: AppModel
    let activate: () -> Void

    /// Rows the filter excludes are drawn faded, and cannot be selected.
    private var isDimmed: Bool { !pane.matchesFilter(item) }

    /// Tag colour behind the whole row rather than a dot beside the name.
    /// Table has no per-row background, so each cell paints its own; together
    /// they read as one band.
    private var tagTint: Color? {
        item.tagColourName.map { Self.colour(of: $0).opacity(0.28) }
    }

    /// One question, five answers: what happens to this file when I send my
    /// work? An ignored file and an unchanged file get the same answer --
    /// nothing -- so they look the same, and a build folder does not paint half
    /// the pane.
    static func gitColour(_ state: GitState) -> Color? {
        switch state {
        // The system brown, not a hand-mixed one: a fixed dark brown was very
        // nearly invisible against a dark background, which is where most of
        // these rows are read.
        case .untracked:  .brown
        case .added:      .green
        case .changed:    .blue
        case .deleted:    .blue
        // One colour for both: to the person reading the pane, "this file needs
        // attention before it can go anywhere" is the same message, whether the
        // obstacle is a half-finished merge or a change someone else made.
        case .contested, .conflicted: .red
        case .clean:      nil
        }
    }

    static func colour(of tag: String) -> Color {
        switch tag {
        case "Red":    .red
        case "Orange": .orange
        case "Yellow": .yellow
        case "Green":  .green
        case "Blue":   .blue
        case "Purple": .purple
        case "Gray":   .gray
        default:       .clear
        }
    }

    var body: some View {
        Group {
            switch column {
            case .name:        nameCell
            case .permissions: permissionsCell
            default:           plainText
            }
        }
        // Set once for the whole cell. Setting it per branch is what left the
        // name at the default size while the other columns grew: the name cell
        // draws its own Text and never received it. The permissions cell still
        // overrides with the monospaced variant, which wins by being closer.
        .font(PaneFont.swiftUI)
        .opacity(isDimmed ? 0.35 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(tagTint)
    }

    private var plainText: some View {
        Text(item.text(for: column))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .monospacedDigit()
            .frame(maxWidth: .infinity,
                   alignment: column.isTrailingAligned ? .trailing : .leading)
    }

    // MARK: - Name

    private var nameCell: some View {
        HStack(spacing: 6) {
            Image(nsImage: IconCache.icon(for: item))

            if pane.renamingID == item.id {
                RenameField(text: $pane.renameText,
                            onCommit: { advance in model.commitInlineRename(advance: advance) },
                            onCancel: { model.cancelInlineRename() })
            } else {
                // Deliberately no gesture here. Clicks are observed by
                // ClickRouter, outside the view hierarchy, because every
                // gesture attached to a cell so far has broken row selection.
                Text(item.name)
                    .fontWeight(item.isEnterable ? .semibold : .regular)
                    .lineLimit(1)
                    // On the text, not the row: the row background is already
                    // the Finder tag band.
                    .foregroundStyle(Self.gitColour(item.gitState) ?? .primary)
                    .help(item.gitState.explanation ?? "")

                if item.isSymlink {
                    Image(systemName: "arrowshape.turn.up.right")
                        .foregroundStyle(.secondary)
                        // The arrow already says it is a link; what is missing
                        // is where it goes.
                        .help(item.linkTarget.isEmpty
                              ? "Symbolic link"
                              : "Symbolic link to \(item.linkTarget)")
                }
                if item.isExecutable {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: PaneFont.size * 0.8))
                        .foregroundStyle(.orange)
                        .help("Executable")
                }
            }
        }
    }

    // MARK: - Permissions

    @ViewBuilder
    private var permissionsCell: some View {
        if pane.permissionEditAnchor == item.id {
            PermissionField(mode: pane.permissionMode,
                            onCursor: { model.permissionCursorMoved(to: $0) },
                            onCommit: { model.commitPermissionEdit($0) },
                            onCancel: { model.cancelPermissionEdit() })
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(item.text(for: column))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // Same font the editor draws with, so the columns of characters
                // line up between an edited row and its neighbours.
                .font(PaneFont.monospacedSwiftUI)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
