import SwiftUI

/// One cell. A single view type for every column, because `TableColumnForEach`
/// requires the whole dynamic column set to share one content type.
struct CellView: View {

    let column: FileColumn
    let item: FileItem
    @Bindable var pane: PaneModel
    let model: AppModel
    let activate: () -> Void

    /// Rows the filter excludes are drawn faded, and cannot be selected.
    private var isDimmed: Bool { !pane.matchesFilter(item) }

    /// Tag colour behind the whole row rather than a dot beside the name.
    /// Table has no per-row background, so each cell paints its own; together
    /// they read as one band.
    private var tagTint: Color? {
        item.tagColourName.map { Self.colour(of: $0).opacity(0.28) }
    }

    /// True while a drag is spring-loading this exact row: hovering here is
    /// about to open it, the way it would in Finder.
    private var isSpringLoadTarget: Bool {
        model.springLoadPane === pane && model.springLoadTarget?.id == item.id
    }

    /// What do I need to know before I touch this file?
    ///
    /// That used to read "what happens when I send my work?", which was true
    /// until `stale` arrived: a file nobody here has touched is not in the send
    /// at all, and what it has to say is about editing it, not sending it. An
    /// ignored file and an unchanged file still answer the same -- nothing --
    /// so a build folder does not paint half the pane.
    static func gitColour(_ state: GitState) -> Color? {
        switch state {
        // The system brown, not a hand-mixed one: a fixed dark brown was very
        // nearly invisible against a dark background, which is where most of
        // these rows are read.
        case .untracked:  .brown
        case .added:      .green
        case .changed:    .blue
        case .renamed:    .blue
        case .deleted:    .blue
        // Blue like the others that are waiting to be sent, because that is
        // what it is: a change of yours on its way out.
        case .untracking: .blue
        // One colour for both: to the person reading the pane, "this file needs
        // attention before it can go anywhere" is the same message, whether the
        // obstacle is a half-finished merge or a change someone else made.
        case .contested, .conflicted: .red
        // Purple by measurement rather than taste. Orange was the instinct --
        // the footer already counts what is waiting in orange -- but brown is
        // dark orange, and the two were 16 points apart in CIEDE2000 where
        // everything else in this palette is 30 or more. Purple sits 35 from
        // its nearest neighbour in both light and dark, and reads at 4.2:1 on
        // white, better than any colour already here.
        case .stale:      .purple
        // Dimmed rather than coloured, and deliberately the quietest thing in
        // the pane: it is not part of the work, it is a copy set aside until
        // the user has taken what they need from it.
        case .keptCopy:   .secondary
        case .clean:      nil
        }
    }

    static func colour(of tag: String) -> Color {
        switch tag {
        case "Red":    .red
        case "Orange": .orange
        case "Yellow": .yellow
        case "Green":  .green
        case "Blue":   .blue
        case "Purple": .purple
        case "Gray":   .gray
        default:       .clear
        }
    }

    var body: some View {
        Group {
            switch column {
            case .name:        nameCell
            case .permissions: permissionsCell
            case .git:         gitCell
            default:           plainText
            }
        }
        // Set once for the whole cell. Setting it per branch is what left the
        // name at the default size while the other columns grew: the name cell
        // draws its own Text and never received it. The permissions cell still
        // overrides with the monospaced variant, which wins by being closer.
        .font(PaneFont.swiftUI)
        .opacity(isDimmed ? 0.35 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            // The pulse is read off the clock while this row is the target,
            // not run as a repeating animation: setting a repeatForever back
            // does not reliably stop it, and a drop onto the row -- which
            // clears the target while the listing reloads -- left the row
            // flashing for good, even after navigating away and back. With
            // no animation to stop, the flashing ends with the target.
            if isSpringLoadTarget {
                TimelineView(.animation) { context in
                    let seconds = context.date.timeIntervalSinceReferenceDate
                    let phase = (1 - cos(seconds * .pi / 0.45)) / 2
                    Color.accentColor.opacity(0.15 + 0.30 * phase)
                }
            } else {
                tagTint
            }
        }
    }

    private var plainText: some View {
        Text(item.text(for: column))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .monospacedDigit()
            .frame(maxWidth: .infinity,
                   alignment: column.isTrailingAligned ? .trailing : .leading)
    }

