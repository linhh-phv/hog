import Darwin
import Foundation

/// Everything one sensing pass found, before interpretation. Built by `Scanner`, read by `Ownership`, rules
/// and the snapshot builder. Optional collections are `nil` when their sensor was unavailable.
public struct Scan: Sendable {
    public var takenAt: Date
    public var home: String
    public var selfPid: Int32
    public var selfUid: UInt32
    public var system: RawSystem
    /// Whole-machine CPU between the two samples; `nil` in fast mode.
    public var cpu: CPUSplit?
    public var processes: [Int32: RawProcess]
    /// Per-process CPU % between the two samples; empty in fast mode.
    public var cpuNowPct: [Int32: Double]
    /// When the second CPU sample was read (`cpuTimeNs` is from then); `nil` in fast mode.
    public var cpuSampledAt: Date?
    /// CPU hog itself used between the two machine samples, its finished commands (`lsof`, `launchctl`…) included,
    /// in % of one core: not part of "macOS and system services". `nil` in fast mode.
    public var hogCpuPct: Double?
    public var launchd: [Int32: String]?
    public var network: ExternalSensors.Network?
    public var vscode: CodeStatusParser.Status?
    public var windows: [Int: CodeStatusParser.Window]? { vscode?.windows }
    public var sessions: [Int32: ClaudeSession]?
    public var watchman: ExternalSensors.Watchman?
    public var containers: [DockerClient.Container]?
    /// Temperatures and fans (SMC); unmeasured when not read.
    public var heat: HeatInfo = .unmeasured
    /// Problems with data files the scan itself reads (`smc/*.json`), for the snapshot's `warnings`.
    public var dataWarnings: [String] = []
    public var sensors: [SensorStatus]

    public init(takenAt: Date = Date(), home: String = NSHomeDirectory(), selfPid: Int32 = getpid(), selfUid: UInt32 = getuid(),
                system: RawSystem, cpu: CPUSplit? = nil, processes: [Int32: RawProcess],
                cpuNowPct: [Int32: Double] = [:], launchd: [Int32: String]? = nil, network: ExternalSensors.Network? = nil,
                vscode: CodeStatusParser.Status? = nil, sessions: [Int32: ClaudeSession]? = nil,
                watchman: ExternalSensors.Watchman? = nil, containers: [DockerClient.Container]? = nil,
                sensors: [SensorStatus] = []) {
        self.takenAt = takenAt; self.home = home; self.selfPid = selfPid; self.selfUid = selfUid; self.system = system
        self.cpu = cpu; self.processes = processes; self.cpuNowPct = cpuNowPct; self.launchd = launchd
        self.network = network; self.vscode = vscode; self.sessions = sessions; self.watchman = watchman
        self.containers = containers; self.sensors = sensors
    }
}

public struct CPUSplit: Sendable, Equatable {
    public var user: Double
    public var sys: Double
    public var idle: Double
    public init(user: Double, sys: Double, idle: Double) { self.user = user; self.sys = sys; self.idle = idle }
}

/// Runs the sensors (design section 3). External sensors run in parallel; fast mode skips `code --status`,
/// watchman and the second CPU sample (`cpu.now_pct` is then `null`).
public struct Scanner: Sendable {
    public var external: ExternalSensors
    public var fast: Bool
    /// Seconds between the two CPU samples.
    public var cpuInterval: TimeInterval
    /// Which SMC keys are the CPU and GPU temperatures of each chip.
    public var smcKeys: SMCKeyTable

    public init(external: ExternalSensors = ExternalSensors(), fast: Bool = false, cpuInterval: TimeInterval = 1,
                smcKeys: SMCKeyTable? = nil) {
        self.external = external
        self.fast = fast
        self.cpuInterval = cpuInterval
        self.smcKeys = smcKeys ?? .load(.standard("smc", home: external.home))
    }

