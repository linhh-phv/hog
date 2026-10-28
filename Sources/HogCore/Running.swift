import Foundation

/// What the compact menu and `hog` show (docs/design/compact/screens.html): the machine's state in one
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

    /// Whether stopping a thing makes sense, from what hog already concluded about it — never a new guess (user 2026-10-27:
    /// "những tiến trình con bên trong có thể thêm nhãn để biết cái nào an toàn có thể tắt"). A line of several processes takes
    /// the strongest; `nil` (no label) when hog has no conclusion, e.g. a small process it does not analyse.
    public enum Safety: Int, Sendable, Comparable {
        /// A pre-checked "Nên dọn" suggestion: measured unused, hog can stop it. Decided before `restarts` (see `safety`),
        /// never combined with protection (a protected thing is not may-stop).
        case canStop = 1
        /// Soft protection: part of a Claude session, window or app in use.
        case inUse = 2
        /// The catalog says its parent starts it again at once: stopping gives nothing back, in use or not (a language server
        /// of a busy window says this rather than "in use").
        case restarts = 3
        /// Hard protection: hog itself, what runs hog, macOS or another user.
        case keep = 4
        public static func < (a: Safety, b: Safety) -> Bool { a.rawValue < b.rawValue }
    }

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
        /// What it is, in one sentence of the catalog ("Vẽ đồ hoạ bằng GPU cho mọi cửa sổ VS Code."); nil when hog does not know.
        public var summary: String? = nil
        public var safety: Safety? = nil
        /// What stopping it does, from the catalog; nil when hog does not know (the page then says so).
        public var stopEffect: String? = nil
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
        /// The app bundle of an app group (`/Applications/Google Chrome.app`, `~` for home), for its icon.
        public var appPath: String? = nil
    }

    public var status: Status
    public var ramUsed: Int64?
    public var ramTotal: Int64
    public var pressure: Pressure?
    public var cpuUsed: Double?
    public var swapUsed: Int64?
    public var compressed: Int64?
    public var thermal: ThermalState?
    /// Degrees and fans (SMC); every value may be unmeasured.
    public var heat: HeatInfo
    public var cleanups: [Cleanup]
    /// Sum of RAM of the cleanups (what "Dọn" would give back).
    public var reclaimable: Int64
    public var groups: [Group]
    public var processCount: Int
    public var takenAt: Date
    public var selfBytes: Int64?
    /// Sensors that could not measure, in words ("Docker — the engine is stopped"), and data-file warnings.
    public var notes: [String]

    /// Groups on the main page before "Tất cả N tiến trình".
    public static let mainGroups = 5
    static let portFamilies: Set<String> = ["dev-server", "bundler", "mobile-tooling", "container"]
    /// Apps below both go to "Other".
    static let smallAppBytes: Int64 = 100_000_000
    static let smallAppCPU: Double = 5
    /// A group or line using at least this share of the whole machine's CPU is shown in red.
    public static let heavyCPU: Double = 50

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

        // Nên dọn: every may-stop / ask / watch finding, may-stop first, biggest first. Not what its parent starts again at once
        // (VS Code's GPU process): stopping it gives nothing back, whatever it holds (user 2026-10-27, a "dormant-large" GPU
        // process in the list with no reason to act on).
        let order: [Verdict] = [.mayStop, .ask, .watch]
        let procOfItem = Dictionary(s.processes.compactMap { p in p.itemId.value.map { ($0, p) } }, uniquingKeysWith: { a, _ in a })
        func givesBack(_ f: Finding) -> Bool { f.verdict == .mayStop || f.stop.respawns.value != .byParent }
        let cleanups = s.findings.filter { order.contains($0.verdict) && givesBack($0) }.compactMap { f -> Cleanup? in
            guard let item = items[f.itemId] else { return nil }
            let proc = procOfItem[f.itemId]
            let project = proc?.project.value ?? ownerProject(item.ownerId.value)
            let (why, kind) = shortReason(f, item, lang, cores: Double(max(1, s.host.ncpu)))
            let name = item.catalogId.value.flatMap { catalog.entries[$0]?.name.text(lang) } ?? proc?.exe.value ?? item.label
            return Cleanup(itemId: f.itemId, name: shortName(name), project: project, why: why, whyKind: kind, bytes: item.footprintBytes.value,
                           verdict: f.verdict, manual: f.stop.strategy == .manual, preselected: f.verdict == .mayStop && f.stop.strategy != .manual)
        }
        .sorted { a, b in
            let (ra, rb) = (order.firstIndex(of: a.verdict)!, order.firstIndex(of: b.verdict)!)
            return ra != rb ? ra < rb : (a.bytes ?? 0, a.itemId) > (b.bytes ?? 0, b.itemId)
        }
        let cleanupOf = Dictionary(uniqueKeysWithValues: cleanups.map { ($0.itemId, $0) })
        func safety(_ item: Item?, catalogId: String?) -> Safety? {
            if item?.protection.value?.level == .hard { return .keep }
            // A may-stop suggestion wins over its catalog's `by-parent`: an orphaned language server has no parent left to start
            // it again (reviewer 2026-10-28), and "Nên dọn" (`givesBack`) already lets may-stop through. Things only a person
            // closes (`manual`, as every by-parent catalog entry is) get no label: their row shows the reason instead.
            if let c = item.flatMap({ cleanupOf[$0.id] }), c.verdict == .mayStop { return c.preselected ? .canStop : nil }
            if catalogId.flatMap({ catalog.entries[$0]?.respawns }) == .byParent { return .restarts }
            if item?.protection.value?.level == .soft { return .inUse }
            return nil
        }

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
            if kind == .app, g.appPath == nil, let path = p.exePath.value { g.appPath = Ownership.appBundle(path) }
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
                unknown: catalogName == nil && kind != .app && Self.isUnknownProgram(p),
                cleanup: item.flatMap { cleanupOf[$0.id] },
                summary: (p.catalogId.value ?? item?.catalogId.value).flatMap { catalog.entries[$0]?.summary.text(lang) },
                stopEffect: (p.catalogId.value ?? item?.catalogId.value).flatMap { catalog.entries[$0]?.stopEffect.text(lang) })
            e.pids.append(p.pid)
            if let s = safety(item, catalogId: p.catalogId.value ?? item?.catalogId.value) { e.safety = max(e.safety ?? s, s) }
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
            for (eid, e) in entriesByGroup[id] ?? [:] {
                // Same name already in Other (two small apps' helpers): add up, never drop a process.
                if var have = entriesByGroup["other"]?[eid] {
                    have.pids += e.pids
                    if let s = e.safety { have.safety = max(have.safety ?? s, s) }
                    if let b = e.bytes { have.bytes = (have.bytes ?? 0) + b }
                    if let c = e.cpu { have.cpu = (have.cpu ?? 0) + c }
                    entriesByGroup["other"]?[eid] = have
                } else {
                    entriesByGroup["other", default: [:]][eid] = e
                }
            }
            groups[id] = nil
            entriesByGroup[id] = nil
        }
        var list = groups.values.map { g -> Group in
            var g = g
            g.entries = (entriesByGroup[g.id] ?? [:]).values.sorted { ($0.bytes ?? 0, $0.id) > ($1.bytes ?? 0, $1.id) }
            // Under "Google Chrome", "Helper (Renderer)" says it all; cut at the end of a narrow row, the full name kept only
            // "Google Chrome Helper (…" and two different helpers looked the same (QA 2026-10-27).
            if g.kind == .app {
                g.entries = g.entries.map { e in
                    var e = e
                    if e.name.hasPrefix(g.name + " ") { e.name = String(e.name.dropFirst(g.name.count + 1)).capitalizedFirst }
                    return e
                }
            }
            let names = g.entries.map(\.name).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            g.summary = g.kind == .project ? names.prefix(3).joined(separator: ", ")
                : (lang == .vi ? "\(g.processCount) tiến trình" : g.processCount == 1 ? "1 process" : "\(g.processCount) processes")
            return g
        }
        // "Other" last among the readable groups, whatever its size; system at the very end.
        list.sort { a, b in
            if (a.kind == .other) != (b.kind == .other) { return b.kind == .other }
            return (a.bytes, a.id) > (b.bytes, b.id)
        }
        // CPU as a share of the whole machine everywhere, so the lines add up to "CPU đang bận" (QA 2026-10-27: per-core
        // values above 100 % next to a whole-machine percentage confused).
        let cores = Double(max(1, s.host.ncpu))
        list = list.map { g in
            var g = g
            g.cpu = g.cpu.map { $0 / cores }
            g.entries = g.entries.map { e in var e = e; e.cpu = e.cpu.map { $0 / cores }; return e }
            return g
        }
        let systemCPU = (s.cpu.top.value?.first { $0.id == "system" }?.pct).map { $0 / cores }
        if s.memory.unreadableProcessCount > 0 || systemCPU != nil {
            list.append(Group(id: "system", kind: .system, name: t("macOS và hệ thống", "macOS and system"),
                              summary: t("hog không đọc được từng tiến trình", "hog cannot read each process"),
                              bytes: 0, cpu: systemCPU, entries: [], processCount: s.memory.unreadableProcessCount))
        }

        let reclaimable = cleanups.compactMap(\.bytes).reduce(0, +)
        return Overview(status: status(s, cleanups: cleanups, reclaimable: reclaimable, groups: list),
                        ramUsed: s.memory.usedBytes.value, ramTotal: s.host.memTotalBytes, pressure: s.memory.pressure.value,
                        cpuUsed: s.cpu.usedPct, swapUsed: s.memory.swapUsedBytes.value, compressed: s.memory.compressedStoredBytes.value,
                        thermal: s.cpu.thermal.value, heat: s.heat, cleanups: cleanups, reclaimable: reclaimable, groups: list,
                        processCount: s.processes.count + s.memory.unreadableProcessCount, takenAt: s.takenAt,
                        selfBytes: s.hog.selfFootprintBytes.value, notes: notes(s))
    }

    /// The worst of memory pressure, heat and CPU, as one phrase plus a line.
    static func status(_ s: Snapshot, cleanups: [Cleanup], reclaimable: Int64, groups: [Group]) -> Status {
        let lang = s.lang
        func t(_ vi: String, _ en: String) -> String { lang == .vi ? vi : en }
        let pressure = s.memory.pressure.value
        let thermal = s.cpu.thermal.value ?? .nominal
        let busy = (s.cpu.usedPct ?? 0) >= Analyzer.busyCPUPct
        let topCPU = groups.filter { $0.kind != .system }.max { ($0.cpu ?? 0) < ($1.cpu ?? 0) }
        let cpuHint = topCPU.flatMap { g in (g.cpu ?? 0) >= 10 ? t("\(g.name) ăn CPU nhất", "\(g.name) uses the most CPU") : nil }
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
    static func shortReason(_ f: Finding, _ item: Item, _ lang: Lang, cores: Double) -> (String, WhyKind) {
        func t(_ vi: String, _ en: String) -> String { lang == .vi ? vi : en }
        func fact(_ k: String) -> Double? {
            switch item.facts[k] ?? f.evidence[k] {
            case .int(let i)?: Double(i)
            case .double(let d)?: d
            default: nil
            }
        }
        let rules = Set(f.rules)
        if rules.contains("cpu-heavy"), let c = fact("cpu.now_pct") { return ("\(Format.percent(c / cores, lang)) CPU", .heavy) }
        if rules.contains("container-crash-loop") { return (t("lỗi lặp lại", "crash loop"), .broken) }
        if rules.contains("container-restart-high") { return (t("hay bị sập", "keeps crashing"), .broken) }
        if rules.contains("container-no-clients") { return (t("không ai dùng", "unused"), .idle) }
        if rules.contains("duplicate-language-server") { return (t("bị trùng", "duplicate"), .heavy) }
        if rules.contains("claude-session-abandoned"), let idle = fact("session.idle_s") {
            return (t("rảnh ", "idle ") + Format.duration(Int64(idle), lang), .idle)
        }
        if let age = fact("age_s"), !rules.contains("memory-heavy") || rules.count > 1 {
            return (t("rảnh ", "idle ") + Format.duration(Int64(age), lang), .idle)
        }
        if let b = item.footprintBytes.value { return (Format.bytes(b, lang), .heavy) }
        return (t("nên xem", "check"), .heavy)
    }

    /// A program hog has no entry for and nothing else explains: not inside an app bundle (a Chrome helper is Chrome),
    /// not a macOS or system tool, and big enough to matter. Those get "?" and "copy info" (reviewer 2026-10-27: the first
    /// rule marked 244 lines, every small macOS daemon included).
    static func isUnknownProgram(_ p: ProcessRecord) -> Bool {
        guard (p.footprintBytes.value ?? 0) >= unknownMinBytes, !Presentation.justStarted(p.ageS.value) else { return false }
        let path = p.exePath.value
        return path.flatMap(Ownership.appBundle) == nil && Ownership.isSystemExecutable(path) != true
    }
    static let unknownMinBytes: Int64 = 20_000_000

    /// Sensors that could not measure, and data-file warnings, in words.
    static func notes(_ s: Snapshot) -> [String] {
        func t(_ vi: String, _ en: String) -> String { s.lang == .vi ? vi : en }
        let sensors = s.sensors.filter { $0.status == .unavailable || $0.status == .error }.map { st -> String in
            switch (st.name, st.status) {
            case ("docker", .unavailable): t("Docker — engine đang tắt (không phải lỗi).", "Docker — the engine is stopped (not an error).")
            case ("watchman", .unavailable): t("watchman — không có server nào đang chạy.", "watchman — no server running.")
            case ("vscode", .unavailable) where st.note.value?.contains("timed out") == true:
                t("VS Code — không trả lời lần trước; khởi động lại VS Code để hog chia được theo cửa sổ.",
                  "VS Code — did not answer last time; restart VS Code so hog can split by window.")
            case ("vscode", .unavailable): t("VS Code — không tìm thấy lệnh `code`.", "VS Code — the `code` command was not found.")
            default: "\(st.name) — \(st.note.value ?? st.status.rawValue)"
            }
        }
        return sensors + s.warnings.map { t("Dữ liệu: ", "Data: ") + $0 }
    }

    /// Catalog names can be long ("Cửa sổ VS Code (phần vẽ)"): drop the part in brackets.
    static func shortName(_ s: String) -> String {
        guard let i = s.firstIndex(of: "("), i != s.startIndex else { return s }
        return s[..<i].trimmingCharacters(in: .whitespaces)
    }

}

extension String {
    public var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
