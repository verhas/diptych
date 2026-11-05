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
    var joinSource: URL? { joinSelection?.source }

    /// What Join Parts works from, with the parts selected beside a manifest.
    var joinSelection: (source: URL, selectedParts: [URL]?)? {
        let chosen = active.selectedItems.filter { !$0.isParent }
        guard !chosen.isEmpty,
              chosen.allSatisfy({ !$0.isDirectory && !ArchiveBrowsing.isInside($0.url) })
        else { return nil }
        return FileSplitting.joinSelection(for: chosen.map(\.url))
    }

    var canJoinParts: Bool { joinSource.flatMap { partsFolder(for: $0) } != nil }

    /// Where split parts or a joined file go: beside the file when its pane can
    /// be written to, the other pane when it cannot, or nil when neither can --
    /// so a file on read-only media is still split, into the other pane.
    func partsFolder(for file: URL) -> (folder: URL, otherPane: Bool)? {
        if active.isWritable { return (file.deletingLastPathComponent(), false) }
        if let other = otherPaneFolder, inactive.isWritable { return (other, true) }
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
        // A file on a server is fetched first: the window reads it.
        whenFetched([file]) { [weak self] in
            guard let self else { return }
            let id = SplitStore.shared.register(.init(model: self, file: file,
                                                      folder: destination.folder,
                                                      otherPane: destination.otherPane))
            openSplitWindow?(id)
        }
    }

    /// Called back by the Split window once the parts are written: record it for
    /// undo, reveal the parts, and say so.
    func revealSplitResult(parts: [URL], manifest: URL, in folder: URL, otherPane: Bool) {
        let undoable = FileHistory.shared.recordCreation(.made("Split File"), of: parts + [manifest])
        show(parts, in: folder)
        flash("Split into \(parts.count) part\(parts.count == 1 ? "" : "s")"
              + (otherPane ? " in the other pane" : "") + (undoable ? ", undoable" : ""),
              error: false)
    }

    // MARK: - Joining

    func joinParts() {
        guard let selection = joinSelection else { return }
        let source = selection.source
        guard let destination = partsFolder(for: source) else {
            flash("This folder is read-only and the other pane is not writable either")
            return
        }
        let folder = destination.folder
        // On a server, every part and the manifest are fetched first.
        let parts = FileSplitting.base(of: source).map { base in
            ((try? FileManager.default.contentsOfDirectory(
                at: base.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
                .filter { FileSplitting.base(of: $0)?.lastPathComponent == base.lastPathComponent }
        } ?? [source]
        whenFetched(parts) { [weak self] in
            // The manifest with parts beside it, as selecting everything gives: the
            // join is the manifest's, and the parts selected must be all it lists.
            if let selected = selection.selectedParts,
               let problem = FileSplitting.selectionProblem(manifest: source, selected: selected) {
                self?.dialog = .notice(title: "These are not all the parts", text: problem)
                return
            }
            self?.join(source, into: folder, destination.otherPane)
        }
    }

    private func join(_ source: URL, into folder: URL, _ otherPane: Bool) {
        Task {
            flash("Joining the parts\u{2026}", error: false)
            let result = await BlockingWork.run { () -> Result<URL, Error> in
                Result { try FileSplitting.join(from: source, into: folder) }
            }
            switch result {
            case .success(let joined):
                let undoable = FileHistory.shared.recordCreation(.made("Join Parts"), of: [joined])
                show([joined], in: folder)
                flash("Joined into \u{201C}\(joined.lastPathComponent)\u{201D}"
                      + (otherPane ? " in the other pane" : "") + (undoable ? ", undoable" : ""),
                      error: false)
            case .failure(let error):
                dialog = .notice(title: "The parts could not be joined",
                                 text: error.localizedDescription)
            }
        }
    }
}
