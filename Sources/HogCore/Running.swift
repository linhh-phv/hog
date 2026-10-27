import Foundation

/// What the compact menu and `hog` show (task ui-compact, docs/design/compact/screens.html): the machine's state in one
/// phrase, a few plain numbers, what to clean up, and what is running grouped by **project**. Built from a snapshot
/// analysed with `full: true` (every readable process), so the lists are complete.
public struct Overview: Sendable, Equatable {
    public enum Tone: String, Sendable, Equatable { case ok, warn, critical }

    /// "Máy ổn" / "Máy hơi nặng" / "Máy nặng" / "Máy nóng" and one line saying why or what to do.
    public struct Status: Sendable, Equatable {
        public var tone: Tone
        public var title: String
        public var detail: String
    }

    /// One line of "Nên dọn".
    public struct Cleanup: Sendable, Equatable, Identifiable {
        public var id: String { itemId }
        public var itemId: String
        public var name: String
        public var project: String?
        /// ≤ 3 words: "rảnh 3 giờ", "88 % CPU", "1,2 GB".
        public var why: String
        public var whyKind: WhyKind
        public var bytes: Int64?
        public var verdict: Verdict
        /// Only a person can close it (Claude session…): "Cách đóng", no check box.
        public var manual: Bool
        /// Checked at first: things hog would stop (may-stop) and that it can stop itself.
        public var preselected: Bool
    }
    public enum WhyKind: String, Sendable, Equatable { case idle, heavy, broken }

