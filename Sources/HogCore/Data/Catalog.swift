import Foundation

/// One catalog entry: "what is this, what happens if it stops" (design section 7).
public struct CatalogEntry: Codable, Sendable, Equatable {
    public struct Match: Codable, Sendable, Equatable {
        public var exe: String?
        public var exePathContains: String?
        public var argsContains: String?
        public var parentCatalog: String?
        public var listensPort: Int?
        public var containerImage: String?
        /// Role from `code --status` (`file-watcher`, `pty-host`…): VS Code helpers with identical arguments.
        public var vscodeRole: String?

        static let keys: Set<String> = ["exe", "exe_path_contains", "args_contains", "parent_catalog", "listens_port", "container_image", "vscode_role"]

        /// Number of conditions: the more specific clause wins when several entries match.
        var specificity: Int {
            [exe != nil, exePathContains != nil, argsContains != nil, parentCatalog != nil, listensPort != nil, containerImage != nil, vscodeRole != nil]
                .filter { $0 }.count
        }
    }

    public struct Stop: Codable, Sendable, Equatable { public var strategy: StopStrategy }

    public struct Provenance: Codable, Sendable, Equatable {
        public var added: String
        public var source: String
        public var verified: Bool
        static let sources: Set<String> = ["measured", "user", "claude", "docs"]
    }

    public var id: String
    public var name: LocalizedText
    public var family: String
    public var summary: LocalizedText
    public var stopEffect: LocalizedText
    public var respawns: Respawns
    public var stop: Stop
    public var match: [Match]
    public var detachedByDesign: Bool?
    public var provenance: Provenance

    static let keys: Set<String> = ["id", "name", "family", "summary", "stop_effect", "respawns", "stop", "match",
                                    "detached_by_design", "provenance"]
}

/// What a process looks like to the matcher.
public struct MatchSubject: Sendable {
    public var exeName: String?
    public var exePath: String?
    public var args: String?
    public var parentCatalog: String?
    public var listenPorts: [Int]
    public var containerImage: String?
    public var vscodeRole: String?

    public init(exeName: String? = nil, exePath: String? = nil, args: String? = nil, parentCatalog: String? = nil,
                listenPorts: [Int] = [], containerImage: String? = nil, vscodeRole: String? = nil) {
        self.exeName = exeName; self.exePath = exePath; self.args = args; self.parentCatalog = parentCatalog
        self.listenPorts = listenPorts; self.containerImage = containerImage; self.vscodeRole = vscodeRole
    }
}

public struct Catalog: Sendable {
    public private(set) var entries: [String: CatalogEntry]
    public private(set) var warnings: [DataWarning]

    public init(entries: [CatalogEntry], warnings: [DataWarning] = []) {
        self.entries = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        self.warnings = warnings
    }

    /// Loads bundled entries then local overrides (same id: local wins). Bad files are skipped with a warning.
    public static func load(_ source: DataSource) -> Catalog {
        var entries: [String: CatalogEntry] = [:]
        var warnings: [DataWarning] = []
        for file in source.files() {
            do {
                let e = try parse(file.data)
                entries[e.id] = e
                for lang in e.summary.missingLanguages + e.stopEffect.missingLanguages + e.name.missingLanguages {
                    warnings.append(DataWarning(file: file.name, message: "missing \(lang.rawValue) translation"))
                }
            } catch {
                warnings.append(DataWarning(file: file.name, message: "skipped: \(error)"))
            }
        }
        var c = Catalog(entries: Array(entries.values))
        c.warnings = warnings
        return c
    }

    static func parse(_ data: Data) throws -> CatalogEntry {
        let obj = try StrictJSON.object(data)
        try StrictJSON.check(obj, allowed: CatalogEntry.keys)
        for (i, m) in (obj["match"] as? [[String: Any]] ?? []).enumerated() {
            try StrictJSON.check(m, allowed: CatalogEntry.Match.keys, at: "match[\(i)]")
        }
        if let p = obj["provenance"] as? [String: Any] { try StrictJSON.check(p, allowed: ["added", "source", "verified"], at: "provenance") }
        if let s = obj["stop"] as? [String: Any] { try StrictJSON.check(s, allowed: ["strategy"], at: "stop") }
        let e = try StrictJSON.decoder().decode(CatalogEntry.self, from: data)
        guard !e.match.isEmpty, e.match.allSatisfy({ $0.specificity > 0 }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "match must have at least one non-empty clause"))
        }
        guard CatalogEntry.Provenance.sources.contains(e.provenance.source) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unknown provenance.source \(e.provenance.source)"))
        }
        return e
    }

    /// The best-matching entry id: any clause may match (OR); inside a clause all conditions must hold (AND);
    /// the most specific clause wins; ties break by id for determinism.
    public func match(_ s: MatchSubject) -> String? {
        var best: (spec: Int, id: String)?
        for (id, e) in entries {
            for m in e.match where Self.matches(m, s) {
                if best == nil || m.specificity > best!.spec || (m.specificity == best!.spec && id < best!.id) {
                    best = (m.specificity, id)
                }
            }
        }
        return best?.id
    }

    static func matches(_ m: CatalogEntry.Match, _ s: MatchSubject) -> Bool {
        if let exe = m.exe, s.exeName != exe { return false }
        if let p = m.exePathContains, !(s.exePath?.contains(p) ?? false) { return false }
        if let a = m.argsContains, !(s.args?.contains(a) ?? false) { return false }
        if let pc = m.parentCatalog, s.parentCatalog != pc { return false }
        if let port = m.listensPort, !s.listenPorts.contains(port) { return false }
        if let img = m.containerImage {
            // "" means any container (Swift's `contains("")` is false, so it is handled explicitly).
            guard let image = s.containerImage else { return false }
            if !img.isEmpty && !image.contains(img) { return false }
        }
        if let role = m.vscodeRole, s.vscodeRole != role { return false }
        return true
    }
}
