import HogCore
import SwiftUI

struct MenuView: View {
    @EnvironmentObject var model: HogModel

    var body: some View {
        ZStack {
            Theme.bg
            Group {
                switch model.page {
                case .main: MainPage()
                case .why(let id): WhyPage(itemId: id)
                case .system: SystemPage()
                case .settings: SettingsPage()
                }
            }
            if let plan = model.stopPlan {
                Color.black.opacity(0.25)
                StopSheet(plan: plan).padding(Theme.s3)
            }
        }
        .frame(width: Theme.width)
        .foregroundStyle(Theme.text)
    }
}

struct MainPage: View {
    @EnvironmentObject var model: HogModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.scanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(model.summary == nil ? model.t("Đang quét…", "Scanning…")
                         : model.t("Đang quét… hiện bản lúc ", "Scanning… showing ") + (model.summary?.takenAt.formatted(date: .omitted, time: .shortened) ?? ""))
                }
                .font(Theme.small).foregroundStyle(Theme.text2).padding([.horizontal, .top], Theme.s3)
            }
            if let toast = model.toast {
                HStack { Text("✓").foregroundStyle(Theme.ok); Text(toast) }.font(Theme.small)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Theme.s2).tile()
                    .padding([.horizontal, .top], Theme.s3)
            }
            if let s = model.summary {
                content(s)
            } else {
                Text(model.t("Đang xem máy lần đầu (~3 giây)…", "Looking at the machine for the first time (~3 s)…"))
                    .font(Theme.body).foregroundStyle(Theme.text2).padding(Theme.s4)
            }
            Divider().overlay(Theme.sep).padding(.horizontal, Theme.s3)
            Footer()
        }
    }

    @ViewBuilder func content(_ s: MenuSummary) -> some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            HeadlineCard(text: s.headline)
            HStack(spacing: Theme.s2) {
                MetricTile(label: model.t("Áp lực", "Pressure"), glossaryId: "memory-pressure") { PressureValue(pressure: s.pressure) }
                MetricTile(label: model.t("Đã nén", "Compressed"), glossaryId: "compressed-stored") {
                    Text(s.compressedStored.map { Format.bytes($0, model.lang) } ?? "?")
                }
                MetricTile(label: model.t("Ra ổ đĩa", "Swapped"), glossaryId: "swap-used") {
                    Text(s.swapUsed.map { Format.bytes($0, model.lang) } ?? "?")
                }
            }
            RAMBar(summary: s)
        }
        .padding(Theme.s3)
        Divider().overlay(Theme.sep).padding(.horizontal, Theme.s3)
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: model.t("Đề xuất", "Suggestions"))
            if s.cards.isEmpty {
                Text(model.t("Không có gì cần tắt. hog sẽ báo khi có.", "Nothing to stop. hog will tell you when there is."))
                    .font(Theme.small).foregroundStyle(Theme.text2)
            }
            ForEach(s.cards) { SuggestionCard(card: $0) }
            if s.moreCount > 0 {
                Text(model.t("+ \(s.moreCount) đề xuất khác (hog trong terminal)", "+ \(s.moreCount) more (hog in a terminal)"))
                    .font(Theme.caption).foregroundStyle(Theme.text2)
            }
            if !s.notes.isEmpty {
                SectionTitle(text: model.t("Chưa đo được", "Not measured")).padding(.top, 4)
                ForEach(s.notes) { Text($0.text).font(Theme.small).foregroundStyle(Theme.text2) }
            }
        }
        .padding(Theme.s3)
    }
}

struct WhyPage: View {
    @EnvironmentObject var model: HogModel
    let itemId: String

