import SwiftUI

/// What a sync both ways would do, path by path, with a say in each -- and
/// the conflicts, which wait for one.
struct TwoWaySyncSheet: View {

    let plan: DirectorySync.TwoWayPlan
    let options: DirectoryComparison.Options
    let onCancel: () -> Void
    let onConfirm: (_ choices: [String: DirectorySync.Choice], _ deleteOutright: Bool) -> Void

    /// Only what differs from the suggestion; a conflict is in here once
    /// decided.
    @State private var choices: [String: DirectorySync.Choice] = [:]
    @State private var deleteOutright = false
    @State private var notice: String?
    /// The item whose properties are shown in a popover -- two folders or two
    /// links, which have no text to compare.
    @State private var inspected: String?
    @State private var inspectedOpen: Bool? = true
    @Environment(\.openWindow) private var openWindow

    private var undecided: Int {
        plan.items.filter { $0.isConflict && choices[$0.id] == nil }.count
    }

    var body: some View {
        let resolved = plan.resolve(choices)
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync \u{201C}\(plan.left.lastPathComponent)\u{201D} and "
                 + "\u{201C}\(plan.right.lastPathComponent)\u{201D} both ways")
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text("Left   \(NamingTemplate.tilde(plan.left.path))")
                Text("Right  \(NamingTemplate.tilde(plan.right.path))")
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

            if plan.isFirst {
                Text("These two have not been synced before, so nothing can be told to be a "
                     + "deletion: whatever is on one side only is copied to the other. From "
                     + "now on, what is deleted on one side is deleted on the other.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Text(resolved.summary + ".").font(.callout)
                if undecided > 0 {
                    Text("\(undecided) conflict\(undecided == 1 ? "" : "s") to decide.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            if plan.conflicts > 0 {
                HStack(spacing: 8) {
                    Text("Every conflict:").font(.caption).foregroundStyle(.secondary)
                    Button("Newer Wins") { decideConflicts { $0.newer ?? .skip } }
                        .help("The copy changed last is kept, on both sides; for a deletion "
                              + "against a change, the change")
                    Button("Keep Both") {
                        decideConflicts { $0.keepBoth == nil ? ($0.newer ?? .skip) : .keepBoth }
                    }
                    .help("Two files: both sides end up with both, the newer under its "
                          + "name and the older beside it, renamed. Anything else: the newer "
                          + "wins")
                    Button("Leave as Is") { decideConflicts { _ in .skip } }
                        .help("Change nothing now: each side keeps its own; the next sync "
                              + "asks again")
                }
                .controlSize(.small)
            }

            List(plan.items) { item in
                row(item)
            }
            .listStyle(.bordered)
            .frame(minHeight: 200, maxHeight: 360)

            if let notice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }

            if let left = DirectorySyncSheet.leftAlone(options) {
                Text(left)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if resolved.count(.delete) + resolved.count(.replace) > 0 {
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
                Button("Sync") { onConfirm(choices, deleteOutright) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(undecided > 0)
                    .help(undecided > 0 ? "Decide every conflict first, or skip it" : "")
            }
        }
        .padding(20)
        .frame(width: 680)
    }

    private func decideConflicts(_ choose: (DirectorySync.Item) -> DirectorySync.Choice) {
        for item in plan.items where item.isConflict {
            choices[item.id] = choose(item)
        }
    }

    private func row(_ item: DirectorySync.Item) -> some View {
        let choice = choices[item.id] ?? item.suggested
        return HStack(spacing: 8) {
            Image(systemName: item.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                if let pair = item.comparable {
                    Button {
                        compare(pair)
                    } label: {
                        Text(item.relativePath)
                            .underline()
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                    .help("Compare the two files")
                } else if let sides = item.sides {
                    Button {
                        inspected = item.id
                    } label: {
                        Text(item.relativePath + (item.isDirectory ? "/" : ""))
                            .underline()
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                    .help("Compare the properties of the two")
                    .popover(isPresented: Binding(
                        get: { inspected == item.id },
                        set: { if !$0 { inspected = nil } })) {
                        PropertiesPanel(properties: PropertyComparison.of(sides.left, sides.right),
                                        isOpen: $inspectedOpen, contentIsSame: true)
                            .padding(12)
                            .frame(width: 560)
                    }
                } else {
                    Text(item.relativePath + (item.isDirectory ? "/" : ""))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(item.reason)
                    .font(.caption)
                    .foregroundStyle(item.isConflict ? Color.orange : Color.secondary)
            }
            Spacer()
            Menu {
                ForEach(item.choices, id: \.self) { option in
                    Button {
                        choices[item.id] = option == item.suggested ? nil : option
                    } label: {
                        Text(Self.label(option, item, long: true))
                    }
                }
            } label: {
                Text(choice.map { Self.label($0, item) } ?? "Decide\u{2026}")
                    .foregroundStyle(choice == nil ? Color.orange : Color.primary)
            }
            .fixedSize()
            .help(choice.map { Self.effect(item.steps($0)) } ?? "A conflict: choose what to do")
        }
        .padding(.vertical, 1)
    }

    /// The two files in the comparison window, beside this sheet -- edit
    /// them there, and what the sync does is up to the choice made here.
    private func compare(_ pair: DiffPair) {
        if let clash = DiffWindows.shared.alreadyOpen(pair) {
            notice = "\(clash.lastPathComponent) is already open in a comparison or in Text Edit."
            return
        }
        notice = nil
        OpenDiffDocuments.shared.refreshIfOpen(pair)
        openWindow(id: DiptychApp.diffWindowID, value: pair)
    }

    /// The choice, said by what it does to this item -- in full in the menu,
    /// where the choices are told apart, and short on the row.
    private static func label(_ choice: DirectorySync.Choice, _ item: DirectorySync.Item,
                              long: Bool = false) -> String {
        if long {
            switch choice {
            case .keepBoth:
                return "Keep both: the older as \u{201C}\(item.keptAside ?? "a copy")\u{201D}, "
                    + "on both sides"
            case .skip:
                return "Leave as is: change nothing, ask again next sync"
            default: break
            }
        }
        return switch choice {
        case .toRight: item.toRight.allSatisfy { $0.kind == .delete }
            ? "Delete on the right" : "Left \u{2192} right"
        case .toLeft: item.toLeft.allSatisfy { $0.kind == .delete }
            ? "Delete on the left" : "Left \u{2190} right"
        case .keepBoth: "Keep both"
        case .skip: "Leave as is"
        }
    }

    private static func effect(_ steps: [DirectorySync.Step]) -> String {
        guard !steps.isEmpty else { return "Nothing changes" }
        return steps.map { step in
            let side = step.target.path
            switch step.kind {
            case .copy: return "copy to \(NamingTemplate.tilde(side))"
            case .replace: return "replace \(NamingTemplate.tilde(side))"
            case .metadata: return "set attributes of \(NamingTemplate.tilde(side))"
            case .move: return "rename \(NamingTemplate.tilde(side)) to "
                + (step.destination?.lastPathComponent ?? "")
            case .delete: return "delete \(NamingTemplate.tilde(side))"
            }
        }.joined(separator: "; ")
    }
}
