import AppKit
import HogCore
import SwiftUI

/// Menu bar app. `HogBar --render <dir> [--sample] [--lang vi|en]` writes PNGs of every page (light, and dark for the
/// main page) for comparing with the approved mock (docs/design/compact/screens.html) and exits.
@main
struct HogBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = HogModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
                .onAppear { model.page = .main; model.toast = nil; model.copied = nil; model.refresh() }
        } label: {
            Image(nsImage: model.icon)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // no Dock icon (LSUIElement in the bundle does the same)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            Task { @MainActor in
                await Renderer.render(to: URL(fileURLWithPath: args[i + 1]), sample: args.contains("--sample"))
                exit(0)
            }
        }
    }
}

@MainActor
enum Renderer {
    static func render(to dir: URL, sample: Bool) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Theme.offscreen = true
        let model = HogModel()
        if let i = CommandLine.arguments.firstIndex(of: "--lang"), i + 1 < CommandLine.arguments.count {
            model.overrideLang = Lang(rawValue: CommandLine.arguments[i + 1])
        }
        let snapshot: Snapshot
        if sample {
            snapshot = Self.sampleSnapshot(lang: model.lang)
        } else {
            let analyzer = Analyzer.standard(lang: model.lang, full: true)
            snapshot = await Task.detached { analyzer.analyze(Scanner().scan()) }.value
        }
        model.load(snapshot)
        model.scanning = false

