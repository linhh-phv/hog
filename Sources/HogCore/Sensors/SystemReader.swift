import Darwin
import Foundation

/// Machine-wide numbers read with native APIs (design section 3.1).
public struct RawSystem: Sendable, Equatable {
    public var memTotalBytes: Int64
    public var ncpu: Int
    public var pageSize: Int64
    public var freeBytes: Int64?
    public var wiredBytes: Int64?
    public var compressorBytes: Int64?
    public var compressedStoredBytes: Int64?
    public var swapUsedBytes: Int64?
    public var swapTotalBytes: Int64?
    public var pressureLevel: Int32?
    public var uptimeS: Int64?
    public var load: [Double]?

    public init(memTotalBytes: Int64, ncpu: Int, pageSize: Int64) {
        self.memTotalBytes = memTotalBytes; self.ncpu = ncpu; self.pageSize = pageSize
    }
}

public enum SystemReader {
    public static func read() -> RawSystem {
        let pageSize = Int64(getpagesize())
        var s = RawSystem(memTotalBytes: sysctlInt64("hw.memsize") ?? 0,
                          ncpu: Int(sysctlInt32("hw.ncpu") ?? 0),
                          pageSize: pageSize)
        if let vm = vmStatistics() {
            s.freeBytes = Int64(vm.free_count) * pageSize
            s.wiredBytes = Int64(vm.wire_count) * pageSize
            s.compressorBytes = Int64(vm.compressor_page_count) * pageSize
            s.compressedStoredBytes = Int64(vm.total_uncompressed_pages_in_compressor) * pageSize
        }
        if let sw = swapUsage() {
            s.swapUsedBytes = Int64(sw.xsu_used)
            s.swapTotalBytes = Int64(sw.xsu_total)
        }
        s.pressureLevel = sysctlInt32("kern.memorystatus_vm_pressure_level")
        s.uptimeS = uptime()
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 { s.load = loads }
        return s
    }

    /// Only the pressure level: one sysctl, cheap enough for the menu bar icon every 10 s.
    public static func pressureNow() -> Pressure? { pressure(sysctlInt32("kern.memorystatus_vm_pressure_level")) }

    /// Maps the kernel pressure level: 1 normal, 2 warn, 4 critical. Anything else is unknown.
    public static func pressure(_ level: Int32?) -> Pressure? {
        switch level {
        case 1: .normal
        case 2: .warn
        case 4: .critical
        default: nil
        }
    }

    static func vmStatistics() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? stats : nil
    }

    static func swapUsage() -> xsw_usage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? usage : nil
    }

    static func uptime() -> Int64? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        return Int64(Date().timeIntervalSince1970) - Int64(boot.tv_sec)
    }

    static func sysctlInt64(_ name: String) -> Int64? {
        var v: Int64 = 0
        var size = MemoryLayout<Int64>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? v : nil
    }

    static func sysctlInt32(_ name: String) -> Int32? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? v : nil
    }

    // MARK: - Whole-machine CPU

    public struct CPUTicks: Sendable, Equatable { var user, system, idle, nice: UInt64 }

    public static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return CPUTicks(user: UInt64(t.0), system: UInt64(t.1), idle: UInt64(t.2), nice: UInt64(t.3))
    }

    /// user/sys/idle percentages between two tick samples.
    public static func cpuPercent(from a: CPUTicks, to b: CPUTicks) -> (user: Double, sys: Double, idle: Double)? {
        let user = Double(b.user &- a.user) + Double(b.nice &- a.nice)
        let sys = Double(b.system &- a.system)
        let idle = Double(b.idle &- a.idle)
        let total = user + sys + idle
        guard total > 0 else { return nil }
        return (user / total * 100, sys / total * 100, idle / total * 100)
    }
}