    /// The words, in their own colours, comma separated.
    ///
    /// A folder lists everything inside it -- "clash, changed, new" -- because
    /// one word can only ever report the worst thing in there, which tells you
    /// nothing about what else you would find. Colouring each word is what
    /// makes the list readable at a glance instead of something to parse, and
    /// it is what carries the meaning for anyone who cannot separate the hues
    /// in the name column.
    private var gitCell: some View {
        HStack(spacing: 0) {
            ForEach(Array(item.gitStates.enumerated()), id: \.offset) { index, state in
                if index > 0 {
                    Text(", ").foregroundStyle(.secondary)
                }
                Text(state.title)
                    .foregroundStyle(Self.gitColour(state) ?? .secondary)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Name

    private var nameCell: some View {
        HStack(spacing: 6) {
            Image(nsImage: IconCache.icon(for: item))

            if pane.renamingID == item.id {
                RenameField(text: $pane.renameText,
                            onCommit: { advance in model.commitInlineRename(advance: advance) },
                            onCancel: { model.cancelInlineRename() })
            } else {
                // Deliberately no gesture here. Clicks are observed by
                // ClickRouter, outside the view hierarchy, because every
                // gesture attached to a cell so far has broken row selection.
                Text(item.name)
                    .fontWeight(item.isEnterable ? .semibold : .regular)
                    .lineLimit(1)
                    // On the text, not the row: the row background is already
                    // the Finder tag band.
                    .foregroundStyle(Self.gitColour(item.gitState) ?? .primary)
                    .help(item.gitState.explanation ?? "")

                // More than one name for the same file. Grey, so it does not
                // read as part of the name.
                if item.hardLinkCount > 1 {
                    Text("(\(item.hardLinkCount))")
                        .font(.system(size: PaneFont.size * 0.8))
                        .foregroundStyle(.secondary)
                        .help("\(item.hardLinkCount) hard links: this file has "
                              + "\(item.hardLinkCount) names")
                }

                if item.isSymlink {
                    Image(systemName: "arrowshape.turn.up.right")
                        .foregroundStyle(.secondary)
                        // Where ClickRouter finds the arrow -- a double-click on
                        // it goes to the link's target instead of opening it --
                        // and where it says what the link points to, the next
                        // step only, whether or not anything is there.
                        .overlay(LinkArrowMarker(toolTip: arrowToolTip))
                    linkSteps
                }
                if item.isExecutable {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: PaneFont.size * 0.8))
                        .foregroundStyle(.orange)
                        .help("Executable")
                }
            }
        }
    }

    private var arrowToolTip: String {
        guard !item.linkTarget.isEmpty else { return "Symbolic link" }
        return "Symbolic link to \(item.linkTarget)"
            + (item.linkTargetExists ? " \u{2014} double-click the arrow to go there" : "")
    }

    /// How far a link goes, after its arrow. A plain number when it reaches
    /// something through more than one link; a red dot when it ends at nothing
    /// -- "(3)" before it when that is the third link along; a red broken
    /// circle when the links go round, with how many can be followed first.
    /// A bare dot or circle is (1) or (0): nothing to count.
    @ViewBuilder
    private var linkSteps: some View {
        if let chain = item.linkChain {
            if chain.finalTarget != nil {
                if chain.length > 1 {
                    stepCount(chain.length, colour: .primary)
                        .help("Through \(chain.length) links to its target")
                }
            } else if let steps = chain.brokenAfter {
                HStack(spacing: 2) {
                    if steps > 1 { stepCount(steps, colour: .red) }
                    Circle().fill(Color.red)
                        .frame(width: PaneFont.size * 0.6, height: PaneFont.size * 0.6)
                }
                .help(steps == 1
                      ? "Broken link: \u{201C}\(item.linkTarget)\u{201D} is not there"
                      : "Broken link: \(steps) links along, the target is not there")
            } else if let steps = chain.stepsBeforeLoop {
                HStack(spacing: 2) {
                    if steps > 0 { stepCount(steps, colour: .red) }
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: PaneFont.size * 0.75, weight: .bold))
                        .foregroundStyle(.red)
                }
                .help(steps == 0
                      ? "Broken link: it points to itself"
                      : "Broken link: after \(steps) links the links lead round in a loop")
            }
        }
    }

    private func stepCount(_ count: Int, colour: Color) -> some View {
        Text("(\(count))")
            .font(.system(size: PaneFont.size * 0.8))
            .foregroundStyle(colour)
    }

    // MARK: - Permissions

    @ViewBuilder
    private var permissionsCell: some View {
        if pane.permissionEditAnchor == item.id {
            PermissionField(mode: pane.permissionMode,
                            onCursor: { model.permissionCursorMoved(to: $0) },
                            onCommit: { model.commitPermissionEdit($0) },
                            onCancel: { model.cancelPermissionEdit() })
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if item.isSymlink {
            // A link's own bits are always rwxr-xr-x on macOS and govern
            // nothing -- its target's do. Shown, they were noise, and offered
            // an edit that could only fail.
            Text("")
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(item.text(for: column))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // Same font the editor draws with, so the columns of characters
                // line up between an edited row and its neighbours.
                .font(PaneFont.monospacedSwiftUI)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
