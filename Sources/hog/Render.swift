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

    // MARK: status (compact)

    /// `hog`: state and plain numbers, what to clean up, what is running by project. `all`: every group and process.
    func overview(_ o: Overview, all: Bool) -> String {
        var out: [String] = []
        let mark = switch o.status.tone { case .ok: green("●"); case .warn: yellow("◐"); case .critical: red("▲") }
        var head = mark + " " + bold(o.status.title)
        if let used = o.ramUsed, o.ramTotal > 0 { head += " · RAM " + Format.percent(Double(used) / Double(o.ramTotal) * 100, lang) }
        head += " · CPU " + (o.cpuUsed.map { Format.percent($0, lang) } ?? dim(t("chưa đo", "not measured")))
        if let sw = o.swapUsed { head += " · " + t("tràn ra ổ đĩa ", "swapped ") + bytes(sw) }
        if let th = o.thermal {
            let word = Format.thermal(th, lang)
            head += " · " + t("nhiệt ", "heat ") + (th >= .serious ? red(word) : (th == .fair ? yellow(word) : word))
        }
        out.append(head)
        // The line under the state says why it is not fine, or that there is nothing to do ("Nên dọn" says the rest).
        if !o.status.detail.isEmpty, o.cleanups.isEmpty || o.status.tone != .ok { out.append(dim(o.status.detail)) }

        if !o.cleanups.isEmpty {
            out.append("")
            out.append(bold(t("Nên dọn", "Clean up")) + dim(t(" (lấy lại \(bytes(o.reclaimable)))", " (frees \(bytes(o.reclaimable)))")))
            let nameW = min(22, o.cleanups.map(\.name.count).max() ?? 8) + 1
            let projW = min(16, o.cleanups.map { $0.project?.count ?? 0 }.max() ?? 0) + 1
            for c in o.cleanups {
                let why = switch c.whyKind { case .idle: yellow(pad(c.why, 13)); case .heavy: red(pad(c.why, 13)); case .broken: red(pad(c.why, 13)) }
                let how = (c.manual ? t("cách đóng: ", "how to close: ") : "") + "hog stop \(c.itemId)"
                out.append("  " + pad(trunc(c.name, nameW - 1), nameW) + dim(pad(trunc(c.project ?? "", projW - 1), projW)) + why
                           + padLeft(bytes(c.bytes), 8) + "   " + dim(how))
            }
        }

        out.append("")
        out.append(bold(pad(t("Đang chạy", "Running"), 36)) + dim(padLeft("RAM", 8) + padLeft("CPU", 7)))
        let readable = o.groups.filter { $0.kind != .system }
        let shown = all ? readable : Array(readable.prefix(Overview.mainGroups))
        for g in shown {
            let tag = g.kind == .project ? dim(t(" (dự án)", " (project)")) : ""
            let nameCol = trunc(g.name, 24) + tag
            let visible = trunc(g.name, 24).count + (g.kind == .project ? t(" (dự án)", " (project)").count : 0)
            out.append("  " + nameCol + String(repeating: " ", count: max(1, 34 - visible)) + padLeft(bytes(g.bytes), 8)
                       + padLeft(g.cpu.map { Format.percent($0, lang) } ?? "–", 7) + "   " + dim(trunc(g.summary, 40)))
            if all {
                for e in g.entries {
                    let label = trunc(e.name, 28) + (e.unknown ? yellow(" ?") : "") + (e.detail.isEmpty ? "" : dim(" · " + e.detail))
                    let visible = trunc(e.name, 28).count + (e.unknown ? 2 : 0) + (e.detail.isEmpty ? 0 : e.detail.count + 3)
                    out.append("      " + label + String(repeating: " ", count: max(1, 30 - visible)) + padLeft(bytes(e.bytes), 8)
                               + padLeft(e.cpu.map { Format.percent($0, lang) } ?? "–", 7)
                               + (e.pids.count > 1 ? dim("   ×\(e.pids.count)") : ""))
                }
            }
        }
        var tail: [String] = []
        if !all, readable.count > shown.count { tail.append(t("… \(readable.count - shown.count) nhóm khác", "… \(readable.count - shown.count) more groups")) }
        if let sys = o.groups.first(where: { $0.kind == .system }) {
            tail.append(t("macOS và hệ thống", "macOS and system") + (sys.cpu.map { " " + Format.percent($0, lang) + " CPU" } ?? "")
                        + t(" (\(sys.processCount) tiến trình hog không đọc được)", " (\(sys.processCount) processes hog cannot read)"))
        }
        if !tail.isEmpty { out.append("  " + dim(tail.joined(separator: " · "))) }

        // Unknown things among what is shown: how to ask about them.
        let unknowns = shown.flatMap { g in g.entries.filter(\.unknown).prefix(all ? 99 : 2).map { (g, $0) } }.prefix(all ? 99 : 3)
        out.append("")
        if !unknowns.isEmpty {
            out.append(dim(t("Chưa rõ: ", "Not known: ") + unknowns.map { g, e in "\(e.name) (\(g.name)) — hog explain \(e.itemId ?? String(e.pids[0])) --share" }
                .joined(separator: t("; ", "; "))))
        }
        // What could not be measured, so a missing table is never read as "nothing there".
        if !o.notes.isEmpty { out.append(yellow(t("Chưa đo được: ", "Not measured: ") + o.notes.joined(separator: " · "))) }
        out.append(dim(t("Chi tiết: hog explain <id> · Đầy đủ: hog --all · Cho Claude: hog --json",
                         "Details: hog explain <id> · Everything: hog --all · For Claude: hog --json")))
        return out.joined(separator: "\n")
    }

    func trunc(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(max(1, n - 1))) + "…" : s }

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
            out.append(verdictLabel(f.verdict) + dim("  (\(t("độ tin", "confidence")): \(Format.confidence(f.confidence, lang)); \(t("quy tắc", "rules")): \(f.rules.joined(separator: ", ")))"))
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
            let help = Presentation.factGlossary[k].map { dim("   ? hog explain \($0)") } ?? ""
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
