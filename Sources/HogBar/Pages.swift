import AppKit
import HogCore
import SwiftUI

struct MenuView: View {
    @EnvironmentObject var model: HogModel

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                switch model.page {
                case .main: MainPage()
                case .entry(let g, let e): EntryPage(groupId: g, entryId: e)
                case .all: AllPage()
                case .system: SystemPage()
                case .settings: SettingsPage()
                }
            }
            if let plan = model.stopPlan { Sheet { StopSheet(plan: plan) } }
            if let plans = model.batch { Sheet { BatchSheet(plans: plans) } }
        }
        .frame(width: Theme.width)
    }
}

/// A confirmation over the menu: dimmed backdrop + a raised card.
struct Sheet<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25)
            content
                .padding(Theme.s4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
                .padding(Theme.s3).padding(.top, 48)
        }
    }
}

// MARK: Main

struct MainPage: View {
    @EnvironmentObject var model: HogModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let toast = model.toast {
                Label(toast, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.primary)
                    .symbolRenderingMode(.multicolor)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Theme.s2).module()
                    .padding([.horizontal, .top], Theme.s3)
            }
            if let o = model.overview {
                content(o)
            } else {
                Loading()
            }
            Divider()
            Footer()
        }
    }

    @ViewBuilder func content(_ o: Overview) -> some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            StatusHeader(o: o)
            HStack(spacing: 6) {
                MetricChip(label: model.t("CPU đang bận", "CPU busy"), glossaryId: "cpu-machine") {
                    Text(o.cpuUsed.map { Format.percent($0, model.lang) } ?? "–")
                        .foregroundStyle((o.cpuUsed ?? 0) >= 80 ? Color.red : Color.primary)
                }
                MetricChip(label: model.t("Tràn ra ổ đĩa", "Swapped to disk"), glossaryId: "swap-used") {
                    Text(o.swapUsed.map { Format.bytes($0, model.lang) } ?? "–")
                }
                MetricChip(label: model.t("Nhiệt", "Heat"), glossaryId: "thermal-state") {
                    Text(o.thermal.map { Format.thermal($0, model.lang).capitalizedFirst } ?? "–").foregroundStyle(Theme.thermal(o.thermal))
                }
            }
            if !o.cleanups.isEmpty { cleanups(o) }
        }
        .padding(Theme.s3)
        running(o)
    }

    @ViewBuilder func cleanups(_ o: Overview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.t("Nên dọn", "Clean up")).font(.headline)
                Spacer()
                Text(Format.bytes(o.reclaimable, model.lang)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            ForEach(o.cleanups) { CleanupRow(c: $0) }
            let n = o.cleanups.filter { model.selected.contains($0.itemId) && !$0.manual }.count
            // Only things a person closes (Claude sessions…): no batch button to show.
            if o.cleanups.contains(where: { !$0.manual }) { HStack {
                Text(model.t("Đã chọn \(n)", "\(n) selected")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.t("Dọn \(n) thứ", n == 1 ? "Clean up 1" : "Clean up \(n)")) { model.prepareBatch() }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.small).disabled(n == 0)
            }
            .padding(.top, 2) }
        }
        .padding(Theme.s3)
        .module()
    }

    @ViewBuilder func running(_ o: Overview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.t("Đang chạy", "Running")).font(.headline)
                Spacer()
                Text("RAM · CPU").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 2)
            ForEach(o.groups.filter { $0.kind != .system && $0.kind != .other }.prefix(Overview.mainGroups)) { g in
                GroupRow(g: g)
                if model.expanded.contains(g.id) {
                    ForEach(g.entries) { EntryRow(g: g, e: $0) }
                }
            }
            Button { model.page = .all } label: {
                HStack {
                    Text(model.t("Tất cả \(o.processCount) tiến trình", "All \(o.processCount) processes"))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.tint).font(.callout).padding(.vertical, 6)
        }
        .padding(.horizontal, Theme.s3).padding(.bottom, Theme.s2)
    }
}

struct Loading: View {
    @EnvironmentObject var model: HogModel
    var body: some View {
        HStack(spacing: Theme.s3) {
            ProgressView().controlSize(.regular)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.t("Đang xem máy…", "Looking at the machine…")).font(.title3.weight(.semibold))
                Text(model.t("Khoảng 2 giây", "About 2 seconds")).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(Theme.s4)
    }
}

