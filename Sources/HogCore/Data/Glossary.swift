import Foundation

/// One glossary entry: what a number means in plain words (design section 5.2).
public struct GlossaryEntry: Codable, Sendable, Equatable {
    public var id: String
    /// The matching Activity Monitor name, or `nil` when Activity Monitor has none.
    public var activityMonitor: String?
    public var name: LocalizedText
    public var plain: LocalizedText
    public var howToRead: LocalizedText
    public var act: LocalizedText
    public var provenance: CatalogEntry.Provenance

    static let keys: Set<String> = ["id", "activity_monitor", "name", "plain", "how_to_read", "act", "provenance"]
}

/// One-line headline templates per situation (design section 5.1).
public struct HeadlineTemplates: Codable, Sendable, Equatable {
    public struct Template: Codable, Sendable, Equatable {
        public var text: LocalizedText
        public var glossaryIds: [String]
    }
    /// pressure normal, nothing to suggest
    public var okClean: Template
    /// pressure normal, there are may-stop suggestions
    public var okSuggest: Template
    public var warn: Template
    public var critical: Template
    /// pressure critical, nothing to suggest (`{list}` would be empty)
    public var criticalNoSuggest: Template
    /// pressure could not be read
    public var unknown: Template
    /// second sentence: the machine is hot (thermal state serious/critical)
    public var hot: Template
    /// second sentence: not hot, but the CPU is busy
    public var busy: Template
}

public struct Explanations: Sendable {
    public private(set) var glossary: [String: GlossaryEntry]
    public private(set) var headlines: HeadlineTemplates?
    public private(set) var warnings: [DataWarning]

    public init(glossary: [GlossaryEntry], headlines: HeadlineTemplates?, warnings: [DataWarning] = []) {
        self.glossary = Dictionary(glossary.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        self.headlines = headlines
        self.warnings = warnings
    }

    /// `glossary/*.json` (one entry per file) + `headline.json`, bundled then local.
    public static func load(_ source: DataSource) -> Explanations {
        var entries: [String: GlossaryEntry] = [:]
        var warnings: [DataWarning] = []
        let sub = DataSource(bundledDirectory: source.bundledDirectory?.appendingPathComponent("glossary"),
                             localDirectory: source.localDirectory?.appendingPathComponent("glossary"))
        for file in sub.files() {
            do {
                let obj = try StrictJSON.object(file.data)
                try StrictJSON.check(obj, allowed: GlossaryEntry.keys)
                let e = try StrictJSON.decoder().decode(GlossaryEntry.self, from: file.data)
                entries[e.id] = e
                for t in [e.name, e.plain, e.howToRead, e.act] {
                    for lang in t.missingLanguages {
                        warnings.append(DataWarning(file: file.name, message: "missing \(lang.rawValue) translation"))
                    }
                }
            } catch {
                warnings.append(DataWarning(file: file.name, message: "skipped: \(error)"))
            }
        }
        var headlines: HeadlineTemplates?
        for dir in [source.localDirectory, source.bundledDirectory].compactMap({ $0 }) {
            let url = dir.appendingPathComponent("headline.json")
            guard let data = FileManager.default.contents(atPath: url.path) else { continue }
            do {
                headlines = try StrictJSON.decoder().decode(HeadlineTemplates.self, from: data)
                break
            } catch {
                warnings.append(DataWarning(file: url.lastPathComponent, message: "skipped: \(error)"))
            }
        }
        if headlines == nil { warnings.append(DataWarning(file: "headline.json", message: "missing")) }
        return Explanations(glossary: Array(entries.values), headlines: headlines, warnings: warnings)
    }
}

/// Human formatting per language: decimal comma in Vietnamese, point in English.
public enum Format {
    public static func bytes(_ b: Int64, _ lang: Lang) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 1 { return number(gb, 1, lang) + " GB" }
        let mb = Double(b) / 1_048_576
        return number(mb, 0, lang) + " MB"
    }

    public static func duration(_ seconds: Int64, _ lang: Lang) -> String {
        let s = max(0, seconds)
        let (d, h, m) = (s / 86_400, s / 3_600, s / 60)
        switch lang {
        case .vi:
            if d >= 1 { return "\(Int((Double(s) / 86_400).rounded())) ngày" }
            if h >= 1 { return "\(h) giờ" }
            if m >= 1 { return "\(m) phút" }
            return "\(s) giây"
        case .en:
            func plural(_ n: Int64, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s")" }
            if d >= 1 { return plural(Int64((Double(s) / 86_400).rounded()), "day") }
            if h >= 1 { return plural(h, "hour") }
            if m >= 1 { return plural(m, "minute") }
            return plural(s, "second")
        }
    }

