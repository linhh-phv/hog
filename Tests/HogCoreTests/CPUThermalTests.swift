import Foundation
import Testing
@testable import HogCore

/// Task cpu-thermal: macOS's thermal state, CPU in the headline and the menu, the cpu-heavy rule.
@Suite struct CPUThermalTests {
    let analyzer: Analyzer = {
        let b = { (k: String) in DataSource(bundledDirectory: DataSource.standard(k).bundledDirectory, localDirectory: nil) }
        return Analyzer(catalog: .load(b("catalog")), rules: .load(b("rules")), explain: .load(b("explain")), lang: .en)
    }()

    @Test func thermalStateMapping() {
        #expect(SystemReader.thermal(.nominal) == .nominal)
        #expect(SystemReader.thermal(.fair) == .fair)
        #expect(SystemReader.thermal(.serious) == .serious)
        #expect(SystemReader.thermal(.critical) == .critical)
        #expect(SystemReader.thermalNow() != nil, "readable without root on this machine")
        #expect(ThermalState.fair < .serious && HeadlineLevel.warn < .critical)
    }

    /// A scan with one busy process of an app, one busy process without an app, and the given machine state.
    func scan(thermal: ThermalState?, idle: Double?) -> Scan {
        var system = RawSystem(memTotalBytes: 16 << 30, ncpu: 8, pageSize: 16384)
        system.pressureLevel = 1
        system.thermal = thermal
        var app = RawProcess(pid: 100); app.ppid = 1; app.uid = getuid(); app.footprintBytes = 300_000_000
        app.exePath = "/Applications/Busy.app/Contents/MacOS/Busy"; app.cwd = "/"; app.startSec = 1; app.cpuTimeNs = 3_600_000_000_000
        var tool = RawProcess(pid: 200); tool.ppid = 1; tool.uid = getuid(); tool.footprintBytes = 200_000_000
        tool.exePath = "/usr/local/bin/cruncher"; tool.cwd = "/"; tool.startSec = Int64(Date().timeIntervalSince1970) - 3600
        tool.cpuTimeNs = 1_800_000_000_000  // 30 min of CPU in 1 h: 50 % on average
        return Scan(system: system, cpu: idle.map { CPUSplit(user: 100 - $0, sys: 0, idle: $0) }, processes: [100: app, 200: tool],
                    cpuNowPct: idle == nil ? [:] : [100: 120, 200: 95], launchd: [:])
    }

    @Test func snapshotCarriesThermal() throws {
        let s = analyzer.analyze(scan(thermal: .fair, idle: 60))
        #expect(s.cpu.thermal.value == .fair)
        let json = try #require(String(data: SnapshotJSON.encode(s), encoding: .utf8))
        #expect(json.contains("\"thermal\" : \"fair\""))
    }

    @Test func headlineSaysHotWithTopCPU() {
        let s = analyzer.analyze(scan(thermal: .serious, idle: 20))
        #expect(s.headline.text.contains("The machine is hot"))
        #expect(s.headline.text.contains("Busy (120 %)") && s.headline.text.contains("cruncher (95 %)"))
        #expect(!s.headline.text.contains("{"), "every placeholder filled")
        #expect(s.headline.level == .warn, "hot raises the level to at least warn")
        #expect(s.headline.glossaryIds.contains("thermal-state"))
        #expect(analyzer.analyze(scan(thermal: .critical, idle: 20)).headline.level == .critical)
    }

    @Test func headlineSaysBusyWhenNotHot() {
        let busy = analyzer.analyze(scan(thermal: .nominal, idle: 15))
        #expect(busy.headline.text.contains("The CPU is busy (85 %"))
        #expect(busy.headline.level == .ok, "busy alone does not raise the level")
        let calm = analyzer.analyze(scan(thermal: .nominal, idle: 70))
        #expect(!calm.headline.text.contains("CPU"), "nothing about CPU when it does not matter")
    }

