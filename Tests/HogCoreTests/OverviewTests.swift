import Foundation
import Testing
@testable import HogCore

/// What the compact menu and `hog` show.
@Suite struct OverviewTests {
    let catalog: Catalog = .load(DataSource(bundledDirectory: DataSource.standard("catalog").bundledDirectory, localDirectory: nil))

    func proc(_ pid: Int32, _ exe: String, mb: Int64, cpu: Double? = nil, project: String? = nil, owner: String? = nil,
              item: String? = nil, catalogId: String? = nil, port: Int? = nil, path: String? = nil) -> ProcessRecord {
        ProcessRecord(pid: pid, exe: Measured(exe), exePath: Measured(path), footprintBytes: Measured(mb * 1_000_000), cpu: ProcessCPU(nowPct: Measured(cpu)),
                      project: Measured(project), net: ProcessNet(listen: port.map { [ListenSocket(addr: "*", port: $0)] } ?? []),
                      catalogId: Measured(catalogId), ownerId: Measured(owner), itemId: Measured(item))
    }

    func snapshot(_ processes: [ProcessRecord], owners: [Owner] = [], items: [Item] = [], findings: [Finding] = [],
                  pressure: Pressure = .normal, thermal: ThermalState = .nominal, idle: Double = 90) -> Snapshot {
        var s = SampleSnapshot.make()
        s.lang = .en
        s.host.ncpu = 4
        s.processes = processes; s.owners = owners; s.items = items; s.findings = findings
        s.memory.pressure = Measured(pressure)
        s.memory.usedBytes = Measured(12_000_000_000)
        s.cpu = CPUInfo(idlePct: Measured(idle), thermal: Measured(thermal), top: Measured([CPUUser(id: "system", label: "macOS", pct: 30, count: 0)]))
        return s
    }

    @Test func groupsByProjectIncludingWindowVotes() throws {
        // A VS Code window with no title-derived project: most of its processes work in web-app, so the window does too.
        let owners = [Owner(id: "app:code", kind: .app, label: "Visual Studio Code"),
                      Owner(id: "vscode:1", kind: .vscodeWindow, label: "window 1", parent: "app:code")]
        let o = Overview.make(snapshot([
            proc(1, "Code Helper (Renderer)", mb: 800, cpu: 2, owner: "vscode:1", catalogId: "vscode-renderer"),
            proc(2, "node", mb: 300, cpu: 1, project: "web-app", owner: "vscode:1", port: 3000),
            proc(3, "zsh", mb: 5, project: "web-app", owner: "vscode:1"),
            proc(4, "Code", mb: 150, owner: "app:code"),
        ], owners: owners), catalog: catalog)
        let web = try #require(o.groups.first { $0.id == "project:web-app" })
        #expect(web.kind == .project && web.processCount == 3 && web.bytes == 1_105_000_000)
        #expect(web.entries.first?.name == "VS Code window", "catalog name without the part in brackets")
        #expect(web.entries.contains { $0.name == "node" && $0.detail == "port 3000" && $0.unknown })
        #expect(o.groups.contains { $0.id == "app:code" && $0.processCount == 1 }, "the app's own process stays with the app")
        #expect(o.groups.last?.kind == .system && o.groups.last?.cpu == 7.5, "CPU as a share of the whole machine: 30 % of a core / 4")
        #expect(web.cpu == 0.75)
    }

