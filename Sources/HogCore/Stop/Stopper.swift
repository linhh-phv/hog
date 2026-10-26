import Darwin
import Foundation

/// Builds stop plans and executes them through the hard safety gates (design section 8). The gates live here and
/// only here: the CLI, the menu bar app and Claude all go through this type. No flag disables a gate; `--yes`
/// only replaces the confirmation question.
public struct Stopper: Sendable {
    public var plans: PlanStore
    public var log: ActionLog
    /// G4: how long to wait after SIGTERM.
    public var sigtermWait: TimeInterval = 10
    public var dockerSocket: @Sendable () -> String?
    public var locator: CommandLocator
    public var lang: Lang

    public init(plans: PlanStore = .standard(), log: ActionLog = .standard(), lang: Lang = .vi,
                locator: CommandLocator = CommandLocator(),
                dockerSocket: @escaping @Sendable () -> String? = { DockerClient.findSocket() }) {
        self.plans = plans; self.log = log; self.lang = lang; self.locator = locator; self.dockerSocket = dockerSocket
    }

    func t(_ vi: String, _ en: String) -> String { lang == .vi ? vi : en }

    // MARK: - Targets

    public enum TargetError: Error, Equatable, CustomStringConvertible {
        case notFound(String)
        case ambiguous(String, [String])
        public var description: String {
            switch self {
            case .notFound(let s): "no process, port, item or container matches \(s)"
            case .ambiguous(let s, let ids): "\(s) matches several targets: \(ids.joined(separator: ", "))"
            }
        }
    }

    /// Resolves `<pid | port | item-id | container name>` to an item. `itemFor` builds an item (facts + protection) for
    /// a PID that is not among the snapshot's items, e.g. `Analyzer.item(forPid:in:)`; without it such targets have no
    /// item and gate G6 blocks them.
    public func resolve(_ target: String, in snapshot: Snapshot, scan: Scan,
                        itemFor: ((Int32) -> Item?)? = nil) throws -> (identity: StopIdentity, item: Item?) {
        if let item = snapshot.items.first(where: { $0.id == target }) { return (identity(of: item, scan: scan), item) }
        if let c = scan.containers?.first(where: { $0.name == target || $0.id.hasPrefix(target) && target.count >= 6 }) {
            return (.container(c.id), snapshot.items.first { $0.id == "ctr:\(c.id.prefix(12))" })
        }
        if let n = Int32(target) {
            // A port first when something listens on it (like `lps kill 3000`), else a PID.
            let listeners = (scan.network?.listening ?? [:]).filter { $0.value.contains { $0.port == Int(n) } }.map(\.key)
            if listeners.count > 1 { throw TargetError.ambiguous(target, listeners.sorted().map(String.init)) }
            let pid = listeners.first ?? n
            guard let p = scan.processes[pid] else { throw TargetError.notFound(target) }
            let item = snapshot.items.first { $0.pids.first == pid } ?? itemFor?(pid)
            return (.process(pid, startSec: p.startSec, startUsec: p.startUsec), item)
        }
        throw TargetError.notFound(target)
    }

    func identity(of item: Item, scan: Scan) -> StopIdentity {
        if item.kind == .container, let c = scan.containers?.first(where: { "ctr:\($0.id.prefix(12))" == item.id }) {
            return .container(c.id)
        }
        let pid = item.pids.first ?? 0
        let p = scan.processes[pid]
        return .process(pid, startSec: p?.startSec, startUsec: p?.startUsec)
    }

    // MARK: - Planning