    @Test func fastModeSaysNotMeasured() {
        let s = analyzer.analyze(scan(thermal: .serious, idle: nil))
        #expect(s.headline.text.contains("not measured (--fast)"))
        #expect(Presentation.cpuRows(s, max: 3).isEmpty)
    }

    @Test func cpuHeavyRule() {
        let s = analyzer.analyze(scan(thermal: .nominal, idle: 50))
        let tool = s.items.first { $0.pids == [200] }
        let f = s.findings.first { $0.itemId == tool?.id }
        #expect(f?.verdict == .watch && f?.rules.contains("cpu-heavy") == true)
        #expect(f?.reason.contains("95 %") == true)
        // Not measured (fast mode): the rule does not fire.
        let fast = analyzer.analyze(scan(thermal: .nominal, idle: nil))
        #expect(!fast.findings.contains { $0.rules.contains("cpu-heavy") })
    }

    // Reviewer 2026-10-27: the thresholds themselves.
    func one(now: Double, avgSeconds: Double) -> Scan {
        var p = RawProcess(pid: 300); p.ppid = 1; p.uid = getuid(); p.footprintBytes = 200_000_000
        p.exePath = "/usr/local/bin/edge"; p.cwd = "/"; p.startSec = Int64(Date().timeIntervalSince1970) - 1000
        p.cpuTimeNs = UInt64(avgSeconds * 1e9)
        return Scan(system: RawSystem(memTotalBytes: 16 << 30, ncpu: 8, pageSize: 16384), cpu: CPUSplit(user: 50, sys: 0, idle: 50),
                    processes: [300: p], cpuNowPct: [300: now], launchd: [:])
    }

    @Test func cpuHeavyThresholds() {
        func fires(_ s: Scan) -> Bool { analyzer.analyze(s).findings.contains { $0.rules.contains("cpu-heavy") } }
        #expect(!fires(one(now: 79, avgSeconds: 500)), "79 % now")
        #expect(!fires(one(now: 80, avgSeconds: 89)), "8.9 % average")
        #expect(fires(one(now: 80, avgSeconds: 101)), "80 % now, 10.1 % average")
    }

    @Test func topCountsSmallAndSystemProcesses() throws {
        // A 30 MB process at 100 % (not an item by size) and CPU nobody readable accounts for.
        var small = RawProcess(pid: 400); small.ppid = 1; small.uid = getuid(); small.footprintBytes = 30_000_000
        small.exePath = "/usr/local/bin/cruncher"; small.cwd = "/"; small.startSec = Int64(Date().timeIntervalSince1970) - 600
        small.cpuTimeNs = 300_000_000_000
        var twin = small; twin.pid = 401
        let scan = Scan(system: RawSystem(memTotalBytes: 16 << 30, ncpu: 8, pageSize: 16384), cpu: CPUSplit(user: 40, sys: 10, idle: 50),
                        processes: [400: small, 401: twin], cpuNowPct: [400: 100, 401: 100], launchd: [:])
        let s = analyzer.analyze(scan)
        let top = try #require(s.cpu.top.value)
        #expect(top.first?.label == "macOS and system services" && top.first.map { abs($0.pct - 200) < 0.01 } == true, "8 cores × 50 % − 200 %")
        #expect(top.contains { $0.label == "cruncher (×2)" && $0.pct == 200 && $0.count == 2 }, "same program grouped")
        #expect(s.items.contains { $0.pids == [400] }, "100 % makes it an item whatever its size")
        #expect(s.findings.contains { $0.rules.contains("cpu-heavy") })
    }

    // Reviewer 2: the branch the name says — CPU measured, nothing of the user's at 1 % or more.
    @Test func noReadableCPUIsNotFastMode() {
        var system = RawSystem(memTotalBytes: 16 << 30, ncpu: 8, pageSize: 16384)
        system.pressureLevel = 1; system.thermal = .serious
        let s = analyzer.analyze(Scan(system: system, cpu: CPUSplit(user: 0.1, sys: 0, idle: 99.9), processes: [:], cpuNowPct: [:], launchd: [:]))
        #expect(s.cpu.top.value == [])
        #expect(s.headline.text.contains("nothing at 1 % of a core or more") && !s.headline.text.contains("--fast"))
    }

