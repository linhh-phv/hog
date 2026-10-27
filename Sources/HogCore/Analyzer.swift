import Foundation

/// Turns a `Scan` into a `Snapshot`: items + facts, rules, findings, owners, headline (design sections 3.4–7).
public struct Analyzer: Sendable {
    public var catalog: Catalog
    public var rules: RuleSet
    public var explain: Explanations
    public var lang: Lang
    /// Include every own process in `processes` (`--full`), not only significant ones.
    public var full: Bool
    /// `launchctl print` for a label; injected so tests do not call launchctl.
    public var launchdPrint: @Sendable (String) -> String?

    public static let significantFootprint: Int64 = 50 * 1_048_576
    public static let significantCPU: Double = 5
    /// Without `--full`: items without a finding kept (largest first), and processes kept (largest first).
    public static let maxExtraItems = 20
    public static let maxProcesses = 15
    /// Owners smaller than this are dropped from the snapshot unless something kept refers to them.
    public static let minOwnerFootprint: Int64 = 50 * 1_048_576

    public init(catalog: Catalog, rules: RuleSet, explain: Explanations, lang: Lang, full: Bool = false,
                launchdPrint: @escaping @Sendable (String) -> String? = { _ in nil }) {
        self.catalog = catalog; self.rules = rules; self.explain = explain; self.lang = lang; self.full = full
        self.launchdPrint = launchdPrint
    }

    /// Bundled data plus `~/.config/hog/*.d` overrides.
    public static func standard(lang: Lang, full: Bool = false, home: String = NSHomeDirectory(),
                                external: ExternalSensors = ExternalSensors()) -> Analyzer {
        Analyzer(catalog: .load(.standard("catalog", home: home)), rules: .load(.standard("rules", home: home)),
                 explain: .load(.standard("explain", home: home)), lang: lang, full: full,
                 launchdPrint: { external.launchdPrint(label: $0) })
    }

    // MARK: - Analysis

    /// Everything computed once per scan and shared by every item.
    struct Context {
        var own: [Int32: ProcessOwnership]
        var selfChain: (chain: [Int32], complete: Bool)
        var selfSet: Set<Int32>
        /// VS Code window that contains hog (its caller), if any: `self.window`.
        var selfWindow: Int?
        var catalogOf: [Int32: String]
        var sessionPids: Set<Int32>
    }

    func context(_ scan: Scan) -> Context {
        let own = Ownership.resolve(scan)
        let selfChain = Ownership.ancestors(of: scan.selfPid, in: scan.processes)
        let selfSet = Set([scan.selfPid] + selfChain.chain.filter { $0 != 1 })
        return Context(own: own, selfChain: selfChain, selfSet: selfSet,
                       selfWindow: ([scan.selfPid] + selfChain.chain).lazy.compactMap { own[$0]?.window }.first,
                       catalogOf: matchCatalog(scan),
                       sessionPids: Set(own.values.compactMap(\.session)).filter { own[$0]?.session == $0 })
    }

    /// An item for any PID — also small processes that are not part of the snapshot's items — with facts and
    /// protection, so the stop gates never see a target without its protections (review finding, 2026-10-26).
    public func item(forPid pid: Int32, in scan: Scan) -> Item? {
        guard let p = scan.processes[pid] else { return nil }
        let ctx = context(scan)
        let isSession = ctx.sessionPids.contains(pid)
        var item = Item(id: isSession ? "claude:\(pid)" : "proc:\(pid):\(p.startSec ?? 0)", kind: isSession ? .claudeSession : .process,
                        label: label(pid: pid, p: p, catalogId: ctx.catalogOf[pid], ownership: ctx.own[pid], scan: scan),
                        catalogId: ctx.catalogOf[pid], pids: [pid], ownerId: ctx.own[pid]?.ownerId,
                        footprintBytes: Measured(p.footprintBytes), residentRatio: Measured(residentRatio(p)))
        var restarts: [String: Bool?] = [:]
        if let label = scan.launchd?[pid] { restarts[label] = launchdPrint(label).flatMap { LaunchctlParser.restartsAfterStop(printOutput: $0) } }
        item.facts = facts(for: item, scan: scan, ctx: ctx, items: [item], restarts: restarts)
        item.protection = Measured(RuleEngine.run(rules.rules, kind: item.kind, facts: item.facts).protection)
        return item
    }

