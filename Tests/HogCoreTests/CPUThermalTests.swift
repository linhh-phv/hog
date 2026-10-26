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
        #expect(MenuSummary.cpuRows(s, max: 3).isEmpty)
    }

    @Test func menuShowsCPUOnlyWhenItMatters() {
        let hot = MenuSummary.make(analyzer.analyze(scan(thermal: .fair, idle: 90)))
        #expect(hot.showCPU && hot.cpuRows.map(\.label) == ["Busy", "cruncher"])
        let calm = MenuSummary.make(analyzer.analyze(scan(thermal: .nominal, idle: 90)))
        #expect(!calm.showCPU)
        #expect(MenuSummary.make(analyzer.analyze(scan(thermal: .nominal, idle: 40))).showCPU, "CPU at least half busy")
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
}
