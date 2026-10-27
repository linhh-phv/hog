import Darwin
import Foundation

/// Raw facts about one process, read with native macOS APIs (design section 3.1).
/// Every field is optional: macOS denies some reads (EPERM for other users' processes) and that is "not measured".
public struct RawProcess: Sendable, Equatable {
    public var pid: Int32
    public var ppid: Int32?
    public var uid: UInt32?
    /// Start time, seconds + microseconds since 1970. Part of the process identity (gate G3).
    public var startSec: Int64?
    public var startUsec: Int64?
    public var exePath: String?
    public var args: [String]?
    public var cwd: String?
    public var footprintBytes: Int64?
    public var residentBytes: Int64?
    /// Total CPU time (user + system), nanoseconds.
    public var cpuTimeNs: UInt64?

    public init(pid: Int32) { self.pid = pid }

    public var startDate: Date? {
        guard let s = startSec else { return nil }
        return Date(timeIntervalSince1970: Double(s) + Double(startUsec ?? 0) / 1_000_000)
    }
}

/// Native reads of per-process information. Pure wrappers: no caching, no interpretation.
public enum ProcessReader {
    /// All PIDs currently known to the kernel.
    public static func allPids() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard n > 0 else { return [] }
        return pids.prefix(Int(n)).filter { $0 > 0 }
    }

    /// Reads everything readable about a process. Missing parts stay `nil`.
    public static func read(_ pid: Int32, includeArgs: Bool = true) -> RawProcess {
        var p = RawProcess(pid: pid)
        if let b = bsdInfo(pid) ?? kinfoProc(pid) {
            p.ppid = b.ppid; p.uid = b.uid; p.startSec = b.startSec; p.startUsec = b.startUsec
        }
        let procArgs = includeArgs ? procArgs2(pid) : nil
        p.exePath = pidPath(pid) ?? procArgs.flatMap { $0.execPath.hasPrefix("/") ? $0.execPath : nil }
        p.args = procArgs?.argv
        p.cwd = cwd(pid)
        if let r = rusage(pid) {
            p.footprintBytes = Int64(clamping: r.ri_phys_footprint)
            p.residentBytes = Int64(clamping: r.ri_resident_size)
            p.cpuTimeNs = machToNanos(r.ri_user_time &+ r.ri_system_time)
        }
        return p
    }

    // MARK: - Individual reads

    struct BSDInfo { var ppid: Int32; var uid: UInt32; var startSec: Int64; var startUsec: Int64 }

    /// `proc_pidinfo(PROC_PIDTBSDINFO)`: EPERM for processes of other users.
    static func bsdInfo(_ pid: Int32) -> BSDInfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return BSDInfo(ppid: Int32(info.pbi_ppid), uid: info.pbi_uid,
                       startSec: Int64(info.pbi_start_tvsec), startUsec: Int64(info.pbi_start_tvusec))
    }

    /// `sysctl KERN_PROC_PID` (`kinfo_proc`): readable for almost every PID, used when `bsdInfo` is denied.
    static func kinfoProc(_ pid: Int32) -> BSDInfo? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return BSDInfo(ppid: info.kp_eproc.e_ppid, uid: info.kp_eproc.e_ucred.cr_uid,
                       startSec: Int64(start.tv_sec), startUsec: Int64(start.tv_usec))
    }

    /// Resolved executable path. Empty when the binary was deleted or replaced while running.
    static func pidPath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    struct ProcArgs { var execPath: String; var argv: [String] }

    /// `sysctl KERN_PROCARGS2`: argc, exec path as passed to execve (not resolved), then argv.
    static func procArgs2(_ pid: Int32) -> ProcArgs? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs2(Array(buf.prefix(size)))
    }

    /// Parses the KERN_PROCARGS2 buffer. Exposed for tests.
    static func parseProcArgs2(_ buf: [UInt8]) -> ProcArgs? {
        guard buf.count > 4 else { return nil }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        func readString() -> String? {
            guard i < buf.count else { return nil }
            let start = i
            while i < buf.count, buf[i] != 0 { i += 1 }
            let s = String(decoding: buf[start..<i], as: UTF8.self)
            return s
        }
        guard let execPath = readString() else { return nil }
        while i < buf.count, buf[i] == 0 { i += 1 }
        var argv: [String] = []
        while argv.count < Int(argc), i < buf.count, let s = readString() {
            argv.append(s)
            i += 1
        }
        return ProcArgs(execPath: execPath, argv: argv)
    }

    static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    static func rusage(_ pid: Int32) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return r == 0 ? info : nil
    }

    static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    static func machToNanos(_ t: UInt64) -> UInt64 {
        t.multipliedReportingOverflow(by: UInt64(timebase.numer)).partialValue / UInt64(max(timebase.denom, 1))
    }
}