    public func analyze(_ scan: Scan) -> Snapshot {
        let ctx = context(scan)
        let (own, selfChain, catalogOf, sessionPids) = (ctx.own, ctx.selfChain, ctx.catalogOf, ctx.sessionPids)

        // Items
        var items: [Item] = []
        var itemOfPid: [Int32: String] = [:]
        for (pid, p) in scan.processes {
            let isSession = sessionPids.contains(pid)
            let ownUid = p.uid.map { $0 == scan.selfUid }
            let significant = (p.footprintBytes ?? 0) >= Self.significantFootprint || catalogOf[pid] != nil
                || own[pid]?.orphan == true || !(scan.network?.listening[pid] ?? []).isEmpty
                || (scan.cpuNowPct[pid] ?? 0) >= Self.significantCPUPct  // small but burning CPU: cpu-heavy can see it
            guard isSession || (ownUid == true && significant) else { continue }
            let id = isSession ? "claude:\(pid)" : "proc:\(pid):\(p.startSec ?? 0)"
            itemOfPid[pid] = id
            items.append(Item(id: id, kind: isSession ? .claudeSession : .process,
                              label: label(pid: pid, p: p, catalogId: catalogOf[pid], ownership: own[pid], scan: scan),
                              catalogId: catalogOf[pid], pids: [pid], ownerId: own[pid]?.ownerId,
                              footprintBytes: Measured(p.footprintBytes), residentRatio: Measured(residentRatio(p))))
        }
        for c in scan.containers ?? [] {
            items.append(Item(id: "ctr:\(c.id.prefix(12))", kind: .container, label: c.name,
                              catalogId: catalog.match(MatchSubject(containerImage: c.image)), pids: []))
        }

        // Facts, first pass without launchd configs (each `launchctl print` is a process spawn).
        for i in items.indices {
            items[i].facts = facts(for: items[i], scan: scan, ctx: ctx, items: items)
        }
        // Second pass: read the launchd config only for launchd jobs that could be suggested for stopping,
        // in parallel, then recompute their facts (design 3.1: `launchd.restarts_after_stop`).
        let candidates: [(Int, String)] = items.indices.compactMap { i in
            guard let pid = items[i].pids.first, let label = scan.launchd?[pid] else { return nil }
            let v = RuleEngine.run(rules.rules, kind: items[i].kind, facts: items[i].facts).verdict
            return v == .mayStop || v == .ask ? (i, label) : nil
        }
        if !candidates.isEmpty {
            let print = launchdPrint
            let prints = ExternalSensors.parallelMap(candidates.map(\.1)) { label in print(label) }
            var restarts: [String: Bool?] = [:]
            for (k, c) in candidates.enumerated() { restarts[c.1] = prints[k].flatMap { LaunchctlParser.restartsAfterStop(printOutput: $0) } }
            for (i, _) in candidates {
                items[i].facts = facts(for: items[i], scan: scan, ctx: ctx, items: items, restarts: restarts)
            }
        }

        // Rules → protection + findings
        var findings: [Finding] = []
        for i in items.indices {
            let outcome = RuleEngine.run(rules.rules, kind: items[i].kind, facts: items[i].facts)
            items[i].protection = Measured(outcome.protection)
            guard let verdict = outcome.verdict else { continue }
            findings.append(finding(for: items[i], outcome: outcome, verdict: verdict, ncpu: scan.system.ncpu))
        }
        findings.sort { a, b in
            if a.verdict != b.verdict { return rank(a.verdict) > rank(b.verdict) }
            return footprint(of: a.itemId, items) > footprint(of: b.itemId, items)
        }
        items.sort { ($0.footprintBytes.value ?? -1, $0.id) > ($1.footprintBytes.value ?? -1, $1.id) }
        if !full {
            // Size cap (design 4, ≤ 100 KB): items with a finding + the largest others.
            let withFinding = Set(findings.map(\.itemId))
            var kept = 0
            // Containers always stay: they have no footprint (sorted last) and no other way back as a stop target.
            // So do "not known yet" candidates (the app lists them; QA 2026-10-26: a 120 MB one fell below the cap).
            var unknowns = 0
            items = items.filter { withFinding.contains($0.id) || $0.kind == .container
                || (Presentation.isUnknownCandidate($0) && { unknowns += 1; return unknowns <= Presentation.maxUnknownCandidates }())
                || { kept += 1; return kept <= Self.maxExtraItems }() }
            let keptIds = Set(items.map(\.id))
            itemOfPid = itemOfPid.filter { keptIds.contains($0.value) }
        }

        var owners = buildOwners(scan: scan, own: own)
        let cpuTop = cpuTop(scan: scan, own: own, owners: owners)
        let findingItems = Set(findings.map(\.itemId))
        let processes = buildProcesses(scan: scan, own: own, catalogOf: catalogOf, itemOfPid: itemOfPid, mustInclude: findingItems)
        if !full {
            // Keep owners that are large, or referenced by a kept item, or parents of kept owners.
            var keep = Set(owners.filter { $0.totalFootprintBytes >= Self.minOwnerFootprint }.map(\.id))
            keep.formUnion(items.compactMap(\.ownerId.value))
            let parents = Set(owners.filter { keep.contains($0.id) }.compactMap(\.parent.value))
            keep.formUnion(parents)
            owners = owners.filter { keep.contains($0.id) }
        }
        let memory = MemoryInfo(freeBytes: Measured(scan.system.freeBytes), usedBytes: Measured(scan.system.usedBytes),
                                wiredBytes: Measured(scan.system.wiredBytes),
                                compressorBytes: Measured(scan.system.compressorBytes),
                                compressedStoredBytes: Measured(scan.system.compressedStoredBytes),
                                swapUsedBytes: Measured(scan.system.swapUsedBytes), swapTotalBytes: Measured(scan.system.swapTotalBytes),
                                pressure: Measured(SystemReader.pressure(scan.system.pressureLevel)),
                                unreadableProcessCount: scan.processes.values.filter { $0.footprintBytes == nil }.count,
                                measuredFootprintBytes: scan.processes.values.reduce(0) { $0 + ($1.footprintBytes ?? 0) })
        var snapshot = Snapshot(
            lang: lang, takenAt: scan.takenAt,
            hog: HogInfo(pid: scan.selfPid, ancestors: selfChain.chain, ancestorsComplete: selfChain.complete,
                         selfFootprintBytes: Measured(scan.processes[scan.selfPid]?.footprintBytes)),
            host: HostInfo(arch: Self.arch, ncpu: scan.system.ncpu, memTotalBytes: scan.system.memTotalBytes,
                           uptimeS: Measured(scan.system.uptimeS)),
            memory: memory,
            cpu: CPUInfo(userPct: Measured(scan.cpu?.user), sysPct: Measured(scan.cpu?.sys), idlePct: Measured(scan.cpu?.idle),
                         load: Measured(scan.system.load), thermal: Measured(scan.system.thermal), top: Measured(cpuTop)),
            heat: scan.heat,
            headline: Headline(level: .ok, text: "", glossaryIds: []),
            sensors: scan.sensors, owners: owners, processes: processes, items: items, findings: findings,
            warnings: (catalog.warnings + rules.warnings + explain.warnings).map(\.description) + scan.dataWarnings)
        snapshot.headline = headline(snapshot)
        return snapshot
    }

