import SwiftUI

/// The path bar while Option is held: every folder on the way from / to here
/// as a link, `/ Users / verhasp / github`, so going up several levels is one
/// click instead of editing the text.
struct PathCrumbs: View {

    let directory: URL
    /// Called with the folder clicked, and the one under it on the way here --
    /// which the pane selects, as going up does.
    let go: (_ folder: URL, _ cameFrom: URL) -> Void

    var body: some View {
        // Left-aligned, as the text is. Only a path too long for the bar
        // scrolls, and it starts scrolled to the right: the end of it is what
        // matters, as with the text, which is truncated at the head. Anchored
        // right always, a short path sat at the far end of the bar.
        ViewThatFits(in: .horizontal) {
            crumbs.fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) { crumbs }
                .defaultScrollAnchor(.trailing)
        }
    }

    private var crumbs: some View {
        HStack(spacing: 0) {
            ForEach(Array(folders.enumerated()), id: \.offset) { index, folder in
                // `/ Users / verhasp`: the root is a slash already, so
                // only a space follows it.
                if index > 0 { Text(index == 1 ? " " : " / ").foregroundStyle(.secondary) }
                if index == folders.count - 1 {
                    // Where the pane already is: not a link.
                    name(of: folder)
                } else {
                    link(to: folder, cameFrom: folders[index + 1])
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 4)
        .frame(height: 21)
    }

    /// `/`, `/Users`, `/Users/verhasp`, ... down to the pane's own folder.
    var folders: [URL] { Self.folders(of: directory) }

    nonisolated static func folders(of directory: URL) -> [URL] {
        var folders = [directory]
        while let last = folders.last, last.pathComponents.count > 1 {
            folders.append(last.deletingLastPathComponent())
        }
        return folders.reversed()
    }

    private func name(of folder: URL) -> Text {
        Text(folder.pathComponents.count == 1 ? "/" : folder.lastPathComponent)
    }

    private func link(to folder: URL, cameFrom: URL) -> some View {
        Button {
            go(folder, cameFrom)
        } label: {
            name(of: folder)
                .underline()
                .foregroundStyle(Color(nsColor: .linkColor))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(folder.path)
    }
}
