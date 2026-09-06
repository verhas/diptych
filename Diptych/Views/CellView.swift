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
        if column == .name {
            nameCell
        } else {
            Text(item.text(for: column))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .monospacedDigit()
                .frame(maxWidth: .infinity,
                       alignment: column.isTrailingAligned ? .trailing : .leading)
        }
    }

    private var nameCell: some View {
        HStack(spacing: 6) {
            Image(nsImage: IconCache.icon(for: item))

            if pane.renamingID == item.id {
                RenameField(text: $pane.renameText,
                            onCommit: { advance in model.commitInlineRename(advance: advance) },
                            onCancel: { model.cancelInlineRename() })
            } else {
                Text(item.name)
                    .fontWeight(item.isEnterable ? .semibold : .regular)
                    .lineLimit(1)
                if item.isSymlink {
                    Image(systemName: "arrowshape.turn.up.right")
                        .foregroundStyle(.secondary)
                        .help("Symbolic link")
                }
                // The system icon for a shell script is easily mistaken for a
                // folder at 16pt, and mistaking the two in a file manager is
                // expensive.
                if item.isExecutable {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .help("Executable")
                }
            }
        }
    }
}