    static var arch: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    // MARK: Catalog

    /// Two passes so `parent_catalog` clauses can use the parent's match.
    func matchCatalog(_ scan: Scan) -> [Int32: String] {
        var result: [Int32: String] = [:]
        for pass in 0..<2 {
            for (pid, p) in scan.processes {
                let subject = MatchSubject(exeName: p.exePath.map { ($0 as NSString).lastPathComponent },
                                           exePath: p.exePath, args: p.args?.joined(separator: " "),
                                           parentCatalog: pass == 0 ? nil : p.ppid.flatMap { result[$0] },
                                           listenPorts: (scan.network?.listening[pid] ?? []).map(\.port),
                                           vscodeRole: scan.vscode?.roles[pid])
                if let id = catalog.match(subject) { result[pid] = id }
            }
        }
        return result
    }

    // MARK: Facts

    func facts(for item: Item, scan: Scan, ctx: Context, items: [Item], restarts: [String: Bool?] = [:]) -> [String: FactValue] {
        let own = ctx.own
        var f: [String: FactValue] = [:]
        let entry = item.catalogId.value.flatMap { catalog.entries[$0] }
        // Matching the catalog is deterministic: no match is "" (known), not null (unknown), so rules about a family
        // do not report it as "not measured" (QA 2026-10-26, G7).
        f["catalog.id"] = .string(item.catalogId.value ?? "")
        f["catalog.family"] = .string(entry?.family ?? "")
        f["catalog.detached"] = .bool(entry?.detachedByDesign ?? false)

        if item.kind == .container, let c = scan.containers?.first(where: { "ctr:\($0.id.prefix(12))" == item.id }) {
            f["container.restart_count"] = c.restartCount.map { .int(Int64($0)) } ?? .null
            f["container.restart_policy"] = c.restartPolicy.map(FactValue.string) ?? .null
            f["container.state"] = .string(c.state)
            f["container.uptime_s"] = (c.state == "running" ? c.startedAt : nil).map { .int(Int64(scan.takenAt.timeIntervalSince($0))) } ?? .null
            if let net = scan.network, !c.publishedPorts.isEmpty {
                f["container.connections"] = .int(Int64(net.connections.filter { c.publishedPorts.contains($0.localPort) }.count))
            } else {
                f["container.connections"] = .null
            }
            f["owner.kind"] = .string("none")
            f["footprint_bytes"] = .null
            return f
        }

        guard let pid = item.pids.first, let p = scan.processes[pid] else { return f }
        let o = own[pid]
        let age = p.startDate.map { Int64(scan.takenAt.timeIntervalSince($0)) }
        f["age_s"] = age.map(FactValue.int) ?? .null

        f["orphan"] = o?.orphan.map(FactValue.bool) ?? .null
        f["footprint_bytes"] = p.footprintBytes.map(FactValue.int) ?? .null
        f["resident_ratio"] = residentRatio(p).map(FactValue.double) ?? .null
        f["cpu.now_pct"] = scan.cpuNowPct[pid].map(FactValue.double) ?? .null
        f["cpu.avg_pct"] = Self.averageCPU(p, scan).map(FactValue.double) ?? .null
        if let net = scan.network {
            f["net.established"] = .int(Int64(net.connections.filter { $0.pid == pid }.count))
            f["net.listen_count"] = .int(Int64(net.listening[pid]?.count ?? 0))
        } else {
            f["net.established"] = .null
            f["net.listen_count"] = .null
        }
        f["self.ancestor"] = .bool(ctx.selfSet.contains(pid))
        // Same VS Code window as hog's caller: "the window containing it" (design 6.2, 8 G1).
        f["self.window"] = .bool(ctx.selfWindow != nil && o?.window == ctx.selfWindow)
        f["own"] = p.uid.map { .bool($0 == scan.selfUid) } ?? .null
        f["exe.name"] = p.exePath.map { .string(($0 as NSString).lastPathComponent) } ?? .null
        f["exe.system"] = Ownership.isSystemExecutable(p.exePath).map(FactValue.bool) ?? .null
        f["exe.macos"] = Ownership.isMacOSExecutable(p.exePath).map(FactValue.bool) ?? .null

        // Owner facts: the session for session items and their descendants, else window / app / none.
        let session = item.kind == .claudeSession ? pid : o?.session
        if let s = session, let cs = scan.sessions?[s] {
            f["owner.kind"] = .string("claude-session")
            let busy = cs.busy
            let idle: Int64? = busy == true ? 0 : cs.statusUpdatedAt.map { Int64(scan.takenAt.timeIntervalSince($0)) }
            f["session.busy"] = busy.map(FactValue.bool) ?? .null
            f["session.idle_s"] = idle.map(FactValue.int) ?? .null
            f["owner.busy"] = f["session.busy"]
            f["owner.idle_s"] = f["session.idle_s"]
        } else if o?.orphan == true {
            // An orphan has no owner by definition (whatever started it is gone), even when its binary sits inside an
            // .app (Python.app for `python3 -m http.server`): QA 2026-10-26.
            f["owner.kind"] = .string("none")
            f["owner.busy"] = .bool(false)
            f["owner.idle_s"] = .null
        } else if o?.window != nil {
            f["owner.kind"] = .string("vscode-window")
            f["owner.busy"] = .null  // no busy/idle signal for a VS Code window
            f["owner.idle_s"] = .null
        } else if o?.app != nil {
            f["owner.kind"] = .string("app")
            f["owner.busy"] = .null
            f["owner.idle_s"] = .null
        } else {
            f["owner.kind"] = .string("none")
            f["owner.busy"] = .bool(false)
            f["owner.idle_s"] = .null
        }

        // Siblings: same catalog entry in other VS Code windows.
        if let cid = item.catalogId.value {
            let otherWindows = Set(items.compactMap { other -> Int? in
                guard other.id != item.id, other.catalogId.value == cid, let opid = other.pids.first else { return nil }
                return own[opid]?.window
            }).subtracting([o?.window].compactMap { $0 })
            f["siblings.same_catalog_other_windows"] = .int(Int64(otherWindows.count))
        } else {
            f["siblings.same_catalog_other_windows"] = .null
        }

        f["watchman.subscriptions"] = item.catalogId.value == "watchman" ? (scan.watchman?.subscriptions.map { .int(Int64($0)) } ?? .null) : .null

        if let label = scan.launchd?[pid] {
            f["launchd.label"] = .string(label)
            f["launchd.job"] = .bool(true)
            // Not looked up (small, uncatalogued) or unreadable → unknown.
            f["launchd.restarts_after_stop"] = (restarts[label] ?? nil).map(FactValue.bool) ?? .null
        } else {
            f["launchd.label"] = .null
            // A failed launchd sensor is unknown, not "not a job" (protect rules fire on unknown).
            f["launchd.job"] = scan.launchd == nil ? .null : .bool(false)
            f["launchd.restarts_after_stop"] = scan.launchd == nil ? .null : .bool(false)
        }
        return f
    }

