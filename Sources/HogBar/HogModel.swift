import AppKit
import HogCore
import ServiceManagement
import SwiftUI

/// App state. All sensing, rules and stopping go through HogCore (the CLI uses the very same code).
@MainActor
final class HogModel: ObservableObject {
    /// Pages of the compact menu (docs/design/compact/screens.html).
    enum Page: Equatable { case main, entry(group: String, entry: String), all, system, settings }
    enum LangSetting: String, CaseIterable { case system, vi, en }

    @Published var snapshot: Snapshot?
    @Published var overview: Overview?
    @Published var scanning = false
    @Published var pressure: Pressure? = SystemReader.pressureNow()
    @Published var thermal: ThermalState? = SystemReader.thermalNow()
    @Published var page: Page = .main {
        didSet {
            if case .entry = page { back = oldValue == .all ? .all : .main } else if page != .main { back = .main }
        }
    }
    /// Where "‹ Back" goes from an entry: the full list when it was opened from there.
    var back: Page = .main
    @Published var expanded: Set<String> = []
    /// "Nên dọn" check boxes. Pre-selected suggestions start checked; what the person changes stays across rescans.
    @Published var selected: Set<String> = []
    private var seenCleanups: Set<String> = []
    @Published var search = ""
    @Published var stopPlan: StopPlan?
    /// "Dọn N thứ": one plan per thing, confirmed together.
    @Published var batch: [StopPlan]?
    @Published var stopRunning = false
    @Published var toast: String?
    @Published var systemRows: [SystemDetail.Row]?
    @Published var systemMeasuring = false
    /// Entry whose info was just copied (the button shows "Copied").
    @Published var copied: String?

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
    private var thermalObserver: NSObjectProtocol?

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
        analyzer = Analyzer.standard(lang: .en, full: true)
        explanations = .load(.standard("explain"))
        catalog = .load(.standard("catalog"))
        reloadData()
        // Menu closed: only the pressure level and heat, every 10 s. One scan right after launch, so the first menu
        // opening already has numbers.
        Task { @MainActor in self.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pressure = SystemReader.pressureNow(); self?.thermal = SystemReader.thermalNow() }
        }
        // macOS posts this when the thermal state changes: the icon follows at once, not 10 s later.
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                                                 queue: .main) { [weak self] _ in
            Task { @MainActor in self?.thermal = SystemReader.thermalNow() }
        }
    }

    func reloadData() {
        // Full analysis: "Đang chạy" and "Tất cả" list every readable process.
        analyzer = Analyzer.standard(lang: lang, full: true)
        explanations = .load(.standard("explain"))
        catalog = .load(.standard("catalog"))
    }

    var icon: NSImage { PigIcon.image(pressure: pressure, thermal: thermal, colored: coloredIcon) }

    /// Menu opened: show the last scan at once and scan again in the background.
    func refresh() {
        guard !scanning else { return }
        scanning = true
        let analyzer = self.analyzer
        Task.detached(priority: .userInitiated) {
            let scan = Scanner().scan()
            let snapshot = analyzer.analyze(scan)
            await MainActor.run {
                self.scan = scan
                self.load(snapshot)
                self.scanning = false
            }
        }
    }

    /// Shows a snapshot (a scan, or the fixed sample of `--render`).
    func load(_ snapshot: Snapshot) {
        self.snapshot = snapshot
        let o = Overview.make(snapshot, catalog: catalog)
        overview = o
        pressure = snapshot.memory.pressure.value
        thermal = snapshot.cpu.thermal.value
        // New suggestions start as hog proposes; the person's own ticks are kept; gone ones are dropped.
        let ids = Set(o.cleanups.map(\.itemId))
        let fresh = o.cleanups.filter { !seenCleanups.contains($0.itemId) && $0.preselected }.map(\.itemId)
        selected = selected.intersection(ids).union(fresh)
        seenCleanups = ids
    }

    func glossary(_ id: String) -> GlossaryEntry? { explanations.glossary[id] }

    func group(_ id: String) -> Overview.Group? { overview?.groups.first { $0.id == id } }

    func entry(_ group: String, _ entry: String) -> Overview.Entry? { self.group(group)?.entries.first { $0.id == entry } }

    func toggle(_ group: String) {
        if expanded.contains(group) { expanded.remove(group) } else { expanded.insert(group) }
    }

    // MARK: Stop

    var stopper: Stopper { Stopper(lang: lang) }

    /// A stop target for an entry: its item, else its first process.
    func target(_ e: Overview.Entry) -> String { e.itemId ?? e.pids.first.map(String.init) ?? e.id }

    func plan(_ target: String) -> StopPlan? {
        let analyzer = self.analyzer
        guard let scan, let snapshot,
              let resolved = try? stopper.resolve(target, in: snapshot, scan: scan, itemFor: { analyzer.item(forPid: $0, in: scan) }) else { return nil }
        return stopper.plan(resolved.identity, item: resolved.item, snapshot: snapshot, scan: scan)
    }

    /// "Dừng…" / "Cách đóng" for one thing: builds the plan (gates G1, G2, G6, G7) and shows the sheet. Nothing runs yet.
    func prepareStop(_ target: String) { stopPlan = plan(target) }

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
                case .done(let m): self.stopPlan = nil; self.toast = m; self.page = .main; self.refresh()
                case .needsNewPlan(let k): self.stopPlan = k  // G4: a new plan, a new "yes"
                case .manual: self.stopPlan = nil
                case .blocked(let g): self.toast = "\(g.gate): \(g.reason)"; self.stopPlan = nil; self.page = .main
                case .failed(let m): self.toast = m; self.stopPlan = nil; self.page = .main
                }
            }
        }
    }

    /// "Dọn N thứ": a plan for each checked thing; one sheet confirms them together. Every plan still has its own gates.
    func prepareBatch() {
        guard let o = overview else { return }
        batch = o.cleanups.filter { selected.contains($0.itemId) && !$0.manual }.compactMap { plan($0.itemId) }
    }

    /// Plans the batch would run: not blocked by a gate, not manual.
    var batchRunnable: [StopPlan] { (batch ?? []).filter { $0.blocked == nil && $0.action != .manual } }

    func confirmBatch() {
        guard let scan else { return }
        let plans = batchRunnable
        guard !plans.isEmpty else { batch = nil; return }
        stopRunning = true
        let stopper = self.stopper
        let lang = self.lang
        Task.detached {
            var done: [String] = [], other: [String] = []
            for plan in plans {
                switch stopper.execute(plan, scan: scan) {
                case .done: done.append(plan.label)
                // A forced stop needs its own plan and its own "yes" (G4): never inside a batch.
                case .needsNewPlan: other.append(lang == .vi ? "\(plan.label) chưa tắt (cần buộc tắt — mở riêng)" : "\(plan.label) did not stop (needs a forced stop — open it)")
                case .manual: other.append(plan.label)
                case .blocked(let g): other.append("\(plan.label): \(g.reason)")
                case .failed(let m): other.append("\(plan.label): \(m)")
                }
            }
            await MainActor.run {
                self.stopRunning = false
                self.batch = nil
                let head = done.isEmpty ? "" : (lang == .vi ? "Đã dọn: " : "Cleaned up: ") + done.joined(separator: ", ")
                self.toast = ([head] + other).filter { !$0.isEmpty }.joined(separator: " · ")
                self.page = .main
                self.refresh()
            }
        }
    }

    // MARK: Share

    /// "Chép thông tin": `hog.share/1` to the clipboard, to paste into a chat with Claude. hog sends nothing.
    func copyShare(_ e: Overview.Entry) {
        guard let scan else { return }
        let item = e.itemId.flatMap { id in snapshot?.items.first { $0.id == id } } ?? e.pids.first.flatMap { analyzer.item(forPid: $0, in: scan) }
        guard let item else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ShareInfo.make(item, scan: scan).text(lang), forType: .string)
        copied = e.id
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
}
