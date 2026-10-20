import Foundation

/// What a Trash listing offers on a trashed file: put it back where it came
/// from, or compare it with whatever is at its old place now.
///
/// Only files Diptych itself trashed carry an original location (macOS keeps
/// Finder's put-back privately), so both are offered only when that is known.
extension AppModel {

    /// The single selected item in a Trash listing whose original location
    /// Diptych knows.
    var restorableTrashedItem: (item: FileItem, original: URL)? {
        guard active.isTrashListing, active.selectedItems.count == 1,
              let item = active.selectedItems.first, !item.isParent,
              !item.originalLocation.isEmpty else { return nil }
        return (item, URL(fileURLWithPath: item.originalLocation))
    }

    var canRestoreFromTrash: Bool { restorableTrashedItem != nil }

    /// Move the trashed item back to where it came from. A name taken in the
    /// meantime is stepped past rather than overwritten, and the missing folder
    /// is recreated.
    func restoreFromTrash() {
        guard let (item, original) = restorableTrashedItem else { return }
        let trashed = item.url
        Task {
            let outcome = await BlockingWork.run { () -> (target: URL?, problem: String?) in
                let fm = FileManager()
                let folder = original.deletingLastPathComponent()
                if !fm.fileExists(atPath: folder.path) {
                    do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
                    catch { return (nil, error.localizedDescription) }
                }
                let target = fm.fileExists(atPath: original.path)
                    ? FileSplitting.freeName(original.lastPathComponent, in: folder)
                    : original
                do {
                    try fm.moveItem(at: trashed, to: target)
                    return (target, nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }
            if let target = outcome.target {
                TrashOriginals.shared.forget(trashed)
                active.reload()
                show([target], in: target.deletingLastPathComponent())
                flash("Restored to \u{201C}\(target.path)\u{201D}", error: false)
            } else {
                dialog = .notice(title: "\u{201C}\(item.name)\u{201D} could not be restored",
                                 text: outcome.problem ?? "The file could not be moved.")
            }
        }
    }

    /// A trashed file to compare with whatever sits at its old location now --
    /// offered only when there is something there to compare with.
    var comparableTrashedItem: (trashed: URL, original: URL)? {
        guard let (item, original) = restorableTrashedItem, !item.isDirectory,
              FileManager.default.fileExists(atPath: original.path) else { return nil }
        return (item.url, original)
    }

    var canCompareTrashedWithOriginal: Bool { comparableTrashedItem != nil }

    /// Compare the trashed version with what is at its old location now. Both
    /// are ordinary, readable paths -- a file in the Trash is nothing special
    /// to read -- so the comparison is done in place, with no copying: the
    /// trashed version on the left, what replaced it on the right.
    func compareTrashedWithOriginal() {
        guard let (trashed, original) = comparableTrashedItem else { return }
        openDiffWindow?(DiffPair(left: trashed, right: original))
    }
}
