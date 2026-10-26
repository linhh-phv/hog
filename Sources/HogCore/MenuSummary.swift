import Foundation

/// What the menu bar app shows, derived from a snapshot (docs/design/design-system.md, "Luật dùng"). Kept in HogCore
/// so the presentation rules are tested without UI.
public struct MenuSummary: Sendable, Equatable {
    public struct Group: Sendable, Equatable, Identifiable {
        public var id: String
        public var label: String
        public var bytes: Int64
        /// Owners inside this group (VS Code windows), plus "shared" for the group's own processes.
        public var children: [Child]
    }

    public struct Child: Sendable, Equatable, Identifiable {
        public var id: String
        public var label: String
        public var bytes: Int64
    }

    public enum Action: Sendable, Equatable { case stop, howTo, why }

    public struct Card: Sendable, Equatable, Identifiable {
        public var id: String { itemId }
        public var itemId: String
        public var verdict: Verdict
        public var label: String
        public var bytes: Int64?
        public var reason: String
        public var action: Action
    }

    public struct Note: Sendable, Equatable, Identifiable {
        public var id: String { sensor }
        public var sensor: String
        public var text: String
    }

    public var headline: String
    public var level: HeadlineLevel
    public var pressure: Pressure?
    public var compressedStored: Int64?
    public var compressor: Int64?
    public var swapUsed: Int64?
    /// Top groups for the RAM bar (at most `maxGroups`).
    public var groups: [Group]
    /// Measured footprint of everything not in `groups`.
    public var othersBytes: Int64
    /// Base of the bar: the measured footprint of all readable processes.
    public var barTotal: Int64
    public var unreadableCount: Int
    public var cards: [Card]
    /// Suggestions not shown as cards ("+ N đề xuất khác").
    public var moreCount: Int
    public var notes: [Note]
    public var selfBytes: Int64?
    public var takenAt: Date

    public static let maxGroups = 3
    public static let maxCards = 3

    public static func make(_ s: Snapshot) -> MenuSummary {
        let lang = s.lang
        func t(_ vi: String, _ en: String) -> String { lang == .vi ? vi : en }

        // Groups: top-level owners and items with no owner, largest first.
        var all: [Group] = s.owners.filter { $0.parent.value == nil }.map { o in
            var children = s.owners.filter { $0.parent.value == o.id }
                .sorted { $0.totalFootprintBytes > $1.totalFootprintBytes }
                .map { Child(id: $0.id, label: $0.label, bytes: $0.totalFootprintBytes) }
            if !children.isEmpty, o.selfFootprintBytes > 0 {
                children.append(Child(id: o.id + ":shared", label: t("Phần chung (GPU, terminal…)", "Shared (GPU, terminals…)"),
                                      bytes: o.selfFootprintBytes))
            }
            return Group(id: o.id, label: o.label, bytes: o.totalFootprintBytes, children: children)
        }
        for i in s.items where i.ownerId.value == nil {
            if let b = i.footprintBytes.value { all.append(Group(id: i.id, label: i.label, bytes: b, children: [])) }
        }
        all.sort { ($0.bytes, $0.id) > ($1.bytes, $1.id) }
        let groups = Array(all.prefix(maxGroups))
        let total = max(s.memory.measuredFootprintBytes, groups.reduce(0) { $0 + $1.bytes })
        let others = max(0, total - groups.reduce(0) { $0 + $1.bytes })

        // Cards: may-stop → ask → watch; info stays out of the menu.
        let order: [Verdict] = [.mayStop, .ask, .watch]
        let shown = s.findings.filter { order.contains($0.verdict) }
            .sorted { (order.firstIndex(of: $0.verdict)!, $0.itemId) < (order.firstIndex(of: $1.verdict)!, $1.itemId) }
        let items = Dictionary(uniqueKeysWithValues: s.items.map { ($0.id, $0) })
        let cards = shown.prefix(maxCards).map { f -> Card in
            let item = items[f.itemId]
            let action: Action = switch f.verdict {
            case .mayStop, .ask: f.stop.strategy == .manual ? .howTo : .stop
            default: .why
            }
            return Card(itemId: f.itemId, verdict: f.verdict, label: item?.label ?? f.itemId, bytes: item?.footprintBytes.value,
                        reason: f.reason, action: action)
        }

        let notes = s.sensors.filter { $0.status == .unavailable || $0.status == .error }.map { st -> Note in
            let text: String = switch (st.name, st.status) {
            case ("docker", .unavailable): t("Docker — engine đang tắt (không phải lỗi).", "Docker — the engine is stopped (not an error).")
            case ("watchman", .unavailable): t("watchman — không có server nào đang chạy.", "watchman — no server running.")
            case ("vscode", .unavailable): t("VS Code — không tìm thấy lệnh `code`.", "VS Code — the `code` command was not found.")
            case ("claude", .unavailable): t("Phiên Claude — chưa đọc được.", "Claude sessions — could not be read.")
            default: "\(st.name) — \(st.note.value ?? st.status.rawValue)"
            }
            return Note(sensor: st.name, text: text)
        }

        return MenuSummary(headline: s.headline.text, level: s.headline.level, pressure: s.memory.pressure.value,
                           compressedStored: s.memory.compressedStoredBytes.value, compressor: s.memory.compressorBytes.value,
                           swapUsed: s.memory.swapUsedBytes.value, groups: groups, othersBytes: others, barTotal: total,
                           unreadableCount: s.memory.unreadableProcessCount, cards: Array(cards), moreCount: max(0, shown.count - cards.count),
                           notes: notes, selfBytes: s.hog.selfFootprintBytes.value, takenAt: s.takenAt)
    }
}