    /// Builds the plan and runs the gates that can be checked before acting (G1, G2, G6, G7, plus G5's precheck).
    public func plan(_ identity: StopIdentity, item: Item?, snapshot: Snapshot, scan: Scan,
                     action requested: StopAction? = nil, now: Date = Date()) -> StopPlan {
        let finding = item.flatMap { i in snapshot.findings.first { $0.itemId == i.id } }
        var action = requested ?? defaultAction(identity: identity, item: item, finding: finding)
        var gates: [GateCheck] = []
        var steps: [String] = []
        var previousPolicy: String?

        // G1 — never self-harm.
        if identity.kind == .process, let pid = identity.pid {
            let ancestors = Set([snapshot.hog.pid] + snapshot.hog.ancestors.filter { $0 != 1 })
            if ancestors.contains(pid) || pid == 1 || item?.facts["self.window"] == .bool(true) {
                gates.append(GateCheck(gate: "G1", result: .block, reason: t("Đây là hog, thứ đang chạy hog, hoặc thuộc cửa sổ chứa nó.",
                                                                            "This is hog, something running hog, or part of the window containing it.")))
            } else if !snapshot.hog.ancestorsComplete {
                gates.append(GateCheck(gate: "G1", result: .block, reason: t(
                    "Không đọc được hết chuỗi tiến trình đang chạy hog, nên không chắc đích không phải tổ tiên của hog.",
                    "The chain of processes running hog could not be read fully, so the target might be one of them.")))
            } else {
                gates.append(GateCheck(gate: "G1", result: .pass, reason: t("Không phải hog hay tổ tiên của hog.", "Not hog or one of its ancestors.")))
            }
        }

        // G6 — only our own things; hard protections.
        if identity.kind == .process, let pid = identity.pid {
            let p = scan.processes[pid]
            if item == nil {
                gates.append(GateCheck(gate: "G6", result: .block, reason: t("hog không đọc được đủ về thứ này (không có số đo, không biết bảo vệ gì) nên không dừng.",
                                                                            "hog could not read enough about this (no measurements, unknown protections), so it does not stop it.")))
            } else if p?.uid != scan.selfUid {
                gates.append(GateCheck(gate: "G6", result: .block, reason: t("Không thuộc người dùng hiện tại (hog không dùng sudo).",
                                                                            "Not owned by the current user (hog never uses sudo).")))
            } else if let prot = item?.protection.value, prot.level == .hard {
                gates.append(GateCheck(gate: "G6", result: .block, reason: t("Được bảo vệ cứng: \(prot.rules.joined(separator: ", ")).",
                                                                            "Hard-protected: \(prot.rules.joined(separator: ", ")).")))
            } else {
                gates.append(GateCheck(gate: "G6", result: .pass, reason: t("Thuộc người dùng hiện tại.", "Owned by the current user.")))
            }
        }

        // G2 — belongs to another session/window, or the owner may be busy → a person must confirm, seeing the owner.
        let ownerLabel = item?.ownerId.value.flatMap { id in snapshot.owners.first { $0.id == id }?.label }
        let callerSession = snapshot.hog.ancestors.first { pid in snapshot.items.contains { $0.id == "claude:\(pid)" } }
        var g2Reasons: [String] = []
        if let prot = item?.protection.value, prot.level == .soft { g2Reasons.append(prot.rules.joined(separator: ", ")) }
        if item?.kind == .claudeSession || (item?.ownerId.value?.hasPrefix("claude:") ?? false) {
            let owner = item?.kind == .claudeSession ? item?.id : item?.ownerId.value
            if owner != callerSession.map({ "claude:\($0)" }) { g2Reasons.append(t("thuộc một phiên Claude khác", "belongs to another Claude session")) }
        }
        if item?.facts["owner.kind"] == .string("vscode-window") { g2Reasons.append(t("thuộc một cửa sổ VS Code", "belongs to a VS Code window")) }
        if g2Reasons.isEmpty {
            gates.append(GateCheck(gate: "G2", result: .pass, reason: t("Không thuộc phiên/cửa sổ nào khác.", "Not part of another session or window.")))
        } else {
            gates.append(GateCheck(gate: "G2", result: .confirm, reason: t(
                "Hỏi trước: \(g2Reasons.joined(separator: "; "))" + (ownerLabel.map { " — chủ: \($0)" } ?? ""),
                "Ask first: \(g2Reasons.joined(separator: "; "))" + (ownerLabel.map { " — owner: \($0)" } ?? ""))))
        }

        // G7 — evidence; stopping without measurements is allowed but said plainly.
        if finding == nil {
            gates.append(GateCheck(gate: "G7", result: .confirm, reason: t("hog chưa có đề xuất dừng thứ này; chưa có số đo nói nó không được dùng.",
                                                                          "hog has no suggestion to stop this; nothing measured says it is unused.")))
        } else if let f = finding, !f.unmeasured.isEmpty {
            gates.append(GateCheck(gate: "G7", result: .confirm, reason: t("Chưa có số đo cho: \(f.unmeasured.joined(separator: ", ")).",
                                                                          "Not measured: \(f.unmeasured.joined(separator: ", ")).")))
        } else {
            gates.append(GateCheck(gate: "G7", result: .confirm, reason: t("Có bằng chứng đo; vẫn cần người đồng ý.", "Backed by measurements; a person still has to agree.")))
        }

        // launchd would restart it → instructions only (design 8).
        if item?.facts["launchd.label"].map({ !$0.isNull }) == true, item?.facts["launchd.restarts_after_stop"] != .bool(false),
           action == .sigterm || action == .watchmanShutdown {
            action = .manual
        }

        switch action {
        case .sigterm:
            steps = [t("Gửi SIGTERM tới PID \(identity.pid ?? 0), chờ tối đa \(Int(sigtermWait)) giây.", "Send SIGTERM to PID \(identity.pid ?? 0), wait up to \(Int(sigtermWait)) s."),
                     t("Nếu vẫn sống: dừng lại và hỏi lại trước khi SIGKILL.", "If still alive: stop and ask again before SIGKILL.")]
        case .sigkill:
            steps = [t("Gửi SIGKILL tới PID \(identity.pid ?? 0) (có thể mất dữ liệu chưa lưu).", "Send SIGKILL to PID \(identity.pid ?? 0) (unsaved data may be lost).")]
        case .watchmanShutdown:
            steps = [t("Chạy `watchman --no-spawn --no-local shutdown-server`, chờ tiến trình thoát.", "Run `watchman --no-spawn --no-local shutdown-server` and wait for it to exit.")]
        case .dockerStop:
            if let id = identity.containerId, let c = scan.containers?.first(where: { $0.id == id }) {
                previousPolicy = c.restartPolicy
                if let pol = c.restartPolicy, ["always", "unless-stopped", "on-failure"].contains(pol) {
                    steps.append(t("Đặt restart policy `\(pol)` → `no`, đọc lại để chắc chắn.", "Set restart policy `\(pol)` → `no` and read it back."))
                }
                steps.append(t("Dừng container \(c.name). Không xoá container hay volume.", "Stop container \(c.name). Nothing is deleted."))
                if let pol = c.restartPolicy, pol != "no" {
                    steps.append(t("Khôi phục: `docker update --restart=\(pol) \(c.name) && docker start \(c.name)`.",
                                   "Restore: `docker update --restart=\(pol) \(c.name) && docker start \(c.name)`."))
                }
            }
            if previousPolicy == nil {
                gates.append(GateCheck(gate: "G5", result: .block, reason: t("Không đọc được restart policy của container; dừng có thể bị Docker bật lại ngay.",
                                                                            "Could not read the container's restart policy; Docker might restart it at once.")))
            } else {
                gates.append(GateCheck(gate: "G5", result: .pass, reason: t("Restart policy sẽ được tắt và kiểm lại trước khi dừng.",
                                                                           "The restart policy is turned off and verified before stopping.")))
            }
        case .manual:
            steps = manualSteps(identity: identity, item: item)
        }

        let label = item?.label ?? scan.processes[identity.pid ?? -1]?.exePath.map { ($0 as NSString).lastPathComponent } ?? identity.key
        // Whole seconds: the stored plan (RFC 3339) must read back identical.
        let created = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        return StopPlan(planId: StopPlan.makeId(identity, action), createdAt: created, expiresAt: created.addingTimeInterval(StopPlan.lifetime),
                        identity: identity, action: action, label: label, ownerLabel: ownerLabel, itemId: item?.id,
                        rules: finding?.rules ?? [], reason: finding?.reason, evidence: finding?.evidence ?? [:],
                        unmeasured: finding?.unmeasured ?? [], effect: finding?.stop.effect ?? t("Chưa biết tắt thì ảnh hưởng gì.", "Effect of stopping it is unknown."),
                        steps: steps, gates: gates, previousRestartPolicy: previousPolicy)
    }

