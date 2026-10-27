import Darwin
import Foundation
import Testing
@testable import HogCore

/// Regression tests for the phase-1 review (2026-10-26). Each test names the finding it pins.
@Suite(.serialized) final class ReviewFixTests {
    let state = FileManager.default.temporaryDirectory.appendingPathComponent("hog-rev-\(UUID().uuidString)")
    lazy var stopper: Stopper = {
        var s = Stopper(plans: PlanStore(directory: state.appendingPathComponent("plans")),
                        log: ActionLog(file: state.appendingPathComponent("a.jsonl")), lang: .en, dockerSocket: { nil })
        s.sigtermWait = 1
        return s
    }()
    let analyzer: Analyzer = {
        let b = { (k: String) in DataSource(bundledDirectory: DataSource.standard(k).bundledDirectory, localDirectory: nil) }
        return Analyzer(catalog: .load(b("catalog")), rules: .load(b("rules")), explain: .load(b("explain")), lang: .en)
    }()

    deinit { try? FileManager.default.removeItem(at: state) }

    func emptySnapshot(pid: Int32 = getpid(), ancestors: [Int32] = []) -> Snapshot {
        Snapshot(lang: .en, takenAt: Date(), hog: HogInfo(pid: pid, ancestors: ancestors, ancestorsComplete: true, selfFootprintBytes: nil),
                 host: HostInfo(arch: "arm64", ncpu: 1, memTotalBytes: 0, uptimeS: nil), memory: MemoryInfo(), cpu: CPUInfo(),
                 headline: Headline(level: .ok, text: "", glossaryIds: []))
    }

    // Finding 1: a PID that is not a snapshot item still gets facts + protections, or is blocked.
    @Test func nonItemTargetWithoutFactsIsBlocked() throws {
        let child = try Child("/bin/sleep", ["30"])
        let scan = Scan(system: RawSystem(memTotalBytes: 0, ncpu: 1, pageSize: 16384), processes: [child.pid: ProcessReader.read(child.pid)], launchd: [:])
        let (identity, item) = try stopper.resolve(String(child.pid), in: emptySnapshot(), scan: scan)
        #expect(item == nil)
        #expect(stopper.plan(identity, item: item, snapshot: emptySnapshot(), scan: scan).blocked?.gate == "G6")
        #expect(kill(child.pid, 0) == 0)
    }

    @Test func smallMacOSProcessIsHardProtected() throws {
        let child = try Child("/bin/sleep", ["30"])
        var raw = ProcessReader.read(child.pid)
        raw.exePath = "/System/Library/CoreServices/lockoutagent"  // pretend: a small macOS process of the user
        let scan = Scan(system: RawSystem(memTotalBytes: 0, ncpu: 1, pageSize: 16384), processes: [child.pid: raw], launchd: [:])
        let (identity, item) = try stopper.resolve(String(child.pid), in: emptySnapshot(), scan: scan,
                                                   itemFor: { self.analyzer.item(forPid: $0, in: scan) })
        #expect(item?.protection.value?.level == .hard)
        #expect(stopper.plan(identity, item: item, snapshot: emptySnapshot(), scan: scan).blocked?.gate == "G6")
    }

    @Test func smallUserCommandIsNotBlocked() throws {
        let child = try Child("/bin/sleep", ["30"])
        let scan = Scan(system: RawSystem(memTotalBytes: 0, ncpu: 1, pageSize: 16384), processes: [child.pid: ProcessReader.read(child.pid)], launchd: [:])
        let (identity, item) = try stopper.resolve(String(child.pid), in: emptySnapshot(), scan: scan,
                                                   itemFor: { self.analyzer.item(forPid: $0, in: scan) })
        let plan = stopper.plan(identity, item: item, snapshot: emptySnapshot(), scan: scan)
        #expect(item != nil && plan.blocked == nil)
    }

    // Finding 2: a failed launchd sensor never lifts a protection.
    @Test func failedLaunchdSensorKeepsProtection() throws {
        let child = try Child("/bin/sleep", ["30"])
        var raw = ProcessReader.read(child.pid)
        raw.exePath = "/usr/libexec/somed"
        let scan = Scan(system: RawSystem(memTotalBytes: 0, ncpu: 1, pageSize: 16384), processes: [child.pid: raw], launchd: nil)
        #expect(analyzer.item(forPid: child.pid, in: scan)?.protection.value?.level == .hard)
    }