    func residentRatio(_ p: RawProcess) -> Double? {
        guard let fp = p.footprintBytes, let rs = p.residentBytes, fp > 0 else { return nil }
        return min(1, Double(rs) / Double(fp))
    }

    // MARK: Findings

    func finding(for item: Item, outcome: RuleEngine.Outcome, verdict: Verdict, ncpu: Int) -> Finding {
        // Sentences say CPU as a share of the whole machine, like every screen ("11 %", not 88 % of one core); facts and
        // evidence keep % of one core.
        var machine: [String: String] = [:]
        for k in ["cpu.now_pct", "cpu.avg_pct"] {
            if let x = item.facts[k]?.number { machine[k.replacingOccurrences(of: "_pct", with: "_machine")] = Format.percent(x / Double(max(1, ncpu)), lang) }
        }
        let reason = outcome.fired.compactMap { $0.reason.text(lang) }.map { Format.fill($0, facts: item.facts, extra: machine, lang: lang) }
            .joined(separator: "\n")
        let used = Set(outcome.fired.flatMap(\.when.facts)).subtracting(FactNames.structural)
        let evidence = item.facts.filter { used.contains($0.key) && !$0.value.isNull }
        let entry = item.catalogId.value.flatMap { catalog.entries[$0] }
        var strategy = entry?.stop.strategy ?? (item.kind == .claudeSession ? .manual : (item.kind == .container ? .dockerContainer : .signal))
        var effect = entry?.stopEffect.text(lang) ?? (lang == .vi ? "Chưa có trong danh mục: chưa biết tắt thì ảnh hưởng gì."
                                                                 : "Not in the catalog yet: the effect of stopping it is unknown.")
        if item.facts["launchd.label"].map({ !$0.isNull }) == true, item.facts["launchd.restarts_after_stop"] != .bool(false) {
            strategy = .manual
            effect += lang == .vi ? "\nNếu chỉ dừng, macOS sẽ tự bật lại nó." : "\nIf it is only stopped, macOS starts it again."
        }
        return Finding(itemId: item.id, verdict: verdict, confidence: outcome.confidence, rules: outcome.fired.map(\.id),
                       reason: reason, evidence: evidence, unmeasured: outcome.unmeasured,
                       stop: StopAdvice(strategy: strategy, respawns: entry?.respawns, effect: effect), blockedBy: outcome.blockedBy)
    }

