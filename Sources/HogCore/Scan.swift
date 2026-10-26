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
    public var launchd: [Int32: String]?
    public var network: ExternalSensors.Network?
    public var windows: [Int: CodeStatusParser.Window]?
    public var sessions: [Int32: ClaudeSession]?
    public var watchman: ExternalSensors.Watchman?
    public var containers: [DockerClient.Container]?
    public var sensors: [SensorStatus]

    public init(takenAt: Date = Date(), home: String = NSHomeDirectory(), selfPid: Int32 = getpid(), selfUid: UInt32 = getuid(),
                system: RawSystem, cpu: CPUSplit? = nil, processes: [Int32: RawProcess],
                cpuNowPct: [Int32: Double] = [:], launchd: [Int32: String]? = nil, network: ExternalSensors.Network? = nil,
                windows: [Int: CodeStatusParser.Window]? = nil, sessions: [Int32: ClaudeSession]? = nil,
                watchman: ExternalSensors.Watchman? = nil, containers: [DockerClient.Container]? = nil,
                sensors: [SensorStatus] = []) {
        self.takenAt = takenAt; self.home = home; self.selfPid = selfPid; self.selfUid = selfUid; self.system = system
        self.cpu = cpu; self.processes = processes; self.cpuNowPct = cpuNowPct; self.launchd = launchd
        self.network = network; self.windows = windows; self.sessions = sessions; self.watchman = watchman
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

    public init(external: ExternalSensors = ExternalSensors(), fast: Bool = false, cpuInterval: TimeInterval = 1) {
        self.external = external
        self.fast = fast
        self.cpuInterval = cpuInterval
    }

    public func scan() -> Scan {
        let started = Date()
        let ticks0 = fast ? nil : SystemReader.cpuTicks()
        let first = Self.readAll()

        // External sensors in parallel with the CPU sampling interval.
        nonisolated(unsafe) var launchd: Sensed<[Int32: String]>?
        nonisolated(unsafe) var network: Sensed<ExternalSensors.Network>?
        nonisolated(unsafe) var windows: Sensed<[Int: CodeStatusParser.Window]>?
        nonisolated(unsafe) var sessions: Sensed<[Int32: ClaudeSession]>?
        nonisolated(unsafe) var watchman: Sensed<ExternalSensors.Watchman>?
        nonisolated(unsafe) var docker: Sensed<[DockerClient.Container]>?
        let ext = external
        let vscodeRunning = first.values.contains { $0.exePath.map(Self.isVSCodeMain) ?? false }
        let group = DispatchGroup()
        let q = DispatchQueue.global(qos: .userInitiated)
        q.async(group: group) { launchd = ext.launchdJobs() }
        q.async(group: group) { network = ext.network() }
        q.async(group: group) { sessions = ext.claudeSessions() }
        q.async(group: group) { docker = ext.docker() }
        if !fast {
            if vscodeRunning {
                q.async(group: group) { windows = ext.vscodeWindows() }
            }
            q.async(group: group) { watchman = ext.watchman() }
        }
        if !fast { Thread.sleep(forTimeInterval: max(0, cpuInterval - Date().timeIntervalSince(started))) }
        let second = fast ? first : Self.readAll(includeArgs: false)
        let ticks1 = fast ? nil : SystemReader.cpuTicks()
        group.wait()

        var processes = first
        var cpuNow: [Int32: Double] = [:]
        if !fast {
            let elapsedNs = cpuInterval * 1_000_000_000
            for (pid, p) in second {
                guard let a = first[pid]?.cpuTimeNs, let b = p.cpuTimeNs, b >= a, first[pid]?.startSec == p.startSec else { continue }
                cpuNow[pid] = Double(b - a) / elapsedNs * 100
                processes[pid]?.cpuTimeNs = b
                processes[pid]?.footprintBytes = p.footprintBytes
                processes[pid]?.residentBytes = p.residentBytes
            }
        }

        var sensors: [SensorStatus] = [
            SensorStatus(name: "native-proc", status: .ok, tookMs: Int(Date().timeIntervalSince(started) * 1000)),
        ]
        sensors += [launchd?.status, network?.status, sessions?.status, docker?.status].compactMap { $0 }
        if fast {
            sensors.append(SensorStatus(name: "vscode", status: .skipped, tookMs: 0, note: "--fast"))
            sensors.append(SensorStatus(name: "watchman", status: .skipped, tookMs: 0, note: "--fast"))
        } else {
            sensors.append(windows?.status ?? SensorStatus(name: "vscode", status: .skipped, tookMs: 0, note: "VS Code is not running"))
            if let w = watchman?.status { sensors.append(w) }
        }

        return Scan(takenAt: started, home: external.home, system: SystemReader.read(),
                    cpu: ticks0.flatMap { a in ticks1.flatMap { SystemReader.cpuPercent(from: a, to: $0) } }.map { CPUSplit(user: $0.user, sys: $0.sys, idle: $0.idle) },
                    processes: processes, cpuNowPct: cpuNow, launchd: launchd?.value, network: network?.value,
                    windows: windows?.value, sessions: sessions?.value, watchman: watchman?.value,
                    containers: docker?.value, sensors: sensors.sorted { $0.name < $1.name })
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