    public static func percent(_ p: Double, _ lang: Lang) -> String { number(p, p < 10 ? 1 : 0, lang) + " %" }

    public static func number(_ x: Double, _ digits: Int, _ lang: Lang) -> String {
        let s = String(format: "%.\(digits)f", x)
        return lang == .vi ? s.replacingOccurrences(of: ".", with: ",") : s
    }

    /// Renders a fact value for a reason template.
    public static func fact(_ name: String, _ v: FactValue, _ lang: Lang) -> String {
        switch (name, v) {
        case (_, .null): return lang == .vi ? "chưa đo" : "not measured"
        case let (n, .int(i)) where n.hasSuffix("_bytes"): return bytes(i, lang)
        case let (n, .int(i)) where n.hasSuffix("_s"): return duration(i, lang)
        case let (n, .double(d)) where n.hasSuffix("_s"): return duration(Int64(d), lang)
        case let (n, x) where n.hasSuffix("_pct"): return percent(x.number ?? 0, lang)
        case let (n, x) where n.hasSuffix("_ratio"): return percent((x.number ?? 0) * 100, lang)
        case (_, .bool(let b)): return lang == .vi ? (b ? "có" : "không") : (b ? "yes" : "no")
        default: return v.description
        }
    }

    /// macOS's thermal assessment in words.
    public static func thermal(_ t: ThermalState, _ lang: Lang) -> String {
        switch (t, lang) {
        // `nominal` is not "cool": the machine can be at 90 °C with its fans at 2/3 and still be nominal (measured 2026-10-27).
        case (.nominal, .vi): "bình thường"
        case (.fair, .vi): "ấm"
        case (.serious, .vi): "nóng"
        case (.critical, .vi): "rất nóng"
        case (.nominal, .en): "normal"
        case (.fair, .en): "warm"
        case (.serious, .en): "hot"
        case (.critical, .en): "very hot"
        }
    }

