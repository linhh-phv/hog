import Darwin
import Foundation
import HogCore

struct CLI {
    var args: Args
    var r: Render
    var out: (String) -> Void = { print($0) }
    var err: (String) -> Void = { fflush(stdout); FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    init(_ args: Args) {
        self.args = args
        self.r = Render(lang: args.lang, noColor: args.noColor)
    }

    func t(_ vi: String, _ en: String) -> String { r.t(vi, en) }

    func run() -> Exit {
        switch args.command {
        case "status", "ls": return status()
        case "explain": return explain()
        case "ports": return ports(orphansOnly: false)
        case "orphans": return ports(orphansOnly: true)
        case "stop": return stop()
        case "catalog": return catalog()
        case "rules": return rules()
        case "version":
            out("hog \(Hog.version)")
            out("data: " + (DataSource.resourcePath.map { Privacy.scrubPath($0) } ?? "?"))
            return .ok
        case "help": out(help()); return .ok
        case "kill":
            err(t("`kill` đã bỏ: dùng `hog stop <cổng|pid>` (luôn qua cổng an toàn, không tự SIGKILL).",
                  "`kill` was removed: use `hog stop <port|pid>` (always through the safety gates, never an automatic SIGKILL)."))
            return .usage
        default:
            err(t("Lệnh lạ: \(args.command). Xem `hog help`.", "Unknown command: \(args.command). See `hog help`."))
            return .usage
        }
    }

    func world(fast: Bool? = nil) -> (Scan, Snapshot) {
        let scan = Scanner(fast: fast ?? args.fast).scan()
        return (scan, Analyzer.standard(lang: args.lang, full: args.full).analyze(scan))
    }

    // MARK: status / json

    func status() -> Exit {
        let (_, snapshot) = world()
        if args.json {
            // Compact by default: this goes into Claude's context (design 4: ≤ 100 KB). --pretty for people.
            guard let data = try? SnapshotJSON.encode(args.brief ? SnapshotJSON.brief(snapshot) : snapshot, pretty: args.pretty) else { return .error }
            out(String(decoding: data, as: UTF8.self))
        } else {
            out(r.status(snapshot))
        }
        return .ok
    }

    // MARK: explain

    func explain() -> Exit {
        guard let target = args.positional.first else {
            err(t("Cần đích: `hog explain <item-id | pid | cổng | thuật ngữ | system>`.", "Needs a target: `hog explain <item-id | pid | port | term | system>`."))
            return .usage
        }
        let explanations = Explanations.load(.standard("explain"))
        if let g = explanations.glossary[target] { out(r.glossary(g)); return .ok }
        if target == "system" { return systemDetail() }
        if target == "terms" {
            out(explanations.glossary.values.sorted { $0.id < $1.id }.map { "  " + r.pad($0.id, 24) + ($0.name.text(args.lang) ?? "") }.joined(separator: "\n"))
            return .ok
        }
        let (scan, snapshot) = world()
        let stopper = Stopper(lang: args.lang)
        let analyzer = Analyzer.standard(lang: args.lang)
        guard let resolved = try? stopper.resolve(target, in: snapshot, scan: scan, itemFor: { analyzer.item(forPid: $0, in: scan) }),
              let item = resolved.item else {
            err(t("Không tìm thấy \(target) trong các thứ hog theo dõi. Thuật ngữ: `hog explain terms`.",
                  "\(target) is not among the things hog tracks. Terms: `hog explain terms`."))
            return .error
        }
        if args.json {
            let data = (try? SnapshotJSON.encoder().encode(item)) ?? Data()
            out(String(decoding: data, as: UTF8.self))
            return .ok
        }
        let plan = stopper.plan(resolved.identity, item: item, snapshot: snapshot, scan: scan)
        out(r.explainItem(item, snapshot, catalog: Catalog.load(.standard("catalog")), plan: plan))
        return .ok
    }

    func systemDetail() -> Exit {
        let pids = Set(ProcessReader.allPids().filter { ProcessReader.read($0, includeArgs: false).footprintBytes == nil })
        out(t("Đang đo bằng `top` (~2 giây)…", "Measuring with `top` (~2 s)…"))
        guard let rows = SystemDetail.measure(pids: pids) else {
            err(t("Không chạy được `top`.", "Could not run `top`."))
            return .error
        }
        out(r.systemDetail(rows, measured: rows.count))
        return .ok
    }

    // MARK: ports

    func ports(orphansOnly: Bool) -> Exit {
        let scan = Scanner(fast: true).scan()
        out(r.ports(PortsReport.rows(scan, orphansOnly: orphansOnly), orphansOnly: orphansOnly))
        return .ok
    }

    // MARK: stop

    func stop() -> Exit {
        let stopper = Stopper(lang: args.lang)
        if let planId = args.plan {
            guard args.yes else {
                err(t("`--plan` cần đi cùng `--yes` (nghĩa là: người đã đồng ý đúng kế hoạch này).",
                      "`--plan` needs `--yes` (meaning: a person agreed to exactly this plan)."))
                return .usage
            }
            return stopAgreed(planId, stopper: stopper)
        }
        guard let target = args.positional.first else {
            err(t("Cần đích: `hog stop <item-id | pid | cổng | tên container>`.", "Needs a target: `hog stop <item-id | pid | port | container name>`."))
            return .usage
        }
        let (scan, snapshot) = world(fast: false)
        let resolved: (identity: StopIdentity, item: Item?)
        let analyzer = Analyzer.standard(lang: args.lang)
        do { resolved = try stopper.resolve(target, in: snapshot, scan: scan, itemFor: { analyzer.item(forPid: $0, in: scan) }) } catch {
            err("\(error)")
            return .error
        }
        let plan = stopper.plan(resolved.identity, item: resolved.item, snapshot: snapshot, scan: scan)
        return present(plan, stopper: stopper, scan: scan)
    }

    /// Shows a plan, then: blocked → 4; instructions → 0; TTY → ask; no TTY → store the plan and exit 3.
    func present(_ plan: StopPlan, stopper: Stopper, scan: Scan) -> Exit {
        out(r.bold(t("Kế hoạch dừng", "Stop plan")) + r.dim("  (plan \(plan.planId))"))
        out(r.planLines(plan).joined(separator: "\n"))
        fflush(stdout)
        if let b = plan.blocked {
            err(r.red(t("Bị chặn bởi \(b.gate): \(b.reason)", "Blocked by \(b.gate): \(b.reason)")))
            return .blocked
        }
        if plan.action == .manual { return .ok }
        guard isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 else {
            do { try stopper.plans.save(plan) } catch {
                err(t("Không lưu được kế hoạch: \(error)", "Could not store the plan: \(error)"))
                return .error
            }
            out(t("Cần người đồng ý. Nếu đồng ý, chạy trong 10 phút: hog stop --yes --plan \(plan.planId)",
                  "A person must agree. If they do, run within 10 minutes: hog stop --yes --plan \(plan.planId)"))
            return .needsConfirmation
        }
        Swift.print(t("Dừng \(plan.label)? [y/N] ", "Stop \(plan.label)? [y/N] "), terminator: "")
        fflush(stdout)
        guard let answer = readLine(), ["y", "yes", "c", "có", "co"].contains(answer.lowercased()) else {
            out(t("Đã huỷ.", "Cancelled."))
            return .ok
        }
        return finish(stopper.execute(plan, scan: scan), stopper: stopper, scan: scan)
    }

    /// `--yes --plan <id>`: the stored plan must still be valid *and* re-planning on the current state must give the
    /// same plan with no block (identity unchanged, gates still pass).
    func stopAgreed(_ planId: String, stopper: Stopper) -> Exit {
        let (scan, snapshot) = world(fast: false)
        let analyzer = Analyzer.standard(lang: args.lang)
        switch stopper.reconfirm(planId: planId, snapshot: snapshot, scan: scan, itemFor: { analyzer.item(forPid: $0, in: scan) }) {
        case .failure(.expired):
            err(t("Kế hoạch \(planId) đã hết hạn (10 phút). Tạo lại bằng `hog stop <đích>`.", "Plan \(planId) expired (10 minutes). Make a new one with `hog stop <target>`."))
            return .blocked
        case .failure(.notFound):
            err(t("Không có kế hoạch \(planId).", "No plan \(planId)."))
            return .error
        case .failure(.changed):
            err(t("Trạng thái đã đổi so với kế hoạch đã duyệt; không làm gì.", "The state changed since the plan was agreed; nothing done."))
            return .blocked
        case .failure(.blocked(let b)):
            err(r.red(t("Bị chặn bởi \(b.gate): \(b.reason)", "Blocked by \(b.gate): \(b.reason)")))
            return .blocked
        case .success(let fresh):
            out(r.planLines(fresh).joined(separator: "\n"))
            return finish(stopper.execute(fresh, scan: scan), stopper: stopper, scan: scan)
        }
    }

    func finish(_ outcome: Stopper.Outcome, stopper: Stopper, scan: Scan) -> Exit {
        switch outcome {
        case .done(let m): out(r.green("✓ ") + m); return .ok
        case .manual(let steps): out(steps.map { "→ " + $0 }.joined(separator: "\n")); return .ok
        case .blocked(let g):
            err(r.red(t("Bị chặn bởi \(g.gate): \(g.reason)", "Blocked by \(g.gate): \(g.reason)")))
            return .blocked
        case .failed(let m): err(r.red("✗ ") + m); return .error
        case .needsNewPlan(let k):
            out(r.yellow(t("SIGTERM chưa đủ.", "SIGTERM was not enough.")))
            return present(k, stopper: stopper, scan: scan)
        }
    }

    // MARK: data

    func catalog() -> Exit {
        let c = Catalog.load(.standard("catalog"))
        switch args.positional.first ?? "list" {
        case "list":
            for e in c.entries.values.sorted(by: { $0.id < $1.id }) {
                out("  " + r.pad(e.id, 24) + r.pad(e.family, 22) + (e.name.text(args.lang) ?? "") + (e.provenance.verified ? "" : r.yellow("  ⚠")))
            }
            return .ok
        case "show":
            guard let id = args.positional.dropFirst().first, let e = c.entries[id],
                  let data = try? JSONEncoder.pretty.encode(e) else { err(t("Không có mục đó.", "No such entry.")); return .error }
            out(String(decoding: data, as: UTF8.self))
            return .ok
        case "check":
            return report(c.warnings, count: c.entries.count, kind: t("mục danh mục", "catalog entries"))
        default:
            err(t("Dùng: hog catalog list | show <id> | check", "Usage: hog catalog list | show <id> | check"))
            return .usage
        }
    }

    func rules() -> Exit {
        let set = RuleSet.load(.standard("rules"))
        switch args.positional.first ?? "list" {
        case "list":
            for rule in set.rules {
                let kind = rule.ruleClass == .protect ? "protect/\(rule.level?.rawValue ?? "")" : "advice/\(rule.verdict?.rawValue ?? "")"
                out("  " + r.pad(rule.id, 28) + r.pad(kind, 18) + (rule.reason.text(args.lang) ?? ""))
            }
            return .ok
        case "check":
            return report(set.warnings, count: set.rules.count, kind: t("quy tắc", "rules"))
        default:
            err(t("Dùng: hog rules list | check", "Usage: hog rules list | check"))
            return .usage
        }
    }

    /// Exit 1 when a file was skipped; missing translations are warnings only.
    func report(_ warnings: [DataWarning], count: Int, kind: String) -> Exit {
        out(t("\(count) \(kind) nạp được.", "\(count) \(kind) loaded."))
        for w in warnings { out(r.yellow("  ⚠ \(w)")) }
        return warnings.contains { $0.message.hasPrefix("skipped") || $0.message.hasPrefix("ignored") } ? .error : .ok
    }

    func help() -> String {
        t("""
        hog \(Hog.version) — máy đang hao vì cái gì, của ai, và có nên tắt không

        DÙNG
          hog                         câu kết luận, thứ ăn nhiều nhất, đề xuất
          hog --json                  ảnh chụp đầy đủ cho Claude/hub (--fast: nhanh, không có CPU tức thời)
          hog explain <đích>          vì sao: số đo, quy tắc, danh mục, cổng an toàn
          hog explain <thuật ngữ>     giải nghĩa một con số (hog explain terms để xem danh sách)
          hog explain system          đo chi tiết tiến trình hệ thống bằng top (~2 giây)
          hog ports | hog orphans     cổng đang nghe, gom theo dự án (như lps cũ)
          hog stop <đích>             dừng qua cổng an toàn; không TTY → lưu kế hoạch, mã thoát 3
          hog stop --yes --plan <id>  chạy kế hoạch người đã đồng ý (còn hạn 10 phút)
          hog catalog list|show|check · hog rules list|check
          hog version · hog help

        CỜ
          --lang vi|en (hoặc HOG_LANG)  --full  --fast  --pretty (JSON dễ đọc)  --brief (JSON gọn cho Claude)  --no-color (hoặc NO_COLOR)

        MÃ THOÁT
          0 xong · 1 lỗi · 2 dùng sai · 3 cần người đồng ý · 4 bị cổng an toàn chặn
        """, """
        hog \(Hog.version) — what is eating the machine, who owns it, and whether to stop it

        USAGE
          hog                         headline, biggest consumers, suggestions
          hog --json                  full snapshot for Claude/hub (--fast: quicker, no current CPU)
          hog explain <target>        why: measurements, rules, catalog, safety gates
          hog explain <term>          what a number means (hog explain terms for the list)
          hog explain system          measure system processes with top (~2 s)
          hog ports | hog orphans     listening ports grouped by project (like lps)
          hog stop <target>           stop through the safety gates; no TTY → stores the plan, exit 3
          hog stop --yes --plan <id>  run a plan a person agreed to (valid 10 minutes)
          hog catalog list|show|check · hog rules list|check
          hog version · hog help

        FLAGS
          --lang vi|en (or HOG_LANG)  --full  --fast  --pretty (readable JSON)  --brief (short JSON for Claude)  --no-color (or NO_COLOR)

        EXIT CODES
          0 done · 1 error · 2 usage · 3 needs a person's agreement · 4 blocked by a safety gate
        """)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
}
