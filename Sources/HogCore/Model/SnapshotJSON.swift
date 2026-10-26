import Foundation

/// Encoding and decoding of the snapshot contract (design section 4).
///
/// Swift properties are camelCase and JSON keys are snake_case. The built-in snake_case strategies also rewrite
/// dictionary keys, which would turn the fact `age_s` into `ageS` on decode, so a custom strategy leaves keys
/// inside `facts` and `evidence` untouched.
public enum SnapshotJSON {
    /// Dictionaries whose keys are fact names and must be kept verbatim.
    static let verbatimKeyContainers: Set<String> = ["facts", "evidence"]

    public static func encoder(pretty: Bool = true) -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .custom { path in
            let key = path.last!
            if isInsideVerbatim(path) { return key }
            return AnyKey(camelToSnake(key.stringValue))
        }
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom { path in
            let key = path.last!
            if isInsideVerbatim(path) { return key }
            return AnyKey(snakeToCamel(key.stringValue))
        }
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func encode(_ snapshot: Snapshot, pretty: Bool = true) throws -> Data {
        try encoder(pretty: pretty).encode(snapshot)
    }

    /// `--brief`: what Claude needs to answer "why is the machine heavy" in one read (fits a tool's output limit):
    /// no `processes`, only items that have a finding, owners limited to the largest top-level ones and their windows.
    public static func brief(_ s: Snapshot, owners maxOwners: Int = 12) -> Snapshot {
        var b = s
        let withFinding = Set(s.findings.map(\.itemId))
        b.items = s.items.filter { withFinding.contains($0.id) }
        b.processes = []
        let top = s.owners.filter { $0.parent.value == nil }.sorted { $0.totalFootprintBytes > $1.totalFootprintBytes }.prefix(maxOwners)
        let topIds = Set(top.map(\.id))
        b.owners = s.owners.filter { topIds.contains($0.id) || ($0.parent.value.map(topIds.contains) ?? false) }
        return b
    }

    public static func decode(_ data: Data) throws -> Snapshot {
        try decoder().decode(Snapshot.self, from: data)
    }

    static func isInsideVerbatim(_ path: [CodingKey]) -> Bool {
        guard path.count >= 2 else { return false }
        return verbatimKeyContainers.contains(path[path.count - 2].stringValue)
    }

    static func camelToSnake(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch.isUppercase {
                if !out.isEmpty { out.append("_") }
                out.append(Character(ch.lowercased()))
            } else {
                out.append(ch)
            }
        }
        return out
    }

    static func snakeToCamel(_ s: String) -> String {
        let parts = s.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return s }
        return parts.enumerated().map { i, p in i == 0 ? String(p) : p.prefix(1).uppercased() + p.dropFirst() }.joined()
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
