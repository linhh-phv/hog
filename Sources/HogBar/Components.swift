import AppKit
import HogCore
import SwiftUI

// Components of the compact menu (docs/design/compact/screens.html), built from native macOS controls.

/// RAM gauge + state phrase + one line. Tapping the gauge explains RAM (and the compressed part).
struct StatusHeader: View {
    @EnvironmentObject var model: HogModel
    let o: Overview
    @State private var explain = false

    var body: some View {
        HStack(spacing: Theme.s3) {
            Button { explain.toggle() } label: {
                Gauge(value: ramFraction) {
                    Text("RAM")
                } currentValueLabel: {
                    VStack(spacing: -2) {
                        Text(o.ramUsed.map { _ in Format.percent(ramFraction * 100, model.lang).replacingOccurrences(of: " ", with: "") } ?? "?")
                        Text("RAM").font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(Theme.pressure(o.pressure))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.t("RAM đã dùng", "Memory used"))
            .accessibilityValue(Format.percent(ramFraction * 100, model.lang))
            .popover(isPresented: $explain, arrowEdge: .bottom) {
                Explanation(id: "memory-used", extra: o.compressed.map {
                    model.t("Trong đó \(Format.bytes($0, model.lang)) đã được nén để vừa RAM.",
                            "Of it, \(Format.bytes($0, model.lang)) is compressed to fit.")
                })
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if o.status.tone != .ok { Image(systemName: "exclamationmark.triangle.fill") }
                    Text(o.status.title)
                }
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.tone(o.status.tone))
                Text(o.status.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    var ramFraction: Double {
        guard let used = o.ramUsed, o.ramTotal > 0 else { return 0 }
        return min(1, Double(used) / Double(o.ramTotal))
    }
}

/// One plain number; tapping it explains it in plain words (replaces the old "?" buttons).
struct MetricChip<Value: View>: View {
    @EnvironmentObject var model: HogModel
    let label: String
    let glossaryId: String
    @ViewBuilder let value: Value
    @State private var explain = false

    var body: some View {
        Button { explain.toggle() } label: {
            VStack(alignment: .leading, spacing: 1) {
                value.font(.callout.weight(.semibold)).monospacedDigit().lineLimit(1)
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.s2).padding(.vertical, 6)
            .module()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $explain, arrowEdge: .bottom) { Explanation(id: glossaryId, extra: nil) }
    }
}

/// Glossary entry in plain words, for popovers.
struct Explanation: View {
    @EnvironmentObject var model: HogModel
    let id: String
    let extra: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let e = model.glossary(id) {
                Text(e.name.text(model.lang) ?? id).font(.headline)
                Text(e.plain.text(model.lang) ?? "")
                Text(e.howToRead.text(model.lang) ?? "").foregroundStyle(.secondary)
                if let extra { Text(extra).foregroundStyle(.secondary) }
                if let am = e.activityMonitor {
                    Text(model.t("Activity Monitor gọi là \"\(am)\"", "Activity Monitor calls it \"\(am)\"")).font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 280, alignment: .leading)
        .padding(Theme.s3)
    }
}

/// A short reason in a capsule; tapping it says the whole reason.
struct ReasonTag: View {
    @EnvironmentObject var model: HogModel
    let c: Overview.Cleanup
    @State private var explain = false

    var body: some View {
        Button { explain.toggle() } label: {
            Text(c.why).font(.caption.weight(.medium)).monospacedDigit()
                .foregroundStyle(c.whyKind == .idle ? Color.orange : Color.red)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background((c.whyKind == .idle ? Color.orange : Color.red).opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $explain, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(c.name).font(.headline)
                if let f = model.snapshot?.findings.first(where: { $0.itemId == c.itemId }) {
                    Text(f.reason)
                    Text(f.stop.effect).foregroundStyle(.secondary)
                }
            }
            .font(.callout).fixedSize(horizontal: false, vertical: true).frame(width: 280, alignment: .leading).padding(Theme.s3)
        }
    }
}

/// One line of "Nên dọn": check box · name · project · reason · RAM.
struct CleanupRow: View {
    @EnvironmentObject var model: HogModel
    let c: Overview.Cleanup

    var body: some View {
        HStack(spacing: Theme.s2) {
            if c.manual {
                Image(systemName: "hand.raised").foregroundStyle(.secondary).frame(width: 16)
            } else {
                Toggle("", isOn: Binding(get: { model.selected.contains(c.itemId) },
                                         set: { if $0 { model.selected.insert(c.itemId) } else { model.selected.remove(c.itemId) } }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel(c.name)
            }
            (Text(c.name) + Text(c.project.map { " · \($0)" } ?? "").foregroundColor(.secondary))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if c.manual {
                Button(model.t("Cách đóng", "How to close")) { model.prepareStop(c.itemId) }.buttonStyle(.link).font(.caption)
            } else {
                ReasonTag(c: c)
            }
            Text(c.bytes.map { Format.bytes($0, model.lang) } ?? "–").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .frame(minHeight: 26)
    }
}

/// A group of "Đang chạy": icon · name · summary · RAM · CPU; tap opens it.
struct GroupRow: View {
    @EnvironmentObject var model: HogModel
    let g: Overview.Group

    var body: some View {
        Button { if g.kind == .system { model.measureSystem() } else { withAnimation(.easeOut(duration: 0.15)) { model.toggle(g.id) } } } label: {
            HStack(spacing: Theme.s2) {
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(model.expanded.contains(g.id) ? 90 : 0)).frame(width: 10)
                GroupIcon(g: g)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Text(g.name).lineLimit(1).truncationMode(.tail)
                        if g.kind == .project {
                            Text(model.t("dự án", "project")).font(.caption2.weight(.semibold)).foregroundStyle(.tint)
                                .padding(.horizontal, 4).overlay(Capsule().stroke(.tint, lineWidth: 0.8))
                        }
                    }
                    Text(g.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(g.kind == .system ? "—" : Format.bytes(g.bytes, model.lang)).monospacedDigit().frame(minWidth: 54, alignment: .trailing)
                Text(g.cpu.map { Format.percent($0, model.lang) } ?? "–").monospacedDigit().foregroundStyle(cpuColor)
                    .frame(minWidth: 40, alignment: .trailing)
            }
            .font(.callout)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(model.t("Mở để xem từng thứ", "Opens to show each thing"))
    }

    var cpuColor: Color { (g.cpu ?? 0) >= Overview.heavyCPU ? .red : .secondary }
}

/// The app's own icon, else a symbol for projects, "Other" and macOS.
struct GroupIcon: View {
    let g: Overview.Group
    var body: some View {
        Group {
            if let path = g.appPath.map({ ($0 as NSString).expandingTildeInPath }), FileManager.default.fileExists(atPath: path) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
            } else {
                Image(systemName: symbol)
                .foregroundStyle(g.kind == .project ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        }
        .frame(width: 18, height: 18)
    }

    var symbol: String {
        switch g.kind {
        case .project: "folder.fill"
        case .app: "app.dashed"
        case .other: "square.grid.2x2"
        case .system: "apple.logo"
        }
    }
}

/// A thing inside an open group: name · "?" when unknown · detail · RAM · CPU.
struct EntryRow: View {
    @EnvironmentObject var model: HogModel
    let g: Overview.Group
    let e: Overview.Entry

    var body: some View {
        Button { model.page = .entry(group: g.id, entry: e.id) } label: {
            HStack(spacing: 4) {
                Text(e.name).lineLimit(1).truncationMode(.tail)
                if e.unknown { Image(systemName: "questionmark.circle").foregroundStyle(.orange).accessibilityLabel(model.t("chưa rõ", "unknown")) }
                if !e.detail.isEmpty { Text("· " + e.detail).foregroundStyle(.secondary).lineLimit(1) }
                if e.pids.count > 1 { Text("×\(e.pids.count)").foregroundStyle(.tertiary) }
                Spacer(minLength: 4)
                if let c = e.cleanup { Text(c.why).font(.caption).foregroundStyle(c.whyKind == .idle ? .orange : .red) }
                Text(e.bytes.map { Format.bytes($0, model.lang) } ?? "–").monospacedDigit().frame(minWidth: 54, alignment: .trailing)
                Text(e.cpu.map { Format.percent($0, model.lang) } ?? "–").monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 40, alignment: .trailing)
            }
            .font(.callout)
            .padding(.leading, 30)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct Footer: View {
    @EnvironmentObject var model: HogModel
    var body: some View {
        HStack(spacing: Theme.s2) {
            if model.scanning { ProgressView().controlSize(.mini) }
            if let o = model.overview {
                Text(o.takenAt.formatted(date: .omitted, time: .shortened)
                     + (o.selfBytes.map { " · hog " + Format.bytes($0, model.lang) } ?? ""))
                    .monospacedDigit()
            }
            Spacer()
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help(model.t("Làm mới", "Refresh")).disabled(model.scanning)
            Button { model.page = .settings } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help(model.t("Cài đặt", "Settings"))
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, Theme.s3).padding(.vertical, Theme.s2)
    }
}

struct BackButton: View {
    @EnvironmentObject var model: HogModel
    var body: some View {
        Button { model.page = model.back } label: { Label(model.t("Quay lại", "Back"), systemImage: "chevron.left") }
            .buttonStyle(.borderless).font(.callout)
    }
}