    func defaultAction(identity: StopIdentity, item: Item?, finding: Finding?) -> StopAction {
        if identity.kind == .container { return .dockerStop }
        switch finding?.stop.strategy {
        case .manual?: return .manual
        case .watchmanShutdown?: return .watchmanShutdown
        case .dockerContainer?: return .dockerStop
        default: return item?.kind == .claudeSession ? .manual : .sigterm
        }
    }

    func manualSteps(identity: StopIdentity, item: Item?) -> [String] {
        if item?.kind == .claudeSession {
            return [t("Đóng tab/phiên Claude đó trong VS Code (hoặc gõ /exit trong terminal). Lịch sử vẫn mở lại được.",
                      "Close that Claude tab in VS Code (or type /exit in the terminal). The history can be resumed.")]
        }
        if let label = item?.facts["launchd.label"], case .string(let l) = label {
            return [t("launchd sẽ bật lại nó nếu chỉ dừng. Gỡ job (thay đổi cấu hình máy, hog không tự làm): `launchctl bootout gui/\(getuid())/\(l)`.",
                      "launchd would restart it if only stopped. Remove the job (a machine config change hog does not make): `launchctl bootout gui/\(getuid())/\(l)`.")]
        }
        return [t("hog không tự dừng thứ này. Xem \"tắt thì sao\" ở trên để biết cách làm đúng.",
                  "hog does not stop this itself. See the effect above for the right way to do it.")]
    }

