import AppKit
import HogCore
import SwiftUI

/// Menu bar app. `HogBar --render <dir> [--sample]` writes PNGs of the menu (light + dark) for comparing with the
/// approved mock (docs/design/menubar/) and exits.
@main
struct HogBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = HogModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
                .onAppear { model.page = .main; model.toast = nil; model.copiedItem = nil; model.refresh() }
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
        let model = HogModel()
        if let i = CommandLine.arguments.firstIndex(of: "--lang"), i + 1 < CommandLine.arguments.count {
            model.overrideLang = Lang(rawValue: CommandLine.arguments[i + 1])
        }
        if sample {
            model.load(Self.sampleSnapshot())
        } else {
            let analyzer = Analyzer.standard(lang: model.lang)
            let snapshot = await Task.detached { analyzer.analyze(Scanner().scan()) }.value
            model.load(snapshot)
        }
        for (name, appearance) in [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
            for page in ["main", "expanded"] {
                model.expandedGroup = page == "expanded" ? model.summary?.groups.first?.id : nil
                let view = MenuView().environmentObject(model).environment(\.colorScheme, name == "dark" ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                var image: NSImage?
                appearance.performAsCurrentDrawingAppearance { image = renderer.nsImage }
                if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("menu-\(page)-\(name).png"))
                }
            }
        }
        model.expandedGroup = nil
        // Phase 2 pages: an unknown item, then every suggestion.
        if let unknown = model.summary?.unknowns.first {
            model.page = .item(unknown.itemId)
            write(model, dir, "menu-item-light")
        }
        if (model.summary?.moreCount ?? 0) > 0 {
            model.page = .suggestions
            write(model, dir, "menu-suggestions-light")
        }
        model.page = .main
        // CPU and heat (task cpu-thermal): the main page when the machine is hot.
        if sample {
            model.load(Self.sampleSnapshot(hot: true))
            write(model, dir, "menu-hot-light")
            model.load(Self.sampleSnapshot())
        }
        if let first = model.summary?.cards.first {
            model.prepareStopForRender(first.itemId)
            write(model, dir, "menu-stop-light")
        }
        print("rendered to \(dir.path)")
    }

    /// Lays the menu out in a real (off-screen) AppKit window, like the menu bar panel: unlike `ImageRenderer`, this draws
    /// `ScrollView` content (the item and suggestions pages scroll).
    static func write(_ model: HogModel, _ dir: URL, _ name: String) {
        let host = NSHostingView(rootView: MenuView().environmentObject(model).environment(\.colorScheme, .light))
        host.appearance = NSAppearance(named: .aqua)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }

    /// Fake data shaped like a real run (no real names).
    static func sampleSnapshot(hot: Bool = false) -> Snapshot {
        let item = Item(id: "proc:69339:1", kind: .process, label: "Watchman", catalogId: "watchman", pids: [69339],
                        footprintBytes: Measured(339_000_000), residentRatio: Measured(0.04),
                        facts: ["age_s": .int(10_800), "watchman.subscriptions": .int(0), "footprint_bytes": .int(339_000_000),
                                "resident_ratio": .double(0.04), "launchd.restarts_after_stop": .bool(false), "owner.kind": .string("none")])
        let s1 = Item(id: "claude:91747", kind: .claudeSession, label: "Claude Code — hub", pids: [91747], footprintBytes: Measured(226_000_000))
        let s2 = Item(id: "claude:39806", kind: .claudeSession, label: "Claude Code — hub", pids: [39806], footprintBytes: Measured(161_000_000))
        let node = Item(id: "proc:52311:1", kind: .process, label: "node", pids: [52311], footprintBytes: Measured(412_000_000),
                        residentRatio: Measured(0.3),
                        facts: ["age_s": .int(172_800), "footprint_bytes": .int(412_000_000), "cpu.avg_pct": .double(0.1),
                                "cpu.now_pct": .double(hot ? 88 : 0.2),
                                "net.listen_count": .int(1), "net.established": .int(0), "orphan": .bool(false),
                                "resident_ratio": .double(0.3), "owner.kind": .string("none")])
        let python = Item(id: "proc:48820:1", kind: .process, label: "python3.12", pids: [48820], footprintBytes: Measured(268_000_000),
                          facts: ["age_s": .int(86_400), "footprint_bytes": .int(268_000_000), "owner.kind": .string("none")])
        func f(_ id: String, _ reason: String, _ strategy: StopStrategy, _ verdict: Verdict = .mayStop) -> Finding {
            Finding(itemId: id, verdict: verdict, confidence: .high, rules: ["x"], reason: reason, evidence: [:], unmeasured: [],
                    stop: StopAdvice(strategy: strategy, respawns: .onDemand, effect: "Tắt không mất dữ liệu; lần sau Metro/Jest cần thì nó được bật lại."))
        }
        return Snapshot(
            lang: .vi, takenAt: Date(timeIntervalSince1970: 1_793_000_000),  // fixed: renders are reproducible
            hog: HogInfo(pid: getpid(), ancestors: [], ancestorsComplete: true, selfFootprintBytes: Measured(31_000_000)),
            host: HostInfo(arch: "arm64", ncpu: 8, memTotalBytes: 17_179_869_184, uptimeS: nil),
            memory: MemoryInfo(compressorBytes: Measured(3_330_000_000), compressedStoredBytes: Measured(7_410_000_000),
                               swapUsedBytes: Measured(6_010_000_000), pressure: Measured(.normal), unreadableProcessCount: 181,
                               measuredFootprintBytes: 21_000_000_000),
            cpu: CPUInfo(idlePct: Measured(hot ? 22 : 88), thermal: Measured(hot ? .serious : .nominal),
                         top: Measured(hot ? [CPUUser(id: "app:visual-studio-code", label: "Visual Studio Code", pct: 310, count: 24),
                                              CPUUser(id: "app:google-chrome", label: "Google Chrome", pct: 95, count: 12),
                                              CPUUser(id: "exe:node", label: "node", pct: 88, count: 1)]
                                        : [CPUUser(id: "app:visual-studio-code", label: "Visual Studio Code", pct: 14, count: 24)])),
            headline: Headline(level: hot ? .warn : .ok, text: "Máy chưa thiếu RAM, nhưng đã nén 6,9 GB dữ liệu (chiếm 3,1 GB RAM) và đẩy 5,6 GB ra ổ đĩa. Có 3 thứ có thể tắt."
                               + (hot ? " Máy đang nóng (macOS tự đánh giá) và có thể tự giảm tốc. Ăn CPU nhiều nhất: Visual Studio Code (310 %), Google Chrome (95 %), node (88 %)." : ""),
                               glossaryIds: []),
            sensors: [SensorStatus(name: "docker", status: .unavailable, tookMs: 0, note: "engine socket missing")],
            owners: [
                Owner(id: "app:visual-studio-code", kind: .app, label: "Visual Studio Code", selfFootprintBytes: 3_650_000_000, totalFootprintBytes: 11_600_000_000,
                      totalCpuPct: Measured(hot ? 310 : 14)),
                Owner(id: "vscode:1", kind: .vscodeWindow, label: "web-app (Workspace)", parent: "app:visual-studio-code", totalFootprintBytes: 4_720_000_000),
                Owner(id: "vscode:2", kind: .vscodeWindow, label: "hog (Workspace)", parent: "app:visual-studio-code", totalFootprintBytes: 1_930_000_000),
                Owner(id: "vscode:3", kind: .vscodeWindow, label: "api (Workspace)", parent: "app:visual-studio-code", totalFootprintBytes: 1_290_000_000),
                Owner(id: "app:google-chrome", kind: .app, label: "Google Chrome", totalFootprintBytes: 3_650_000_000, totalCpuPct: Measured(hot ? 95 : 6)),
                Owner(id: "app:discord", kind: .app, label: "Discord", totalFootprintBytes: 899_000_000),
            ],
            items: [item, s1, s2, node, python],
            findings: [f(item.id, "Watchman chạy 3 giờ, không công cụ nào đăng ký theo dõi.", .watchmanShutdown),
                       f(s1.id, "Phiên Claude rảnh 2 giờ, vẫn giữ 216 MB.", .manual),
                       f(s2.id, "Phiên Claude rảnh 5 giờ, vẫn giữ 154 MB.", .manual),
                       f(node.id, "Chạy 2 ngày, giữ 393 MB, mở 1 cổng nhưng không ai kết nối.", .signal, .watch)])
    }
}

extension HogModel {
    /// For --render: a stop sheet built from the snapshot alone (no live scan).
    func prepareStopForRender(_ itemId: String) {
        guard let s = snapshot, let item = s.items.first(where: { $0.id == itemId }) else { return }
        let scan = Scan(system: RawSystem(memTotalBytes: 0, ncpu: 1, pageSize: 16384), processes: [:])
        var plan = stopper.plan(.process(item.pids.first ?? 0, startSec: nil, startUsec: nil), item: item, snapshot: s, scan: scan)
        plan.gates = plan.gates.filter { $0.gate != "G6" }  // the sample process does not exist on this machine
        stopPlan = plan
    }
}