    // Finding 3: the VS Code window running hog is protected too.
    @Test func windowRunningHogIsProtected() throws {
        let child = try Child("/bin/sleep", ["30"])
        var me = RawProcess(pid: 900); me.ppid = 800; me.uid = getuid(); me.exePath = "/usr/local/bin/hog"
        var host = RawProcess(pid: 800); host.ppid = 700; host.uid = getuid(); host.exePath = "/x/Code Helper (Plugin)"
        var other = ProcessReader.read(child.pid); other.ppid = 800  // e.g. a renderer of the same window
        let scan = Scan(selfPid: 900, system: RawSystem(memTotalBytes: 0, ncpu: 1, pageSize: 16384),
                        processes: [900: me, 800: host, child.pid: other], launchd: [:],
                        vscode: .init(windows: [2: .init(index: 2, extensionHostPid: 800)], roles: [800: "extension-host"]))
        let item = try #require(analyzer.item(forPid: child.pid, in: scan))
        #expect(item.facts["self.window"] == .bool(true))
        #expect(item.protection.value?.level == .hard)
        let snap = emptySnapshot(pid: 900, ancestors: [800, 700])
        #expect(stopper.plan(.process(child.pid, startSec: other.startSec, startUsec: other.startUsec), item: item, snapshot: snap, scan: scan).blocked?.gate == "G1")
    }

    // Finding 4: unknown restart policy → no stop.
    @Test func unknownRestartPolicyBlocks() {
        let c = DockerClient.Container(id: "abc123def4567890", name: "db", image: "x", state: "running", publishedPorts: [],
                                       restartCount: nil, restartPolicy: nil, startedAt: nil)
        let scan = Scan(system: RawSystem(memTotalBytes: 0, ncpu: 1, pageSize: 16384), processes: [:], containers: [c])
        let plan = stopper.plan(.container(c.id), item: nil, snapshot: emptySnapshot(), scan: scan)
        #expect(plan.blocked?.gate == "G5")
    }

    // Finding 5: a headline for every pressure level, never with an empty list.
    @Test(arguments: [(Int32(1), "enough memory"), (Int32(2), "short of memory"), (Int32(4), "found nothing"), (Int32(0), "could not be read")])
    func headlinePerPressure(level: Int32, contains: String) {
        var p = RawProcess(pid: 10); p.ppid = 5; p.uid = getuid(); p.exePath = "/opt/x/foo"; p.footprintBytes = 3_000_000_000
        p.residentBytes = 3_000_000_000; p.startSec = Int64(Date().timeIntervalSince1970) - 60
        var sys = RawSystem(memTotalBytes: 17_179_869_184, ncpu: 8, pageSize: 16384)
        sys.pressureLevel = level; sys.compressedStoredBytes = 1; sys.compressorBytes = 1; sys.swapUsedBytes = 1
        let s = analyzer.analyze(Scan(system: sys, processes: [10: p], launchd: [:]))
        #expect(s.headline.text.contains(contains), "\(s.headline.text)")
        #expect(!s.headline.text.contains(": ."), "no empty list")
        #expect(!s.headline.text.contains("{"), "no unfilled placeholder")
    }

    // Finding 6: snapshot size cap (design 4, ≤ 100 KB) on a busy machine.
    @Test func snapshotStaysUnder100KB() throws {
        var procs: [Int32: RawProcess] = [:]
        for i in 0..<800 {
            var p = RawProcess(pid: Int32(1000 + i)); p.ppid = 1; p.uid = getuid()
            p.exePath = "/Applications/App\(i % 40).app/Contents/MacOS/Helper \(i)"; p.args = [p.exePath!, "--type=renderer", "--flag-\(i)"]
            p.cwd = "/"; p.footprintBytes = Int64(60_000_000 + i * 1000); p.residentBytes = 50_000_000
            p.startSec = Int64(Date().timeIntervalSince1970) - 3600; p.cpuTimeNs = 1_000_000_000
            procs[p.pid] = p
        }
        let s = analyzer.analyze(Scan(system: RawSystem(memTotalBytes: 17_179_869_184, ncpu: 8, pageSize: 16384), processes: procs, launchd: [:]))
        let bytes = try SnapshotJSON.encode(s, pretty: false).count
        #expect(bytes <= 100_000, "\(bytes) bytes")
    }