    /// Facts worth showing, with the glossary entry that explains each.
    static let shownFacts: [(String, String?, String, String)] = [
        ("age_s", nil, "Đã chạy", "Running for"),
        ("footprint_bytes", "footprint", "RAM của chương trình", "Program memory"),
        ("resident_ratio", "resident-ratio", "Phần còn nằm trong RAM", "Share still in RAM"),
        ("cpu.avg_pct", "cpu-avg", "CPU trung bình", "Average CPU"),
        ("orphan", "orphan", "Mồ côi", "Orphaned"),
        ("net.established", nil, "Kết nối đang mở", "Open connections"),
        ("watchman.subscriptions", nil, "Công cụ đăng ký", "Subscribed tools"),
        ("session.idle_s", "idle-session", "Phiên rảnh", "Session idle"),
        ("launchd.restarts_after_stop", nil, "launchd bật lại khi tắt?", "launchd restarts it?"),
        ("container.restart_count", nil, "Số lần khởi động lại", "Restarts"),
    ]

    var body: some View {
        let item = model.snapshot?.items.first { $0.id == itemId }
        let finding = model.snapshot?.findings.first { $0.itemId == itemId }
        let entry = item?.catalogId.value.flatMap { model.catalog.entries[$0] }
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s2) {
                BackButton()
                Text(item?.label ?? itemId).font(Theme.title)
                if let e = entry { Text(e.summary.text(model.lang) ?? "").font(Theme.small).foregroundStyle(Theme.text2) }
                if let f = finding {
                    SectionTitle(text: model.t("Vì sao · độ tin ", "Why · confidence ") + f.confidence.rawValue).padding(.top, 4)
                    Text(f.reason).font(Theme.small)
                    if !f.unmeasured.isEmpty {
                        Text(model.t("Chưa đo: ", "Not measured: ") + f.unmeasured.joined(separator: ", ")).font(Theme.caption).foregroundStyle(Theme.text2)
                    }
                }
                if let item {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                        ForEach(Self.shownFacts.filter { item.facts[$0.0].map { !$0.isNull } ?? false }, id: \.0) { fact, gid, vi, en in
                            GridRow {
                                HStack(spacing: 4) { Text(model.t(vi, en)).foregroundStyle(Theme.text2); if let gid { QuestionButton(glossaryId: gid) } }
                                Text(Format.fact(fact, item.facts[fact]!, model.lang)).monospacedDigit().gridColumnAlignment(.trailing)
                            }
                        }
                    }
                    .font(Theme.small).padding(.top, 4)
                    if let p = item.protection.value {
                        Text(model.t("Được bảo vệ (\(p.level.rawValue)): ", "Protected (\(p.level.rawValue)): ") + p.rules.joined(separator: ", "))
                            .font(Theme.caption).foregroundStyle(Theme.warn)
                    }
                }
                if let e = entry {
                    SectionTitle(text: model.t("Tắt thì sao", "If stopped")).padding(.top, 4)
                    Text(e.stopEffect.text(model.lang) ?? "").font(Theme.small).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                }
                if finding?.verdict == .mayStop || finding?.verdict == .ask {
                    HStack { Spacer(); SmallButton(title: model.t("Dừng…", "Stop…"), role: .danger) { model.prepareStop(itemId) } }
                }
            }
            .padding(Theme.s3)
        }
        .frame(maxHeight: 560)
    }
}

struct SystemPage: View {
    @EnvironmentObject var model: HogModel
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            BackButton()
            Text(model.t("macOS và dịch vụ hệ thống", "macOS and system services")).font(Theme.title)
            Text(model.t("Tiến trình hog không đọc được trực tiếp; đo bằng top.", "Processes hog cannot read directly; measured with top."))
                .font(Theme.small).foregroundStyle(Theme.text2)
            if model.systemMeasuring {
                HStack { ProgressView().controlSize(.mini); Text(model.t("Đang đo (~2 giây)…", "Measuring (~2 s)…")) }.font(Theme.small)
            } else if let rows = model.systemRows {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(rows.prefix(25), id: \.pid) { r in
                            HStack { Text(r.command).lineLimit(1); Spacer(); Text(r.memBytes.map { Format.bytes($0, model.lang) } ?? "?").monospacedDigit() }
                                .font(Theme.small)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            Text(model.t("hog không dừng tiến trình hệ thống.", "hog never stops system processes.")).font(Theme.caption).foregroundStyle(Theme.text2)
        }
        .padding(Theme.s3)
    }
}