// MARK: Entry

/// One thing: numbers, why it is suggested, and the actions (copy info to ask about it; stop when possible).
struct EntryPage: View {
    @EnvironmentObject var model: HogModel
    let groupId: String
    let entryId: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            BackButton()
            if let g = model.group(groupId), let e = model.entry(groupId, entryId) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(e.name).font(.title3.weight(.semibold))
                        if e.unknown { Image(systemName: "questionmark.circle").foregroundStyle(.orange) }
                    }
                    Text(subtitle(g, e)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Grid(alignment: .leading, horizontalSpacing: Theme.s3, verticalSpacing: 4) {
                    row("RAM", e.bytes.map { Format.bytes($0, model.lang) } ?? "–")
                    row("CPU", e.cpu.map { Format.percent($0, model.lang) + model.t(" của cả máy", " of the machine") } ?? "–")
                    if e.pids.count > 1 { row(model.t("Tiến trình", "Processes"), "\(e.pids.count)") }
                    if let age = age(e) { row(model.t("Đã chạy", "Running for"), Format.duration(age, model.lang)) }
                    if !e.detail.isEmpty { row(model.t("Mạng", "Network"), e.detail) }
                }
                .font(.callout)
                .padding(Theme.s3).frame(maxWidth: .infinity, alignment: .leading).module()
                if let f = e.itemId.flatMap({ id in model.snapshot?.findings.first { $0.itemId == id } }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(f.reason)
                        Text(f.stop.effect).foregroundStyle(.secondary)
                    }
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                actions(e)
            } else {
                Text(model.t("Không còn thấy thứ này ở lần quét mới nhất — có thể nó đã thoát.", "Not seen in the latest scan — it may have exited."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.s3)
    }

    func subtitle(_ g: Overview.Group, _ e: Overview.Entry) -> String {
        let part = g.kind == .project ? model.t("Thuộc dự án \(g.name)", "Part of project \(g.name)") : g.name
        guard e.unknown else { return part }
        return part + model.t(" · hog chưa biết thứ này là gì", " · hog does not know what this is yet")
    }

    func age(_ e: Overview.Entry) -> Int64? {
        guard let pid = e.pids.first else { return nil }
        return model.snapshot?.processes.first { $0.pid == pid }?.ageS.value
    }

    @ViewBuilder func row(_ k: String, _ v: String) -> some View {
        GridRow { Text(k).foregroundStyle(.secondary); Text(v).monospacedDigit() }
    }

    @ViewBuilder func actions(_ e: Overview.Entry) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            if e.unknown {
                Text(model.t("Muốn biết nó là gì? Chép thông tin (đã bỏ tên thư mục, mật khẩu) rồi dán vào chat hỏi Claude. hog không gửi gì đi.",
                             "Want to know what it is? Copy the info (directories, secrets removed) and paste it into a chat with Claude. hog sends nothing."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                let copied = model.copied == e.id
                if e.unknown {
                    Button { model.copyShare(e) } label: { Label(copied ? model.t("Đã chép", "Copied") : model.t("Chép thông tin", "Copy info"),
                                                                 systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button { model.copyShare(e) } label: { Label(copied ? model.t("Đã chép", "Copied") : model.t("Chép thông tin", "Copy info"),
                                                                 systemImage: copied ? "checkmark" : "doc.on.doc") }
                }
                // A line of several processes (×N) is not one thing to stop: stop them from their own app or project.
                if e.pids.count == 1 || e.itemId != nil {
                    Button(e.cleanup?.manual == true ? model.t("Cách đóng", "How to close") : model.t("Dừng…", "Stop…")) {
                        model.prepareStop(model.target(e))
                    }
                }
            }
            .controlSize(.regular)
        }
    }
}

// MARK: All processes

struct AllPage: View {
    @EnvironmentObject var model: HogModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            BackButton()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(model.t("Tìm tiến trình…", "Search processes…"), text: $model.search).textFieldStyle(.plain)
            }
            .padding(.horizontal, Theme.s2).padding(.vertical, 6).module()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { g in
                        HStack {
                            GroupIcon(g: g)
                            Text(g.name).font(.subheadline.weight(.semibold))
                            Text("\(g.processCount)").font(.caption).foregroundStyle(.tertiary)
                            Spacer()
                            Text(g.kind == .system ? (g.cpu.map { Format.percent($0, model.lang) + " CPU" } ?? "") : Format.bytes(g.bytes, model.lang))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.top, Theme.s2).padding(.bottom, 2)
                        if g.kind == .system {
                            Button(model.t("hog không đọc được từng cái · Đo chi tiết", "hog cannot read each one · Measure")) { model.measureSystem() }
                                .buttonStyle(.link).font(.caption).padding(.leading, 26)
                        }
                        ForEach(entries(g)) { EntryRow(g: g, e: $0) }
                        Divider().padding(.top, 4)
                    }
                }
            }
            .frame(maxHeight: 460)
        }
        .padding(Theme.s3)
    }

    var query: String { model.search.trimmingCharacters(in: .whitespaces).lowercased() }

    var groups: [Overview.Group] {
        (model.overview?.groups ?? []).filter { g in query.isEmpty || g.name.lowercased().contains(query) || !entries(g).isEmpty }
    }

    func entries(_ g: Overview.Group) -> [Overview.Entry] {
        guard !query.isEmpty, !g.name.lowercased().contains(query) else { return g.entries }
        return g.entries.filter { $0.name.lowercased().contains(query) || $0.detail.lowercased().contains(query) }
    }
}

