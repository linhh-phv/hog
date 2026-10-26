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
