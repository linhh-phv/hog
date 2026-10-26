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

    /// A big item hog has no catalog entry for ("Chưa rõ là gì"): something to copy and ask about.
    public struct Unknown: Sendable, Equatable, Identifiable {
        public var id: String { itemId }
        public var itemId: String
        public var label: String
        public var bytes: Int64
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
    /// Every may-stop/ask/watch suggestion, in card order (the "all suggestions" page).
    public var allCards: [Card]
    /// Suggestions not shown as cards ("+ N đề xuất khác").
    public var moreCount: Int { allCards.count - cards.count }
    public var unknowns: [Unknown]
    public var notes: [Note]
    public var selfBytes: Int64?
    public var takenAt: Date

    public static let maxGroups = 3

    /// Glossary entries the app links to (metric tiles + "why" page). Tested to exist in both languages.
    public static let tileGlossaryIds = ["memory-pressure", "compressed-stored", "swap-used"]

    /// Every number the CLI status line prints, with its glossary entry (criterion 5).
    public static let cliGlossaryIds = ["memory-pressure", "compressed-stored", "compressor-occupied", "swap-used", "cpu-pct", "load", "footprint", "ram-total"]

    /// Glossary entry for every measured fact (`hog explain <item>` prints it next to the number; criterion 5).
    /// Structural facts (what something *is*) are excluded: they are names, not numbers.
    public static let factGlossary: [String: String] = [
        "orphan": "orphan", "age_s": "age", "cpu.now_pct": "cpu-pct", "cpu.avg_pct": "cpu-avg",
        "footprint_bytes": "footprint", "resident_ratio": "resident-ratio", "net.established": "net-established",
        "net.listen_count": "net-listen", "owner.busy": "idle-session", "owner.idle_s": "idle-session",
        "siblings.same_catalog_other_windows": "siblings", "container.restart_count": "restart-count",
        "container.restart_policy": "container-state", "container.state": "container-state", "container.uptime_s": "age",
        "container.connections": "net-established", "watchman.subscriptions": "watchman-subscriptions",
        "launchd.restarts_after_stop": "launchd-restarts", "session.busy": "idle-session", "session.idle_s": "idle-session",
    ]

    public struct WhyFact: Sendable {
        public var fact: String
        public var glossaryId: String
        public var vi: String
        public var en: String
    }

    /// Facts the app shows on the "why" page, with the glossary entry that explains each.
    public static let whyFacts: [WhyFact] = [
        WhyFact(fact: "age_s", glossaryId: "age", vi: "Đã chạy", en: "Running for"),
        WhyFact(fact: "footprint_bytes", glossaryId: "footprint", vi: "RAM của chương trình", en: "Program memory"),
        WhyFact(fact: "resident_ratio", glossaryId: "resident-ratio", vi: "Phần còn nằm trong RAM", en: "Share still in RAM"),
        WhyFact(fact: "cpu.avg_pct", glossaryId: "cpu-avg", vi: "CPU trung bình", en: "Average CPU"),
        WhyFact(fact: "orphan", glossaryId: "orphan", vi: "Mồ côi", en: "Orphaned"),
        WhyFact(fact: "net.established", glossaryId: "net-established", vi: "Kết nối đang mở", en: "Open connections"),
        WhyFact(fact: "watchman.subscriptions", glossaryId: "watchman-subscriptions", vi: "Công cụ đăng ký", en: "Subscribed tools"),
        WhyFact(fact: "session.idle_s", glossaryId: "idle-session", vi: "Phiên rảnh", en: "Session idle"),
        WhyFact(fact: "launchd.restarts_after_stop", glossaryId: "launchd-restarts", vi: "launchd bật lại khi tắt?", en: "launchd restarts it?"),
        WhyFact(fact: "container.restart_count", glossaryId: "restart-count", vi: "Số lần khởi động lại", en: "Restarts"),
    ]
    public static let maxCards = 3
    public static let maxUnknowns = 3
    /// "Chưa rõ là gì" only lists things big enough to matter.
    public static let unknownMinBytes: Int64 = 100_000_000

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
        let items = Dictionary(uniqueKeysWithValues: s.items.map { ($0.id, $0) })
        let shown = s.findings.filter { order.contains($0.verdict) }
            .sorted { a, b in
                let (ra, rb) = (order.firstIndex(of: a.verdict)!, order.firstIndex(of: b.verdict)!)
                if ra != rb { return ra < rb }
                let (ba, bb) = (items[a.itemId]?.footprintBytes.value ?? 0, items[b.itemId]?.footprintBytes.value ?? 0)
                return ba != bb ? ba > bb : a.itemId < b.itemId  // largest first
            }
        let allCards = shown.map { f -> Card in
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
            case ("vscode", .unavailable) where st.note.value?.contains("timed out") == true:
                t("VS Code — không trả lời lần trước; hog chờ VS Code khởi động lại mới hỏi tiếp.",
                  "VS Code — did not answer last time; hog waits for VS Code to restart before asking again.")
            case ("vscode", .unavailable): t("VS Code — không tìm thấy lệnh `code`.", "VS Code — the `code` command was not found.")
            case ("claude", .unavailable): t("Phiên Claude — chưa đọc được.", "Claude sessions — could not be read.")
            default: "\(st.name) — \(st.note.value ?? st.status.rawValue)"
            }
            return Note(sensor: st.name, text: text)
        }

        return MenuSummary(headline: s.headline.text, level: s.headline.level, pressure: s.memory.pressure.value,
                           compressedStored: s.memory.compressedStoredBytes.value, compressor: s.memory.compressorBytes.value,
                           swapUsed: s.memory.swapUsedBytes.value, groups: groups, othersBytes: others, barTotal: total,
                           unreadableCount: s.memory.unreadableProcessCount, cards: Array(allCards.prefix(maxCards)), allCards: allCards,
                           unknowns: unknowns(s, excluding: Set(allCards.prefix(maxCards).map(\.itemId))), notes: notes, selfBytes: s.hog.selfFootprintBytes.value, takenAt: s.takenAt)
    }

    /// Largest items with no catalog entry, at least `unknownMinBytes`, not hard-protected (macOS itself: nothing to ask
    /// about stopping), not part of an app (a "Google Chrome Helper" is already explained by its app), not a Claude
    /// session, not already shown as a card.
    static func unknowns(_ s: Snapshot, excluding: Set<String>) -> [Unknown] {
        s.items.compactMap { i -> Unknown? in
            guard (i.catalogId.value ?? "").isEmpty, i.protection.value?.level != .hard, !excluding.contains(i.id),
                  i.kind != .claudeSession, i.facts["owner.kind"] != .string("app"),
                  let b = i.footprintBytes.value, b >= unknownMinBytes else { return nil }
            return Unknown(itemId: i.id, label: i.label, bytes: b)
        }
        .sorted { ($0.bytes, $0.itemId) > ($1.bytes, $1.itemId) }
        .prefix(maxUnknowns).map { $0 }
    }
}
