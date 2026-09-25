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
    /// The Diptych tab this comparison was opened from, if it is still open --
    /// nil for a window restored across a relaunch, or one whose tab has since
    /// closed, in which case Cmd-G has nowhere to send anything.
    @State private var origin: AppModel?
    @FocusState private var filterIsFocused: Bool

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
        .background(WindowAccessor { window in if let window { AppWindows.shared.register(window) } })
        // `.onAppear`, not `.task`: a `WindowGroup(for:)` scene can keep this
        // view's state across the window being closed, and `.task` then never
        // runs again on reopening the same pair of folders -- which kept
        // showing the comparison as it stood the *first* time it was run,
        // however the folders changed afterwards. `.onAppear` fires on every
        // reappearance regardless.
        .onAppear {
            origin = DirectoryDiffOrigins.shared.origin(for: pair)
            Task { await model.load() }
        }
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
                refreshButton
                Button("Get Info") { showInfo(model.selectedPair) }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(model.selectedPair == nil)
                    .help("Open Get Info on whichever side or sides exist, to compare them "
                          + "side by side")
                Button("Go to") { goToOrigin(model.selectedPair) }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(origin == nil || model.selectedPair == nil)
                    .help("Select these files in the window this comparison was opened from")
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

    /// Always available, not only when a checkbox has changed: the folders
    /// themselves can have changed too, and there is no other way to ask for
    /// a fresh look. Prominent exactly when a checkbox is the reason, so the
    /// two reasons to press it -- "the settings changed" and "the files might
    /// have" -- read differently without needing separate buttons.
    @ViewBuilder
    private var refreshButton: some View {
        if model.needsRefresh {
            Button("Refresh") { Task { await model.load() } }
                .buttonStyle(.borderedProminent)
                .help(refreshHelp)
        } else {
            Button("Refresh") { Task { await model.load() } }
                .buttonStyle(.bordered)
                .help(refreshHelp)
        }
    }

    private var refreshHelp: String {
        guard model.needsRefresh else {
            return "Already reflects the current checkboxes. Refreshing again only helps if "
                 + "the folders themselves have changed since."
        }
        return "The checkboxes have changed since this comparison ran. Refresh to compare "
             + "again with what they say now."
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
                .focused($filterIsFocused)
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
            Toggle("Ignore missing", isOn: $model.ignoreMissing)
                .help("Leave out anything that exists on only one side")

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
                    ForEach(Array(model.displayedPairs.enumerated()), id: \.element.id) {
                        index, pair in
                        row(pair, striped: !index.isMultiple(of: 2))
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

    private func row(_ pair: DirectoryComparison.Pair, striped: Bool) -> some View {
        HStack(spacing: 0) {
            cell(pair.left, other: pair.right, isMissing: pair.left == nil,
                sameContent: pair.leftContentSiblings)
            badgeColumn(pair)
            cell(pair.right, other: pair.left, isMissing: pair.right == nil,
                sameContent: pair.rightContentSiblings)
        }
        .opacity(model.hasFilter && !model.filterHidesOthers && !model.matchesFilter(pair)
                 ? 0.35 : 1)
        .background(model.selection == pair.id ? Color.accentColor.opacity(0.25)
                    : (striped ? Color(nsColor: .alternatingContentBackgroundColors[1])
                              : Color.clear))
        .contentShape(Rectangle())
        .help(helpText(for: pair))
        // Stacked rather than replaced: a double click completes as a second
        // single click first, and selecting the pair it is about to open
        // reads as one action rather than a selection that changes and then
        // reverts.
        .onTapGesture(count: 2) { openComparison(pair) }
        .onTapGesture(count: 1) {
            model.selection = pair.id
            // A click in the list is "somewhere else" as far as the filter
            // field is concerned -- it should not go on blinking there.
            filterIsFocused = false
        }
    }

    /// What the row's tooltip says: what differs, which side is newer when a
    /// date is one of those differences, or that the two are simply the same
    /// -- silence read as a missing tooltip, not as "nothing to say".
    private func helpText(for pair: DirectoryComparison.Pair) -> String {
        switch pair.status {
        case .same: "These are the same."
        case .onlyLeft: "Only on the left."
        case .onlyRight: "Only on the right."
        case .differs:
            "These differ in \(pair.differences.summary)."
                + (newerSideNote(pair).map { " (\($0).)" } ?? "")
        }
    }

    private func newerSideNote(_ pair: DirectoryComparison.Pair) -> String? {
        switch pair.newerSide {
        case .left: "the left one is newer"
        case .right: "the right one is newer"
        case nil: nil
        }
    }

    private func cell(_ entry: DirectoryComparison.Entry?, other: DirectoryComparison.Entry?,
                      isMissing: Bool, sameContent: [String]) -> some View {
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
                    Text(detailText(entry, other: other))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let sameContentText = Self.sameContentText(sameContent) {
                        Text(sameContentText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(sameContentText)
                    }
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

    private func detailText(_ entry: DirectoryComparison.Entry,
                            other: DirectoryComparison.Entry?) -> String {
        let size = entry.isDirectory ? "--" : BinaryComparison.bytes(entry.byteSize)
        var parts = ["\(size)", entry.permissions]
        if let ownership = ownershipDetail(entry, other) { parts.append(ownership) }
        if let attributes = attributesSummary(entry, other) { parts.append(attributes) }
        if let acl = aclSummary(entry, other) { parts.append(acl) }
        return parts.joined(separator: "  \u{2022}  ")
    }

    /// Owner, group, or both -- whichever actually differs from the other
    /// side, and only when ownership is being compared at all. Showing the
    /// one that agrees as well as the one that does not would bury the answer
    /// in the question.
    ///
    /// Checked against `appliedOptions`, the settings the loaded pairs were
    /// actually compared with, not `options`, what the checkboxes currently
    /// say: a box just ticked but not yet refreshed has no data behind it yet
    /// to show.
    private func ownershipDetail(_ entry: DirectoryComparison.Entry,
                                 _ other: DirectoryComparison.Entry?) -> String? {
        guard model.appliedOptions.compareOwnership, let other else { return nil }
        var parts: [String] = []
        if entry.owner != other.owner { parts.append("owner: \(entry.owner)") }
        if entry.group != other.group { parts.append("group: \(entry.group)") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    /// Not a full diff, just enough to say where to look: attribute names that
    /// are missing on one side, or present on both but holding a different
    /// value.
    private func attributesSummary(_ entry: DirectoryComparison.Entry,
                                   _ other: DirectoryComparison.Entry?) -> String? {
        guard model.appliedOptions.compareAttributes, let other else { return nil }
        let mine = Set(entry.attributes.readable.keys).union(entry.attributes.unreadableNames)
        let theirs = Set(other.attributes.readable.keys).union(other.attributes.unreadableNames)
        var changed = mine.symmetricDifference(theirs)
        for name in mine.intersection(theirs)
        where entry.attributes.readable[name] != other.attributes.readable[name] {
            changed.insert(name)
        }
        guard !changed.isEmpty else { return nil }
        return "xattr: " + Self.shortList(changed)
    }

    /// The same idea for the access control list: which principals' entries
    /// do not match, named rather than spelled out in full.
    private func aclSummary(_ entry: DirectoryComparison.Entry,
                            _ other: DirectoryComparison.Entry?) -> String? {
        guard model.appliedOptions.compareACL, let other else { return nil }
        let mine = Self.aclEntries(entry.acl)
        let theirs = Self.aclEntries(other.acl)
        var changed = Set(mine.keys).symmetricDifference(theirs.keys)
        for name in Set(mine.keys).intersection(theirs.keys) where mine[name] != theirs[name] {
            changed.insert(name)
        }
        guard !changed.isEmpty else { return nil }
        return "acl: " + Self.shortList(changed)
    }

    /// One ACL entry's principal name mapped to its permissions, parsed just
    /// well enough to notice a change -- `AccessControl`'s own text format is
    /// `tag:uuid:name:id:allow|deny:permissions`, and only the name and the
    /// last two fields matter here.
    private static func aclEntries(_ text: String?) -> [String: String] {
        guard let text else { return [:] }
        var entries: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("!#acl") {
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 6 else { continue }
            let name = fields[2].isEmpty ? String(fields[1]) : String(fields[2])
            entries[name] = "\(fields[4]):\(fields[5])"
        }
        return entries
    }

    private static func shortList(_ names: Set<String>) -> String {
        shortList(names.sorted())
    }

    /// Up to three names, then a count of the rest -- a hint of what changed,
    /// not an inventory of it.
    private static func shortList(_ names: [String]) -> String {
        let shown = names.prefix(3).joined(separator: ", ")
        let remainder = names.count > 3 ? " (+\(names.count - 3) more)" : ""
        return shown + remainder
    }

    /// "Same content as: ..." for a file that shares its bytes with another
    /// one somewhere in the comparison, besides the pair it is already shown
    /// next to. A rename match only ever accounts for one duplicate; this is
    /// what says there were more.
    private static func sameContentText(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        return "Same content as: " + shortList(names)
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
        filterIsFocused = false
        guard let pair, pair.canOpenComparison,
              let left = pair.left, let right = pair.right else { return }
        model.selection = pair.id

        if pair.isDirectory {
            let nested = DirectoryDiffPair(left: left.url, right: right.url)
            // Forwarded from this window's own origin, not registered as this
            // window: Cmd-G in the narrower view should still land in the
            // same Diptych tab the whole comparison started from.
            DirectoryDiffOrigins.shared.register(nested, from: origin)
            openWindow(id: DiptychApp.directoryDiffWindowID, value: nested)
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
        filterIsFocused = false
        guard let pair else { return }
        if let left = pair.left { openWindow(id: DiptychApp.infoWindowID, value: left.url) }
        if let right = pair.right { openWindow(id: DiptychApp.infoWindowID, value: right.url) }
    }

    /// Sends the pair back to the Diptych tab this comparison was opened
    /// from: the left pane to the left file, the right pane to the right one.
    /// When only one side exists, only that pane moves, and it becomes the
    /// active one; otherwise the left pane becomes active and both files end
    /// up selected, the right one in whatever style an unfocused pane's
    /// selection already takes.
    private func goToOrigin(_ pair: DirectoryComparison.Pair?) {
        filterIsFocused = false
        guard let pair, let origin else { return }

        switch (pair.left, pair.right) {
        case let (left?, right?):
            select(right.url, in: origin.right)
            select(left.url, in: origin.left)
            origin.focus(.left)
        case let (left?, nil):
            select(left.url, in: origin.left)
            origin.focus(.left)
        case let (nil, right?):
            select(right.url, in: origin.right)
            origin.focus(.right)
        case (nil, nil):
            return
        }
        origin.window?.makeKeyAndOrderFront(nil)
    }

    private func select(_ url: URL, in pane: PaneModel) {
        pane.pendingSelection = [url]
        pane.navigate(to: url.deletingLastPathComponent())
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