struct SettingsPage: View {
    @EnvironmentObject var model: HogModel
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            BackButton()
            Text(model.t("Cài đặt", "Settings")).font(Theme.title)
            Picker(model.t("Ngôn ngữ", "Language"), selection: $model.langSetting) {
                Text(model.t("Theo máy", "System")).tag(HogModel.LangSetting.system.rawValue)
                Text("Tiếng Việt").tag(HogModel.LangSetting.vi.rawValue)
                Text("English").tag(HogModel.LangSetting.en.rawValue)
            }
            Toggle(model.t("Mở cùng máy", "Open at login"), isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            Toggle(model.t("Đổi màu icon theo áp lực", "Colour the icon by pressure"), isOn: $model.coloredIcon)
            Text(model.t("hog không gửi dữ liệu đi đâu. Nhật ký dừng: ~/.local/state/hog/actions.jsonl",
                         "hog sends nothing anywhere. Stop log: ~/.local/state/hog/actions.jsonl"))
                .font(Theme.caption).foregroundStyle(Theme.text2)
            Divider()
            Button(model.t("Thoát hog", "Quit hog")) { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(Theme.accent).font(Theme.small)
        }
        .font(Theme.small)
        .padding(Theme.s3)
    }
}

struct StopSheet: View {
    @EnvironmentObject var model: HogModel
    let plan: StopPlan

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Text(plan.action == .manual ? model.t("Cách tắt \(plan.label)", "How to stop \(plan.label)")
                 : model.t("Dừng \(plan.label)?", "Stop \(plan.label)?")).font(Theme.title)
            Text((plan.ownerLabel.map { model.t("Thuộc ", "Owned by ") + $0 } ?? model.t("Không thuộc phiên hay cửa sổ nào", "Not part of a session or window"))
                 + (plan.identity.pid.map { " · PID \($0)" } ?? ""))
                .font(Theme.caption).foregroundStyle(Theme.text2)
            Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 6) {
                if let r = plan.reason { row(model.t("Vì sao", "Why"), r) }
                row(model.t("Tắt thì sao", "If stopped"), plan.effect)
                row(plan.action == .manual ? model.t("Cách làm", "How") : model.t("hog sẽ", "hog will"), plan.steps.joined(separator: "\n").replacingOccurrences(of: "`", with: ""))
            }
            .font(Theme.small).padding(.top, 4)
            if plan.action != .manual { VStack(alignment: .leading, spacing: 2) {
                ForEach(plan.gates, id: \.gate) { g in
                    let (mark, color): (String, Color) = switch g.result {
                    case .pass: ("✓", Theme.ok)
                    case .confirm: ("?", Theme.warn)
                    case .block: ("✗", Theme.red)
                    }
                    Text("\(mark) \(g.reason)").foregroundStyle(color)
                }
            }
            .font(Theme.caption) }
            HStack(spacing: Theme.s2) {
                Spacer()
                if model.stopRunning { ProgressView().controlSize(.small) }
                SmallButton(title: plan.action == .manual || plan.blocked != nil ? model.t("Đóng", "Close") : model.t("Huỷ", "Cancel"), height: 28) {
                    model.stopPlan = nil
                }
                if plan.blocked == nil && plan.action != .manual {
                    let unsure = plan.gates.contains { $0.result == .confirm && ($0.gate == "G2" || $0.gate == "G4") }
                    SmallButton(title: plan.action == .sigkill ? model.t("Buộc tắt", "Force stop")
                                : (unsure ? model.t("Vẫn dừng", "Stop anyway") : model.t("Dừng", "Stop")),
                                role: .danger, height: 28) { model.confirmStop() }
                        .disabled(model.stopRunning)
                }
            }
            .padding(.top, 4)
        }
        .padding(Theme.s4)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.rMenu))
        .overlay(RoundedRectangle(cornerRadius: Theme.rMenu).strokeBorder(Theme.sep, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }

    @ViewBuilder func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(Theme.text2).frame(width: 76, alignment: .leading)
            Text(v).fixedSize(horizontal: false, vertical: true)
        }
    }
}
