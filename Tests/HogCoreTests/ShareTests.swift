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
        #expect(share.item.args == "node server.js --dir=… --token *** https://… --port 3000")
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

    @Test func packageNamesAreKept() {
        #expect(ShareInfo.sharePath("/Applications/Visual Studio Code.app/Contents/Resources/app/extensions/markdown-language-features/dist/serverWorkerMain")
                == "extensions/markdown-language-features/…/serverWorkerMain")
        #expect(ShareInfo.sharePath("/Users/me/.vscode/extensions/ms-python.vscode-pylance-2024.1.1/dist/server.bundle.js")
                == "extensions/ms-python.vscode-pylance-2024.1.1/…/server.bundle.js")
        #expect(ShareInfo.sharePath("/Users/me/work/web-app/node_modules/next/dist/bin/next") == "node_modules/next/…/next")
        #expect(ShareInfo.sharePath("/Users/me/work/web-app/node_modules/vite/bin.js") == "node_modules/vite/bin.js")
        #expect(ShareInfo.sharePath("/Users/me/work/web-app/node_modules/vite") == "node_modules/vite")
        #expect(ShareInfo.sharePath("/Users/me/work/web-app/server.js") == "server.js")
        #expect(ShareInfo.sharePath("/x/node_modules") == "…", "a directory, nothing after the package dir")
    }

    // Reviewer 2026-10-26: directories as arguments, hosts, user info, ids and env secrets must not survive.
    @Test func reviewerLeaksAreClosed() {
        func share(_ a: [String]) -> String { ShareInfo.shareArgs(a, home: "/Users/me") }
        #expect(share(["pnpm", "--dir", "/Users/me/work/acme-billing", "dev"]) == "pnpm --dir … dev")
        #expect(share(["git", "-C", "/Users/me/work/acme-billing", "fsck"]) == "git -C … fsck")
        #expect(share(["node", "--prefix=/Users/me/work/acme-billing"]) == "node --prefix=…")
        #expect(share(["sh", "-c", "cd /Users/me/work/acme-billing && npm run dev"]) == "sh -c cd … && npm run dev")
        #expect(share(["psql", "postgres://u:p@h/acme_prod"]) == "psql postgres://…")
        #expect(share(["git", "clone", "git@github.com:acme-corp/private-repo.git"]) == "git clone …")
        #expect(share(["node", "--redis-url=redis://:hunter2@localhost:6379"]) == "node --redis-url=redis://…")
        #expect(share(["x", "--url", "https://ghp_abcdef123456@github.com"]) == "x --url https://…")
        #expect(share(["sh", "-c", "AWS_SECRET_ACCESS_KEY=abc/def+ghi node x.js"]) == "sh -c AWS_SECRET_ACCESS_KEY=*** node x.js")
        #expect(share(["npm", "--registry=https://npm.corp-internal.example"]) == "npm --registry=https://…")
        #expect(share(["ssh", "deploy@prod.corp.example"]) == "ssh …")
        #expect(share(["node", "/Users/me/w/node_modules/@acme-corp/tool/bin/cli.js"]) == "node node_modules/@…/tool/…/cli.js")
        #expect(share(["chrome", "--metrics-client-id=0b5f2c7e-3d1a-4b8e-9f00-1234567890ab"]) == "chrome --metrics-client-id=…")
        #expect(share(["x", "--session", "AbC123dEf456GhI789jKl0"]) == "x --session …")
        #expect(share(["vite", "--port", "3000", "--host", "--mode", "development"]) == "vite --port 3000 --host --mode development",
                "ordinary words and numbers stay")
    }

    // QA 2026-10-26: secrets in environment assignments, headers, curl -u; paths with spaces stay one piece.
    @Test func qaSecretsAreMasked() {
        func share(_ a: [String]) -> String { ShareInfo.shareArgs(a, home: "/Users/me") }
        #expect(share(["docker", "run", "-e", "DB_PASSWORD=pw-docker-1", "--env", "GITHUB_TOKEN=ghp_envtoken1", "img"])
                == "docker run -e DB_PASSWORD=*** --env GITHUB_TOKEN=*** img")
        #expect(share(["x", "--env=AWS_SECRET_ACCESS_KEY=awsSecretVal"]) == "x --env=AWS_SECRET_ACCESS_KEY=***")
        #expect(share(["env", "NPM_TOKEN=npm_abc7", "API_KEY=sk-abc123", "node", "x.js"]) == "env NPM_TOKEN=*** API_KEY=*** node x.js")
        #expect(share(["curl", "-H", "X-Api-Key: xkeyvalue1", "--header", "X-Auth-Token: xauthval2"])
                == "curl -H X-Api-Key: *** --header X-Auth-Token: ***")
        #expect(share(["curl", "--header=X-Auth: topsecret"]) == "curl --header=X-Auth: ***")
        #expect(share(["curl", "-u", "admin:basicpw4", "https://hooks.example.com/services/T000/B000/XXXXSLACKSECRET"])
                == "curl -u *** https://…")
        #expect(share(["/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)",
                       "--user-data-dir=/Users/me/Library/Application Support/Code", "--type=renderer"])
                == "Code Helper (Plugin) --user-data-dir=… --type=renderer", "a path with spaces is one piece; flag names stay")
        #expect(share(["http", "-u", "admin:basicpw4", "x"]) == "http -u *** x", "any program")
        #expect(share(["mysql", "-u", "root"]) == "mysql -u root", "a user name alone is not a credential")
        #expect(share(["sh", "-c", "Content-Type: text/plain"]) == "sh -c Content-Type: …", "an ordinary header is not a secret")
    }

    @Test func leadSaysWhetherHogKnowsIt() {
        var known = ShareInfo.make(Item(id: "x", kind: .process, label: "x", catalogId: "tsserver", pids: []), scan: scan([]))
        #expect(known.text(.en).contains("identifies this as `tsserver`"))
        known.item.catalogId = nil
        #expect(known.text(.vi).contains("chưa biết thứ này là gì"))
    }

    @Test func knownPrivateNamesAreReplacedEverywhere() {
        let r = Redactor(names: ["acme-billing", "acme", "me", "src", "Phams-MacBook"])
        #expect(r.names("code acme-billing") == "code …")
        #expect(r.names("acme-worker") == "…-worker", "a known name inside a word boundary")
        #expect(r.names("ACME") == "…", "case-insensitive")
        #expect(r.names("src/main.ts") == "src/main.ts", "generic directory names are never treated as private")
        #expect(r.names("acmeX") == "acmeX", "only whole words")
    }

    @Test func redactorLearnsFromTheScan() {
        var p = proc(500, ppid: 1, exe: "/usr/local/bin/acme-server")
        p.cwd = "/Users/me/clients/globex/acme-server"
        let s = scan([p])
        let item = Item(id: "proc:500:1", kind: .process, label: "acme-server", pids: [500], facts: [:])
        let share = ShareInfo.make(item, scan: s)
        #expect(share.item.exe == "…", "a binary named after its project directory")
        #expect(Redactor(scan: s, user: "me", host: "box").names.contains("globex"))
    }

    @Test func composeImagesKeepOnlyTheService() {
        #expect(ShareInfo.shareImage("acme-billing-web:latest") == "…-web:latest")
        #expect(ShareInfo.shareImage("postgres:16") == "postgres:16")
        #expect(ShareInfo.shareImage("registry.example.com/team/acme_api") == "…-api")
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
    func item(_ id: String, _ bytes: Int64, catalog: String? = nil, protection: ProtectionLevel? = nil, ownerKind: String = "none") -> Item {
        Item(id: id, kind: .process, label: id, catalogId: catalog, pids: [1], footprintBytes: Measured(bytes),
             protection: protection.map { Protection(level: $0, rules: ["r"]) }, facts: ["owner.kind": .string(ownerKind)])
    }

    @Test func picksLargestUncataloguedUnprotected() {
        var s = SampleSnapshot.make()
        s.items += [
            item("a", 300_000_000), item("b", 900_000_000), item("c", 500_000_000), item("d", 200_000_000),
            item("small", 99_000_000), item("known", 2_000_000_000, catalog: "tsserver"),
            item("macos", 3_000_000_000, protection: .hard), item("soft", 150_000_000, protection: .soft),
            item("empty-catalog", 250_000_000, catalog: ""), item("chrome-helper", 800_000_000, ownerKind: "app"),
            item("in-window", 120_000_000, ownerKind: "vscode-window"),
        ]
        let u = MenuSummary.make(s).unknowns
        #expect(u.map(\.itemId) == ["b", "c", "a"])
        #expect(MenuSummary.unknowns(s, excluding: ["b"]).map(\.itemId) == ["c", "a", "empty-catalog"])
        #expect(MenuSummary.unknowns(s, excluding: ["b", "c", "a", "empty-catalog", "d"]).map(\.itemId) == ["soft", "in-window"],
                "parts of an app are not unknown; VS Code window helpers are")
    }

    @Test func noneWhenEverythingIsKnown() {
        #expect(MenuSummary.make(SampleSnapshot.make()).unknowns.isEmpty)
    }

    @Test func candidatesSurviveTheSizeCap() {
        // 25 large app processes fill the 20 "extra" slots; the 120 MB unknown must still be kept for the app.
        var procs: [Int32: RawProcess] = [:]
        for i in 0..<25 {
            var p = RawProcess(pid: Int32(1000 + i)); p.ppid = 1; p.uid = getuid(); p.footprintBytes = 900_000_000 - Int64(i)
            p.exePath = "/Applications/Big.app/Contents/MacOS/Big"; p.cwd = "/"; procs[p.pid] = p
        }
        var u = RawProcess(pid: 3000); u.ppid = 1; u.uid = getuid(); u.footprintBytes = 120_000_000
        u.exePath = "/usr/local/bin/mystery"; u.cwd = "/"; procs[3000] = u
        let s = analyzer.analyze(Scan(system: RawSystem(memTotalBytes: 0, ncpu: 8, pageSize: 16384), processes: procs, launchd: [:]))
        #expect(s.items.contains { $0.pids == [3000] })
        #expect(MenuSummary.make(s).unknowns.contains { $0.label.contains("mystery") })
    }

    let analyzer: Analyzer = {
        let b = { (k: String) in DataSource(bundledDirectory: DataSource.standard(k).bundledDirectory, localDirectory: nil) }
        return Analyzer(catalog: .load(b("catalog")), rules: .load(b("rules")), explain: .load(b("explain")), lang: .en)
    }()

    @Test func allCardsListsEverySuggestion() {
        var s = SampleSnapshot.make()
        let base = s.findings[0]
        s.findings = (0..<5).map { i in var f = base; f.itemId = "w\(i)"; f.verdict = .watch; return f } + [base]
        let m = MenuSummary.make(s)
        #expect(m.cards.count == MenuSummary.maxCards && m.allCards.count == 6 && m.moreCount == 3)
        #expect(m.allCards.first?.itemId == base.itemId, "may-stop first")
    }
}