    // MARK: - Agreed plans (`hog stop --yes --plan <id>`)

    public enum ReconfirmError: Error, Equatable {
        case expired, notFound, changed
        case blocked(GateCheck)
    }

    /// A plan a person agreed to: it must still be stored and valid, and planning again on the *current* state must give
    /// the same plan (identity unchanged) with no gate blocking. Returns the fresh plan to execute.
    public func reconfirm(planId: String, snapshot: Snapshot, scan: Scan, itemFor: ((Int32) -> Item?)? = nil,
                          now: Date = Date()) -> Result<StopPlan, ReconfirmError> {
        let stored: StopPlan
        do { stored = try plans.load(planId, now: now) } catch PlanStore.LoadError.expired { return .failure(.expired) } catch {
            return .failure(.notFound)
        }
        let item: Item? = stored.itemId.flatMap { id in snapshot.items.first { $0.id == id } }
            ?? stored.identity.pid.flatMap { pid in snapshot.items.first { $0.pids.first == pid } ?? itemFor?(pid) }
        var fresh = plan(stored.identity, item: item, snapshot: snapshot, scan: scan, action: stored.action, now: now)
        if stored.action == .sigkill { fresh.gates += stored.gates.filter { $0.gate == "G4" } }
        guard fresh.planId == stored.planId else { return .failure(.changed) }
        if let b = fresh.blocked { return .failure(.blocked(b)) }
        // G3 at plan level: the stored identity must still be the live process.
        if stored.identity.kind == .process, !isAlive(stored.identity) { return .failure(.changed) }
        return .success(fresh)
    }

    // MARK: - Execution