    @Test func smallAppsGoToOtherAndSameNamesMerge() throws {
        let owners = [Owner(id: "app:chrome", kind: .app, label: "Google Chrome"), Owner(id: "app:dock", kind: .app, label: "Dock")]
        let o = Overview.make(snapshot([
            proc(1, "Google Chrome Helper", mb: 300, owner: "app:chrome"), proc(2, "Google Chrome Helper", mb: 200, owner: "app:chrome"),
            proc(3, "Dock", mb: 40, cpu: 0.5, owner: "app:dock"), proc(4, "cron", mb: 2),
        ], owners: owners), catalog: catalog)
        let chrome = try #require(o.groups.first { $0.id == "app:chrome" })
        #expect(chrome.entries.count == 1 && chrome.entries[0].pids.count == 2 && chrome.entries[0].bytes == 500_000_000)
        #expect(chrome.summary == "2 processes")
        #expect(chrome.entries[0].name == "Helper", "the app's name is not repeated on its own lines")
        #expect(!o.groups.contains { $0.id == "app:dock" }, "a small app goes to Other")
        let other = try #require(o.groups.first { $0.kind == .other })
        #expect(other.processCount == 2 && other.entries.contains { $0.name == "Dock" && !$0.unknown })
        #expect(other.summary == "2 processes" && Overview.make(snapshot([proc(1, "Finder", mb: 900, owner: "app:dock")], owners: owners),
                                                                 catalog: catalog).groups[0].summary == "1 process")
        #expect(o.groups.firstIndex { $0.kind == .other }! > o.groups.firstIndex { $0.id == "app:chrome" }!, "Other after the named groups")
    }

    @Test func cleanupsWithShortReasons() throws {
        func finding(_ id: String, _ verdict: Verdict, _ rules: [String], _ strategy: StopStrategy = .signal) -> Finding {
            Finding(itemId: id, verdict: verdict, confidence: .high, rules: rules, reason: "r", evidence: [:], unmeasured: [],
                    stop: StopAdvice(strategy: strategy, respawns: nil, effect: "e"))
        }
        let items = [
            Item(id: "a", kind: .process, label: "node", pids: [1], footprintBytes: Measured(400_000_000), facts: ["cpu.now_pct": .double(88)]),
            Item(id: "b", kind: .process, label: "watchman", catalogId: "watchman", pids: [2], footprintBytes: Measured(300_000_000),
                 facts: ["age_s": .int(10_800)]),
            Item(id: "c", kind: .claudeSession, label: "Claude", pids: [3], footprintBytes: Measured(200_000_000), facts: ["session.idle_s": .int(7_200)]),
        ]
        let o = Overview.make(snapshot([proc(1, "node", mb: 400, project: "api", item: "a"), proc(2, "watchman", mb: 300, item: "b"),
                                        proc(3, "claude", mb: 200, project: "hub", item: "c")],
                                       items: items,
                                       findings: [finding("a", .watch, ["cpu-heavy"]), finding("b", .mayStop, ["watchman-no-subscribers"], .watchmanShutdown),
                                                  finding("c", .mayStop, ["claude-session-abandoned"], .manual)]), catalog: catalog)
        #expect(o.cleanups.map(\.itemId) == ["b", "c", "a"], "may-stop first, biggest first")
        #expect(o.cleanups[0].why == "idle 3 hours" && o.cleanups[0].whyKind == .idle && o.cleanups[0].name == "Watchman" && o.cleanups[0].preselected)
        #expect(o.cleanups[1].why == "idle 2 hours" && o.cleanups[1].manual && !o.cleanups[1].preselected && o.cleanups[1].project == "hub")
        #expect(o.cleanups[2].why == "22 % CPU" && o.cleanups[2].whyKind == .heavy && !o.cleanups[2].preselected)
        #expect(o.reclaimable == 900_000_000)
        #expect(o.status.title == "Machine fine" && o.status.detail.contains("3 to clean up"))
        let group = try #require(o.groups.first { $0.id == "project:api" })
        #expect(group.entries.first?.cleanup?.itemId == "a", "a suggested item keeps its own line")
    }

    @Test func statusWords() {
        func status(_ p: Pressure, _ t: ThermalState, idle: Double = 90) -> Overview.Status {
            Overview.make(snapshot([proc(1, "x", mb: 10)], pressure: p, thermal: t, idle: idle), catalog: catalog).status
        }
        #expect(status(.critical, .nominal).tone == .critical && status(.critical, .nominal).title == "Machine struggling")
        #expect(status(.normal, .critical).tone == .critical)
        #expect(status(.warn, .nominal).title == "Machine under strain" && status(.warn, .nominal).detail.contains("Short of memory"))
        #expect(status(.normal, .serious).title == "Machine hot" && status(.normal, .serious).detail.contains("Running hot"))
        #expect(status(.normal, .nominal, idle: 10).title == "Fine, CPU busy")
        #expect(status(.normal, .nominal).title == "Machine fine" && status(.normal, .nominal).detail == "Nothing to clean up")
    }

    @Test func memoryUsedLikeActivityMonitor() {
        var s = RawSystem(memTotalBytes: 16 << 30, ncpu: 8, pageSize: 16384)
        #expect(s.usedBytes == nil, "not measured: no number")
        s.appMemoryBytes = 6_000; s.wiredBytes = 2_000; s.compressorBytes = 1_000
        #expect(s.usedBytes == 9_000)
        #expect(SystemReader.read().usedBytes.map { $0 > 0 && $0 <= SystemReader.read().memTotalBytes } == true)
    }

    @Test func unknownOnlyForBigProgramsNothingExplains() {
        let o = Overview.make(snapshot([
            proc(1, "mystery", mb: 300, path: "/opt/tools/mystery"),
            proc(2, "tiny", mb: 5, path: "/opt/tools/tiny"),
            proc(3, "cfprefsd", mb: 40, path: "/usr/sbin/cfprefsd"),
            proc(4, "Helper", mb: 90, path: "/Applications/Some.app/Contents/MacOS/Helper"),
            proc(5, "Google Chrome", mb: 90, path: "/private/var/folders/x/Google Chrome.app.bundle/Contents/MacOS/Google Chrome"),
        ]), catalog: catalog)
        let unknown = o.groups.flatMap(\.entries).filter(\.unknown).map(\.name)
        #expect(unknown == ["mystery"], "not small, not macOS, not inside an app bundle")
    }

    @Test func otherAddsUpSameNamesFromSmallApps() throws {
        let owners = [Owner(id: "app:a", kind: .app, label: "A"), Owner(id: "app:b", kind: .app, label: "B")]
        let o = Overview.make(snapshot([proc(1, "helper", mb: 10, owner: "app:a"), proc(2, "helper", mb: 20, owner: "app:b")], owners: owners),
                              catalog: catalog)
        let other = try #require(o.groups.first { $0.kind == .other })
        let helper = try #require(other.entries.first { $0.name == "helper" })
        #expect(helper.pids.sorted() == [1, 2] && helper.bytes == 30_000_000, "two small apps' same-named helpers: none dropped")
    }

    @Test func shortReasonsStayShort() {
        let rules = ["watchman-no-subscribers", "claude-session-abandoned", "cpu-heavy", "container-restart-high", "duplicate-language-server"]
        let item = Item(id: "x", kind: .process, label: "x", pids: [1], facts: ["age_s": .int(36_000), "session.idle_s": .int(36_000), "cpu.now_pct": .double(400)])
        for lang in [Lang.vi, .en] {
            for r in rules {
                let f = Finding(itemId: "x", verdict: .mayStop, confidence: .high, rules: [r], reason: "", evidence: [:], unmeasured: [],
                                stop: StopAdvice(strategy: .signal, respawns: nil, effect: ""))
                let (why, _) = Overview.shortReason(f, item, lang, cores: 8)
                #expect(why.split(separator: " ").count <= 3, "\(lang) \(r): \(why)")
            }
        }
    }

    @Test func notesSayWhatWasNotMeasured() {
        var s = snapshot([])
        s.sensors = [SensorStatus(name: "docker", status: .unavailable, tookMs: 1, note: "socket missing"),
                     SensorStatus(name: "watchman", status: .ok, tookMs: 1)]
        s.warnings = ["catalog/x.json: bad JSON"]
        let notes = Overview.make(s, catalog: catalog).notes
        #expect(notes == ["Docker — the engine is stopped (not an error).", "Data: catalog/x.json: bad JSON"])
    }

    @Test func infoFindingsAreNotCleanups() {
        let item = Item(id: "a", kind: .process, label: "node", pids: [1], footprintBytes: Measured(400_000_000))
        let f = Finding(itemId: "a", verdict: .info, confidence: .high, rules: ["x"], reason: "r", evidence: [:], unmeasured: [],
                        stop: StopAdvice(strategy: .signal, respawns: nil, effect: "e"))
        #expect(Overview.make(snapshot([proc(1, "node", mb: 400, item: "a")], items: [item], findings: [f]), catalog: catalog).cleanups.isEmpty)
    }

    @Test func chromeCloneIsChrome() {
        #expect(Ownership.appName("/private/var/folders/x/Google Chrome.app.bundle/Contents/MacOS/Google Chrome") == "Google Chrome")
        #expect(Ownership.appName("/Applications/A.app/Contents/Frameworks/B.app/Contents/MacOS/B") == "A", "outermost")
        #expect(Ownership.appBundle("/Applications/A.app/Contents/MacOS/A") == "/Applications/A.app")
        #expect(Ownership.appName("/usr/bin/zsh") == nil)
    }
}
