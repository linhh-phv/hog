import Darwin
import Foundation
import Testing
@testable import HogCore

/// Every test only signals processes it spawned itself. Gate G1 is tested with an injected ancestor list, so a
/// bug can never send a signal to the real test runner.
@Suite(.serialized) final class StopperTests {
    let state: URL
    var stopper: Stopper

    init() throws {
        state = FileManager.default.temporaryDirectory.appendingPathComponent("hog-stop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        stopper = Stopper(plans: PlanStore(directory: state.appendingPathComponent("plans")),
                          log: ActionLog(file: state.appendingPathComponent("actions.jsonl")), lang: .en,
                          dockerSocket: { nil })
        stopper.sigtermWait = 1
    }

    deinit { try? FileManager.default.removeItem(at: state) }

    func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// A scan + snapshot containing exactly one item for `pid`, owned by nobody, with a may-stop finding.
    func world(_ pid: Int32, uid: UInt32? = nil, ancestors: [Int32] = [], complete: Bool = true,
               protection: Protection? = nil, strategy: StopStrategy = .signal, facts: [String: FactValue] = [:]) -> (Snapshot, Scan) {
        var raw = ProcessReader.read(pid)
        if let uid { raw.uid = uid }
        let scan = Scan(system: RawSystem(memTotalBytes: 0, ncpu: 1, pageSize: 16384), processes: [pid: raw])
        let itemId = "proc:\(pid):\(raw.startSec ?? 0)"
        var f = facts
        f["owner.kind"] = f["owner.kind"] ?? .string("none")
        let item = Item(id: itemId, kind: .process, label: "test-child", pids: [pid], protection: protection, facts: f)
        let finding = Finding(itemId: itemId, verdict: .mayStop, confidence: .high, rules: ["orphan-quiet"], reason: "test",
                              evidence: ["age_s": .int(4000)], unmeasured: [], stop: StopAdvice(strategy: strategy, respawns: .never, effect: "none"))
        let snap = Snapshot(lang: .en, takenAt: Date(),
                            hog: HogInfo(pid: getpid(), ancestors: ancestors, ancestorsComplete: complete, selfFootprintBytes: nil),
                            host: HostInfo(arch: "arm64", ncpu: 1, memTotalBytes: 0, uptimeS: nil), memory: MemoryInfo(), cpu: CPUInfo(),
                            headline: Headline(level: .ok, text: "", glossaryIds: []), items: [item], findings: [finding])
        return (snap, scan)
    }

    func plan(_ snap: Snapshot, _ scan: Scan) throws -> StopPlan {
        let (identity, item) = try stopper.resolve(snap.items[0].id, in: snap, scan: scan)
        return stopper.plan(identity, item: item, snapshot: snap, scan: scan)
    }

    @Test func sigtermStopsAnOwnIdleProcess() throws {
        let child = try Child("/bin/sleep", ["30"])
        let (snap, scan) = world(child.pid)
        let p = try plan(snap, scan)
        #expect(p.action == .sigterm && p.blocked == nil)
        #expect(stopper.execute(p, scan: scan) == .done("Stopped test-child (SIGTERM)."))
        child.process.waitUntilExit()
        #expect(!child.process.isRunning)
        let log = try String(contentsOf: stopper.log.file, encoding: .utf8)
        #expect(log.split(separator: "\n").count == 2, "start + end entries")
    }

