import Foundation

/// The one-click name transforms on the Rename submenu -- lower case, upper
/// case, spaces to underscores, spaces to dashes -- and the shared machinery
/// the find-and-replace window uses too.
///
/// Each decides the new names itself and then runs them through the same
/// collision-safe `RenamePlan`/`RenameRunner` the Rename Many window uses, so a
/// bulk transform is as safe and as undoable as any other rename -- one Undo
/// step, and nothing touched unless the whole plan is sound.
extension AppModel {

    func renameLowercased()  { applyNameTransform("Lower Case") { $0.lowercased() } }
    func renameUppercased()  { applyNameTransform("Upper Case") { $0.uppercased() } }

    func renameSpacesToUnderscores() {
        applyNameTransform("Spaces to Underscores") { $0.replacingOccurrences(of: " ", with: "_") }
    }

    func renameSpacesToDashes() {
        applyNameTransform("Spaces to Dashes") { $0.replacingOccurrences(of: " ", with: "-") }
    }

    /// Apply `transform` to the whole name of every selected file. `label` is
    /// what Undo will call it.
    func applyNameTransform(_ label: String, _ transform: @escaping @Sendable (String) -> String) {
        let pane = active
        guard !refusedAsReadOnly(pane, "renamed here") else { return }
        let urls = pane.selectedItems.filter { !$0.isParent }.map(\.url)
        guard !urls.isEmpty else { return }

        Task {
            // A flat selection can span folders, so group by folder, read each
            // one's full name list for the collision check, and plan deepest
            // first -- the order the runner needs.
            let folderPlans: [(folder: URL, prefix: String, plan: RenamePlan)]
                = await BlockingWork.run {
                let byFolder = Dictionary(grouping: urls) { $0.deletingLastPathComponent() }
                let folders = byFolder.keys.sorted {
                    ($0.pathComponents.count, $0.path) > ($1.pathComponents.count, $1.path)
                }
                return folders.map { folder in
                    let group = byFolder[folder] ?? []
                    let names = (try? FileManager().contentsOfDirectory(atPath: folder.path))
                        ?? group.map { $0.lastPathComponent }
                    let pairs = group.map { (from: $0.lastPathComponent,
                                             to: transform($0.lastPathComponent)) }
                    return (folder, "", RenamePlan.plan(pairs: pairs, among: names))
                }
            }

            let problems = folderPlans.flatMap(\.plan.problems)
            guard problems.isEmpty else {
                dialog = .message("Could not apply \(label):\n\n"
                                  + problems.prefix(10).joined(separator: "\n"))
                return
            }
            guard folderPlans.reduce(0, { $0 + $1.plan.renames }) > 0 else {
                flash("Nothing to change -- the names are already as they would be", error: false)
                return
            }

            let result = await RenameRunner.run(folderPlans)
            FileHistory.shared.recordRenames(result.applied, renames: result.done, as: label)

            // Keep the same files selected, under their new names.
            pane.pendingSelection = Set(urls.map { RenameManyModel.following(result.applied, $0) })
            pane.reload()
            inactive.reload()   // the other pane may be showing the same folder

            if result.failures.isEmpty {
                flash("\(result.done) item\(result.done == 1 ? "" : "s") renamed", error: false)
            } else {
                dialog = .message(result.failures.joined(separator: "\n")
                                  + "\n\n\(result.done) renamed; the remaining "
                                  + "\(result.notStarted) not started. Undo puts back what was done.")
            }
        }
    }
}
