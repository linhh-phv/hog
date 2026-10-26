import Foundation
@testable import HogCore

enum Fixtures {
    /// Root of the bundled fixtures (`Tests/HogCoreTests/Fixtures`).
    static var root: URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures") }

    static func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    static func text(_ relative: String) throws -> String { try String(contentsOf: url(relative), encoding: .utf8) }

    /// Source-tree location of a fixture, used to (re)write golden files with `HOG_UPDATE_GOLDEN=1`.
    static func sourceURL(_ relative: String, file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)").deletingLastPathComponent().appendingPathComponent("Fixtures").appendingPathComponent(relative)
    }
}

/// A fixed snapshot with fake data, mirroring the example in design section 4.
enum SampleSnapshot {
    static let takenAt = ISO8601DateFormatter().date(from: "2026-10-26T03:44:55Z")!
    static let watchmanStart = ISO8601DateFormatter().date(from: "2026-10-15T08:08:52Z")!

    static func make() -> Snapshot {
        let itemId = "proc:74939:1792051732"
        let facts: [String: FactValue] = [
            "orphan": .bool(false), "age_s": .int(934563), "cpu.avg_pct": .double(0.0),
            "footprint_bytes": .int(1_380_000_000), "resident_ratio": .double(0.005), "net.established": .int(0),
            "owner.kind": .string("none"), "owner.busy": .bool(false), "watchman.subscriptions": .int(0),
            "launchd.label": .string("com.github.facebook.watchman"), "launchd.restarts_after_stop": .bool(false),
        ]
        return Snapshot(
            lang: .vi,
            takenAt: takenAt,
            hog: HogInfo(pid: 4242, ancestors: [4100, 3990, 3801], ancestorsComplete: true, selfFootprintBytes: Measured(31_000_000)),
            host: HostInfo(arch: "arm64", ncpu: 8, memTotalBytes: 17_179_869_184, uptimeS: Measured(1_255_000)),
            memory: MemoryInfo(freeBytes: Measured(65_000_000), wiredBytes: Measured(2_731_000_000),
                               compressorBytes: Measured(5_720_000_000), compressedStoredBytes: Measured(11_130_000_000),
                               swapUsedBytes: Measured(3_292_000_000), swapTotalBytes: Measured(4_294_967_296),
                               pressure: Measured(.normal), unreadableProcessCount: 200, measuredFootprintBytes: 19_050_000_000, systemDetail: nil),
            cpu: CPUInfo(userPct: Measured(8.5), sysPct: Measured(13.1), idlePct: Measured(78.4), load: Measured([1.6, 2.2, 2.7])),
            headline: Headline(level: .ok,
                               text: "Máy chưa thiếu RAM (áp lực: bình thường), nhưng đã nén 10,4 GB dữ liệu (chiếm 5,3 GB RAM) và đẩy 3,1 GB ra ổ đĩa. Có 1 thứ có thể tắt: watchman (giữ 1,3 GB, 11 ngày không ai dùng).",
                               glossaryIds: ["memory-pressure", "compressed-stored", "compressor-occupied", "swap-used"]),
            sensors: [
                SensorStatus(name: "native-proc", status: .ok, tookMs: 2),
                SensorStatus(name: "docker", status: .unavailable, tookMs: 0, note: "engine socket missing (engine stopped)"),
            ],
            owners: [
                Owner(id: "app:vscode", kind: .app, label: "Visual Studio Code", selfFootprintBytes: 1_500_000_000,
                      totalFootprintBytes: 5_200_000_000, totalCpuPct: Measured(6.0)),
                Owner(id: "vscode:7", kind: .vscodeWindow, label: "web-app (Workspace)", parent: "app:vscode", project: "web-app",
                      totalFootprintBytes: 2_100_000_000, totalCpuPct: Measured(1.2)),
            ],
            processes: [
                ProcessRecord(pid: 74939, ppid: Measured(1), own: Measured(true), exe: Measured("watchman"),
                              exePath: Measured("/opt/homebrew/bin/watchman"), args: nil,
                              startedAt: Measured(watchmanStart), ageS: Measured(934563),
                              footprintBytes: Measured(1_380_000_000), residentBytes: Measured(6_300_000),
                              residentRatio: Measured(0.005), compressedBytes: nil,
                              cpu: ProcessCPU(nowPct: Measured(0.0), avgPct: Measured(0.0)),
                              cwd: Measured("/"), project: nil, orphan: Measured(false),
                              net: ProcessNet(listen: [], established: Measured(0)),
                              catalogId: Measured("watchman"), ownerId: nil, itemId: Measured(itemId)),
            ],
            items: [
                Item(id: itemId, kind: .process, label: "Watchman", catalogId: "watchman", pids: [74939],
                     footprintBytes: Measured(1_380_000_000), residentRatio: Measured(0.005), protection: nil, facts: facts),
            ],
            findings: [
                Finding(itemId: itemId, verdict: .mayStop, confidence: .high,
                        rules: ["watchman-no-subscribers", "dormant-large"],
                        reason: "Watchman chạy 11 ngày, không công cụ nào đăng ký theo dõi, giữ 1,3 GB nhưng chỉ 6 MB còn nằm trong RAM — tức là lâu rồi không ai đụng tới.",
                        evidence: ["watchman.subscriptions": .int(0), "resident_ratio": .double(0.005), "age_s": .int(934563),
                                   "footprint_bytes": .int(1_380_000_000)],
                        unmeasured: [],
                        stop: StopAdvice(strategy: .watchmanShutdown, respawns: .onDemand,
                                         effect: "Tắt không mất dữ liệu: lần sau Metro/Jest cần thì nó được bật lại và quét lại thư mục một lần.")),
            ],
            warnings: []
        )
    }
}
