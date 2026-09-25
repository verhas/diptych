import SwiftUI

/// Two folders side by side: every file paired with its match on the other
/// side, or shown on its own when it has none.
///
/// One row per pair rather than a tree, because a pair is the unit that means
/// something here -- "these two are the same" or "this one has no partner" --
/// and a tree would have to repeat that judgement at every level for no
/// benefit. Selecting a pair and pressing Cmd-D, or double-clicking it, opens
/// it for a closer look: two files in the file comparison this window is a
/// companion to, two folders in a comparison of their own. Cmd-I opens Get
/// Info on both sides, for comparing whatever a badge does not spell out.
struct DirectoryDiffView: View {

    @State private var model: DirectoryDiffModel
    @Environment(\.openWindow) private var openWindow
    @State private var notice: String?

    private let pair: DirectoryDiffPair

    init(pair: DirectoryDiffPair) {
        self.pair = pair
        _model = State(initialValue: DirectoryDiffModel(left: pair.left, right: pair.right))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            legend
            if let notice {
                Divider()
                HStack {
                    Text(notice).font(.subheadline).foregroundStyle(.orange)
                    Spacer()
                    Button("OK") { self.notice = nil }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .navigationTitle(pair.title)
        .task { await model.load() }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                rootLabel(model.left)
                rootLabel(model.right)
            }

            HStack(spacing: 12) {
                if model.isLoading { ProgressView().controlSize(.small) }
                Text(model.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.needsRefresh {
                    Button("Refresh") { Task { await model.load() } }
                        .help("The checkboxes have changed since this comparison ran. "
                              + "Compare again with what they say now.")
                }
                Button("Get Info") { showInfo(model.selectedPair) }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(model.selectedPair == nil)
                    .help("Open Get Info on whichever side or sides exist, to compare them "
                          + "side by side")
                Button("Compare") { openComparison(model.selectedPair) }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(model.selectedPair?.canOpenComparison != true)
                    .help("Open the selected pair for a closer look")
            }

            optionsRow
            filterRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var optionsRow: some View {
        HStack(spacing: 14) {
            Text("Compare:").font(.caption).foregroundStyle(.secondary)
            Toggle("Content", isOn: $model.options.compareContent)
            Toggle("Permissions", isOn: $model.options.comparePermissions)
            Toggle("Extended attributes", isOn: $model.options.compareAttributes)
            Toggle("ACL", isOn: $model.options.compareACL)
            Toggle("Modified", isOn: $model.options.compareModificationDate)
                .help("Modification date")
            Toggle("Created", isOn: $model.options.compareCreationDate)
                .help("Creation date")
            Toggle("Owner/group", isOn: $model.options.compareOwnership)
            Divider().frame(height: 12)
            Toggle("Recurse into hidden folders", isOn: $model.options.recurseHiddenDirectories)
                .help("Look inside folders whose name starts with a dot, such as .git, "
                      + "instead of only listing them")
            Spacer()
        }
        .toggleStyle(.checkbox)
        .font(.caption)
    }

    private var filterRow: some View {
        HStack(spacing: 10) {
            TextField("Filter", text: $model.filterText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(minWidth: 70, idealWidth: 160, maxWidth: 220)
                .foregroundStyle(model.filterIsValid ? Color.primary : Color.red)
                .help(model.filterIsRegex
                      ? "Regular expression, anchored: .*\\.txt"
                      : "Shell pattern: *.txt")
                .overlay(alignment: .trailing) {
                    if !model.filterText.isEmpty {
                        Button {
                            model.filterText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 4)
                        .help("Clear the filter")
                    }
                }

            Toggle("RegEx", isOn: $model.filterIsRegex)
                .help("Read the filter as a regular expression instead of a shell pattern")
            Toggle("Hide", isOn: $model.filterHidesOthers)
                .help("Leave non-matching items out of the list entirely, instead of "
                      + "dimming them")

            Divider().frame(height: 12)

            Toggle("Only differences", isOn: $model.onlyShowDifferences)
                .help("List only pairs that are not the same")

            Spacer()
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 11))
    }

    private func rootLabel(_ url: URL) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(NamingTemplate.tilde(url.deletingLastPathComponent().path))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .help(url.path)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - The list

    @ViewBuilder
    private var content: some View {
        if let failure = model.failure {
            message(failure)
        } else if model.isLoading && model.pairs.isEmpty {
            message("Comparing\u{2026}")
        } else if model.pairs.isEmpty {
            message("Both folders are empty.")
        } else if model.displayedPairs.isEmpty {
            message("Nothing matches the filter.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.displayedPairs) { pair in
                        row(pair)
                        Divider()
                    }
                }
            }
        }
    }

    private func message(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ pair: DirectoryComparison.Pair) -> some View {
        HStack(spacing: 0) {
            cell(pair.left, isMissing: pair.left == nil)
            badgeColumn(pair)
            cell(pair.right, isMissing: pair.right == nil)
        }
        .opacity(model.hasFilter && !model.filterHidesOthers && !model.matchesFilter(pair)
                 ? 0.35 : 1)
        .background(model.selection == pair.id ? Color.accentColor.opacity(0.25) : .clear)
        .contentShape(Rectangle())
        .help(pair.differences.isEmpty ? "" : "These differ in \(pair.differences.summary)")
        // Stacked rather than replaced: a double click completes as a second
        // single click first, and selecting the pair it is about to open
        // reads as one action rather than a selection that changes and then
        // reverts.
        .onTapGesture(count: 2) { openComparison(pair) }
        .onTapGesture(count: 1) { model.selection = pair.id }
    }

    private func cell(_ entry: DirectoryComparison.Entry?, isMissing: Bool) -> some View {
        HStack(spacing: 6) {
            if let entry {
                Image(systemName: entry.isDirectory ? "folder" : "doc")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let location = location(of: entry) {
                        Text(location)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Text(detailText(entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "minus")
                    .foregroundStyle(.tertiary)
                Text("\u{2014} missing \u{2014}")
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Grey for absent; a match is left plain, since what sets a pair
        // apart from a match is now said by the badges, not by a wash behind
        // the text.
        .background(isMissing ? Color.secondary.opacity(0.08) : Color.clear)
    }

    /// Where this entry actually lives, since the name alone does not say --
    /// two files a hundred folders apart can share a name, and a rename can
    /// move a file into an entirely different one.
    private func location(of entry: DirectoryComparison.Entry) -> String? {
        let directory = (entry.relativePath as NSString).deletingLastPathComponent
        return directory.isEmpty ? nil : directory
    }

    private func detailText(_ entry: DirectoryComparison.Entry) -> String {
        let size = entry.isDirectory ? "--" : BinaryComparison.bytes(entry.byteSize)
        return "\(size)  \u{2022}  \(entry.permissions)"
    }

    // MARK: - What differs, in colour

    /// Letter, colour, tooltip and short label for each kind of difference, in
    /// the order badges are shown. A small, high-contrast letter reads at a
    /// glance across a hundred rows in a way that a shared wash of one colour
    /// cannot: "these two differ" was already visible, "in what" was not --
    /// and the same list, spelt out, is the legend at the foot of the window
    /// for whoever has not memorised the letters yet.
    private static let badgeSpecs:
        [(kind: DirectoryComparison.Difference, letter: String, color: Color,
          help: String, label: String)] = [
        (.kind, "F", .brown, "one is a file, the other a folder", "File vs. folder"),
        (.name, "N", .indigo, "matched by content -- the name or the location differs", "Name"),
        (.size, "S", .blue, "size differs", "Size"),
        (.content, "C", .red, "content differs", "Content"),
        (.permissions, "P", .orange, "permissions differ", "Permissions"),
        (.attributes, "X", .teal, "extended attributes differ", "Extended attributes"),
        (.acl, "A", .purple, "access control list differs", "Access control list"),
        (.modified, "M", .mint, "modification date differs", "Modified"),
        (.created, "B", .yellow, "creation date differs", "Created"),
        (.ownership, "O", .pink, "owner or group differs", "Owner / group"),
    ]

    private func badgeColumn(_ pair: DirectoryComparison.Pair) -> some View {
        let badges = Self.badgeSpecs.filter { pair.differences.contains($0.kind) }
        return ZStack {
            Divider()
            if !badges.isEmpty {
                HStack(spacing: 2) {
                    ForEach(badges, id: \.letter) { spec in
                        badge(spec.letter, color: spec.color, help: spec.help)
                    }
                }
            }
        }
        .frame(width: CGFloat(max(badges.count, 1)) * 17 + 6)
    }

    private func badge(_ letter: String, color: Color, help: String) -> some View {
        Text(letter)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .frame(width: 15, height: 15)
            .background(color)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .help(help)
    }

    /// What every badge means, always on screen: the letters are only mnemonic
    /// once they are familiar, and a comparison run once a month never gets
    /// the chance.
    private var legend: some View {
        FlowLayout(spacing: 12) {
            ForEach(Self.badgeSpecs, id: \.letter) { spec in
                HStack(spacing: 4) {
                    badge(spec.letter, color: spec.color, help: spec.help)
                    Text(spec.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Opening a closer look

    /// Two files open in the file comparison this window is a companion to;
    /// two folders open a directory comparison of their own, narrowed to just
    /// the two of them -- the same window this one is, for people who want a
    /// more focused view of one part of a larger tree.
    private func openComparison(_ pair: DirectoryComparison.Pair?) {
        guard let pair, pair.canOpenComparison,
              let left = pair.left, let right = pair.right else { return }
        model.selection = pair.id

        if pair.isDirectory {
            openWindow(id: DiptychApp.directoryDiffWindowID,
                      value: DirectoryDiffPair(left: left.url, right: right.url))
            return
        }

        let asked = DiffPair(left: left.url, right: right.url)
        if let clash = DiffWindows.shared.alreadyOpen(asked) {
            notice = "\(clash.lastPathComponent) is already open in a comparison or in Text Edit"
            return
        }
        openWindow(id: DiptychApp.diffWindowID, value: asked)
    }

    /// Get Info on whichever side or sides exist, so the two can be put next
    /// to each other and compared by eye -- tags, xattrs, ACL and all the rest
    /// a badge only says is there, not what it is.
    private func showInfo(_ pair: DirectoryComparison.Pair?) {
        guard let pair else { return }
        if let left = pair.left { openWindow(id: DiptychApp.infoWindowID, value: left.url) }
        if let right = pair.right { openWindow(id: DiptychApp.infoWindowID, value: right.url) }
    }
}

/// Lays its children out left to right, wrapping to a new line when the next
/// one would not fit -- what the legend needs, and what an `HStack` cannot do.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                     cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var origin = CGPoint.zero
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > width {
                origin.x = 0
                origin.y += lineHeight + spacing
                lineHeight = 0
            }
            origin.x += size.width + spacing
            maxX = max(maxX, origin.x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxX, height: origin.y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        var origin = bounds.origin
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > bounds.minX, origin.x + size.width > bounds.maxX {
                origin.x = bounds.minX
                origin.y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: origin, anchor: .topLeading, proposal: .unspecified)
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
