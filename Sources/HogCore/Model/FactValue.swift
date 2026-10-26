/// One fact of an item: what rules are allowed to read (design section 6).
///
/// `null` means "not measured". Rules treat it as `unknown` (three-valued logic, design section 6.1).
public enum FactValue: Codable, Sendable, Equatable, CustomStringConvertible {
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .null: try c.encodeNil()
        }
    }

    /// Numbers compare by value: JSON writes `0.0` as `0`, so a round trip may turn `.double` into `.int`.
    public static func == (a: FactValue, b: FactValue) -> Bool {
        switch (a, b) {
        case (.bool(let x), .bool(let y)): x == y
        case (.string(let x), .string(let y)): x == y
        case (.null, .null): true
        default:
            if let x = a.number, let y = b.number { x == y } else { false }
        }
    }

    public var isNull: Bool { if case .null = self { true } else { false } }

    /// Numeric view used by comparisons; `nil` for non-numbers.
    public var number: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }

    public var description: String {
        switch self {
        case .bool(let b): String(b)
        case .int(let i): String(i)
        case .double(let d): String(d)
        case .string(let s): s
        case .null: "null"
        }
    }

    public init<T: Codable & Sendable & Equatable>(_ measured: Measured<T>) {
        switch measured.value {
        case nil: self = .null
        case let b as Bool: self = .bool(b)
        case let i as Int64: self = .int(i)
        case let i as Int32: self = .int(Int64(i))
        case let i as Int: self = .int(Int64(i))
        case let d as Double: self = .double(d)
        case let s as String: self = .string(s)
        case let v?: self = .string(String(describing: v))
        }
    }
}
