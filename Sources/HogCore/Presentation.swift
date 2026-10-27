import Foundation

/// Presentation rules shared by the CLI, the analyzer and the app that are not part of `Overview`: which glossary
/// entries each shown number links to, the CPU top, and which items count as "not known yet" candidates kept through the snapshot size cap.
public enum Presentation {
    /// Glossary entries the menu's gauge and number chips open (Overview page). Tested to exist in both languages.
    public static let tileGlossaryIds = ["memory-used", "cpu-machine", "swap-used", "temperature", "thermal-state", "cpu-pct"]

    /// Every number the CLI prints, with its glossary entry.
    public static let cliGlossaryIds = ["memory-pressure", "memory-used", "compressed-stored", "compressor-occupied", "swap-used", "cpu-pct",
                                        "load", "footprint", "ram-total", "cpu-machine", "thermal-state",
                                        "temperature", "fans"]

    /// Glossary entry for every measured fact (`hog explain <item>` prints it next to the number).
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

    public static let maxCPURows = 3
    /// Rows under 1% of a core are noise.
    static let minCPURowPct: Double = 1
    /// Unknown-item candidates are big enough to matter, and at most this many survive the `--json` size cap.
    public static let unknownMinBytes: Int64 = 100_000_000
    public static let maxUnknownCandidates = 6

    /// Biggest CPU users (`cpu.top`, computed from the whole scan by the analyzer). Empty in fast mode.
    public static func cpuRows(_ s: Snapshot, max n: Int) -> [CPUUser] {
        Array((s.cpu.top.value ?? []).filter { $0.pct >= minCPURowPct }.prefix(n))
    }

    /// No catalog entry, big enough, not hard-protected (macOS itself), not part of an app (a "Google Chrome Helper"
    /// is explained by its app), a process: something to ask about.
    public static func isUnknownCandidate(_ i: Item) -> Bool {
        (i.catalogId.value ?? "").isEmpty && i.protection.value?.level != .hard && i.kind == .process
            && i.facts["owner.kind"] != .string("app") && (i.footprintBytes.value ?? 0) >= unknownMinBytes
    }
}