    @Test func g1BlocksHogAndItsAncestors() throws {
        let child = try Child("/bin/sleep", ["30"])
        // Pretend the child is an ancestor of hog.
        let (snap, scan) = world(child.pid, ancestors: [child.pid, 1])
        let p = try plan(snap, scan)
        #expect(p.blocked?.gate == "G1")
        if case .blocked(let g) = stopper.execute(p, scan: scan) { #expect(g.gate == "G1") } else { Issue.record("not blocked") }
        #expect(alive(child.pid), "no signal may be sent")
    }

    @Test func g1BlocksWhenTheAncestorChainIsIncomplete() throws {
        let child = try Child("/bin/sleep", ["30"])
        let (snap, scan) = world(child.pid, complete: false)
        #expect(try plan(snap, scan).blocked?.gate == "G1")
        #expect(alive(child.pid))
    }

    @Test func g6BlocksOtherUsersAndHardProtection() throws {
        let child = try Child("/bin/sleep", ["30"])
        let (snap, scan) = world(child.pid, uid: 0)
        #expect(try plan(snap, scan).blocked?.gate == "G6")
        let (snap2, scan2) = world(child.pid, protection: Protection(level: .hard, rules: ["protect-foreign"]))
        #expect(try plan(snap2, scan2).blocked?.gate == "G6")
        #expect(alive(child.pid))
    }

    @Test func g2AsksForAnotherSessionOrWindow() throws {
        let child = try Child("/bin/sleep", ["30"])
        let (snap, scan) = world(child.pid, protection: Protection(level: .soft, rules: ["protect-busy-owner"]),
                                 facts: ["owner.kind": .string("vscode-window")])
        let p = try plan(snap, scan)
        #expect(p.blocked == nil)
        #expect(p.gates.contains { $0.gate == "G2" && $0.result == .confirm })
        #expect(p.askFirst?.gate == "G2", "the batch sheet says why to ask")
    }

    @Test func measuredSuggestionIsNotAskFirst() throws {
        let child = try Child("/bin/sleep", ["30"])
        let (snap, scan) = world(child.pid)
        var p = try plan(snap, scan)
        #expect(p.needsConfirmation && p.askFirst == nil, "G7 on measured evidence: pressing Clean up is the consent")
        p.unmeasured = ["net.established"]
        #expect(p.askFirst?.gate == "G7")
    }

    @Test func g3CancelsWhenTheProcessChanged() throws {
        let child = try Child("/bin/sleep", ["30"])
        let (snap, scan) = world(child.pid)
        var p = try plan(snap, scan)
        p.identity.startUsec = (p.identity.startUsec ?? 0) + 1  // what was shown is no longer this process
        if case .blocked(let g) = stopper.execute(p, scan: scan) { #expect(g.gate == "G3") } else { Issue.record("not blocked") }
        #expect(alive(child.pid))
    }

    @Test func g4NeverEscalatesOnItsOwn() throws {
        // Ignores SIGTERM.
        let child = try Child("/bin/sh", ["-c", "trap '' TERM; while :; do sleep 1; done"])
        Thread.sleep(forTimeInterval: 0.2)
        let (snap, scan) = world(child.pid)
        let p = try plan(snap, scan)
        guard case .needsNewPlan(let k) = stopper.execute(p, scan: scan) else { Issue.record("expected a new plan"); return }
        #expect(alive(child.pid), "SIGTERM was ignored and hog did not kill on its own")
        #expect(k.action == .sigkill && k.planId != p.planId)
        #expect(k.gates.contains { $0.gate == "G4" && $0.result == .confirm })
        let stored = try stopper.plans.load(k.planId)
        #expect(stored.action == .sigkill)
        // Only with that new plan, agreed again:
        #expect(stopper.execute(stored, scan: scan) == .done("Killed test-child (SIGKILL)."))
        child.process.waitUntilExit()
    }

    @Test func g8NoLogNoStop() throws {
        let child = try Child("/bin/sleep", ["30"])
        let blocker = state.appendingPathComponent("not-a-dir")
        try Data().write(to: blocker)
        stopper.log = ActionLog(file: blocker.appendingPathComponent("actions.jsonl"))
        let (snap, scan) = world(child.pid)
        if case .blocked(let g) = stopper.execute(try plan(snap, scan), scan: scan) { #expect(g.gate == "G8") } else { Issue.record("not blocked") }
        #expect(alive(child.pid))
    }

    @Test func launchdKeptAliveBecomesInstructions() throws {
        let child = try Child("/bin/sleep", ["30"])
        let (snap, scan) = world(child.pid, facts: ["launchd.label": .string("com.example.job"), "launchd.restarts_after_stop": .bool(true)])
        let p = try plan(snap, scan)
        #expect(p.action == .manual)
        if case .manual(let steps) = stopper.execute(p, scan: scan) { #expect(steps.first?.contains("launchctl bootout") == true) }
        else { Issue.record("expected instructions") }
        #expect(alive(child.pid))
    }

    @Test func plansExpireAndIdsDependOnIdentityAndAction() throws {
        let id = StopIdentity.process(42, startSec: 100, startUsec: 5)
        #expect(StopPlan.makeId(id, .sigterm) == StopPlan.makeId(id, .sigterm))
        #expect(StopPlan.makeId(id, .sigterm) != StopPlan.makeId(id, .sigkill))
        #expect(StopPlan.makeId(id, .sigterm) != StopPlan.makeId(.process(42, startSec: 101, startUsec: 5), .sigterm))
        let child = try Child("/bin/sleep", ["30"])
        let (snap, scan) = world(child.pid)
        let p = try plan(snap, scan)
        try stopper.plans.save(p)
        #expect(try stopper.plans.load(p.planId) == p)
        #expect(throws: PlanStore.LoadError.expired) { try stopper.plans.load(p.planId, now: Date().addingTimeInterval(11 * 60)) }
        #expect(throws: PlanStore.LoadError.notFound) { try stopper.plans.load("../../etc/passwd") }
        #expect(stopper.execute(p, scan: scan, now: Date().addingTimeInterval(11 * 60)) != .done("Stopped test-child (SIGTERM)."))
        #expect(alive(child.pid))
    }

    @Test func portTargetsResolveLikeLps() throws {
        let child = try Child("/bin/sleep", ["30"])
        var (snap, scan) = world(child.pid)
        scan.network = .init(listening: [child.pid: [ListenSocket(addr: "*", port: 3999)]], connections: [])
        let (identity, item) = try stopper.resolve("3999", in: snap, scan: scan)
        #expect(identity.pid == child.pid && item != nil)
        snap.items = []
        #expect(throws: Stopper.TargetError.self) { try stopper.resolve("nope", in: snap, scan: scan) }
    }
}

@Suite(.serialized) final class DockerStopTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hog-dstop-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: dir) }

    func stopper(_ fake: FakeDocker) -> Stopper {
        return Stopper(plans: PlanStore(directory: dir), log: ActionLog(file: dir.appendingPathComponent("a.jsonl")), lang: .en,
                       dockerSocket: { fake.path })
    }

    func world() -> (Snapshot, Scan) {
        let c = DockerClient.Container(id: "abc123def4567890", name: "db", image: "mongo:7", state: "restarting",
                                       publishedPorts: [27017], restartCount: 4057, restartPolicy: "always", startedAt: nil)
        let scan = Scan(system: RawSystem(memTotalBytes: 0, ncpu: 1, pageSize: 16384), processes: [:], containers: [c])
        let item = Item(id: "ctr:abc123def456", kind: .container, label: "db", pids: [], facts: ["owner.kind": .string("none")])
        let f = Finding(itemId: item.id, verdict: .mayStop, confidence: .high, rules: ["container-crash-loop"], reason: "loop",
                        evidence: [:], unmeasured: [], stop: StopAdvice(strategy: .dockerContainer, respawns: .supervisor, effect: "x"))
        let snap = Snapshot(lang: .en, takenAt: Date(), hog: HogInfo(pid: getpid(), ancestors: [], ancestorsComplete: true, selfFootprintBytes: nil),
                            host: HostInfo(arch: "arm64", ncpu: 1, memTotalBytes: 0, uptimeS: nil), memory: MemoryInfo(), cpu: CPUInfo(),
                            headline: Headline(level: .ok, text: "", glossaryIds: []), items: [item], findings: [f])
        return (snap, scan)
    }

    @Test func turnsOffRestartPolicyVerifiesThenStops() throws {
        let fake = try FakeDocker(routes: [
            "POST /containers/abc123def4567890/update": (200, "{}"),
            "GET /containers/abc123def4567890/json": (200, #"{"HostConfig":{"RestartPolicy":{"Name":"no"}}}"#),
            "POST /containers/abc123def4567890/stop?t=10": (204, ""),
        ])
        defer { fake.stop() }
        let s = stopper(fake)
        let (snap, scan) = world()
        let (identity, item) = try s.resolve("db", in: snap, scan: scan)
        let p = s.plan(identity, item: item, snapshot: snap, scan: scan)
        #expect(p.action == .dockerStop && p.previousRestartPolicy == "always")
        #expect(p.steps.contains { $0.contains("docker update --restart=always db") }, "restore hint")
        #expect(s.execute(p, scan: scan) == .done("Stopped the container (nothing deleted)."))
        #expect(fake.seen == ["POST /containers/abc123def4567890/update HTTP/1.0", "GET /containers/abc123def4567890/json HTTP/1.0",
                              "POST /containers/abc123def4567890/stop?t=10 HTTP/1.0"])
    }

