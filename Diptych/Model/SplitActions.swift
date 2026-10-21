import Foundation

/// Split File… and Join Parts: cutting a file into numbered parts and putting
/// them back together.
extension AppModel {

    // MARK: - What can be split or joined

    /// The single selected ordinary file that can be split -- not a folder, not
    /// `..`, not a copy inside an opened archive, and not itself a split part or
    /// manifest.
    var splittableFile: URL? {
        guard active.selectedItems.count == 1, let item = active.selectedItems.first,
              !item.isDirectory, !item.isParent,
              !ArchiveBrowsing.isInside(item.url),
              !FileSplitting.isPart(item.url), !FileSplitting.isManifest(item.url) else { return nil }
        return item.url
    }

    /// Splittable, and somewhere to put the parts -- beside the file, or the
    /// other pane when this one is read-only.
    var canSplitFile: Bool { splittableFile.flatMap { partsFolder(for: $0) } != nil }

    /// What the current selection would join from: a single manifest, a single
    /// part, or several parts of one file. Nil when the selection is not a join.
    var joinSource: URL? {
        let chosen = active.selectedItems.filter { !$0.isParent }
        guard !chosen.isEmpty,
              chosen.allSatisfy({ !$0.isDirectory && !ArchiveBrowsing.isInside($0.url) })
        else { return nil }
        return FileSplitting.joinSource(for: chosen.map(\.url))
    }

    var canJoinParts: Bool { joinSource.flatMap { partsFolder(for: $0) } != nil }

    /// Where split parts or a joined file go: beside the file when its pane can
    /// be written to, the other pane when it cannot, or nil when neither can --
    /// so a file on read-only media is still split, into the other pane.
    func partsFolder(for file: URL) -> (folder: URL, otherPane: Bool)? {
        if !active.volume.isReadOnly { return (file.deletingLastPathComponent(), false) }
        if let other = otherPaneFolder, !inactive.volume.isReadOnly { return (other, true) }
        return nil
    }

    // MARK: - Splitting

    /// Open the (movable) Split window on the selected file.
    func requestSplitFile() {
        guard let file = splittableFile else { return }
        guard let destination = partsFolder(for: file) else {
            flash("This folder is read-only and the other pane is not writable either")
            return
        }
        let id = SplitStore.shared.register(.init(model: self, file: file,
                                                  folder: destination.folder,
                                                  otherPane: destination.otherPane))
        openSplitWindow?(id)
    }

    /// Called back by the Split window once the parts are written: record it for
    /// undo, reveal the parts, and say so.
    func revealSplitResult(parts: [URL], manifest: URL, in folder: URL, otherPane: Bool) {
        FileHistory.shared.recordCreation(.made("Split File"), of: parts + [manifest])
        show(parts, in: folder)
        flash("Split into \(parts.count) part\(parts.count == 1 ? "" : "s")"
              + (otherPane ? " in the other pane" : "") + ", undoable",
              error: false)
    }

    // MARK: - Joining

    func joinParts() {
        guard let source = joinSource else { return }
        guard let destination = partsFolder(for: source) else {
            flash("This folder is read-only and the other pane is not writable either")
            return
        }
        let folder = destination.folder
        Task {
            flash("Joining the parts\u{2026}", error: false)
            let result = await BlockingWork.run { () -> Result<URL, Error> in
                Result { try FileSplitting.join(from: source, into: folder) }
            }
            switch result {
            case .success(let joined):
                FileHistory.shared.recordCreation(.made("Join Parts"), of: [joined])
                show([joined], in: folder)
                flash("Joined into \u{201C}\(joined.lastPathComponent)\u{201D}"
                      + (destination.otherPane ? " in the other pane" : "") + ", undoable",
                      error: false)
            case .failure(let error):
                dialog = .notice(title: "The parts could not be joined",
                                 text: error.localizedDescription)
            }
        }
    }
}