    @Test func hogsOwnScanIsNotSystem() throws {
        // 8 cores × 50 % = 400 core-%; the user's process 100; hog and its commands 80 (its own sample shows only 10).
        var p = RawProcess(pid: 600); p.ppid = 1; p.uid = getuid(); p.footprintBytes = 200_000_000
        p.exePath = "/usr/local/bin/work"; p.cwd = "/"
        var scan = Scan(selfPid: 999, system: RawSystem(memTotalBytes: 16 << 30, ncpu: 8, pageSize: 16384),
                        cpu: CPUSplit(user: 40, sys: 10, idle: 50), processes: [600: p], cpuNowPct: [600: 100, 999: 10], launchd: [:])
        scan.hogCpuPct = 80
        let top = try #require(analyzer.analyze(scan).cpu.top.value)
        #expect(top.first { $0.id == "system" }.map { abs($0.pct - 220) < 0.01 } == true, "400 − 100 − 80")
        #expect(!top.contains { $0.label.contains("pid 999") }, "hog itself is not listed")
        scan.hogCpuPct = nil
        let fallback = try #require(analyzer.analyze(scan).cpu.top.value)
        #expect(fallback.first { $0.id == "system" }.map { abs($0.pct - 290) < 0.01 } == true, "without rusage: hog's own sample")
    }

    @Test func fairIsNotHot() {
        let warm = analyzer.analyze(scan(thermal: .fair, idle: 70))
        #expect(!warm.headline.text.contains("hot") && warm.headline.level == .ok, "warm is usual under load")
    }

    @Test func averageUsesTheSampleTime() {
        // 1.9 s of CPU, started 1 s before the scan, second sample 1 s later: 95 %, not 190 %.
        var p = RawProcess(pid: 500); p.ppid = 1; p.uid = getuid(); p.footprintBytes = 200_000_000
        p.exePath = "/usr/local/bin/young"; p.cwd = "/"; p.startSec = Int64(Date().timeIntervalSince1970) - 1; p.startUsec = 0
        p.cpuTimeNs = 1_900_000_000
        var scan = Scan(system: RawSystem(memTotalBytes: 16 << 30, ncpu: 8, pageSize: 16384), processes: [500: p], cpuNowPct: [500: 95], launchd: [:])
        scan.cpuSampledAt = scan.takenAt.addingTimeInterval(1)
        let item = analyzer.analyze(scan).items.first { $0.pids == [500] }
        if case .double(let avg)? = item?.facts["cpu.avg_pct"] { #expect(avg <= 100) } else { Issue.record("no average") }
        let record = analyzer.analyze(scan).processes.first { $0.pid == 500 }
        #expect(record?.cpu.avgPct.value.map { $0 <= 100 } == true, "processes[] uses the same average (reviewer 2)")
    }

    // Reviewer 3 + QA 3 (2026-10-27): the measurement itself, and boundaries mutations survived.
    @Test func hogCPUPercentFromRusage() {
        let t = Date()
        #expect(Scanner.cpuPercent(from: (t, 1.0), to: (t.addingTimeInterval(2), 1.5)) == 25, "0.5 s of CPU in 2 s")
        #expect(Scanner.cpuPercent(from: (t, 1.0), to: (t, 2.0)) == nil, "empty window")
        #expect(Scanner.cpuPercent(from: (t, 2.0), to: (t.addingTimeInterval(1), 1.0)) == 0, "never negative")
    }

    @Test func ownCPUCountsFinishedChildren() throws {
        // RUSAGE_CHILDREN alone: other tests run in parallel in this process and move RUSAGE_SELF (reviewer 4).
        let before = Scanner.cpuSeconds(RUSAGE_CHILDREN)
        _ = try #require(Command.run("/bin/sh", ["-c", "i=0; while [ $i -lt 40000 ]; do i=$((i+1)); done"], timeout: 20))
        #expect(Scanner.cpuSeconds(RUSAGE_CHILDREN) - before > 0.05)
        #expect(Scanner.ownCPUSeconds() >= Scanner.cpuSeconds(RUSAGE_CHILDREN), "own = self + children")
    }

    /// Fake commands only (never the machine's `code`): a `launchctl` that takes 0.6 s, a `code` and `watchman` that print nothing.
    @Test func sensorsFinishBeforeTheCPUWindow() throws {
        let home = NSTemporaryDirectory() + "hog-scan-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        func fake(_ name: String, _ body: String) throws -> String {
            let path = home + "/" + name
            try ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            chmod(path, 0o755)
            return path
        }
        let locator = CommandLocator(home: home, overrides: ["launchctl": [try fake("launchctl", "sleep 0.6; echo 'PID\tStatus\tLabel'")],
                                                            "code": [try fake("code", "exit 0")], "watchman": [try fake("watchman", "exit 1")]])
        var ext = ExternalSensors(locator: locator, home: home)
        ext.cleanUpCodeStatus = { _ in }
        let scan = Scanner(external: ext, cpuInterval: 0.2).scan()
        let window = try #require(scan.cpuSampledAt).timeIntervalSince(scan.takenAt)
        #expect(window >= 0.75, "the 0.6 s sensor ran before the 0.2 s CPU window, not alongside it (\(window) s)")
        #expect(scan.hogCpuPct != nil && scan.cpu != nil && !scan.cpuNowPct.isEmpty)
        let fast = Scanner(external: ext, fast: true).scan()
        #expect(fast.hogCpuPct == nil && fast.cpu == nil && fast.cpuSampledAt == nil && fast.cpuNowPct.isEmpty)
    }

