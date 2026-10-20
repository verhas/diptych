import Foundation

/// Split File… and Join Parts: cutting a file into numbered parts and putting
/// them back together.
extension AppModel {

    // MARK: - What can be split or joined

    /// The single selected ordinary file that can be split -- not a folder, not
    /// `..`, not a copy inside an opened archive.
    var splittableFile: URL? {
        guard active.selectedItems.count == 1, let item = active.selectedItems.first,
              !item.isDirectory, !item.isParent,
              !ArchiveBrowsing.isInside(item.url) else { return nil }
        return item.url
    }

    /// Splittable, and somewhere to put the parts -- beside the file, or the
    /// other pane when this one is read-only.
    var canSplitFile: Bool { splittableFile.flatMap { partsFolder(for: $0) } != nil }

    /// The single selected file that is the first part of a split file --
    /// `something.001`.
    var joinableFirstPart: URL? {
        guard active.selectedItems.count == 1, let item = active.selectedItems.first,
              !item.isDirectory, !item.isParent,
              FileSplitting.isFirstPart(item.url) else { return nil }
        return item.url
    }

    var canJoinParts: Bool { joinableFirstPart.flatMap { partsFolder(for: $0) } != nil }

    /// Where split parts or a joined file go: beside the file when its pane can
    /// be written to, the other pane when it cannot, or nil when neither can --
    /// so a file on read-only media is still split, into the other pane.
    func partsFolder(for file: URL) -> (folder: URL, otherPane: Bool)? {
        if !active.volume.isReadOnly { return (file.deletingLastPathComponent(), false) }
        if let other = otherPaneFolder, !inactive.volume.isReadOnly { return (other, true) }
        return nil
    }

    /// The other pane's folder when split/join output would be sent there --
    /// what the Split dialog names so the parts are not a surprise.
    var splitOtherPaneFolder: URL? {
        active.volume.isReadOnly ? otherPaneFolder : nil
    }

    // MARK: - Splitting

    /// Ask the part size, then split.
    func requestSplitFile() {
        guard let file = splittableFile else { return }
        guard partsFolder(for: file) != nil else {
            flash("This folder is read-only and the other pane is not writable either")
            return
        }
        splitTarget = file
        textInput = "100"
        splitUnit = .megabytes
        dialog = .splitFile
    }

    /// The Split button in the dialog.
    func confirmSplitFile() {
        guard let file = splitTarget, let destination = partsFolder(for: file) else { return }
        splitTarget = nil
        let size = (Double(textInput.replacingOccurrences(of: ",", with: ".")) ?? 0)
        guard size > 0 else {
            flash("A part size is needed to split a file")
            return
        }
        let bytes = Int64((size * Double(splitUnit.multiplier)).rounded())
        let folder = destination.folder
        Task {
            flash("Splitting \u{201C}\(file.lastPathComponent)\u{201D}\u{2026}", error: false)
            let result = await BlockingWork.run { () -> Result<[URL], Error> in
                Result { try FileSplitting.split(file, partSize: bytes, into: folder) }
            }
            switch result {
            case .success(let parts):
                FileHistory.shared.recordCreation(.made("Split File"), of: parts)
                show(parts, in: folder)
                flash("Split into \(parts.count) part\(parts.count == 1 ? "" : "s")"
                      + (destination.otherPane ? " in the other pane" : "") + ", undoable",
                      error: false)
            case .failure(let error):
                dialog = .notice(title: "\u{201C}\(file.lastPathComponent)\u{201D} could not be split",
                                 text: error.localizedDescription)
            }
        }
    }

    // MARK: - Joining

    func joinParts() {
        guard let first = joinableFirstPart else { return }
        guard let destination = partsFolder(for: first) else {
            flash("This folder is read-only and the other pane is not writable either")
            return
        }
        let folder = destination.folder
        Task {
            let pieces = await BlockingWork.run { FileSplitting.parts(firstPart: first) }
            flash("Joining \(pieces.count) part\(pieces.count == 1 ? "" : "s")\u{2026}", error: false)
            let result = await BlockingWork.run { () -> Result<URL, Error> in
                Result { try FileSplitting.join(firstPart: first, into: folder) }
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
