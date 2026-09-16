import Foundation
import Darwin

/// Which programs have a file open, and which have a folder as their current
/// one.
///
/// Through `libproc` -- `proc_listallpids`, `proc_pidinfo`, `proc_pidfdinfo` --
/// which is what `lsof` itself calls. No subprocess, no output to parse, and
/// nothing that can hang on a stale network mount, because this asks about
/// processes rather than walking the file system.
///
/// Two honest limits, neither of them Diptych's to lift:
///
/// * **Other users' programs cannot be looked inside.** Asking the kernel for
///   another user's open files is refused unless you are root, so a report
///   says how many processes it could not see into. "Nothing of yours has
///   this open" is the strongest true statement, and the tab says exactly
///   that rather than implying nobody has it.
/// * **Open is not locked.** A program that has a file open is usually just
///   reading it. Advisory locks are a separate mechanism whose holders cannot
///   be listed at all, and the user-immutable flag is a third thing again.
///
/// The structures come from `<sys/proc_info.h>`, which ships in the SDK but
/// belongs to the kernel and may change between releases -- so every call
/// checks its own return value and anything unreadable is simply left out
/// rather than treated as an error.
enum OpenFiles {

    struct Holder: Identifiable, Sendable, Equatable {
        let pid: pid_t
        /// The name of the program, and the path it was launched from.
        let program: String
        let executable: String
        let kind: Kind
        /// Which file, when the question was about a folder and this is
        /// something inside it. Nil when it is the thing asked about.
        let path: String?

        var id: String { "\(pid)-\(kind.id)-\(path ?? "")" }

        enum Kind: Sendable, Equatable {
            /// Has it open, on this descriptor.
            case open(descriptor: Int32, writable: Bool)
            /// Is *in* the folder: its working directory.
            case currentFolder

            var id: String {
                switch self {
                case .open(let descriptor, _): "fd\(descriptor)"
                case .currentFolder: "cwd"
                }
            }

            var describes: String {
                switch self {
                case .open(_, let writable): writable ? "open for writing" : "open for reading"
                case .currentFolder: "its current folder"
                }
            }
        }
    }

    /// Beyond this many, the list stops being a list and the point is made
    /// anyway: something is using the folder.
    static let mostHolders = 200

    struct Report: Sendable, Equatable {
        var holders: [Holder] = []
        /// How many processes there were, how many could be looked inside, and
        /// how many the kernel refused -- the three numbers that make the
        /// answer honest.
        var processes = 0
        var looked = 0
        var refused = 0
        var at = Date()
        /// The search ran out of time and stopped early.
        var incomplete = false
        /// There were more than `mostHolders`; the rest are not listed.
        var truncated = false
        /// Not even the list of processes could be had.
        var failure: String?

        var isEmpty: Bool { holders.isEmpty }
    }

    /// Everything holding `url`, as far as this Mac will say.
    ///
    /// `deadline` bounds the whole search: a few hundred processes each with a
    /// few hundred descriptors is quick, but this is a loop over the whole
    /// machine and the Info window must not be held up by it.
    nonisolated static func holders(of url: URL, deadline: TimeInterval = 3) -> Report {
        var report = Report()
        let started = Date()
        let target = resolved(url.path)
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

        // With no buffer this answers how many processes there are.
        let possible = proc_listallpids(nil, 0)
        guard possible > 0 else {
            report.failure = "The list of programs could not be read."
            return report
        }
        // Room to spare: processes start and stop while this runs.
        var pids = [pid_t](repeating: 0, count: Int(possible) + 64)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else {
            report.failure = "The list of programs could not be read."
            return report
        }
        let count = Int(bytes) / MemoryLayout<pid_t>.size
        report.processes = count

        for pid in pids.prefix(count) where pid > 0 {
            if Date().timeIntervalSince(started) > deadline {
                report.incomplete = true
                break
            }

            // Whether this process can be looked inside at all. A refusal is
            // another user's program, or one that has just exited.
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else {
                if errno == EPERM { report.refused += 1 }
                continue
            }
            report.looked += 1

            if isFolder, let folder = currentFolder(of: pid), folder == target {
                report.holders.append(holder(pid, kind: .currentFolder, path: nil))
            }

            let room = Int(size) / MemoryLayout<proc_fdinfo>.size + 32
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: room)
            let read = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors,
                                    Int32(room * MemoryLayout<proc_fdinfo>.size))
            guard read > 0 else { continue }

            for entry in descriptors.prefix(Int(read) / MemoryLayout<proc_fdinfo>.size) {
                guard entry.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { continue }
                var info = vnode_fdinfowithpath()
                let got = proc_pidfdinfo(pid, entry.proc_fd, PROC_PIDFDVNODEPATHINFO, &info,
                                         Int32(MemoryLayout<vnode_fdinfowithpath>.size))
                guard got > 0 else { continue }
                let open = resolved(path(from: info.pvip.vip_path))
                // For a folder, anything inside it counts: "can I move this
                // folder" is answered by what is open *in* it, not by the rare
                // descriptor on the folder itself.
                let inside = isFolder && open.hasPrefix(target + "/")
                guard open == target || inside else { continue }
                guard report.holders.count < mostHolders else {
                    report.truncated = true
                    break
                }
                let writable = info.pfi.fi_openflags & UInt32(bitPattern: FWRITE) != 0
                report.holders.append(holder(pid, kind: .open(descriptor: entry.proc_fd,
                                                              writable: writable),
                                             path: inside ? open : nil))
            }
        }

        // The writer first: that is the one that matters when a file changes
        // under a window that has it open.
        report.holders.sort {
            ($0.isWriting ? 0 : 1, $0.program.lowercased(), $0.pid)
                < ($1.isWriting ? 0 : 1, $1.program.lowercased(), $1.pid)
        }
        return report
    }

    // MARK: - Pieces

    private nonisolated static func holder(_ pid: pid_t, kind: Holder.Kind,
                                           path: String?) -> Holder {
        let executable = executablePath(of: pid)
        let program = executable.isEmpty
            ? "process \(pid)"
            : String(executable.split(separator: "/").last ?? "")
        return Holder(pid: pid, program: program, executable: executable, kind: kind, path: path)
    }

    private nonisolated static func executablePath(of pid: pid_t) -> String {
        // 4 * MAXPATHLEN, which is what proc_pidpath documents as its
        // largest answer; the constant itself is not exposed to Swift.
        var buffer = [CChar](repeating: 0, count: 4 * 1024)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) },
                      as: UTF8.self)
    }

    private nonisolated static func currentFolder(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let got = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info,
                               Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard got > 0 else { return nil }
        let folder = path(from: info.pvi_cdir.vip_path)
        return folder.isEmpty ? nil : resolved(folder)
    }

    /// The kernel hands back a fixed-size C string inside a struct.
    private nonisolated static func path(from field: some Any) -> String {
        withUnsafeBytes(of: field) { raw in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    /// `/tmp` and `/private/tmp` are the same folder, and the kernel and
    /// Foundation do not spell them the same way -- which is exactly how a
    /// first attempt at this found nothing at all.
    private nonisolated static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}

extension OpenFiles.Holder {
    var isWriting: Bool {
        if case .open(_, let writable) = kind { writable } else { false }
    }
}
