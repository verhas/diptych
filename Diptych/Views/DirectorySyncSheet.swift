import SwiftUI

/// What a sync is about to do, for a yes or a no before anything changes.
struct DirectorySyncSheet: View {

    let plan: DirectorySync.Plan
    /// What the comparison behind the plan looked at -- whatever it did not
    /// is left as it is, and the sheet says so.
    let options: DirectoryComparison.Options
    let onCancel: () -> Void
    let onConfirm: (_ deleteOutright: Bool) -> Void

    @State private var deleteOutright = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Make \u{201C}\(plan.targetRoot.lastPathComponent)\u{201D} the same as "
                 + "\u{201C}\(plan.sourceRoot.lastPathComponent)\u{201D}")
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text("From  \(NamingTemplate.tilde(plan.sourceRoot.path))")
                Text("To      \(NamingTemplate.tilde(plan.targetRoot.path))")
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

            if plan.isEmpty {
                Text("Nothing to change: as far as this comparison looks, the two are "
                     + "already the same.")
                    .foregroundStyle(.secondary)
            } else {
                Text(plan.summary + ".").font(.callout)
                List(plan.steps) { step in
                    HStack(spacing: 8) {
                        Image(systemName: Self.symbol(step.kind))
                            .foregroundStyle(step.kind == .delete ? Color.red : Color.secondary)
                            .frame(width: 16)
                        Text(step.relativePath + (step.isDirectory ? "/" : ""))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(Self.word(step.kind))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .help(Self.help(step))
                }
                .listStyle(.bordered)
                .frame(minHeight: 160, maxHeight: 320)
            }

            if let left = Self.leftAlone(options) {
                Text(left)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if plan.count(.delete) + plan.count(.replace) > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What is deleted, and the old version of what is replaced, goes to "
                         + "the Trash.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Delete outright, without the Trash", isOn: $deleteOutright)
                        .toggleStyle(.checkbox)
                        .help("For a server folder whose volume has no Trash to put things in")
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if !plan.isEmpty {
                    Button("Make the Same") { onConfirm(deleteOutright) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    /// What the comparison did not look at, and so what the sync does not
    /// change -- with how to bring it in.
    static func leftAlone(_ options: DirectoryComparison.Options) -> String? {
        var unseen: [String] = []
        if !options.compareContent { unseen.append("content") }
        if !options.comparePermissions { unseen.append("permissions") }
        if !options.compareAttributes { unseen.append("extended attributes") }
        if !options.compareACL { unseen.append("access control lists") }
        if !options.compareModificationDate { unseen.append("modification dates") }
        if !options.compareCreationDate { unseen.append("creation dates") }
        if !options.compareOwnership { unseen.append("owner and group") }
        var said: [String] = []
        if !unseen.isEmpty {
            said.append("Items that differ only in "
                        + ListFormatter.localizedString(byJoining: unseen)
                        + " are left as they are, since this comparison does not look at "
                        + "them. Tick them and the sync takes them in too. Whatever is "
                        + "copied or changed gets all of them anyway.")
        }
        if !options.recurseHiddenDirectories {
            said.append("Folders whose name starts with a dot are copied or deleted whole, "
                        + "but not looked into when they are on both sides.")
        }
        return said.isEmpty ? nil : said.joined(separator: " ")
    }

    static func symbol(_ kind: DirectorySync.Step.Kind) -> String {
        switch kind {
        case .copy: "plus.circle"
        case .replace: "arrow.triangle.2.circlepath"
        case .metadata: "tag"
        case .move: "arrow.right.circle"
        case .delete: "trash"
        }
    }

    private static func word(_ kind: DirectorySync.Step.Kind) -> String {
        switch kind {
        case .copy: "copy"
        case .replace: "replace"
        case .metadata: "attributes"
        case .move: "rename"
        case .delete: "delete"
        }
    }

    private static func help(_ step: DirectorySync.Step) -> String {
        switch step.kind {
        case .copy: "Copied over, with everything under it"
        case .replace: "The content differs: copied over the old one"
        case .metadata: "The same content: only permissions, attributes, ACL or dates change"
        case .move: "Already there under another name or place: renamed from "
            + NamingTemplate.tilde(step.target.path)
        case .delete: "Not in the source folder"
        }
    }
}