    /// One thing inside a group.
    public struct Entry: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        /// "cổng 3000", or empty.
        public var detail: String
        public var bytes: Int64?
        public var cpu: Double?
        public var pids: [Int32]
        public var itemId: String?
        /// Not in the catalog and not part of an app: hog does not know what it is ("?", copy info to ask).
        public var unknown: Bool
        public var cleanup: Cleanup?
    }

    public struct Group: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable, Equatable { case project, app, other, system }
        public var id: String
        public var kind: Kind
        public var name: String
        /// "VS Code, node, Claude" — the main parts, for the collapsed row.
        public var summary: String
        public var bytes: Int64
        public var cpu: Double?
        public var entries: [Entry]
        public var processCount: Int
    }

    public var status: Status
    public var ramUsed: Int64?
    public var ramTotal: Int64
    public var pressure: Pressure?
    public var cpuUsed: Double?
    public var swapUsed: Int64?
    public var compressed: Int64?
    public var thermal: ThermalState?
    public var cleanups: [Cleanup]
    /// Sum of RAM of the cleanups (what "Dọn" would give back).
    public var reclaimable: Int64
    public var groups: [Group]
    public var processCount: Int
    public var takenAt: Date
    public var selfBytes: Int64?

    /// Groups on the main page before "Tất cả N tiến trình".
    public static let mainGroups = 5
    static let portFamilies: Set<String> = ["dev-server", "bundler", "mobile-tooling", "container"]
    /// Apps below both go to "Other".
    static let smallAppBytes: Int64 = 100_000_000
    static let smallAppCPU: Double = 5

    public static func make(_ s: Snapshot, catalog: Catalog) -> Overview {
        let lang = s.lang
        func t(_ vi: String, _ en: String) -> String { lang == .vi ? vi : en }
        let items = Dictionary(uniqueKeysWithValues: s.items.map { ($0.id, $0) })
        let owners = Dictionary(uniqueKeysWithValues: s.owners.map { ($0.id, $0) })
        func root(_ id: String) -> Owner? {
            var o = owners[id], seen: Set<String> = []
            while let p = o?.parent.value, let next = owners[p], seen.insert(p).inserted { o = next }
            return o
        }
        func chain(_ id: String?) -> [Owner] {
            var out: [Owner] = [], cur = id.flatMap { owners[$0] }, seen: Set<String> = []
            while let o = cur, seen.insert(o.id).inserted { out.append(o); cur = o.parent.value.flatMap { owners[$0] } }
            return out
        }
        // A VS Code window without a known project (no `code --status` title) takes the project most of its processes
        // (Claude sessions, dev servers, terminals) work in.
        var votes: [String: [String: Int]] = [:]
        for p in s.processes {
            guard let project = p.project.value else { continue }
            for o in chain(p.ownerId.value) where o.kind == .vscodeWindow { votes[o.id, default: [:]][project, default: 0] += 1 }
        }
        let windowProject = votes.compactMapValues { $0.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key }
        func ownerProject(_ id: String?) -> String? {
            for o in chain(id) {
                if let p = o.project.value { return p }
                if o.kind == .vscodeWindow, let p = windowProject[o.id] { return p }
            }
            return nil
        }

        // Nên dọn: every may-stop / ask / watch finding, may-stop first, biggest first.
        let order: [Verdict] = [.mayStop, .ask, .watch]
        let procOfItem = Dictionary(s.processes.compactMap { p in p.itemId.value.map { ($0, p) } }, uniquingKeysWith: { a, _ in a })
        let cleanups = s.findings.filter { order.contains($0.verdict) }.compactMap { f -> Cleanup? in
            guard let item = items[f.itemId] else { return nil }
            let proc = procOfItem[f.itemId]
            let project = proc?.project.value ?? ownerProject(item.ownerId.value)
            let (why, kind) = shortReason(f, item, lang)
            let name = item.catalogId.value.flatMap { catalog.entries[$0]?.name.text(lang) } ?? proc?.exe.value ?? item.label
            return Cleanup(itemId: f.itemId, name: shortName(name), project: project, why: why, whyKind: kind, bytes: item.footprintBytes.value,
                           verdict: f.verdict, manual: f.stop.strategy == .manual, preselected: f.verdict == .mayStop && f.stop.strategy != .manual)
        }
        .sorted { a, b in
            let (ra, rb) = (order.firstIndex(of: a.verdict)!, order.firstIndex(of: b.verdict)!)
            return ra != rb ? ra < rb : (a.bytes ?? 0, a.itemId) > (b.bytes ?? 0, b.itemId)
        }
        let cleanupOf = Dictionary(uniqueKeysWithValues: cleanups.map { ($0.itemId, $0) })

        // Đang chạy: every readable process, grouped by project, else by app, else "other".
        var groups: [String: Group] = [:]
        var entriesByGroup: [String: [String: Entry]] = [:]
        for p in s.processes {
            let ownerRoot = p.ownerId.value.flatMap(root)
            let project = p.project.value ?? ownerProject(p.ownerId.value)
            let (gid, kind, gname): (String, Group.Kind, String) =
                if let project { ("project:" + project, .project, project) }
                else if let o = ownerRoot, o.kind == .app { (o.id, .app, o.label) }
                else { ("other", .other, t("Khác", "Other")) }
            var g = groups[gid] ?? Group(id: gid, kind: kind, name: gname, summary: "", bytes: 0, cpu: nil, entries: [], processCount: 0)
            g.bytes += p.footprintBytes.value ?? 0
            if let c = p.cpu.nowPct.value { g.cpu = (g.cpu ?? 0) + c }
            g.processCount += 1
            groups[gid] = g

            // One entry per suggested item (it has its own reason and action), else one per program name in the group
            // (`Google Chrome Helper (Renderer) ×12`): the list stays complete without repeating the same line.
            let item = p.itemId.value.flatMap { items[$0] }
            let catalogName = (p.catalogId.value ?? item?.catalogId.value).flatMap { catalog.entries[$0]?.name.text(lang) }.map(shortName)
            let name = catalogName ?? p.exe.value ?? "pid \(p.pid)"
            let eid = item.flatMap { cleanupOf[$0.id] != nil ? $0.id : nil } ?? "name:" + name
            // A port says what something is for a server (dev server, bundler, unknown program), not for an editor's
            // internal debug port.
            let family = (p.catalogId.value ?? item?.catalogId.value).flatMap { catalog.entries[$0]?.family }
            let port = catalogName == nil || Self.portFamilies.contains(family ?? "") ? p.net.listen.map(\.port).min() : nil
            var e = entriesByGroup[gid]?[eid] ?? Entry(
                id: eid, name: name,
                detail: port.map { t("cổng \($0)", "port \($0)") } ?? "", bytes: nil, cpu: nil, pids: [], itemId: item?.id,
                // Not in the catalog and not explained by an app (a Chrome helper is Chrome): something to ask about.
                unknown: catalogName == nil && kind != .app,
                cleanup: item.flatMap { cleanupOf[$0.id] })
            e.pids.append(p.pid)
            if let b = p.footprintBytes.value { e.bytes = (e.bytes ?? 0) + b }
            if let c = p.cpu.nowPct.value { e.cpu = (e.cpu ?? 0) + c }
            entriesByGroup[gid, default: [:]][eid] = e
        }
        // Small apps (Finder, Dock, menu bar helpers…) go to "Other" so the list stays about what matters.
        for (id, g) in groups where g.kind == .app && g.bytes < Self.smallAppBytes && (g.cpu ?? 0) < Self.smallAppCPU {
            var other = groups["other"] ?? Group(id: "other", kind: .other, name: t("Khác", "Other"), summary: "", bytes: 0, cpu: nil, entries: [], processCount: 0)
            other.bytes += g.bytes
            if let c = g.cpu { other.cpu = (other.cpu ?? 0) + c }
            other.processCount += g.processCount
            groups["other"] = other
            for (eid, e) in entriesByGroup[id] ?? [:] { entriesByGroup["other", default: [:]][eid] = e }
            groups[id] = nil
            entriesByGroup[id] = nil
        }
        var list = groups.values.map { g -> Group in
            var g = g
            g.entries = (entriesByGroup[g.id] ?? [:]).values.sorted { ($0.bytes ?? 0, $0.id) > ($1.bytes ?? 0, $1.id) }
            let names = g.entries.map(\.name).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            g.summary = g.kind == .project ? names.prefix(3).joined(separator: ", ")
                : (lang == .vi ? "\(g.processCount) tiến trình" : "\(g.processCount) processes")
            return g
        }
        // "Other" last among the readable groups, whatever its size; system at the very end.
        list.sort { a, b in
            if (a.kind == .other) != (b.kind == .other) { return b.kind == .other }
            return (a.bytes, a.id) > (b.bytes, b.id)
        }
        let systemCPU = s.cpu.top.value?.first { $0.id == "system" }?.pct
        if s.memory.unreadableProcessCount > 0 || systemCPU != nil {
            list.append(Group(id: "system", kind: .system, name: t("macOS và hệ thống", "macOS and system"),
                              summary: t("hog không đọc được từng tiến trình", "hog cannot read each process"),
                              bytes: 0, cpu: systemCPU, entries: [], processCount: s.memory.unreadableProcessCount))
        }

        let reclaimable = cleanups.compactMap(\.bytes).reduce(0, +)
        return Overview(status: status(s, cleanups: cleanups, reclaimable: reclaimable, groups: list),
                        ramUsed: s.memory.usedBytes.value, ramTotal: s.host.memTotalBytes, pressure: s.memory.pressure.value,
                        cpuUsed: s.cpu.usedPct, swapUsed: s.memory.swapUsedBytes.value, compressed: s.memory.compressedStoredBytes.value,
                        thermal: s.cpu.thermal.value, cleanups: cleanups, reclaimable: reclaimable, groups: list,
                        processCount: s.processes.count + s.memory.unreadableProcessCount, takenAt: s.takenAt,
                        selfBytes: s.hog.selfFootprintBytes.value)
    }

    /// The worst of memory pressure, heat and CPU, as one phrase plus a line.
    static func status(_ s: Snapshot, cleanups: [Cleanup], reclaimable: Int64, groups: [Group]) -> Status {
        let lang = s.lang
        func t(_ vi: String, _ en: String) -> String { lang == .vi ? vi : en }
        let pressure = s.memory.pressure.value
        let thermal = s.cpu.thermal.value ?? .nominal
        let busy = (s.cpu.usedPct ?? 0) >= Analyzer.busyCPUPct
        let topCPU = groups.filter { $0.kind != .system }.max { ($0.cpu ?? 0) < ($1.cpu ?? 0) }
        let cpuHint = topCPU.flatMap { g in (g.cpu ?? 0) >= 50 ? t("\(g.name) ăn CPU nhất", "\(g.name) uses the most CPU") : nil }
        var reasons: [String] = []
        if pressure == .critical || pressure == .warn { reasons.append(t("thiếu RAM", "short of memory")) }
        if thermal >= .serious { reasons.append(t("đang nóng", "running hot")) }
        if busy { reasons.append(t("CPU bận", "CPU busy")) }
        let why = (reasons.isEmpty ? [] : [reasons.joined(separator: t(" và ", " and ")).capitalizedFirst]) + (cpuHint.map { [$0] } ?? [])
        let todo = cleanups.isEmpty ? t("Không có gì cần dọn", "Nothing to clean up")
            : t("\(cleanups.count) thứ nên dọn · lấy lại \(Format.bytes(reclaimable, lang))",
                "\(cleanups.count) to clean up · frees \(Format.bytes(reclaimable, lang))")
        if pressure == .critical || thermal == .critical {
            return Status(tone: .critical, title: t("Máy nặng", "Machine struggling"), detail: why.joined(separator: " · "))
        }
        if pressure == .warn {
            return Status(tone: .warn, title: t("Máy hơi nặng", "Machine under strain"), detail: why.joined(separator: " · "))
        }
        if thermal >= .serious {
            return Status(tone: .warn, title: t("Máy nóng", "Machine hot"), detail: why.joined(separator: " · "))
        }
        if busy {
            return Status(tone: .ok, title: t("Máy ổn, CPU bận", "Fine, CPU busy"), detail: cpuHint ?? todo)
        }
        if pressure == nil {
            return Status(tone: .warn, title: t("Chưa đo được RAM", "Memory not measured"), detail: todo)
        }
        return Status(tone: .ok, title: t("Máy ổn", "Machine fine"), detail: todo)
    }

    /// ≤ 3 words: why this is suggested.
    static func shortReason(_ f: Finding, _ item: Item, _ lang: Lang) -> (String, WhyKind) {
        func t(_ vi: String, _ en: String) -> String { lang == .vi ? vi : en }
        func fact(_ k: String) -> Double? {
            switch item.facts[k] ?? f.evidence[k] {
            case .int(let i)?: Double(i)
            case .double(let d)?: d
            default: nil
            }
        }
        let rules = Set(f.rules)
        if rules.contains("cpu-heavy"), let c = fact("cpu.now_pct") { return ("\(Format.percent(c, lang)) CPU", .heavy) }
        if rules.contains("container-crash-loop") { return (t("lỗi lặp lại", "crash loop"), .broken) }
        if rules.contains("container-restart-high") { return (t("khởi động lại nhiều", "restarts a lot"), .broken) }
        if rules.contains("container-no-clients") { return (t("không ai dùng", "unused"), .idle) }
        if rules.contains("duplicate-language-server") { return (t("trùng cửa sổ khác", "duplicate"), .heavy) }
        if rules.contains("claude-session-abandoned"), let idle = fact("session.idle_s") {
            return (t("rảnh ", "idle ") + Format.duration(Int64(idle), lang), .idle)
        }
        if let age = fact("age_s"), !rules.contains("memory-heavy") || rules.count > 1 {
            return (t("rảnh ", "idle ") + Format.duration(Int64(age), lang), .idle)
        }
        if let b = item.footprintBytes.value { return (Format.bytes(b, lang), .heavy) }
        return (t("nên xem", "check"), .heavy)
    }

    /// Catalog names can be long ("Cửa sổ VS Code (phần vẽ)"): drop the part in brackets.
    static func shortName(_ s: String) -> String {
        guard let i = s.firstIndex(of: "("), i != s.startIndex else { return s }
        return s[..<i].trimmingCharacters(in: .whitespaces)
    }

}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
