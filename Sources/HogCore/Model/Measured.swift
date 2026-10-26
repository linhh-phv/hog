/// A value that was either measured or could not be measured.
///
/// The snapshot contract (design section 4) requires that an unmeasured value is written as an explicit
/// `null` and never dropped or replaced by `0`/`false`. Swift's synthesized `Codable` omits `nil`
/// optionals, so every measurable field uses this wrapper: it always encodes its key, as the value or `null`.
public struct Measured<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable, ExpressibleByNilLiteral {
    public var value: Value?

    public init(_ value: Value?) { self.value = value }
    public init(nilLiteral: ()) { self.value = nil }

    public static var unmeasured: Measured { Measured(nil) }

    public var isMeasured: Bool { value != nil }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = container.decodeNil() ? nil : try container.decode(Value.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value { try container.encode(value) } else { try container.encodeNil() }
    }

    /// Transforms a measured value; an unmeasured value stays unmeasured.
    public func map<T>(_ transform: (Value) -> T?) -> Measured<T> {
        Measured<T>(value.flatMap(transform))
    }
}
