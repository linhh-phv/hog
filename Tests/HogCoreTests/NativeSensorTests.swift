import Foundation
import Testing
@testable import HogCore

/// Spawns a child process owned by the test. Tests never touch processes they did not start.
final class Child {
    let process = Process()

    init(_ path: String, _ args: [String], cwd: URL? = nil) throws {
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    var pid: Int32 { process.processIdentifier }

    deinit {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
    }
}

@Suite(.serialized) struct NativeSensorTests {
    @Test func listsOwnProcess() {
        #expect(ProcessReader.allPids().contains(getpid()))
    }

    @Test func readsParentStartCwdPathAndArgs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hog-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = Date()
        let child = try Child("/bin/sleep", ["30"], cwd: dir)
        Thread.sleep(forTimeInterval: 0.2)

        let p = ProcessReader.read(child.pid)
        #expect(p.ppid == getpid())
        #expect(p.uid == getuid())
        let start = try #require(p.startDate)
        #expect(abs(start.timeIntervalSince(before)) < 5)
        #expect(p.exePath == "/bin/sleep")
        #expect(p.args == ["/bin/sleep", "30"])
        // /var is a symlink to /private/var on macOS; compare resolved paths.
        #expect(p.cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == dir.resolvingSymlinksInPath().path)
        #expect((p.footprintBytes ?? 0) > 0)
        #expect(p.cpuTimeNs != nil)
    }

    @Test func kinfoFallbackMatchesBsdInfo() throws {
        let child = try Child("/bin/sleep", ["30"])
        Thread.sleep(forTimeInterval: 0.1)
        let a = try #require(ProcessReader.bsdInfo(child.pid))
        let b = try #require(ProcessReader.kinfoProc(child.pid))
        #expect(a.ppid == b.ppid)
        #expect(a.uid == b.uid)
        #expect(a.startSec == b.startSec)
    }

    @Test func kinfoReadsProcessesBsdInfoCannot() throws {
        // launchd (pid 1) belongs to root: PROC_PIDTBSDINFO is denied, kinfo_proc is not.
        #expect(ProcessReader.bsdInfo(1) == nil || getuid() == 0)
        let k = try #require(ProcessReader.kinfoProc(1))
        #expect(k.uid == 0)
        #expect(ProcessReader.read(1).footprintBytes == nil, "rusage of a root process must be unmeasured, not 0")
    }

    @Test func footprintGrowsWhenChildAllocates() throws {
        // perl allocates ~200 MB of real memory, then sleeps.
        let child = try Child("/usr/bin/perl", ["-e", "my $x = 'a' x 200_000_000; sleep 30;"])
        var footprint: Int64 = 0
        for _ in 0..<50 {
            Thread.sleep(forTimeInterval: 0.1)
            footprint = ProcessReader.read(child.pid).footprintBytes ?? 0
            if footprint > 150_000_000 { break }
        }
        #expect(footprint > 150_000_000)
    }

    @Test func parsesProcArgs2Buffer() throws {
        var buf: [UInt8] = []
        withUnsafeBytes(of: Int32(2)) { buf += $0 }
        buf += Array("./mysleep".utf8) + [0, 0, 0]
        buf += Array("./mysleep".utf8) + [0] + Array("5".utf8) + [0]
        buf += Array("HOME=/x".utf8) + [0]
        let parsed = try #require(ProcessReader.parseProcArgs2(buf))
        #expect(parsed.execPath == "./mysleep")
        #expect(parsed.argv == ["./mysleep", "5"])
    }
}

@Suite struct SystemReaderTests {
    @Test func readsMachineNumbers() throws {
        let s = SystemReader.read()
        #expect(s.memTotalBytes > 1_000_000_000)
        #expect(s.ncpu > 0)
        #expect(s.pageSize > 0)
        #expect(s.wiredBytes != nil)
        #expect(s.compressorBytes != nil)
        #expect(s.swapTotalBytes != nil)
        #expect(SystemReader.pressure(s.pressureLevel) != nil)
        #expect(s.load?.count == 3)
    }

    @Test func compressorMatchesVmStat() throws {
        let s = SystemReader.read()
        let out = try run("/usr/bin/vm_stat")
        let pages = try #require(out.split(separator: "\n").first { $0.contains("Pages occupied by compressor") }
            .flatMap { Int64($0.split(separator: ":").last!.trimmingCharacters(in: .whitespaces).dropLast()) })
        let fromVmStat = pages * s.pageSize
        let native = try #require(s.compressorBytes)
        // The two reads happen at slightly different moments; allow 10 %.
        #expect(abs(Double(native - fromVmStat)) <= max(Double(fromVmStat) * 0.10, 64 * 1024 * 1024))
    }

    @Test func pressureMapping() {
        #expect(SystemReader.pressure(1) == .normal)
        #expect(SystemReader.pressure(2) == .warn)
        #expect(SystemReader.pressure(4) == .critical)
        #expect(SystemReader.pressure(nil) == nil)
        #expect(SystemReader.pressure(3) == nil)
    }

    @Test func cpuPercentFromTicks() throws {
        let a = SystemReader.CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let b = SystemReader.CPUTicks(user: 200, system: 100, idle: 1700, nice: 0)
        let p = try #require(SystemReader.cpuPercent(from: a, to: b))
        #expect(abs(p.user - 10) < 0.001 && abs(p.sys - 5) < 0.001 && abs(p.idle - 85) < 0.001)
        #expect(SystemReader.cpuPercent(from: a, to: a) == nil)
    }

    func run(_ path: String, _ args: [String] = []) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
