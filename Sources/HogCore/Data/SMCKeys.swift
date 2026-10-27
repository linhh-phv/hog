import Foundation

/// One chip family's temperature keys (`Resources/smc/<id>.json`). Fan keys are the same on every Apple Silicon Mac
/// and stay in code (`HeatReader`).
public struct SMCKeyEntry: Codable, Sendable, Equatable {
    public var id: String
    /// Exact `machdep.cpu.brand_string` values ("Apple M1 Pro").
    public var chips: [String]
    /// Averaged into the CPU temperature: one sensor per core.
    public var cpuKeys: [String]
    public var gpuKeys: [String]
    public var provenance: CatalogEntry.Provenance

    static let keys: Set<String> = ["id", "chips", "cpu_keys", "gpu_keys", "provenance"]
}

public struct SMCKeyTable: Sendable {
    /// In load order: bundled files by name, then local ones — a later entry wins for the same id or chip.
    public private(set) var entries: [SMCKeyEntry]
    public private(set) var warnings: [DataWarning]

    public init(entries: [SMCKeyEntry], warnings: [DataWarning] = []) {
        self.entries = entries; self.warnings = warnings
    }

    public static func load(_ source: DataSource) -> SMCKeyTable {
        var entries: [SMCKeyEntry] = []
        var warnings: [DataWarning] = []
        for file in source.files() {
            do {
                let e = try parse(file.data)
                entries.removeAll { $0.id == e.id }
                entries.append(e)
            } catch {
                warnings.append(DataWarning(file: file.name, message: "skipped: \(error)"))
            }
        }
        return SMCKeyTable(entries: entries, warnings: warnings)
    }

    static func parse(_ data: Data) throws -> SMCKeyEntry {
        let obj = try StrictJSON.object(data)
        try StrictJSON.check(obj, allowed: SMCKeyEntry.keys)
        if let p = obj["provenance"] as? [String: Any] { try StrictJSON.check(p, allowed: ["added", "source", "verified"], at: "provenance") }
        let e = try StrictJSON.decoder().decode(SMCKeyEntry.self, from: data)
        func fail(_ m: String) -> Error { DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: m)) }
        guard !e.chips.isEmpty else { throw fail("chips must not be empty") }
        guard !e.cpuKeys.isEmpty else { throw fail("cpu_keys must not be empty") }
        if let bad = (e.cpuKeys + e.gpuKeys).first(where: { SMC.fourCC($0) == nil }) {
            throw fail("\"\(bad)\" is not a four-character SMC key")
        }
        guard CatalogEntry.Provenance.sources.contains(e.provenance.source) else {
            throw fail("unknown provenance.source \(e.provenance.source)")
        }
        return e
    }

    /// The table for this exact chip name; `nil` for a chip no table lists (hog then does not guess).
    public func entry(chip: String) -> SMCKeyEntry? {
        entries.last { $0.chips.contains(chip) }
    }
}
