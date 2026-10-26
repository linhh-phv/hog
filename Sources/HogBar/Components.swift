import HogCore
import SwiftUI

// Components from docs/design/design-system.md.

struct QuestionButton: View {
    @EnvironmentObject var model: HogModel
    let glossaryId: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Text("?").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text2)
                .frame(width: 15, height: 15).overlay(Circle().strokeBorder(Theme.text2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.t("Giải nghĩa", "Explain"))
        .popover(isPresented: $shown, arrowEdge: .bottom) { GlossaryPopover(id: glossaryId).environmentObject(model) }
    }
}

struct GlossaryPopover: View {
    @EnvironmentObject var model: HogModel
    let id: String

    var body: some View {
        let lang = model.lang
        VStack(alignment: .leading, spacing: 6) {
            if let e = model.glossary(id) {
                Text(e.name.text(lang) ?? id).font(.system(size: 13, weight: .semibold))
                if let am = e.activityMonitor {
                    Text("Activity Monitor: \(am)" + (e.provenance.verified ? "" : model.t(" (chưa đối chiếu)", " (not checked yet)")))
                        .font(Theme.caption).foregroundStyle(Theme.text2)
                }
                Text(e.plain.text(lang) ?? "").font(Theme.small)
                (Text(model.t("Đọc thế nào: ", "How to read it: ")).bold() + Text(e.howToRead.text(lang) ?? "")).font(Theme.small)
                (Text(model.t("Nên làm gì: ", "What to do: ")).bold() + Text(e.act.text(lang) ?? "")).font(Theme.small)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 300, alignment: .leading)
        .padding(Theme.s3)
    }
}

struct HeadlineCard: View {
    let text: String
    var body: some View {
        Text(text).font(Theme.body).foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.s3).tile()
    }
}

struct MetricTile<Value: View>: View {
    let label: String
    let glossaryId: String
    @ViewBuilder let value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) { Text(label).font(Theme.caption).foregroundStyle(Theme.text2).lineLimit(1).minimumScaleFactor(0.75); QuestionButton(glossaryId: glossaryId) }
            value.font(Theme.metric).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.s2).padding(.horizontal, 10).tile()
    }
}

struct PressureValue: View {
    @EnvironmentObject var model: HogModel
    let pressure: Pressure?
    var body: some View {
        switch pressure {
        case .normal?: Text("● " + model.t("Ổn", "Normal")).foregroundStyle(Theme.ok)
        case .warn?: Text("◐ " + model.t("Cảnh báo", "Warning")).foregroundStyle(Theme.warn)
        case .critical?: Text("▲ " + model.t("Nghiêm trọng", "Critical")).foregroundStyle(Theme.red)
        case nil: Text("? " + model.t("Chưa đo", "Unknown")).foregroundStyle(Theme.text2)
        }
    }
}

struct RAMBar: View {
    @EnvironmentObject var model: HogModel
    let summary: MenuSummary

    var body: some View {
        let total = Double(max(summary.barTotal, 1))
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Array(summary.groups.enumerated()), id: \.element.id) { i, g in
                        Theme.bars[min(i, 2)].frame(width: geo.size.width * Double(g.bytes) / total)
                    }
                    Theme.bars[3]
                }
            }
            .frame(height: 10).clipShape(RoundedRectangle(cornerRadius: 5))
            .accessibilityElement().accessibilityLabel(model.t("RAM theo chủ sở hữu", "Memory by owner"))
            legend
        }
    }

    var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(summary.groups.enumerated()), id: \.element.id) { i, g in
                legendRow(color: Theme.bars[min(i, 2)], label: g.label + (g.children.count > 1 ? " · \(g.children.count - 1) \(model.t("cửa sổ", "windows"))" : ""),
                          bytes: g.bytes, expandable: !g.children.isEmpty, expanded: model.expandedGroup == g.id) {
                    model.expandedGroup = model.expandedGroup == g.id ? nil : g.id
                }
                if model.expandedGroup == g.id {
                    ForEach(g.children) { c in
                        HStack { Text(c.label).foregroundStyle(Theme.text2).lineLimit(1); Spacer(); Text(Format.bytes(c.bytes, model.lang)).foregroundStyle(Theme.text2) }
                            .font(Theme.small).monospacedDigit().padding(.leading, 18)
                    }
                }
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.bars[3]).frame(width: 9, height: 9)
                Text(model.t("Chương trình khác", "Other programs")).foregroundStyle(Theme.text2)
                if summary.unreadableCount > 0 {
                    Text("·").foregroundStyle(Theme.text2)
                    Button(model.t("Hệ thống: Đo chi tiết", "System: measure")) { model.measureSystem() }
                        .buttonStyle(.plain).foregroundStyle(Theme.accent)
                }
                Spacer()
                Text(Format.bytes(summary.othersBytes, model.lang)).foregroundStyle(Theme.text2)
            }
            .font(Theme.small).monospacedDigit()
        }
    }

    func legendRow(color: Color, label: String, bytes: Int64, expandable: Bool, expanded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
                if expandable { Text(expanded ? "⌄" : "›").foregroundStyle(Theme.text2) }
                Text(label).lineLimit(1)
                Spacer()
                Text(Format.bytes(bytes, model.lang)).monospacedDigit()
            }
            .font(Theme.small).foregroundStyle(Theme.text).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(expandable)  // not `.disabled`: that dims the row
    }
}

