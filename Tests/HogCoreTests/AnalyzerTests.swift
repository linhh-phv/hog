import Foundation
import Testing
@testable import HogCore

@Suite final class AnalyzerTests {
    let home: String
    let now = Date(timeIntervalSince1970: 1_792_990_000)
    let analyzer: Analyzer

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("hog-an-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home + "/work/web-app", withIntermediateDirectories: true)
        try Data(#"{"name":"web-app"}"#.utf8).write(to: URL(fileURLWithPath: home + "/work/web-app/package.json"))
        let bundled = { (k: String) in DataSource(bundledDirectory: DataSource.standard(k).bundledDirectory, localDirectory: nil) }
        let watchmanPrint = try Fixtures.text("launchctl/print-crashed-true.txt")
        analyzer = Analyzer(catalog: .load(bundled("catalog")), rules: .load(bundled("rules")), explain: .load(bundled("explain")),
                            lang: .vi, launchdPrint: { $0 == "com.github.facebook.watchman" ? watchmanPrint : nil })
    }

    deinit { try? FileManager.default.removeItem(atPath: home) }

    func p(_ pid: Int32, _ ppid: Int32, _ exe: String, args: [String]? = nil, cwd: String? = "/", fp: Int64 = 10_000_000,
           rs: Int64? = nil, ageH: Double = 30, cpuSec: Double = 1, uid: UInt32 = 501) -> RawProcess {
        var r = RawProcess(pid: pid)
        r.ppid = ppid; r.uid = uid; r.exePath = exe; r.args = args ?? [exe]; r.cwd = cwd
        r.startSec = Int64(now.timeIntervalSince1970 - ageH * 3600); r.startUsec = 0
        r.footprintBytes = fp; r.residentBytes = rs ?? fp; r.cpuTimeNs = UInt64(cpuSec * 1e9)
        return r
    }

    func scan() -> Scan {
        let vs = "/Applications/Visual Studio Code.app/Contents"
        let plugin = vs + "/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        let claude = home + "/.vscode/extensions/anthropic.claude-code/resources/native-binary/claude"
        let procs: [RawProcess] = [
            p(1, 0, "/sbin/launchd", uid: 0),
            p(100, 1, vs + "/MacOS/Code", fp: 300_000_000),
            p(200, 100, plugin, args: [plugin, "--inspect-port=0"], fp: 400_000_000),
            p(210, 100, plugin, args: [plugin, "--inspect-port=0"], fp: 350_000_000),
            p(201, 200, plugin, args: [plugin, "/x/tsserver.js", "--useNodeIpc"], fp: 568_000_000, rs: 65_000_000),
            p(211, 210, plugin, args: [plugin, "/x/tsserver.js", "--useNodeIpc"], fp: 500_000_000),
            // An idle Claude session (3 h) and a busy one; the busy one is running hog.
            p(300, 200, claude, cwd: home + "/work/web-app", fp: 200_000_000),
            p(310, 210, claude, cwd: home + "/work/web-app", fp: 300_000_000),
            p(311, 310, "/bin/zsh", cwd: home + "/work/web-app"),
            p(312, 311, "/usr/local/bin/hog", cwd: home + "/work/web-app"),
            // watchman: launchd job, cwd /, 1.3 GB with almost nothing resident
            p(400, 1, "/opt/homebrew/bin/watchman", fp: 1_380_000_000, rs: 6_300_000, ageH: 260, cpuSec: 30),
            // a forgotten dev server, orphaned in the project
            p(500, 1, "/opt/homebrew/bin/node", args: ["node", "server.js"], cwd: home + "/work/web-app", fp: 150_000_000, ageH: 5, cpuSec: 2),
            // tmux on purpose
            p(600, 1, "/opt/homebrew/bin/tmux", cwd: home, fp: 60_000_000, ageH: 50),
            // a root process we cannot read
            { var r = p(700, 1, "/usr/sbin/somed", uid: 0); r.footprintBytes = nil; r.residentBytes = nil; return r }(),
        ]
        var sessions: [Int32: ClaudeSession] = [:]
        for (pid, busy, idleMin) in [(Int32(300), false, 180.0), (Int32(310), true, 0.0)] {
            let start = Date(timeIntervalSince1970: Double(procs.first { $0.pid == pid }!.startSec!))
            sessions[pid] = ClaudeSession(pid: pid, sessionId: "s\(pid)", cwd: home + "/work/web-app", busy: busy,
                                          statusUpdatedAt: now.addingTimeInterval(-idleMin * 60), startedAt: nil, procStart: start)
        }
        let windows: [Int: CodeStatusParser.Window] = [
            1: .init(index: 1, title: "server.ts — web-app (Workspace)", extensionHostPid: 200),
            2: .init(index: 2, title: "notes — api (Workspace)", extensionHostPid: 210),
        ]
        var system = RawSystem(memTotalBytes: 17_179_869_184, ncpu: 8, pageSize: 16384)
        system.compressorBytes = 5_720_000_000; system.compressedStoredBytes = 11_130_000_000
        system.swapUsedBytes = 3_292_000_000; system.swapTotalBytes = 4_294_967_296; system.pressureLevel = 1
        system.wiredBytes = 2_731_000_000; system.freeBytes = 65_000_000
        let containers = [DockerClient.Container(id: "abc123def4567890", name: "db", image: "mongo:7", state: "restarting",
                                                 publishedPorts: [27017], restartCount: 4057, restartPolicy: "always", startedAt: now)]
        return Scan(takenAt: now, home: home, selfPid: 312, selfUid: 501, system: system,
                    processes: Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0) }),
                    launchd: [400: "com.github.facebook.watchman"],
                    network: .init(listening: [500: [ListenSocket(addr: "*", port: 3000)]], connections: []),
                    vscode: .init(windows: windows, roles: [200: "extension-host", 210: "extension-host"]),
                    sessions: sessions, watchman: .init(roots: ["/a"], subscriptions: 0), containers: containers)
    }

    func finding(_ s: Snapshot, _ itemPrefix: String) -> Finding? { s.findings.first { $0.itemId.hasPrefix(itemPrefix) } }

    @Test func watchmanIsSuggestedWithMeasuredEvidence() throws {
        let s = analyzer.analyze(scan())
        let f = try #require(finding(s, "proc:400:"))
        #expect(f.verdict == .mayStop)
        #expect(f.rules.contains("watchman-no-subscribers") && f.rules.contains("dormant-large"))
        #expect(f.confidence == .high)
        #expect(f.stop.strategy == .watchmanShutdown, "KeepAlive {Crashed=true}: a normal stop is not restarted")
        #expect(f.reason.contains("11 ngày") && f.reason.contains("1,3 GB"))
        let item = try #require(s.items.first { $0.id.hasPrefix("proc:400:") })
        #expect(item.facts["orphan"] == .bool(false), "a launchd job is not an orphan")
    }

    @Test func orphanDevServerButNotTmux() throws {
        let s = analyzer.analyze(scan())
        let f = try #require(finding(s, "proc:500:"))
        #expect(f.verdict == .mayStop && f.rules == ["orphan-quiet"])
        #expect(finding(s, "proc:600:")?.verdict != .mayStop, "tmux is detached by design")
    }

    @Test func idleSessionSuggestedBusySessionProtected() throws {
        let s = analyzer.analyze(scan())
        let idle = try #require(finding(s, "claude:300"))
        #expect(idle.verdict == .mayStop && idle.stop.strategy == .manual)
        let busyItem = try #require(s.items.first { $0.id == "claude:310" })
        #expect(busyItem.protection.value?.level == .hard, "the busy session runs hog: protect-self")
    }

    @Test func languageServerDuplicatesAreInfoAndProtected() throws {
        let s = analyzer.analyze(scan())
        let f = try #require(finding(s, "proc:201:"))
        #expect(f.rules.contains("duplicate-language-server"))
        #expect(f.verdict == .info)
        #expect(s.items.first { $0.id.hasPrefix("proc:201:") }?.protection.value?.level == .soft)
    }

    @Test func crashLoopingContainer() throws {
        let s = analyzer.analyze(scan())
        let f = try #require(finding(s, "ctr:abc123def456"))
        #expect(f.verdict == .mayStop)
        #expect(f.rules.contains("container-crash-loop") && f.rules.contains("container-restart-high"))
        #expect(f.stop.strategy == .dockerContainer)
    }

    @Test func ownersRollUp() throws {
        let s = analyzer.analyze(scan())
        let app = try #require(s.owners.first { $0.id == "app:visual-studio-code" })
        #expect(app.totalFootprintBytes >= 300_000_000 + 400_000_000 + 350_000_000 + 568_000_000 + 500_000_000)
        let w1 = try #require(s.owners.first { $0.id == "vscode:1" })
        #expect(w1.parent.value == "app:visual-studio-code")
        #expect(w1.label == "server.ts — web-app (Workspace)")
        #expect(s.memory.unreadableProcessCount == 1)
    }

    @Test func headlineAndPrivacy() throws {
        let s = analyzer.analyze(scan())
        #expect(s.headline.level == .ok)
        #expect(s.headline.text.contains("thứ có thể tắt."), "the menu lists them as cards, so the headline only counts them")
        #expect(!s.headline.text.contains("Watchman ("))
        #expect(s.headline.text.contains("10,4 GB"))
        let json = String(decoding: try SnapshotJSON.encode(s), as: UTF8.self)
        #expect(!json.contains(home), "home must be scrubbed to ~")
        #expect(json.contains("~/work/web-app"))
        #expect(s.warnings.isEmpty, "\(s.warnings)")
    }

    @Test func englishSnapshot() throws {
        var a = analyzer
        a.lang = .en
        let s = a.analyze(scan())
        #expect(s.lang == .en)
        #expect(finding(s, "proc:400:")?.reason.contains("11 days") == true)
        #expect(s.headline.text.contains("10.4 GB"))
    }
}