    func rank(_ v: Verdict) -> Int { switch v { case .mayStop: 3; case .ask: 2; case .watch: 1; case .info: 0 } }

    func footprint(of itemId: String, _ items: [Item]) -> Int64 {
        items.first { $0.id == itemId }?.footprintBytes.value ?? 0
    }

    func label(pid: Int32, p: RawProcess, catalogId: String?, ownership: ProcessOwnership?, scan: Scan) -> String {
        if let id = catalogId, let name = catalog.entries[id]?.name.text(lang) {
            if id == "claude-code-session", let project = ownership?.project { return "\(name) — \(project)" }
            return name
        }
        let exe = p.exePath.map { ($0 as NSString).lastPathComponent } ?? "pid \(pid)"
        if let project = ownership?.project { return "\(exe) — \(project)" }
        return exe
    }

    // MARK: Owners

    func buildOwners(scan: Scan, own: [Int32: ProcessOwnership]) -> [Owner] {
        struct Acc { var selfBytes: Int64 = 0; var totalBytes: Int64 = 0; var cpu: Double = 0; var cpuMeasured = false }
        var acc: [String: Acc] = [:]
        var meta: [String: Owner] = [:]
        for (pid, p) in scan.processes {
            guard let o = own[pid], let fp = p.footprintBytes else { continue }
            let cpu = scan.cpuNowPct[pid]
            var chain: [String] = []
            if let app = o.app {
                let id = "app:\(Ownership.slug(app))"
                chain.append(id)
                meta[id] = meta[id] ?? Owner(id: id, kind: .app, label: app)
            }
            if let w = o.window {
                let id = "vscode:\(w)"
                chain.append(id)
                if meta[id] == nil {
                    // Without `code --status` there is no title: name the window by its most common project.
                    let projects = own.filter { $0.value.window == w }.compactMap(\.value.project)
                    let common = Dictionary(grouping: projects, by: { $0 }).max { $0.value.count < $1.value.count }?.key
                    let fallback = (lang == .vi ? "Cửa sổ VS Code \(w)" : "VS Code window \(w)") + (common.map { " — \($0)" } ?? "")
                    meta[id] = Owner(id: id, kind: .vscodeWindow, label: scan.windows?[w]?.title ?? fallback,
                                     parent: o.app.map { "app:\(Ownership.slug($0))" })
                }
            }
            if let s = o.session {
                let id = "claude:\(s)"
                chain.append(id)
                if meta[id] == nil {
                    let project = own[s]?.project
                    meta[id] = Owner(id: id, kind: .claudeSession, label: "Claude" + (project.map { " — \($0)" } ?? ""),
                                     parent: own[s].flatMap { $0.window.map { "vscode:\($0)" } ?? $0.app.map { "app:\(Ownership.slug($0))" } },
                                     project: project)
                }
            }
            for (i, id) in chain.enumerated() {
                var a = acc[id] ?? Acc()
                a.totalBytes += fp
                if i == chain.count - 1 { a.selfBytes += fp }
                if let cpu { a.cpu += cpu; a.cpuMeasured = true }
                acc[id] = a
            }
        }
        return meta.values.map { o in
            var o = o
            let a = acc[o.id] ?? Acc()
            o.selfFootprintBytes = a.selfBytes
            o.totalFootprintBytes = a.totalBytes
            o.totalCpuPct = a.cpuMeasured ? Measured(a.cpu) : nil
            return o
        }.sorted { ($0.totalFootprintBytes, $0.id) > ($1.totalFootprintBytes, $1.id) }
    }