    // Finding 7: secrets in arguments.
    @Test func secretsInArgumentsAreMasked() {
        let home = "/Users/me"
        #expect(Privacy.scrubArgs(["curl", "-H", "Authorization: Bearer abc123", "https://x"], home: home) == "curl -H Authorization: Bearer *** https://x")
        #expect(Privacy.scrubArgs(["curl", "-H", "Authorization:", "Bearer", "abc123"], home: home) == "curl -H Authorization: Bearer ***")
        #expect(Privacy.scrubArgs(["node", "server.js", "postgres://app:s3cr3t@host/db"], home: home) == "node server.js postgres://app:***@host/db")
        #expect(Privacy.scrubArgs(["node", "x", "https://h/p?access_token=abc&x=1"], home: home) == "node x https://h/p?access_token=***&x=1")
        #expect(Privacy.scrubArgs(["redis-cli", "-a", "hunter2"], home: home) == "redis-cli -a ***")
        #expect(Privacy.scrubArgs(["mysql", "-psecret", "-u", "root"], home: home) == "mysql -p*** -u root")
        #expect(Privacy.scrubArgs(["vite", "--port", "3000"], home: home) == "vite --port 3000", "ordinary flags untouched")
        #expect(Privacy.scrubArgs(["ls", "/Users/me2/other", "/Users/me/x"], home: home) == "ls /Users/me2/other ~/x", "home only at a path boundary")
    }

    // Finding 8: `--yes --plan` re-planning lives in HogCore and is tested.
    @Test func agreedPlanIsReplannedAndChecked() throws {
        let child = try Child("/bin/sleep", ["30"])
        let scan = Scan(system: RawSystem(memTotalBytes: 0, ncpu: 1, pageSize: 16384), processes: [child.pid: ProcessReader.read(child.pid)], launchd: [:])
        let itemFor: (Int32) -> Item? = { self.analyzer.item(forPid: $0, in: scan) }
        let (identity, item) = try stopper.resolve(String(child.pid), in: emptySnapshot(), scan: scan, itemFor: itemFor)
        let plan = stopper.plan(identity, item: item, snapshot: emptySnapshot(), scan: scan)
        try stopper.plans.save(plan)
        guard case .success(let fresh) = stopper.reconfirm(planId: plan.planId, snapshot: emptySnapshot(), scan: scan, itemFor: itemFor) else {
            Issue.record("expected success"); return
        }
        #expect(fresh.planId == plan.planId)
        #expect(stopper.reconfirm(planId: "deadbeefdeadbeef", snapshot: emptySnapshot(), scan: scan) == .failure(.notFound))
        #expect(stopper.reconfirm(planId: plan.planId, snapshot: emptySnapshot(), scan: scan, itemFor: itemFor,
                                  now: Date().addingTimeInterval(11 * 60)) == .failure(.expired))
        // The process went away (or the PID was reused): the agreed plan no longer applies.
        try stopper.plans.save(plan)
        child.process.terminate(); child.process.waitUntilExit()
        #expect(stopper.reconfirm(planId: plan.planId, snapshot: emptySnapshot(), scan: scan, itemFor: itemFor) == .failure(.changed))
    }

    // Criterion 5: every glossary entry the app and the headlines link to exists, in both languages.
    @Test func glossaryIdsUsedByTheAppExist() throws {
        let ids = Presentation.tileGlossaryIds + Presentation.cliGlossaryIds + Array(Presentation.factGlossary.values) + ["system-processes"]
        let h = try #require(analyzer.explain.headlines)
        for id in ids + [h.okClean, h.okSuggest, h.warn, h.critical, h.criticalNoSuggest, h.unknown, h.hot, h.busy].flatMap(\.glossaryIds) {
            let e = analyzer.explain.glossary[id]
            #expect(e != nil, "missing glossary \(id)")
            #expect(e.map { ($0.name.missingLanguages + $0.plain.missingLanguages).isEmpty } ?? false)
        }
    }
}