    @Test func doesNotStopWhenThePolicyIsStillOn() throws {
        let fake = try FakeDocker(routes: [
            "POST /containers/abc123def4567890/update": (200, "{}"),
            "GET /containers/abc123def4567890/json": (200, #"{"HostConfig":{"RestartPolicy":{"Name":"always"}}}"#),
        ])
        defer { fake.stop() }
        let s = stopper(fake)
        let (snap, scan) = world()
        let (identity, item) = try s.resolve("db", in: snap, scan: scan)
        if case .blocked(let g) = s.execute(s.plan(identity, item: item, snapshot: snap, scan: scan), scan: scan) { #expect(g.gate == "G5") }
        else { Issue.record("not blocked") }
        #expect(!fake.seen.contains { $0.contains("/stop") }, "no stop request after a failed policy change")
    }

    @Test func doesNotStopWhenTheUpdateFails() throws {
        let fake = try FakeDocker(routes: ["POST /containers/abc123def4567890/update": (500, "{}")])
        defer { fake.stop() }
        let s = stopper(fake)
        let (snap, scan) = world()
        let (identity, item) = try s.resolve("db", in: snap, scan: scan)
        if case .blocked(let g) = s.execute(s.plan(identity, item: item, snapshot: snap, scan: scan), scan: scan) { #expect(g.gate == "G5") }
        else { Issue.record("not blocked") }
        #expect(!fake.seen.contains { $0.contains("/stop") })
    }
}
