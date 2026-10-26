import AppKit
import HogCore
import ServiceManagement
import SwiftUI

/// App state. All sensing, rules and stopping go through HogCore (the CLI uses the very same code).
@MainActor
final class HogModel: ObservableObject {
    enum Page: Equatable { case main, why(String), system, settings }
    enum LangSetting: String, CaseIterable { case system, vi, en }

    @Published var snapshot: Snapshot?
    @Published var summary: MenuSummary?
    @Published var scanning = false
    @Published var pressure: Pressure? = SystemReader.pressureNow()
    @Published var page: Page = .main
    @Published var expandedGroup: String?
    @Published var stopPlan: StopPlan?
    @Published var stopRunning = false
    @Published var toast: String?
    @Published var systemRows: [SystemDetail.Row]?
    @Published var systemMeasuring = false

    @Published var langSetting: String = UserDefaults.standard.string(forKey: "lang") ?? LangSetting.system.rawValue {
        didSet { UserDefaults.standard.set(langSetting, forKey: "lang"); reloadData(); refresh() }
    }
    @Published var coloredIcon: Bool = UserDefaults.standard.object(forKey: "coloredIcon") as? Bool ?? true {
        didSet { UserDefaults.standard.set(coloredIcon, forKey: "coloredIcon") }
    }

    private var scan: Scan?
    private var analyzer: Analyzer
    private(set) var explanations: Explanations
    private(set) var catalog: Catalog
    private var timer: Timer?

    /// Forced language (for --render).
    var overrideLang: Lang?

    var lang: Lang {
        if let overrideLang { return overrideLang }
        return switch LangSetting(rawValue: langSetting) ?? .system {
        case .vi: .vi
        case .en: .en
        case .system: (Locale.preferredLanguages.first ?? "en").hasPrefix("vi") ? .vi : .en
        }
    }

    func t(_ vi: String, _ en: String) -> String { lang == .vi ? vi : en }

    init() {
        analyzer = Analyzer.standard(lang: .en)
        explanations = .load(.standard("explain"))
        catalog = .load(.standard("catalog"))
        reloadData()
        // Menu closed: only the pressure level, every 10 s (design system, "Luật dùng").
        // One scan right after launch, so the first menu opening already has numbers (criterion 10: < 0,5 s).
        Task { @MainActor in self.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pressure = SystemReader.pressureNow() }
        }
    }

    func reloadData() {
        analyzer = Analyzer.standard(lang: lang)
        explanations = .load(.standard("explain"))
        catalog = .load(.standard("catalog"))
    }

    var icon: NSImage { PigIcon.image(pressure: pressure, colored: coloredIcon) }

    /// Menu opened: show the last snapshot at once and scan in the background (~3 s).
    func refresh() {
        guard !scanning else { return }
        scanning = true
        let analyzer = self.analyzer
        Task.detached(priority: .userInitiated) {
            let scan = Scanner().scan()
            let snapshot = analyzer.analyze(scan)
            await MainActor.run {
                self.scan = scan
                self.snapshot = snapshot
                self.summary = MenuSummary.make(snapshot)
                self.pressure = snapshot.memory.pressure.value
                self.scanning = false
            }
        }
    }

    func glossary(_ id: String) -> GlossaryEntry? { explanations.glossary[id] }

    // MARK: Stop

    var stopper: Stopper { Stopper(lang: lang) }

    /// "Dừng…" / "Cách đóng": builds the plan (gates G1, G2, G6, G7) and shows the sheet. Nothing runs yet.
    func prepareStop(_ itemId: String) {
        let analyzer = self.analyzer
        guard let scan, let snapshot,
              let resolved = try? stopper.resolve(itemId, in: snapshot, scan: scan, itemFor: { analyzer.item(forPid: $0, in: scan) }) else { return }
        stopPlan = stopper.plan(resolved.identity, item: resolved.item, snapshot: snapshot, scan: scan)
    }

    /// The person agreed in the sheet: execute (G3, G4, G5, G8 inside HogCore).
    func confirmStop() {
        guard let plan = stopPlan, let scan else { return }
        stopRunning = true
        let stopper = self.stopper
        Task.detached {
            let outcome = stopper.execute(plan, scan: scan)
            await MainActor.run {
                self.stopRunning = false
                switch outcome {
                case .done(let m): self.stopPlan = nil; self.toast = m; self.refresh()
                case .needsNewPlan(let k): self.stopPlan = k  // G4: a new plan, a new "yes"
                case .manual: self.stopPlan = nil
                case .blocked(let g): self.toast = "\(g.gate): \(g.reason)"; self.stopPlan = nil
                case .failed(let m): self.toast = m; self.stopPlan = nil
                }
            }
        }
    }

    // MARK: System detail

    func measureSystem() {
        page = .system
        guard !systemMeasuring else { return }
        systemMeasuring = true
        Task.detached {
            let pids = Set(ProcessReader.allPids().filter { ProcessReader.read($0, includeArgs: false).footprintBytes == nil })
            let rows = SystemDetail.measure(pids: pids)
            await MainActor.run { self.systemRows = rows; self.systemMeasuring = false }
        }
    }

    // MARK: Settings

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { toast = t("Không đổi được \"mở cùng máy\": \(error.localizedDescription)", "Could not change \"open at login\": \(error.localizedDescription)") }
            objectWillChange.send()
        }
    }

    // For --render: a fixed snapshot without scanning.
    func load(_ snapshot: Snapshot) {
        self.snapshot = snapshot
        self.summary = MenuSummary.make(snapshot)
        self.pressure = snapshot.memory.pressure.value
    }
}