    /// The points of an explanation: data texts put one point per line (`\n`); blank lines are dropped.
    public static func points(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The label of a running thing: may it be stopped (`Overview.Safety`).
    public static func safety(_ s: Overview.Safety, _ lang: Lang) -> String {
        switch (s, lang) {
        case (.keep, .vi): "đừng tắt"
        case (.inUse, .vi): "đang dùng"
        case (.canStop, .vi): "có thể tắt"
        case (.restarts, .vi): "tắt vô ích"
        case (.keep, .en): "keep"
        case (.inUse, .en): "in use"
        case (.canStop, .en): "can stop"
        case (.restarts, .en): "comes back"
        }
    }

    /// "53 °C": whole degrees, sensors of one chip already differ by more than that.
    public static func celsius(_ c: Double, _ lang: Lang) -> String { number(c, 0, lang) + " °C" }

    public static func rpm(_ r: Int, _ lang: Lang) -> String { lang == .vi ? "\(r) vòng/phút" : "\(r) rpm" }

    /// The fans in a few words: none, all stopped, or the fastest with how hard they work; `nil` when not measured.
    public static func fans(_ h: HeatInfo, _ lang: Lang) -> String? {
        guard let fans = h.fans.value else { return nil }
        if fans.isEmpty { return lang == .vi ? "không có quạt" : "no fan" }
        guard let fastest = fans.compactMap(\.rpm.value).max() else { return nil }
        if fastest == 0 { return lang == .vi ? "quạt đứng" : (fans.count == 1 ? "fan stopped" : "fans stopped") }
        return (lang == .vi ? "quạt " : (fans.count == 1 ? "fan " : "fans ")) + rpm(fastest, lang) + (h.fanPct.map { " (\($0) %)" } ?? "")
    }

    /// The word next to the degrees (app chip label): what is measured about cooling, not a judgement of the number.
    /// macOS says it is hot (it may slow down) → its word, which then agrees with the number ("có thể giảm tốc" does not fit
    /// the chip); else the fans (stopped / % of their maximum); without fans, macOS's word.
    /// No temperature thresholds of hog's own: Apple does not publish them and they differ per chip (user chose 2026-10-27).
    public static func heatTag(_ h: HeatInfo, thermal: ThermalState?, _ lang: Lang) -> String? {
        if let th = thermal, th >= .serious { return Self.thermal(th, lang) }
        if let fans = h.fans.value, !fans.isEmpty {
            if fans.compactMap(\.rpm.value).max() == 0 { return lang == .vi ? "quạt đứng" : "fans stopped" }
            if let pct = h.fanPct { return (lang == .vi ? "quạt " : "fans ") + "\(pct) %" }
        }
        return thermal.map { Self.thermal($0, lang) }
    }

    /// What macOS's thermal state means for the machine (it is about slowing down, not about how warm it is).
    public static func thermalMeaning(_ t: ThermalState, _ lang: Lang) -> String {
        switch (t, lang) {
        case (.nominal, .vi): "bình thường, chưa phải giảm tốc vì nóng"
        case (.fair, .vi): "hơi nóng, chưa giảm tốc"
        case (.serious, .vi): "nóng, có thể giảm tốc"
        case (.critical, .vi): "rất nóng, đang giảm tốc"
        case (.nominal, .en): "normal, no need to slow down for heat"
        case (.fair, .en): "slightly hot, not slowing down"
        case (.serious, .en): "hot, may slow down"
        case (.critical, .en): "very hot, slowing down"
        }
    }

    /// Everything hog knows about heat, one line each, for the "Nhiệt" explanation: CPU, GPU, each fan, macOS's own
    /// word, and where the degrees come from (unofficial sensors) — or why there are none.
    public static func heatDetail(_ h: HeatInfo, thermal: ThermalState?, _ lang: Lang) -> [String] {
        func t(_ vi: String, _ en: String) -> String { lang == .vi ? vi : en }
        var out: [String] = []
        if let avg = h.cpuAvgC.value, let max = h.cpuMaxC.value {
            out.append(t("CPU: trung bình \(celsius(avg, lang)), nóng nhất \(celsius(max, lang)) (\(h.cpuSensors) cảm biến)",
                         "CPU: \(celsius(avg, lang)) on average, hottest \(celsius(max, lang)) (\(h.cpuSensors) sensors)"))
        }
        if let avg = h.gpuAvgC.value { out.append("GPU: " + celsius(avg, lang)) }
        switch h.fans.value {
        case nil: break
        case let fans? where fans.isEmpty: out.append(t("Máy không có quạt", "This Mac has no fan"))
        case let fans?:
            for f in fans {
                let name = t("Quạt \(f.index + 1)", "Fan \(f.index + 1)")
                let now = f.rpm.value.map { $0 == 0 ? t("đứng", "stopped") : rpm($0, lang) } ?? t("chưa đo", "not measured")
                let pct = f.rpm.value == 0 ? nil : f.pct
                let range = f.minRpm.value.flatMap { lo in f.maxRpm.value.map { "\(lo)–\($0)" } }
                let notes = [pct.map { t("\($0) % sức", "\($0) % of its maximum") }, range.map { t("chạy \($0)", "runs \($0)") }].compactMap { $0 }
                out.append("\(name): \(now)" + (notes.isEmpty ? "" : " (" + notes.joined(separator: "; ") + ")"))
            }
        }
        if let th = thermal { out.append("macOS: " + thermalMeaning(th, lang)) }
        let chip = h.chip.value ?? t("chip này", "this chip")
        if h.cpuAvgC.value != nil {
            out.append(h.keysVerified.value == true
                ? t("Nguồn: cảm biến SMC không chính thức (Apple không công bố) — khoá của \(chip) đã kiểm trên máy thật.",
                    "Source: unofficial SMC sensors (not published by Apple) — the \(chip) keys were checked on a real Mac.")
                : t("Nguồn: cảm biến SMC không chính thức (Apple không công bố) — khoá của \(chip) chưa kiểm trên máy thật, số có thể lệch.",
                    "Source: unofficial SMC sensors (not published by Apple) — the \(chip) keys are not checked on a real Mac yet; numbers may be off."))
        } else if h.keyTable.value == nil {
            out.append(t("Chưa đo được độ C: hog chưa biết khoá cảm biến của \(chip).",
                         "Degrees not measured: hog does not know the sensor keys of \(chip) yet."))
        } else {
            out.append(t("Chưa đo được độ C: cảm biến không trả lời.", "Degrees not measured: the sensors did not answer."))
        }
        return out
    }

    /// How sure a finding is, in words (the raw value is English).
    public static func confidence(_ c: Confidence, _ lang: Lang) -> String {
        switch (c, lang) {
        case (.high, .vi): "cao"
        case (.medium, .vi): "vừa"
        case (.low, .vi): "thấp"
        case (_, .en): c.rawValue
        }
    }

    /// Fills `{fact}` placeholders.
    public static func fill(_ template: String, facts: [String: FactValue], extra: [String: String] = [:], lang: Lang) -> String {
        var out = template
        for (k, v) in extra { out = out.replacingOccurrences(of: "{\(k)}", with: v) }
        for (k, v) in facts where out.contains("{\(k)}") { out = out.replacingOccurrences(of: "{\(k)}", with: fact(k, v, lang)) }
        return out
    }
}
