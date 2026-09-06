import SwiftUI

/// One cell. A single view type for every column, because `TableColumnForEach`
/// requires the whole dynamic column set to share one content type.
struct CellView: View {

    let column: FileColumn
    let item: FileItem
    @Bindable var pane: PaneModel
    let model: AppModel
    let activate: () -> Void

    var body: some View {
        switch column {
        case .name:        nameCell
        case .permissions: permissionsCell
        default:           plainText
        }
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

                if item.isSymlink {
                    Image(systemName: "arrowshape.turn.up.right")
                        .foregroundStyle(.secondary)
                        .help("Symbolic link")
                }
                if item.isExecutable {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 9))
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
            PermissionField(text: pane.permissionText,
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
                .font(.system(size: PermissionEditorView.fontSize, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
