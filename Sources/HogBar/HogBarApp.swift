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
                .onAppear { model.page = .main; model.toast = nil; model.refresh() }
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
        if let first = model.summary?.cards.first {
            model.prepareStopForRender(first.itemId)
            let view = MenuView().environmentObject(model).environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            var image: NSImage?
            NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { image = renderer.nsImage }
            if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("menu-stop-light.png"))
            }
        }
        print("rendered to \(dir.path)")
    }

    /// Fake data shaped like a real run (no real names).
    static func sampleSnapshot() -> Snapshot {
        let item = Item(id: "proc:69339:1", kind: .process, label: "Watchman", catalogId: "watchman", pids: [69339],
                        footprintBytes: Measured(339_000_000), residentRatio: Measured(0.04),
                        facts: ["age_s": .int(10_800), "watchman.subscriptions": .int(0), "footprint_bytes": .int(339_000_000),
                                "resident_ratio": .double(0.04), "launchd.restarts_after_stop": .bool(false), "owner.kind": .string("none")])
        let s1 = Item(id: "claude:91747", kind: .claudeSession, label: "Claude Code — hub", pids: [91747], footprintBytes: Measured(226_000_000))
        let s2 = Item(id: "claude:39806", kind: .claudeSession, label: "Claude Code — hub", pids: [39806], footprintBytes: Measured(161_000_000))
        func f(_ id: String, _ reason: String, _ strategy: StopStrategy) -> Finding {
            Finding(itemId: id, verdict: .mayStop, confidence: .high, rules: ["x"], reason: reason, evidence: [:], unmeasured: [],
                    stop: StopAdvice(strategy: strategy, respawns: .onDemand, effect: "Tắt không mất dữ liệu; lần sau Metro/Jest cần thì nó được bật lại."))
        }
        return Snapshot(
            lang: .vi, takenAt: Date(),
            hog: HogInfo(pid: getpid(), ancestors: [], ancestorsComplete: true, selfFootprintBytes: Measured(31_000_000)),
            host: HostInfo(arch: "arm64", ncpu: 8, memTotalBytes: 17_179_869_184, uptimeS: nil),
            memory: MemoryInfo(compressorBytes: Measured(3_330_000_000), compressedStoredBytes: Measured(7_410_000_000),
                               swapUsedBytes: Measured(6_010_000_000), pressure: Measured(.normal), unreadableProcessCount: 181,
                               measuredFootprintBytes: 21_000_000_000),
            cpu: CPUInfo(),
            headline: Headline(level: .ok, text: "Máy chưa thiếu RAM, nhưng đã nén 6,9 GB dữ liệu (chiếm 3,1 GB RAM) và đẩy 5,6 GB ra ổ đĩa. Có 3 thứ có thể tắt.", glossaryIds: []),
            sensors: [SensorStatus(name: "docker", status: .unavailable, tookMs: 0, note: "engine socket missing")],
            owners: [
                Owner(id: "app:visual-studio-code", kind: .app, label: "Visual Studio Code", selfFootprintBytes: 3_650_000_000, totalFootprintBytes: 11_600_000_000),
                Owner(id: "vscode:1", kind: .vscodeWindow, label: "web-app (Workspace)", parent: "app:visual-studio-code", totalFootprintBytes: 4_720_000_000),
                Owner(id: "vscode:2", kind: .vscodeWindow, label: "hog (Workspace)", parent: "app:visual-studio-code", totalFootprintBytes: 1_930_000_000),
                Owner(id: "vscode:3", kind: .vscodeWindow, label: "api (Workspace)", parent: "app:visual-studio-code", totalFootprintBytes: 1_290_000_000),
                Owner(id: "app:google-chrome", kind: .app, label: "Google Chrome", totalFootprintBytes: 3_650_000_000),
                Owner(id: "app:discord", kind: .app, label: "Discord", totalFootprintBytes: 899_000_000),
            ],
            items: [item, s1, s2],
            findings: [f(item.id, "Watchman chạy 3 giờ, không công cụ nào đăng ký theo dõi.", .watchmanShutdown),
                       f(s1.id, "Phiên Claude rảnh 2 giờ, vẫn giữ 216 MB.", .manual),
                       f(s2.id, "Phiên Claude rảnh 5 giờ, vẫn giữ 154 MB.", .manual)])
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
