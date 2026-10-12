import Foundation

/// Why a file could not be written, in words that are true.
///
/// macOS hands back "You do not have permission to save the file X in the
/// folder Y" for a whole family of failures, most of which have nothing to do
/// with permission. A save that fails because an attribute cannot be copied
/// produces that sentence, and it sends the reader off to check ownership,
/// group, ACLs and the folder above -- all of which are fine, because they
/// were never the problem. One technical user described being dumbfounded by
/// it; somebody who is not technical has nowhere to go at all.
///
/// So the message is worked out from the file rather than repeated from the
/// system: ask what is actually true, say that, and say what can be done. When
/// nothing is wrong that the user could fix, say *that* too, plainly, rather
/// than implying they have failed to set something up.
enum WriteTrouble {

    static func explaining(_ error: Error, writing url: URL) -> String {
        let manager = FileManager.default
        let name = url.lastPathComponent
        let folder = url.deletingLastPathComponent()
        let code = (error as NSError).code

        if code == NSFileWriteOutOfSpaceError {
            return "There is no room left on the disk."
        }
        if code == NSFileWriteVolumeReadOnlyError {
            return "That disk is read-only, so nothing on it can be changed."
        }
        // Before the permissions: they can say rw- on a volume -- an FTP
        // server, a share mounted read-only -- that takes no writes at all.
        if let volume = readOnlyVolume(of: url) {
            return "\(volume) is mounted read-only, so nothing on it can be changed from this "
                 + "Mac, whatever \u{201C}\(name)\u{201D}\u{2019}s permissions say."
        }

        // Locked in the Finder sense: the user can undo this one themselves,
        // and the Finder's own wording is the one they will recognise.
        if let flags = (try? manager.attributesOfItem(atPath: url.path)[.immutable]) as? Bool,
           flags {
            return "\u{201C}\(name)\u{201D} is locked. Unlock it in Get Info and try again."
        }

        if manager.fileExists(atPath: url.path), !manager.isWritableFile(atPath: url.path) {
            return "\u{201C}\(name)\u{201D} cannot be written to. Its permissions do not allow "
                 + "it, and Get Info can change them."
        }
        if !manager.isWritableFile(atPath: folder.path) {
            return "The folder \u{201C}\(folder.lastPathComponent)\u{201D} cannot be written to. "
                 + "Its permissions do not allow it, and Get Info can change them."
        }

        // Everything the user could be expected to check is in order, so the
        // refusal is the system's own and there is nothing for them to fix.
        // Saying so is more use than repeating a sentence about permission
        // that has already been shown to be untrue.
        return "macOS refused to write \u{201C}\(name)\u{201D}, and it is not about "
             + "permissions \u{2014} the file and its folder are both writable. "
             + "\n\nThere is nothing you need to change. If it keeps happening, copying the "
             + "file and working on the copy will get past it."
             + "\n\nWhat macOS said: \(error.localizedDescription)"
    }

    /// The volume `url` is on, quoted -- "“ftp.example.com”" -- when it is
    /// mounted read-only; nil when it takes writes.
    static func readOnlyVolume(of url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey,
                                                       .volumeLocalizedNameKey])
        guard values?.volumeIsReadOnly == true else { return nil }
        return values?.volumeLocalizedName.map { "\u{201C}\($0)\u{201D}" } ?? "Its volume"
    }
}
