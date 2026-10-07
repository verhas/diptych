import Foundation

/// The page Quick Look shows for a symbolic link.
///
/// Quick Look follows a link and previews what is at the end, which hides the
/// one thing that makes it a link: where it goes. A link to a link to a file
/// looked exactly like the file, and a broken one like nothing at all. This
/// says it is a link and lists every step to the end -- a file or folder, a
/// name with nothing behind it, or the link the chain went round to.
enum LinkReport {

    static func html(for chain: LinkChain, name: String, path: String) -> String {
        var body = "<h1>\(escape(name))</h1>"
        body += "<p class=lead>\(summary(chain))</p>"
        body += "<p class=meta>\(escape(path))</p>"

        body += "<table>"
        for (index, step) in chain.steps.enumerated() {
            body += "<tr><td class=icon>\u{21AA}\u{FE0E}</td>"
            body += "<td class=name>\(escape(step.link.path))"
            body += "<div class=via>\(index == 0 ? "points to" : "which points to") "
                  + "\(escape(step.destination))</div></td>"
            body += "<td class=size></td><td class=when></td></tr>"
        }
        body += endRow(chain.end)
        body += "</table>"
        return ListingReport.page(title: name, body: body)
    }

    private static func summary(_ chain: LinkChain) -> String {
        let through = chain.length == 1 ? "" : " through \(chain.length) links"
        switch chain.end {
        case .target(let url):
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
                ?? false
            return "Symbolic link\(through) to a \(isFolder ? "folder" : "file")"
        case .missing:
            return chain.length == 1
                ? "<span class=bad>Broken symbolic link: its target is not there</span>"
                : "<span class=bad>Broken symbolic link: link \(chain.length) of "
                  + "\(chain.length) points to something that is not there</span>"
        case .loop:
            return "<span class=bad>Broken symbolic link: the links go round in a loop</span>"
        }
    }

    private static func endRow(_ end: LinkChain.End) -> String {
        switch end {
        case .target(let url):
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isFolder = values?.isDirectory ?? false
            let size = isFolder ? "" : values?.fileSize.map { ListingReport.bytes(Int64($0)) } ?? ""
            return "<tr><td class=icon>\(isFolder ? "\u{1F4C1}" : "\u{1F4C4}")</td>"
                + "<td class=name>\(escape(url.path))</td>"
                + "<td class=size>\(size)</td>"
                + "<td class=when>\(values?.contentModificationDate.map(ListingReport.when) ?? "")"
                + "</td></tr>"
        case .missing(let url):
            return "<tr><td class=icon>\u{274C}</td>"
                + "<td class=name><span class=bad>\(escape(url.path))</span>"
                + "<div class=via>is not there</div></td><td class=size></td><td class=when></td></tr>"
        case .loop(let url):
            return "<tr><td class=icon>\u{1F501}</td>"
                + "<td class=name><span class=bad>\(escape(url.path))</span>"
                + "<div class=via>again \u{2014} the links go round</div></td>"
                + "<td class=size></td><td class=when></td></tr>"
        }
    }

    private static func escape(_ text: String) -> String { ListingReport.escape(text) }
}
