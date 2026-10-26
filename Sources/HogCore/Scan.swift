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
    public var launchd: [Int32: String]?
    public var network: ExternalSensors.Network?
    public var vscode: CodeStatusParser.Status?
    public var windows: [Int: CodeStatusParser.Window]? { vscode?.windows }
    public var sessions: [Int32: ClaudeSession]?
    public var watchman: ExternalSensors.Watchman?
    public var containers: [DockerClient.Container]?
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
        if !fast { Thread.sleep(forTimeInterval: max(0, cpuInterval - Date().timeIntervalSince(started))) }
        let second = fast ? first : Self.readAll(includeArgs: false)
        let sampledAt = Date()
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
            sensors.append(vscode?.status ?? SensorStatus(name: "vscode", status: .skipped, tookMs: 0, note: "VS Code is not running"))
            if let w = watchman?.status { sensors.append(w) }
        }

        return Scan(takenAt: started, home: external.home, system: SystemReader.read(),
                    cpu: ticks0.flatMap { a in ticks1.flatMap { SystemReader.cpuPercent(from: a, to: $0) } }.map { CPUSplit(user: $0.user, sys: $0.sys, idle: $0.idle) },
                    processes: processes, cpuNowPct: cpuNow, launchd: launchd?.value, network: network?.value,
                    vscode: vscode?.value ?? (vscodeRunning ? CodeStatusParser.fallback(processes) : nil), sessions: sessions?.value, watchman: watchman?.value,
                    containers: docker?.value, sensors: sensors.sorted { $0.name < $1.name })
            .with { if !fast { $0.cpuSampledAt = sampledAt } }
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