// MARK: System detail

struct SystemPage: View {
    @EnvironmentObject var model: HogModel
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            BackButton()
            Text(model.t("macOS và hệ thống", "macOS and system")).font(.title3.weight(.semibold))
            Text(model.t("Tiến trình hog không đọc được trực tiếp; đo bằng top.", "Processes hog cannot read directly; measured with top."))
                .font(.callout).foregroundStyle(.secondary)
            if model.systemMeasuring {
                HStack { ProgressView().controlSize(.small); Text(model.t("Đang đo (~2 giây)…", "Measuring (~2 s)…")) }.font(.callout)
            } else if let rows = model.systemRows {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(rows.prefix(25), id: \.pid) { r in
                            HStack { Text(r.command).lineLimit(1); Spacer(); Text(r.memBytes.map { Format.bytes($0, model.lang) } ?? "?").monospacedDigit() }
                                .font(.callout)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            Text(model.t("hog không dừng tiến trình hệ thống.", "hog never stops system processes.")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(Theme.s3)
    }
}

// MARK: Settings

struct SettingsPage: View {
    @EnvironmentObject var model: HogModel
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            BackButton()
            Text(model.t("Cài đặt", "Settings")).font(.title3.weight(.semibold))
            Form {
                Picker(model.t("Ngôn ngữ", "Language"), selection: $model.langSetting) {
                    Text(model.t("Theo máy", "System")).tag(HogModel.LangSetting.system.rawValue)
                    Text("Tiếng Việt").tag(HogModel.LangSetting.vi.rawValue)
                    Text("English").tag(HogModel.LangSetting.en.rawValue)
                }
                Toggle(model.t("Mở cùng máy", "Open at login"), isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle(model.t("Đổi màu icon theo áp lực và nhiệt", "Colour the icon by pressure and heat"), isOn: $model.coloredIcon)
            }
            Text(model.t("hog không gửi dữ liệu đi đâu. Nhật ký dừng: ~/.local/state/hog/actions.jsonl",
                         "hog sends nothing anywhere. Stop log: ~/.local/state/hog/actions.jsonl"))
                .font(.caption).foregroundStyle(.secondary)
            if let notes = notes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.t("Chưa đo được", "Not measured")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Divider()
            Button(model.t("Thoát hog", "Quit hog")) { NSApp.terminate(nil) }.buttonStyle(.link)
        }
        .padding(Theme.s3)
    }

    /// Sensors that could not measure, in words (from HogCore; not on the main page).
    var notes: [String]? { model.overview?.notes }
}

// MARK: Stop sheets

struct StopSheet: View {
    @EnvironmentObject var model: HogModel
    let plan: StopPlan

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Text(plan.action == .manual ? model.t("Cách tắt \(plan.label)", "How to stop \(plan.label)")
                 : model.t("Dừng \(plan.label)?", "Stop \(plan.label)?")).font(.headline)
            Text((plan.ownerLabel.map { model.t("Thuộc ", "Owned by ") + $0 } ?? model.t("Không thuộc phiên hay cửa sổ nào", "Not part of a session or window"))
                 + (plan.identity.pid.map { " · PID \($0)" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
            if let r = plan.reason { Text(r).font(.callout).fixedSize(horizontal: false, vertical: true) }
            Text(plan.effect).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if plan.action == .manual {
                Text(plan.steps.joined(separator: "\n").replacingOccurrences(of: "`", with: "")).font(.callout).fixedSize(horizontal: false, vertical: true)
            } else {
                GateList(gates: plan.gates)
            }
            HStack(spacing: Theme.s2) {
                Spacer()
                if model.stopRunning { ProgressView().controlSize(.small) }
                Button(plan.action == .manual || plan.blocked != nil ? model.t("Đóng", "Close") : model.t("Huỷ", "Cancel")) { model.stopPlan = nil }
                    .keyboardShortcut(.cancelAction)
                if plan.blocked == nil && plan.action != .manual {
                    let unsure = plan.gates.contains { $0.result == .confirm && ($0.gate == "G2" || $0.gate == "G4") }
                    Button(plan.action == .sigkill ? model.t("Buộc tắt", "Force stop")
                           : (unsure ? model.t("Vẫn dừng", "Stop anyway") : model.t("Dừng", "Stop"))) { model.confirmStop() }
                        .buttonStyle(.borderedProminent).tint(.red).disabled(model.stopRunning)
                }
            }
            .padding(.top, 4)
        }
    }
}

/// "Dọn N thứ": every checked thing with its gates; blocked ones are listed but not run.
struct BatchSheet: View {
    @EnvironmentObject var model: HogModel
    let plans: [StopPlan]

