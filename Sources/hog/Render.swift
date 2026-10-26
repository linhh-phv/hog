import Darwin
import Foundation
import HogCore

/// Terminal output: plain words first, numbers second (design section 5).
struct Render {
    var lang: Lang
    var color: Bool

    init(lang: Lang, noColor: Bool) {
        self.lang = lang
        self.color = !noColor && isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    }

    func t(_ vi: String, _ en: String) -> String { lang == .vi ? vi : en }

    func paint(_ s: String, _ code: String) -> String { color ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    func bold(_ s: String) -> String { paint(s, "1") }
    func dim(_ s: String) -> String { paint(s, "2") }
    func red(_ s: String) -> String { paint(s, "31") }
    func yellow(_ s: String) -> String { paint(s, "33") }
    func green(_ s: String) -> String { paint(s, "32") }
    func cyan(_ s: String) -> String { paint(s, "36") }

    func bytes(_ b: Int64?) -> String { b.map { Format.bytes($0, lang) } ?? "?" }

    func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
    func padLeft(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }

    func pressure(_ p: Pressure?) -> String {
        switch p {
        case .normal?: green("● " + t("bình thường", "normal"))
        case .warn?: yellow("● " + t("cảnh báo", "warning"))
        case .critical?: red("● " + t("nghiêm trọng", "critical"))
        case nil: dim("? " + t("chưa đo", "not measured"))
        }
    }

    func verdictLabel(_ v: Verdict) -> String {
        switch v {
        case .mayStop: red("● " + t("có thể tắt", "can stop"))
        case .ask: yellow("◐ " + t("hỏi trước", "ask first"))
        case .watch: cyan("○ " + t("để ý", "watch"))
        case .info: dim("· " + t("thông tin", "info"))
        }
    }

    // MARK: status

    func status(_ s: Snapshot) -> String {
        var out: [String] = []
        out.append(bold(s.headline.text))
        out.append("")
        let m = s.memory
        var memLine = t("Áp lực bộ nhớ ", "Memory pressure ") + pressure(m.pressure.value)
        memLine += "   RAM \(bytes(s.host.memTotalBytes))"
        if let st = m.compressedStoredBytes.value, let oc = m.compressorBytes.value {
            memLine += " · " + t("đã nén \(bytes(st)) (chiếm \(bytes(oc)))", "compressed \(bytes(st)) (taking \(bytes(oc)))")
        }
        if let su = m.swapUsedBytes.value {
            memLine += " · " + t("đẩy ra ổ đĩa", "swapped") + " \(bytes(su))" + (m.swapTotalBytes.value.map { " / \(bytes($0))" } ?? "")
        }
        out.append(memLine)
        var cpuLine = "CPU "
        if let idle = s.cpu.idlePct.value { cpuLine += Format.percent(100 - idle, lang) } else { cpuLine += dim(t("chưa đo (--fast)", "not measured (--fast)")) }
        if let l = s.cpu.load.value, l.count == 3 { cpuLine += " · " + t("tải", "load") + " " + l.map { Format.number($0, 1, lang) }.joined(separator: " / ") }
        out.append(cpuLine)

        out.append("")
        out.append(bold(t("Đang ăn nhiều nhất", "Biggest")))
        for line in biggest(s) { out.append(line) }

        let actionable = s.findings.filter { $0.verdict == .mayStop || $0.verdict == .ask }
        let watch = s.findings.filter { $0.verdict == .watch }
        let info = s.findings.filter { $0.verdict == .info }
        out.append("")
        out.append(bold(t("Đề xuất", "Suggestions")))
        if actionable.isEmpty && watch.isEmpty { out.append("  " + dim(t("Không có gì cần tắt.", "Nothing to stop."))) }
        for f in actionable + watch.prefix(5) { out += finding(f, s) }
        if !info.isEmpty {
            out.append("  " + dim(t("+ \(info.count) thông tin khác (hog --json để xem đủ)", "+ \(info.count) more info items (hog --json for all)")))
        }
        let notes = s.sensors.filter { $0.status != .ok && $0.status != .skipped }
        if !notes.isEmpty {
            out.append("")
            out.append(dim(t("Chưa đo được: ", "Not measured: ") + notes.map { "\($0.name) (\($0.note.value ?? $0.status.rawValue))" }.joined(separator: "; ")))
        }
        if !s.warnings.isEmpty { out.append(yellow(t("Cảnh báo dữ liệu: ", "Data warnings: ") + s.warnings.joined(separator: "; "))) }
        return out.joined(separator: "\n")
    }

    func biggest(_ s: Snapshot) -> [String] {
        var rows: [(String, Int64, [String])] = []
        for o in s.owners where o.parent.value == nil {
            let children = s.owners.filter { $0.parent.value == o.id }.sorted { $0.totalFootprintBytes > $1.totalFootprintBytes }
            rows.append((o.label, o.totalFootprintBytes, children.prefix(3).map {
                "          " + padLeft(bytes($0.totalFootprintBytes), 7) + "  " + dim($0.label)
            }))
        }
        for i in s.items where i.ownerId.value == nil {
            if let b = i.footprintBytes.value { rows.append((i.label, b, [])) }
        }
        rows.sort { $0.1 > $1.1 }
        var out: [String] = []
        for r in rows.prefix(8) {
            out.append("  " + padLeft(bytes(r.1), 7) + "  " + r.0)
            out += r.2
        }
        if s.memory.unreadableProcessCount > 0 {
            out.append("  " + padLeft("…", 7) + "  " + t("macOS và dịch vụ hệ thống — \(s.memory.unreadableProcessCount) tiến trình chưa đo",
                                                         "macOS and system services — \(s.memory.unreadableProcessCount) processes not measured")
                       + dim("  (hog explain system)"))
        }
        return out
    }

    func finding(_ f: Finding, _ s: Snapshot) -> [String] {
        let item = s.items.first { $0.id == f.itemId }
        var head = "  " + verdictLabel(f.verdict) + "  " + (item?.label ?? f.itemId)
        if let b = item?.footprintBytes.value { head += dim(" · \(bytes(b))") }
        var lines = [head, "      " + f.reason]
        if f.verdict == .mayStop || f.verdict == .ask {
            let how = f.stop.strategy == .manual ? t("cách làm", "how") : t("dừng", "stop")
            lines.append("      " + dim("→ \(how): hog stop \(f.itemId)   ·   " + t("vì sao", "why") + ": hog explain \(f.itemId)"))
        }
        return lines
    }

    // MARK: explain

    func explainItem(_ item: Item, _ s: Snapshot, catalog: Catalog, plan: StopPlan?) -> String {
        var out = [bold(item.label) + dim("  (\(item.id))")]
        if let cid = item.catalogId.value, let e = catalog.entries[cid] {
            out.append(e.summary.text(lang) ?? "")
            out.append(t("Tắt thì sao: ", "If stopped: ") + (e.stopEffect.text(lang) ?? ""))
            if !e.provenance.verified { out.append(yellow("⚠ " + t("mục danh mục chưa kiểm trên máy thật", "catalog entry not verified on a real machine"))) }
        } else {
            out.append(dim(t("Chưa có trong danh mục.", "Not in the catalog yet.")))
        }
        if let o = item.ownerId.value, let owner = s.owners.first(where: { $0.id == o }) { out.append(t("Chủ sở hữu: ", "Owner: ") + owner.label) }
        if let f = s.findings.first(where: { $0.itemId == item.id }) {
            out.append("")
            out.append(verdictLabel(f.verdict) + dim("  (\(t("độ tin", "confidence")): \(f.confidence.rawValue); \(t("quy tắc", "rules")): \(f.rules.joined(separator: ", ")))"))
            out.append("  " + f.reason)
            if !f.unmeasured.isEmpty { out.append("  " + dim(t("Chưa đo: ", "Not measured: ") + f.unmeasured.joined(separator: ", "))) }
        }
        if let p = item.protection.value {
            out.append(yellow(t("Được bảo vệ (\(p.level.rawValue)): ", "Protected (\(p.level.rawValue)): ") + p.rules.joined(separator: ", ")))
        }
        out.append("")
        out.append(bold(t("Số đo", "Measurements")))
        for (k, v) in item.facts.sorted(by: { $0.key < $1.key }) {
            let value = v.isNull ? dim(Format.fact(k, v, lang)) : Format.fact(k, v, lang)
            let help = MenuSummary.factGlossary[k].map { dim("   ? hog explain \($0)") } ?? ""
            out.append("  " + pad(k, 36) + value + help)
        }
        if let plan {
            out.append("")
            out.append(bold(t("Nếu dừng", "If stopped")))
            out += planLines(plan)
        }
        return out.joined(separator: "\n")
    }

    func glossary(_ e: GlossaryEntry) -> String {
        var out = [bold(e.name.text(lang) ?? e.id)]
        if let am = e.activityMonitor {
            out.append(dim("Activity Monitor: \(am)" + (e.provenance.verified ? "" : t(" (chưa đối chiếu)", " (not checked yet)"))))
        }
        out.append(e.plain.text(lang) ?? "")
        out.append(t("Đọc thế nào: ", "How to read it: ") + (e.howToRead.text(lang) ?? ""))
        out.append(t("Nên làm gì: ", "What to do: ") + (e.act.text(lang) ?? ""))
        return out.joined(separator: "\n")
    }

    func systemDetail(_ rows: [SystemDetail.Row], measured: Int) -> String {
        var out = [bold(t("macOS và dịch vụ hệ thống", "macOS and system services")) + dim("  (top, \(measured) " + t("tiến trình", "processes") + ")")]
        out.append(dim("  " + padLeft("RAM", 9) + "  " + padLeft(t("nén", "cmprs"), 9) + "  " + padLeft("CPU", 7) + "  " + t("tiến trình", "process")))
        for r in rows.prefix(20) {
            out.append("  " + padLeft(bytes(r.memBytes), 9) + "  " + padLeft(bytes(r.compressedBytes), 9) + "  "
                       + padLeft(r.cpuPct.map { Format.percent($0, lang) } ?? "?", 7) + "  " + r.command + dim("  pid \(r.pid)"))
        }
        out.append(dim(t("hog không dừng tiến trình hệ thống.", "hog never stops system processes.")))
        return out.joined(separator: "\n")
    }

    // MARK: stop

    func planLines(_ p: StopPlan) -> [String] {
        var out: [String] = []
        out.append("  " + bold(p.label) + (p.ownerLabel.map { dim("  — " + t("chủ", "owner") + ": \($0)") } ?? ""))
        if let r = p.reason { out.append("  " + r) }
        out.append("  " + t("Tắt thì sao: ", "If stopped: ") + p.effect)
        for step in p.steps { out.append("  → " + step) }
        for g in p.gates {
            let mark = switch g.result {
            case .pass: green("✓")
            case .confirm: yellow("?")
            case .block: red("✗")
            }
            out.append("    \(mark) \(g.gate) " + dim(g.reason))
        }
        return out
    }

    // MARK: ports (lps view)

    func ports(_ rows: [PortsReport.Row], orphansOnly: Bool) -> String {
        if rows.isEmpty {
            return orphansOnly ? green("  " + t("Không có tiến trình mồ côi nào đang nghe cổng.", "No orphan services running."))
                : dim("  " + t("Không có gì đang nghe cổng.", "No services listening."))
        }
        func trunc(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }
        var out = [bold(pad("PID", 7) + " " + pad("PORT", 7) + " " + pad("COMMAND", 32) + " " + pad("PROJECT", 22) + " CWD")]
        out.append(dim(String(repeating: "-", count: 100)))
        for r in rows {
            let port = r.orphan ? yellow(pad(String(r.port), 7)) : (r.system ? dim(pad(String(r.port), 7)) : green(pad(String(r.port), 7)))
            out.append(pad(String(r.pid), 7) + " " + port + " " + pad(trunc(r.command, 32), 32) + " " + cyan(pad(trunc(r.project, 22), 22))
                       + " " + dim(r.cwd) + (r.orphan ? " " + red("[orphan]") : ""))
        }
        return out.joined(separator: "\n")
    }
}