    // MARK: Processes

    func buildProcesses(scan: Scan, own: [Int32: ProcessOwnership], catalogOf: [Int32: String], itemOfPid: [Int32: String],
                        mustInclude: Set<String> = []) -> [ProcessRecord] {
        var out: [ProcessRecord] = []
        for (pid, p) in scan.processes {
            let listen = scan.network?.listening[pid] ?? []
            let cpuNow = scan.cpuNowPct[pid]
            let significant = full ? p.uid == scan.selfUid
                : ((p.footprintBytes ?? 0) >= Self.significantFootprint || (cpuNow ?? 0) >= Self.significantCPU
                   || !listen.isEmpty || itemOfPid[pid] != nil)
            guard significant else { continue }
            let o = own[pid]
            let age = p.startDate.map { Int64(scan.takenAt.timeIntervalSince($0)) }
            out.append(ProcessRecord(
                pid: pid, ppid: Measured(p.ppid), own: Measured(p.uid.map { $0 == scan.selfUid }),
                exe: Measured(p.exePath.map { ($0 as NSString).lastPathComponent }),
                exePath: Measured(p.exePath.map { Privacy.scrubPath($0, home: scan.home) }),
                args: Measured(p.args.map { Privacy.scrubArgs($0, home: scan.home) }),
                startedAt: Measured(p.startDate.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }),
                ageS: Measured(age), footprintBytes: Measured(p.footprintBytes), residentBytes: Measured(p.residentBytes),
                residentRatio: Measured(residentRatio(p)), compressedBytes: nil,
                cpu: ProcessCPU(nowPct: Measured(cpuNow),
                                avgPct: Measured(Self.averageCPU(p, scan))),
                cwd: Measured(p.cwd.map { Privacy.scrubPath($0, home: scan.home) }), project: Measured(o?.project),
                orphan: Measured(o?.orphan),
                net: ProcessNet(listen: listen, established: Measured(scan.network.map { n in n.connections.filter { $0.pid == pid }.count })),
                catalogId: Measured(catalogOf[pid]), ownerId: Measured(o?.ownerId), itemId: Measured(itemOfPid[pid])))
        }
        let sorted = out.sorted { ($0.footprintBytes.value ?? -1, $0.pid) > ($1.footprintBytes.value ?? -1, $1.pid) }
        if full { return sorted }
        var kept = 0
        // Processes of items with a finding always stay; the rest are capped (largest first).
        return sorted.filter { $0.itemId.value.map(mustInclude.contains) == true || { kept += 1; return kept <= Self.maxProcesses }() }
    }

    // MARK: Headline

    func headline(_ s: Snapshot) -> Headline {
        guard let t = explain.headlines else { return Headline(level: .ok, text: "", glossaryIds: []) }
        let suggestions = s.findings.filter { $0.verdict == .mayStop }
        let itemsById = Dictionary(uniqueKeysWithValues: s.items.map { ($0.id, $0) })
        let list = suggestions.prefix(5).compactMap { f -> String? in
            guard let i = itemsById[f.itemId] else { return nil }
            return i.footprintBytes.value.map { "\(i.label) (\(Format.bytes($0, lang)))" } ?? i.label
        }.joined(separator: ", ")
        // Biggest: top-level owners (apps) and items without an app.
        var groups: [(String, Int64)] = s.owners.filter { $0.parent.value == nil }.map { ($0.label, $0.totalFootprintBytes) }
        for i in s.items where i.ownerId.value == nil {
            if let b = i.footprintBytes.value { groups.append((i.label, b)) }
        }
        groups.sort { $0.1 > $1.1 }
        func top(_ n: Int) -> String { groups.prefix(n).map { "\($0.0) (\(Format.bytes($0.1, lang)))" }.joined(separator: ", ") }
        let mem = s.memory
        let extra: [String: String] = [
            "top1": top(1), "top3": top(3), "list": list, "n": String(suggestions.count),
            "n_things": lang == .vi ? "\(suggestions.count) thứ" : (suggestions.count == 1 ? "1 thing" : "\(suggestions.count) things"),
            "compressed_stored": mem.compressedStoredBytes.value.map { Format.bytes($0, lang) } ?? "?",
            "compressor": mem.compressorBytes.value.map { Format.bytes($0, lang) } ?? "?",
            "swap": mem.swapUsedBytes.value.map { Format.bytes($0, lang) } ?? "?",
        ]
        let (template, level): (HeadlineTemplates.Template, HeadlineLevel) = switch mem.pressure.value {
        case .normal?: (suggestions.isEmpty ? t.okClean : t.okSuggest, .ok)
        case .warn?: (t.warn, .warn)
        case .critical?: (suggestions.isEmpty ? t.criticalNoSuggest : t.critical, .critical)
        case nil: (t.unknown, .warn)
        }
        var text = Format.fill(template.text.text(lang) ?? "", facts: [:], extra: extra, lang: lang)
        var finalLevel = level
        var ids = template.glossaryIds
        // CPU and heat (task cpu-thermal): a second sentence only when it matters.
        let rows = Presentation.cpuRows(s, max: 3)
        let cpuTopText: String = if s.cpu.top.value == nil {
            lang == .vi ? "chưa đo (--fast)" : "not measured (--fast)"
        } else if rows.isEmpty {
            lang == .vi ? "không thứ gì từ 1 % một nhân" : "nothing at 1 % of a core or more"
        } else {
            rows.map { "\($0.label) (\(Format.percent($0.pct, lang)))" }.joined(separator: ", ")
        }
        let cpuExtra: [String: String] = [
            "thermal": s.cpu.thermal.value.map { Format.thermal($0, lang) } ?? "?",
            "cpu_used": s.cpu.usedPct.map { Format.percent($0, lang) } ?? "?",
            "cpu_top": cpuTopText,
        ]
        var second: HeadlineTemplates.Template?
        if let th = s.cpu.thermal.value, th >= .serious {
            second = t.hot
            finalLevel = max(finalLevel, th == .critical ? .critical : .warn)
        } else if let used = s.cpu.usedPct, used >= Self.busyCPUPct {
            second = t.busy
        }
        if let second {
            text += " " + Format.fill(second.text.text(lang) ?? "", facts: [:], extra: cpuExtra, lang: lang)
            ids += second.glossaryIds.filter { !ids.contains($0) }
        }
        return Headline(level: finalLevel, text: text, glossaryIds: ids)
    }

    /// Whole-machine CPU use above which the headline says the CPU is busy.
    static let busyCPUPct: Double = 80
    /// Average CPU since start (% of one core). CPU time is from the second sample, so divide by the time up to that
    /// sample, not by the whole seconds at the scan start (QA 2026-10-27: a process 1 s old showed 197 %, then 252 %).
    static func averageCPU(_ p: RawProcess, _ scan: Scan) -> Double? {
        guard let ns = p.cpuTimeNs, let start = p.startDate else { return nil }
        let age = (scan.cpuSampledAt ?? scan.takenAt).timeIntervalSince(start)
        return age >= 1 ? Double(ns) / 1e9 / age * 100 : nil
    }

    /// A process this busy (% of one core) becomes an item whatever its size.
    static let significantCPUPct: Double = 50
    static let maxCPUTop = 5

    /// Biggest CPU users from every process of the scan, before the size cap (reviewer + QA 2026-10-27): top-level owners
    /// (an app with all its processes), programs without an owner grouped by name, and `system` for CPU the machine used
    /// that no readable process accounts for (other users' processes: WindowServer, kernel_task…). `nil` in fast mode.
    func cpuTop(scan: Scan, own: [Int32: ProcessOwnership], owners: [Owner]) -> [CPUUser]? {
        guard !scan.cpuNowPct.isEmpty || scan.cpu != nil else { return nil }
        let parent = Dictionary(uniqueKeysWithValues: owners.map { ($0.id, $0.parent.value) })
        let label = Dictionary(uniqueKeysWithValues: owners.map { ($0.id, $0.label) })
        func root(_ id: String) -> String {
            var id = id, seen: Set<String> = []
            while let p = parent[id] ?? nil, !seen.contains(p) { seen.insert(id); id = p }
            return id
        }
        var groups: [String: CPUUser] = [:]
        var readable = 0.0
        for (pid, pct) in scan.cpuNowPct where pid != scan.selfPid {
            readable += pct
            let key: String, name: String
            if let o = own[pid]?.ownerId { key = root(o); name = label[key] ?? key } else {
                // Same program in the same project: one line (`node — web-app (×3)`), not one per process.
                let exe = scan.processes[pid]?.exePath.map { ($0 as NSString).lastPathComponent } ?? "pid \(pid)"
                let project = own[pid]?.project
                key = "exe:" + exe + "|" + (project ?? ""); name = exe + (project.map { " — \($0)" } ?? "")
            }
            var g = groups[key] ?? CPUUser(id: key, label: name, pct: 0, count: 0)
            g.pct += pct; g.count += 1
            groups[key] = g
        }
        var rows = groups.values.map { g -> CPUUser in
            var g = g
            if g.id.hasPrefix("exe:"), g.count > 1 { g.label += " (×\(g.count))" }
            return g
        }
        if let idle = scan.cpu?.idle {
            let used = max(0, 100 - idle) / 100 * Double(scan.system.ncpu) * 100
            // hog's own scan (and the commands it ran) is not "system" (reviewer + QA 2026-10-27: ~35 points too high).
            let rest = used - readable - (scan.hogCpuPct ?? scan.cpuNowPct[scan.selfPid] ?? 0)
            if rest >= 1 {
                rows.append(CPUUser(id: "system", label: lang == .vi ? "macOS và dịch vụ hệ thống" : "macOS and system services", pct: rest, count: 0))
            }
        }
        return Array(rows.filter { $0.pct >= 1 }.sorted { ($0.pct, $0.id) > ($1.pct, $1.id) }.prefix(Self.maxCPUTop))
    }
}
