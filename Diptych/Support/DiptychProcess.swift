import Darwin
import Foundation

/// This running Diptych, as MCP's `get_diptych_info` and the run records name
/// it. A process id alone does not identify a session -- ids are reused after
/// a restart -- so the process's own start time travels with it.
enum DiptychProcess {

    static let pid: Int32 = getpid()

    /// When the kernel started this process, not when someone first asked.
    static let startedAt: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec)
                    + TimeInterval(start.tv_usec) / 1_000_000)
    }()

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