    var body: some View {
        let runnable = model.batchRunnable
        let frees = runnable.compactMap { p in model.overview?.cleanups.first { $0.itemId == p.itemId }?.bytes }.reduce(0, +)
        VStack(alignment: .leading, spacing: Theme.s2) {
            Text(model.t("Dọn \(runnable.count) thứ?", runnable.count == 1 ? "Clean up 1 thing?" : "Clean up \(runnable.count) things?")
                 + (frees > 0 ? model.t(" · lấy lại \(Format.bytes(frees, model.lang))", " · frees \(Format.bytes(frees, model.lang))") : ""))
                .font(.headline)
            ForEach(plans, id: \.planId) { p in
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(p.label).lineLimit(1)
                        Spacer()
                        if p.blocked != nil {
                            Label(model.t("bị chặn", "blocked"), systemImage: "xmark.circle.fill").foregroundStyle(.red)
                        } else if p.askFirst != nil {
                            Label(model.t("hỏi trước", "ask first"), systemImage: "questionmark.circle.fill").foregroundStyle(.orange)
                        } else {
                            Label(model.t("an toàn", "safe"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                    .font(.callout)
                    // Why it is blocked or why to ask (owner, unmeasured facts) before what stopping costs.
                    Text(p.blocked.map(\.reason) ?? p.askFirst?.reason ?? p.effect).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            HStack(spacing: Theme.s2) {
                Spacer()
                if model.stopRunning { ProgressView().controlSize(.small) }
                Button(model.t("Huỷ", "Cancel")) { model.batch = nil }.keyboardShortcut(.cancelAction)
                Button(model.t("Dọn", "Clean up")) { model.confirmBatch() }
                    .buttonStyle(.borderedProminent).tint(.red).disabled(runnable.isEmpty || model.stopRunning)
            }
            .padding(.top, 4)
        }
    }
}

struct GateList: View {
    @EnvironmentObject var model: HogModel
    let gates: [GateCheck]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(gates, id: \.gate) { g in
                let (symbol, color): (String, Color) = switch g.result {
                case .pass: ("checkmark.circle.fill", .green)
                case .confirm: ("questionmark.circle.fill", .orange)
                case .block: ("xmark.circle.fill", .red)
                }
                Label(g.reason, systemImage: symbol).foregroundStyle(color)
            }
        }
        .font(.caption)
    }
}