struct VerdictTag: View {
    @EnvironmentObject var model: HogModel
    let verdict: Verdict
    var body: some View {
        switch verdict {
        case .mayStop: Text("● " + model.t("có thể tắt", "can stop")).foregroundStyle(Theme.red)
        case .ask: Text("◐ " + model.t("hỏi trước", "ask first")).foregroundStyle(Theme.warn)
        case .watch: Text("○ " + model.t("để ý", "watch")).foregroundStyle(Theme.text2)
        case .info: Text("· " + model.t("thông tin", "info")).foregroundStyle(Theme.text2)
        }
    }
}

struct SuggestionCard: View {
    @EnvironmentObject var model: HogModel
    let card: MenuSummary.Card

    var verdictText: Text {
        switch card.verdict {
        case .mayStop: Text("● " + model.t("có thể tắt", "can stop")).foregroundColor(Theme.red)
        case .ask: Text("◐ " + model.t("hỏi trước", "ask first")).foregroundColor(Theme.warn)
        case .watch: Text("○ " + model.t("để ý", "watch")).foregroundColor(Theme.text2)
        case .info: Text("· " + model.t("thông tin", "info")).foregroundColor(Theme.text2)
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.s2) {
            VStack(alignment: .leading, spacing: 2) {
                // One Text so a long name wraps instead of being cut ("Phiên Cl…").
                (verdictText.font(Theme.captionBold) + Text("  ") + Text(card.label)
                 + Text(card.bytes.map { "  " + Format.bytes($0, model.lang) } ?? "").foregroundColor(Theme.text2))
                    .font(Theme.body).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                Text(card.reason).font(Theme.caption).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            switch card.action {
            case .stop: SmallButton(title: model.t("Dừng…", "Stop…")) { model.prepareStop(card.itemId) }
            case .howTo: SmallButton(title: model.t("Cách đóng", "How to")) { model.prepareStop(card.itemId) }
            case .why: Button(model.t("Vì sao?", "Why?")) { model.page = .why(card.itemId) }.buttonStyle(.plain).foregroundStyle(Theme.accent).font(Theme.small)
            }
        }
        .padding(.vertical, Theme.s2).padding(.horizontal, 10).tile()
        .contentShape(Rectangle())
        .onTapGesture { model.page = .why(card.itemId) }
    }
}

struct SmallButton: View {
    let title: String
    var role: Role = .normal
    var height: CGFloat = 24
    let action: () -> Void
    enum Role { case normal, primary, danger }

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).frame(minHeight: height)
                .foregroundStyle(role == .normal ? Theme.text : .white)
                .background(role == .danger ? Theme.redBg : (role == .primary ? Theme.accentBg : Theme.raised), in: RoundedRectangle(cornerRadius: Theme.rButton))
                .overlay(RoundedRectangle(cornerRadius: Theme.rButton).strokeBorder(role == .normal ? Theme.sep : .clear, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2).frame(maxWidth: .infinity, alignment: .leading) }
}

struct Footer: View {
    @EnvironmentObject var model: HogModel
    var body: some View {
        HStack(spacing: Theme.s2) {
            if let s = model.summary {
                Text(model.t("Cập nhật ", "Updated ") + s.takenAt.formatted(date: .omitted, time: .shortened)
                     + (s.selfBytes.map { " · " + model.t("hog dùng ", "hog uses ") + Format.bytes($0, model.lang) } ?? ""))
                    .monospacedDigit()
            }
            Spacer()
            Button(model.t("Làm mới", "Refresh")) { model.refresh() }.buttonStyle(.plain).foregroundStyle(Theme.accent)
            Button(model.t("Cài đặt", "Settings")) { model.page = .settings }.buttonStyle(.plain).foregroundStyle(Theme.accent)
        }
        .font(Theme.caption).foregroundStyle(Theme.text2)
        .padding(.horizontal, Theme.s3).padding(.vertical, Theme.s2)
    }
}

struct BackButton: View {
    @EnvironmentObject var model: HogModel
    var body: some View {
        Button("‹ " + model.t("Quay lại", "Back")) { model.page = .main }
            .buttonStyle(.plain).foregroundStyle(Theme.accent).font(Theme.small)
    }
}