    @Test func busyBoundaryAndNotMeasured() {
        #expect(!analyzer.analyze(scan(thermal: .nominal, idle: 20.5)).headline.text.contains("busy"), "79.5 %")
        #expect(analyzer.analyze(scan(thermal: .nominal, idle: 20)).headline.text.contains("The CPU is busy"), "80 %")
        #expect(!analyzer.analyze(scan(thermal: .nominal, idle: nil)).headline.text.contains("busy"), "not measured: not busy")
    }

    @Test func atMostThreeLinesAndGroupedByProject() throws {
        func proc(_ pid: Int32, _ exe: String, cwd: String) -> RawProcess {
            var p = RawProcess(pid: pid); p.ppid = 1; p.uid = getuid(); p.footprintBytes = 10_000_000
            p.exePath = exe; p.cwd = cwd; p.startSec = Int64(Date().timeIntervalSince1970) - 100
            return p
        }
        let home = NSTemporaryDirectory() + "hog-cpu-\(UUID().uuidString)"
        for proj in ["alpha", "beta"] {
            try FileManager.default.createDirectory(atPath: home + "/w/\(proj)/.git", withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(atPath: home) }
        let procs = [proc(1, "/usr/local/bin/node", cwd: home + "/w/alpha"), proc(2, "/usr/local/bin/node", cwd: home + "/w/alpha"),
                     proc(3, "/usr/local/bin/node", cwd: home + "/w/beta"), proc(4, "/usr/bin/a", cwd: "/"), proc(5, "/usr/bin/b", cwd: "/")]
        let scan = Scan(home: home, system: RawSystem(memTotalBytes: 16 << 30, ncpu: 8, pageSize: 16384), cpu: CPUSplit(user: 10, sys: 0, idle: 90),
                        processes: Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0) }),
                        cpuNowPct: [1: 10, 2: 10, 3: 15, 4: 5, 5: 4], launchd: [:])
        let s = analyzer.analyze(scan)
        let top = try #require(s.cpu.top.value)
        #expect(top.contains { $0.label == "node — alpha (×2)" && $0.pct == 20 })
        #expect(top.contains { $0.label == "node — beta" && $0.pct == 15 }, "another project is another line")
        #expect(Presentation.cpuRows(s, max: Presentation.maxCPURows).count == 3)
    }
}