    public func scan() -> Scan {
        let started = Date()
        let first = Self.readAll()

        // External sensors first, in parallel, then the CPU window: nothing of hog's runs while the machine is sampled.
        // `code --status` starts a `Code --status` that is not hog's child, so its CPU would otherwise count as "system"
        // (reviewer 2026-10-27: +200 points while VS Code ran).
        nonisolated(unsafe) var launchd: Sensed<[Int32: String]>?
        nonisolated(unsafe) var network: Sensed<ExternalSensors.Network>?
        nonisolated(unsafe) var vscode: Sensed<CodeStatusParser.Status>?
        nonisolated(unsafe) var sessions: Sensed<[Int32: ClaudeSession]>?
        nonisolated(unsafe) var watchman: Sensed<ExternalSensors.Watchman>?
        nonisolated(unsafe) var docker: Sensed<[DockerClient.Container]>?
        let ext = external
        // The VS Code main process: `…/Visual Studio Code.app/Contents/MacOS/Code`, not a `--status` helper.
        let vscodeMain = first.values.filter {
            ($0.exePath.map(Self.isVSCodeMain) ?? false) && !($0.args?.contains("--status") ?? false)
        }.min { ($0.startSec ?? .max) < ($1.startSec ?? .max) }
        let vscodeRunning = vscodeMain != nil
        let mainIdentity = vscodeMain.map { (pid: $0.pid, start: $0.startSec ?? 0) }
        let group = DispatchGroup()
        let q = DispatchQueue.global(qos: .userInitiated)
        q.async(group: group) { launchd = ext.launchdJobs() }
        q.async(group: group) { network = ext.network() }
        q.async(group: group) { sessions = ext.claudeSessions() }
        q.async(group: group) { docker = ext.docker() }
        if !fast {
            if vscodeRunning {
                q.async(group: group) { vscode = ext.vscode(main: mainIdentity) }
            }
            q.async(group: group) { watchman = ext.watchman() }
        }
        group.wait()

        // The CPU window: machine ticks, every process's CPU time, sleep, again. hog only sleeps in between.
        var ticks0: SystemReader.CPUTicks?, ticks1: SystemReader.CPUTicks?
        var usage0 = (Date(), 0.0), usage1 = (Date(), 0.0)
        var before: [Int32: RawProcess] = [:], second: [Int32: RawProcess] = [:]
        var sampledAt = Date()
        var elapsed = cpuInterval
        if !fast {
            ticks0 = SystemReader.cpuTicks()
            usage0 = (Date(), Self.ownCPUSeconds())
            before = Self.readAll(includeArgs: false)
            let windowStart = Date()
            Thread.sleep(forTimeInterval: cpuInterval)
            second = Self.readAll(includeArgs: false)
            sampledAt = Date()
            elapsed = sampledAt.timeIntervalSince(windowStart)
            ticks1 = SystemReader.cpuTicks()
            usage1 = (Date(), Self.ownCPUSeconds())
        }

        var processes = first
        var cpuNow: [Int32: Double] = [:]
        if !fast {
            let elapsedNs = elapsed * 1_000_000_000
            for (pid, p) in second {
                // Identity from the two samples of the window: a process started during the sensors (after `first`) still
                // counts as readable instead of falling into "system" (reviewer 2026-10-27).
                guard let a = before[pid]?.cpuTimeNs, let b = p.cpuTimeNs, b >= a, before[pid]?.startSec == p.startSec else { continue }
                if processes[pid]?.startSec != p.startSec { processes[pid] = p }
                cpuNow[pid] = Double(b - a) / elapsedNs * 100
                processes[pid]?.cpuTimeNs = b
                processes[pid]?.footprintBytes = p.footprintBytes
                processes[pid]?.residentBytes = p.residentBytes
            }
        }

        var sensors: [SensorStatus] = [
            SensorStatus(name: "native-proc", status: .ok, tookMs: Int(Date().timeIntervalSince(started) * 1000)),
        ]
        // Cheap (a few ms, no command): read in `--fast` too, after the CPU window like the other native numbers.
        let heat = HeatReader.read(table: smcKeys)
        sensors.append(heat.status)
        sensors += [launchd?.status, network?.status, sessions?.status, docker?.status].compactMap { $0 }
        if fast {
            sensors.append(SensorStatus(name: "vscode", status: .skipped, tookMs: 0, note: "--fast"))
            sensors.append(SensorStatus(name: "watchman", status: .skipped, tookMs: 0, note: "--fast"))
        } else {
            sensors.append(vscode?.status ?? SensorStatus(name: "vscode", status: .skipped, tookMs: 0, note: "VS Code is not running"))
            if let w = watchman?.status { sensors.append(w) }
        }

        return Scan(takenAt: started, home: external.home, system: SystemReader.read(),
                    cpu: ticks0.flatMap { a in ticks1.flatMap { SystemReader.cpuPercent(from: a, to: $0) } }.map { CPUSplit(user: $0.user, sys: $0.sys, idle: $0.idle) },
                    processes: processes, cpuNowPct: cpuNow, launchd: launchd?.value, network: network?.value,
                    vscode: vscode?.value ?? (vscodeRunning ? CodeStatusParser.fallback(processes) : nil), sessions: sessions?.value, watchman: watchman?.value,
                    containers: docker?.value, sensors: sensors.sorted { $0.name < $1.name })
            .with {
                $0.heat = heat.heat
                $0.dataWarnings = smcKeys.warnings.map(\.description)
                guard !fast else { return }
                $0.cpuSampledAt = sampledAt
                $0.hogCpuPct = Self.cpuPercent(from: usage0, to: usage1)
            }
    }

    /// % of one core used between two `(time, CPU seconds)` readings; `nil` for an empty window.
    static func cpuPercent(from a: (Date, Double), to b: (Date, Double)) -> Double? {
        let window = b.0.timeIntervalSince(a.0)
        return window > 0 ? max(0, b.1 - a.1) / window * 100 : nil
    }

    /// CPU seconds of this process and of its children that have been waited for (`Command.run` waits for each).
    static func ownCPUSeconds() -> Double { cpuSeconds(RUSAGE_SELF) + cpuSeconds(RUSAGE_CHILDREN) }

    /// User + system CPU seconds from `getrusage(who)`.
    static func cpuSeconds(_ who: Int32) -> Double {
        var u = rusage()
        guard getrusage(who, &u) == 0 else { return 0 }
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }

    static func readAll(includeArgs: Bool = true) -> [Int32: RawProcess] {
        let pids = ProcessReader.allPids()
        nonisolated(unsafe) var out = [RawProcess?](repeating: nil, count: pids.count)
        DispatchQueue.concurrentPerform(iterations: pids.count) { i in out[i] = ProcessReader.read(pids[i], includeArgs: includeArgs) }
        return Dictionary(uniqueKeysWithValues: out.compactMap { $0 }.map { ($0.pid, $0) })
    }

    /// The VS Code main process (`…/Visual Studio Code.app/Contents/MacOS/Code` or `Electron`).
    static func isVSCodeMain(_ path: String) -> Bool {
        path.contains("Visual Studio Code.app/Contents/MacOS/")
    }
}

extension Scan {
    func with(_ change: (inout Scan) -> Void) -> Scan { var s = self; change(&s); return s }
}