    public enum Outcome: Sendable, Equatable {
        case done(String)
        /// SIGTERM was not enough: a new SIGKILL plan that needs a fresh "yes" (G4).
        case needsNewPlan(StopPlan)
        case blocked(GateCheck)
        case manual([String])
        case failed(String)
    }

    /// Runs a plan whose confirmations were given. Re-checks identity right before acting (G3) and writes the
    /// action log before and after (G8).
    public func execute(_ plan: StopPlan, scan: Scan, now: Date = Date()) -> Outcome {
        if let b = plan.blocked { return .blocked(b) }
        if plan.isExpired(at: now) { return .failed(t("Kế hoạch đã hết hạn; tạo lại.", "The plan expired; make a new one.")) }
        if plan.action == .manual { return .manual(plan.steps) }

        // G3 — identity must still match what was shown.
        if plan.identity.kind == .process {
            guard let pid = plan.identity.pid, let live = ProcessReader.bsdInfo(pid) ?? ProcessReader.kinfoProc(pid),
                  live.startSec == plan.identity.startSec, live.startUsec == plan.identity.startUsec else {
                return .blocked(GateCheck(gate: "G3", result: .block, reason: t(
                    "Tiến trình đã đổi (PID không còn là thứ đã hiển thị). Huỷ.", "The process changed (the PID is no longer what was shown). Cancelled.")))
            }
        }

        // G8 — no log, no stop.
        do { try log.append(entry(plan, phase: "start", outcome: nil)) } catch {
            return .blocked(GateCheck(gate: "G8", result: .block, reason: t("Không ghi được nhật ký hành động: \(error)", "Cannot write the action log: \(error)")))
        }
        let outcome: Outcome
        switch plan.action {
        case .sigterm: outcome = runSigterm(plan, scan: scan, now: now)
        case .sigkill: outcome = runSigkill(plan)
        case .watchmanShutdown: outcome = runWatchman(plan)
        case .dockerStop: outcome = runDocker(plan)
        case .manual: outcome = .manual(plan.steps)
        }
        try? log.append(entry(plan, phase: "end", outcome: String(describing: outcome)))
        plans.remove(plan.planId)
        return outcome
    }

    func entry(_ plan: StopPlan, phase: String, outcome: String?) -> ActionLog.Entry {
        ActionLog.Entry(at: Date(), phase: phase, planId: plan.planId, identity: plan.identity, action: plan.action, label: plan.label,
                        gates: plan.gates, evidence: plan.evidence, previousRestartPolicy: plan.previousRestartPolicy, outcome: outcome)
    }

    func isAlive(_ identity: StopIdentity) -> Bool {
        guard let pid = identity.pid, let live = ProcessReader.bsdInfo(pid) ?? ProcessReader.kinfoProc(pid) else { return false }
        return live.startSec == identity.startSec && live.startUsec == identity.startUsec
    }

    func waitGone(_ identity: StopIdentity, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isAlive(identity) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !isAlive(identity)
    }

    func runSigterm(_ plan: StopPlan, scan: Scan, now: Date) -> Outcome {
        guard let pid = plan.identity.pid else { return .failed("no pid") }
        guard kill(pid, SIGTERM) == 0 else { return .failed(t("Gửi SIGTERM thất bại: \(String(cString: strerror(errno)))", "SIGTERM failed: \(String(cString: strerror(errno)))")) }
        if waitGone(plan.identity, timeout: sigtermWait) { return .done(t("Đã dừng \(plan.label) (SIGTERM).", "Stopped \(plan.label) (SIGTERM).")) }
        // G4 — never escalate on our own: a new plan, a new "yes".
        var k = plan
        k.action = .sigkill
        k.planId = StopPlan.makeId(plan.identity, .sigkill)
        k.createdAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        k.expiresAt = k.createdAt.addingTimeInterval(StopPlan.lifetime)
        k.steps = [t("Gửi SIGKILL tới PID \(pid) (có thể mất dữ liệu chưa lưu).", "Send SIGKILL to PID \(pid) (unsaved data may be lost).")]
        k.gates = plan.gates.filter { $0.result != .confirm } + [GateCheck(gate: "G4", result: .confirm, reason: t(
            "Còn sống sau \(Int(sigtermWait)) giây SIGTERM. Buộc tắt cần bạn đồng ý lần nữa.",
            "Still alive \(Int(sigtermWait)) s after SIGTERM. Forcing it needs your agreement again."))]
        try? plans.save(k)
        return .needsNewPlan(k)
    }

