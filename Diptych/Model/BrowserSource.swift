import Foundation

/// A place a pane can browse whose listing is produced, not read from a real
/// directory: an archive now, SFTP or a process list later. One code shape for
/// all of them; version 1 implements the file-shaped ones.
///
/// The local file system is conceptually a source too -- the identity one --
/// but it stays implemented directly until expressing it here buys clarity.
protocol BrowserSource: Sendable {
    var capabilities: BrowserManifest.Capabilities { get }
    /// The children at a directory within the source; the root is "".
    func listing(of directory: String) -> [BrowserManifest.Node]
    /// A local file to open, preview or copy out, materialized if need be;
    /// nil when there is nothing to hand over.
    func localFile(for node: BrowserManifest.Node) -> URL?
}