        write(model, dir, "menu-main-light")
        write(model, dir, "menu-main-dark", dark: true)
        if let g = model.overview?.groups.first(where: { $0.kind == .project }) {
            model.expanded = [g.id]
            write(model, dir, "menu-project-light")
            model.expanded = []
            if let e = g.entries.first(where: \.unknown) ?? g.entries.first {
                model.page = .entry(group: g.id, entry: e.id)
                write(model, dir, "menu-entry-light")
            }
        }
        if let c = model.overview?.cleanups.first(where: { $0.whyKind == .heavy }) {
            model.open(c)
            write(model, dir, "menu-cleanup-entry-light")
        }
        // Something hog knows (catalog): explained, no "Chép thông tin".
        if let c = model.overview?.cleanups.first(where: { $0.whyKind == .idle }) {
            model.open(c)
            write(model, dir, "menu-cleanup-known-light")
        }
        model.page = .all
        write(model, dir, "menu-all-light")
        model.page = .main
        if sample {
            model.batch = Self.samplePlans(model)
            write(model, dir, "menu-clean-light")
            model.batch = nil
            model.load(Self.sampleSnapshot(lang: model.lang, hot: true))
            write(model, dir, "menu-hot-light")
            model.load(Self.sampleSnapshot(lang: model.lang, calm: true))
            write(model, dir, "menu-calm-light")
        }
        print("rendered to \(dir.path)")
    }

    /// Lays the menu out in a real (off-screen) AppKit window, like the menu bar panel: unlike `ImageRenderer`, this draws
    /// `ScrollView` content. The menu's material is drawn as the window background colour (materials need a screen).
    static func write(_ model: HogModel, _ dir: URL, _ name: String, dark: Bool = false) {
        let view = MenuView().environmentObject(model)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }

    /// Fake data shaped like a real run (no real names): two projects, two apps, a few small things.
    static func sampleSnapshot(lang: Lang, hot: Bool = false, calm: Bool = false) -> Snapshot {
        func proc(_ pid: Int32, _ exe: String, mb: Int64, cpu: Double, project: String? = nil, owner: String? = nil, item: String? = nil,
                  catalogId: String? = nil, port: Int? = nil, age: Int64 = 86_400) -> ProcessRecord {
            ProcessRecord(pid: pid, exe: Measured(exe), ageS: Measured(age), footprintBytes: Measured(mb * 1_000_000),
                          cpu: ProcessCPU(nowPct: Measured(cpu)), project: Measured(project),
                          net: ProcessNet(listen: port.map { [ListenSocket(addr: "*", port: $0)] } ?? []),
                          catalogId: Measured(catalogId), ownerId: Measured(owner), itemId: Measured(item))
        }
        let k = hot ? 1.0 : 0.0
        var processes = [
            proc(101, "Code Helper (Renderer)", mb: 3_100, cpu: 6 + 20 * k, owner: "vscode:1", catalogId: "vscode-renderer"),
            proc(102, "Code Helper (Plugin)", mb: 612, cpu: 2, owner: "vscode:1", catalogId: "tsserver"),
            proc(103, "node", mb: 484, cpu: 1, project: "web-app", owner: "vscode:1", port: 3000),
            proc(104, "watchman", mb: 323, cpu: 0, owner: nil, item: "proc:104:1", catalogId: "watchman", age: 10_800),
            proc(105, "claude", mb: 390, cpu: 0, project: "web-app", owner: "claude:105", catalogId: "claude-code-session"),
            proc(106, "python3.12", mb: 256, cpu: 0, project: "web-app", owner: "vscode:1", port: 8000, age: 172_800),
            proc(201, "Code Helper (Renderer)", mb: 1_100, cpu: 2, owner: "vscode:2", catalogId: "vscode-renderer"),
            proc(202, "node", mb: 393, cpu: hot ? 310 : 88, project: "api", owner: "vscode:2", item: "proc:202:1", port: 4000),
            proc(301, "Google Chrome Helper (Renderer)", mb: 2_900, cpu: 6, owner: "app:chrome"),
            proc(302, "Google Chrome", mb: 500, cpu: 1, owner: "app:chrome"),
            proc(401, "Discord Helper (Renderer)", mb: 857, cpu: 1, owner: "app:discord"),
            proc(501, "zsh", mb: 4, cpu: 0, project: "web-app", owner: "vscode:1", catalogId: "shell"),
            proc(601, "figma_agent", mb: 98, cpu: 0),
        ]
        if calm { processes.removeAll { $0.itemId.value != nil } }
        let owners = [
            Owner(id: "app:code", kind: .app, label: "Visual Studio Code"),
            Owner(id: "vscode:1", kind: .vscodeWindow, label: "web-app", parent: "app:code", project: "web-app"),
            Owner(id: "vscode:2", kind: .vscodeWindow, label: "api", parent: "app:code", project: "api"),
            Owner(id: "claude:105", kind: .claudeSession, label: "Claude — web-app", parent: "vscode:1", project: "web-app"),
            Owner(id: "app:chrome", kind: .app, label: "Google Chrome"),
            Owner(id: "app:discord", kind: .app, label: "Discord"),
        ]
        let watchman = Item(id: "proc:104:1", kind: .process, label: "Watchman", catalogId: "watchman", pids: [104],
                            footprintBytes: Measured(323_000_000), facts: ["age_s": .int(10_800)])
        let node = Item(id: "proc:202:1", kind: .process, label: "node", pids: [202], ownerId: "vscode:2",
                        footprintBytes: Measured(393_000_000), facts: ["cpu.now_pct": .double(hot ? 310 : 88)])
        func finding(_ id: String, _ v: Verdict, _ rules: [String], _ reason: String, _ strategy: StopStrategy) -> Finding {
            Finding(itemId: id, verdict: v, confidence: .high, rules: rules, reason: reason, evidence: [:], unmeasured: [],
                    stop: StopAdvice(strategy: strategy, respawns: .onDemand,
                                     effect: lang == .vi ? "Không mất dữ liệu.\nCần thì nó tự bật lại." : "No data is lost.\nIt starts again when needed."))
        }
        let vi = lang == .vi
        return Snapshot(
            lang: lang, takenAt: Date(timeIntervalSince1970: 1_793_000_000),  // fixed: renders are reproducible
            hog: HogInfo(pid: getpid(), ancestors: [], ancestorsComplete: true, selfFootprintBytes: Measured(23_000_000)),
            host: HostInfo(arch: "arm64", ncpu: 8, memTotalBytes: 17_179_869_184, uptimeS: nil),
            memory: MemoryInfo(usedBytes: Measured(hot ? 16_400_000_000 : (calm ? 9_800_000_000 : 12_500_000_000)),
                               compressorBytes: Measured(3_330_000_000), compressedStoredBytes: Measured(6_900_000_000),
                               swapUsedBytes: Measured(hot ? 7_800_000_000 : (calm ? 0 : 5_600_000_000)),
                               pressure: Measured(hot ? .critical : .normal), unreadableProcessCount: 181, measuredFootprintBytes: 21_000_000_000),
            cpu: CPUInfo(idlePct: Measured(hot ? 22 : 88), thermal: Measured(hot ? .serious : .nominal),
                         top: Measured([CPUUser(id: "system", label: "macOS", pct: 34, count: 0)])),
            heat: HeatInfo(chip: Measured("Apple M1 Pro"), keyTable: Measured("m1"), keysVerified: Measured(true),
                           cpuAvgC: Measured(hot ? 88.4 : 52.8), cpuMaxC: Measured(hot ? 93.1 : 54.5), cpuSensors: 10,
                           gpuAvgC: Measured(hot ? 74.0 : 51.6), gpuMaxC: Measured(hot ? 75.2 : 52.9), gpuSensors: 2,
                           fans: Measured([HeatInfo.Fan(index: 0, rpm: Measured(hot ? 4_210 : 0), minRpm: Measured(1200), maxRpm: Measured(5779)),
                                           HeatInfo.Fan(index: 1, rpm: Measured(hot ? 4_530 : 0), minRpm: Measured(1200), maxRpm: Measured(6241))])),
            headline: Headline(level: .ok, text: "", glossaryIds: []),
            sensors: [], owners: owners, processes: processes, items: calm ? [] : [watchman, node],
            findings: calm ? [] : [
                finding(watchman.id, .mayStop, ["watchman-no-subscribers"],
                        vi ? "Watchman đã chạy 3 giờ mà không công cụ nào dùng tới nó." : "Watchman has been running for 3 hours and no tool is using it.", .watchmanShutdown),
                finding(node.id, hot ? .mayStop : .watch, ["cpu-heavy"],
                        vi ? "Đang dùng \(hot ? 39 : 11) % CPU của cả máy — một lý do máy nóng." : "Using \(hot ? 39 : 11) % of the machine's CPU — one reason the machine is hot.", .signal),
            ])
    }

    /// Plans for the "Dọn" sheet without a live scan (the sample processes do not exist on this machine).
    static func samplePlans(_ model: HogModel) -> [StopPlan] {
        guard let s = model.snapshot else { return [] }
        let scan = Scan(system: RawSystem(memTotalBytes: 0, ncpu: 1, pageSize: 16384), processes: [:])
        return s.items.filter { model.selected.contains($0.id) }.map { item in
            var plan = model.stopper.plan(.process(item.pids.first ?? 0, startSec: nil, startUsec: nil), item: item, snapshot: s, scan: scan)
            plan.gates = plan.gates.filter { $0.gate != "G6" }
            return plan
        }
    }
}