    func runSigkill(_ plan: StopPlan) -> Outcome {
        guard let pid = plan.identity.pid else { return .failed("no pid") }
        guard kill(pid, SIGKILL) == 0 else { return .failed(t("Gửi SIGKILL thất bại: \(String(cString: strerror(errno)))", "SIGKILL failed: \(String(cString: strerror(errno)))")) }
        return waitGone(plan.identity, timeout: 3) ? .done(t("Đã buộc tắt \(plan.label) (SIGKILL).", "Killed \(plan.label) (SIGKILL)."))
            : .failed(t("Vẫn còn sau SIGKILL.", "Still alive after SIGKILL."))
    }

    func runWatchman(_ plan: StopPlan) -> Outcome {
        guard let wm = locator.find("watchman") else { return .failed(t("Không tìm thấy lệnh watchman.", "watchman command not found.")) }
        guard let r = Command.run(wm, ["--no-spawn", "--no-local", "shutdown-server"], timeout: 10), r.status == 0 else {
            return .failed(t("`watchman shutdown-server` thất bại.", "`watchman shutdown-server` failed."))
        }
        return waitGone(plan.identity, timeout: sigtermWait) ? .done(t("Đã dừng watchman.", "Stopped watchman."))
            : .failed(t("watchman chưa thoát sau shutdown-server.", "watchman did not exit after shutdown-server."))
    }

    func runDocker(_ plan: StopPlan) -> Outcome {
        guard let id = plan.identity.containerId else { return .failed("no container") }
        guard let socket = dockerSocket() else { return .failed(t("Engine Docker không chạy.", "The Docker engine is not running.")) }
        let docker = DockerClient(socketPath: socket)
        do {
            // G5 — restart policy off and verified before stopping; any failure → no stop.
            if let pol = plan.previousRestartPolicy, pol != "no", !pol.isEmpty {
                let body = Data(#"{"RestartPolicy":{"Name":"no"}}"#.utf8)
                let u = try docker.request("POST", "/containers/\(id)/update", body: body)
                guard u.status == 200 else {
                    return .blocked(GateCheck(gate: "G5", result: .block, reason: t("Không tắt được restart policy (HTTP \(u.status)); không dừng.",
                                                                                   "Could not turn off the restart policy (HTTP \(u.status)); not stopping.")))
                }
                let i = try docker.request("GET", "/containers/\(id)/json")
                let obj = try JSONSerialization.jsonObject(with: i.body) as? [String: Any]
                let now = ((obj?["HostConfig"] as? [String: Any])?["RestartPolicy"] as? [String: Any])?["Name"] as? String
                guard i.status == 200, now == "no" else {
                    return .blocked(GateCheck(gate: "G5", result: .block, reason: t("Đọc lại restart policy không phải `no` (\(now ?? "?")); không dừng.",
                                                                                   "Restart policy read back is not `no` (\(now ?? "?")); not stopping.")))
                }
            }
            let s = try docker.request("POST", "/containers/\(id)/stop?t=10")
            guard s.status == 204 || s.status == 304 else { return .failed("docker stop: HTTP \(s.status)") }
            return .done(t("Đã dừng container (không xoá gì).", "Stopped the container (nothing deleted)."))
        } catch {
            return .failed("docker: \(error)")
        }
    }
}
