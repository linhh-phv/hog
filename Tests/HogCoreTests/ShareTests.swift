import Foundation
import Testing
@testable import HogCore

/// Phase 2: what a person copies to ask Claude must be safe to paste (phase-2 design, section 3).
@Suite struct ShareTests {
    let home = "/Users/me"

    func scan(_ processes: [RawProcess], containers: [DockerClient.Container]? = nil,
              listening: [Int32: [ListenSocket]] = [:]) -> Scan {
        Scan(home: home, system: RawSystem(memTotalBytes: 0, ncpu: 8, pageSize: 16384),
             processes: Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) }),
             network: .init(listening: listening, connections: []), containers: containers)
    }

    func proc(_ pid: Int32, ppid: Int32, exe: String, args: [String]? = nil) -> RawProcess {
        var p = RawProcess(pid: pid); p.ppid = ppid; p.exePath = exe; p.args = args; p.cwd = "/Users/me/work/web-app"
        return p
    }

    @Test func dropsLabelsPathsProjectsAndSecrets() throws {
        let node = proc(500, ppid: 400, exe: "/opt/homebrew/bin/node",
                        args: ["node", "/Users/me/work/web-app/server.js", "--dir=/Users/me/work/web-app/dist", "--token", "s3cr3t",
                               "https://me:pw@git.example.com/web-app/repo", "--port", "3000"])
        let s = scan([node, proc(400, ppid: 300, exe: "/bin/zsh"), proc(300, ppid: 1, exe: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")],
                     listening: [500: [ListenSocket(addr: "*", port: 3000), ListenSocket(proto: "tcp6", addr: "*", port: 3000)]])
        let item = Item(id: "proc:500:1", kind: .process, label: "node — web-app (Workspace)", pids: [500], ownerId: "vscode:7",
                        footprintBytes: Measured(412_000_000),
                        facts: ["footprint_bytes": .int(412_000_000), "orphan": .bool(true), "owner.kind": .string("vscode-window"),
                                "launchd.label": .string("com.example.private"), "catalog.family": .string(""),
                                "session.idle_s": .null, "age_s": .int(7200)])
        let share = ShareInfo.make(item, scan: s)
        #expect(share.item.exe == "node")
        #expect(share.item.args == "node server.js --dir=dist --token *** repo --port 3000")
        #expect(share.parents == ["zsh", "Terminal", "launchd"])
        #expect(share.listenPorts == [3000])
        #expect(share.ownerKind == "vscode-window")
        #expect(share.facts["launchd.label"] == nil, "free-form strings can name private things")
        #expect(share.facts["catalog.family"] == nil, "empty means unknown: dropped")
        #expect(share.facts["session.idle_s"] == nil, "only measured facts")
        #expect(share.facts["age_s"] == .int(7200))
        let text = share.text(.vi)
        for leak in ["/Users", "me:pw", "s3cr3t", "web-app", "Workspace", "vscode:7", "example"] {
            #expect(!text.contains(leak), "leaked \(leak)")
        }
        #expect(text.contains("```json") && text.contains("\"schema\" : \"hog.share/1\""))
    }

    @Test func containerSharesImageNameOnly() {
        let c = DockerClient.Container(id: "abc123def4567890", name: "web-app-db", image: "registry.example.com/team/postgres:16",
                                       state: "running", publishedPorts: [5432], restartCount: 3, restartPolicy: "always")
        let item = Item(id: "ctr:abc123def456", kind: .container, label: "web-app-db", pids: [],
                        facts: ["container.restart_count": .int(3), "container.restart_policy": .string("always")])
        let share = ShareInfo.make(item, scan: scan([], containers: [c]))
        #expect(share.item.image == "postgres:16")
        #expect(share.item.exe == nil && share.item.args == nil)
        #expect(!share.json.contains("web-app") && !share.json.contains("example.com"))
    }

    @Test func parentChainStopsAtLimitAndOnMissingParent() {
        let chain = (2...7).map { proc(Int32($0 * 10), ppid: Int32(($0 + 1) * 10), exe: "/bin/p\($0)") }
        #expect(ShareInfo.ancestors(of: chain[0], in: scan(chain)) == ["p3", "p4", "p5", "p6"])
        #expect(ShareInfo.ancestors(of: proc(9, ppid: 999, exe: "/bin/x"), in: scan([])) == ["?"])
    }
}

@Suite struct UnknownsTests {
    func item(_ id: String, _ bytes: Int64, catalog: String? = nil, protection: ProtectionLevel? = nil) -> Item {
        Item(id: id, kind: .process, label: id, catalogId: catalog, pids: [1], footprintBytes: Measured(bytes),
             protection: protection.map { Protection(level: $0, rules: ["r"]) })
    }

    @Test func picksLargestUncataloguedUnprotected() {
        var s = SampleSnapshot.make()
        s.items += [
            item("a", 300_000_000), item("b", 900_000_000), item("c", 500_000_000), item("d", 200_000_000),
            item("small", 99_000_000), item("known", 2_000_000_000, catalog: "tsserver"),
            item("macos", 3_000_000_000, protection: .hard), item("soft", 150_000_000, protection: .soft),
            item("empty-catalog", 250_000_000, catalog: ""),
        ]
        let u = MenuSummary.make(s).unknowns
        #expect(u.map(\.itemId) == ["b", "c", "a"])
        #expect(MenuSummary.unknowns(s, excluding: ["b"]).map(\.itemId) == ["c", "a", "empty-catalog"])
    }

    @Test func noneWhenEverythingIsKnown() {
        #expect(MenuSummary.make(SampleSnapshot.make()).unknowns.isEmpty)
    }

    @Test func allCardsListsEverySuggestion() {
        var s = SampleSnapshot.make()
        let base = s.findings[0]
        s.findings = (0..<5).map { i in var f = base; f.itemId = "w\(i)"; f.verdict = .watch; return f } + [base]
        let m = MenuSummary.make(s)
        #expect(m.cards.count == MenuSummary.maxCards && m.allCards.count == 6 && m.moreCount == 3)
        #expect(m.allCards.first?.itemId == base.itemId, "may-stop first")
    }
}
