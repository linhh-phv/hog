import Foundation
import IOKit

/// Read-only access to the SMC (`AppleSMC`), the controller that holds the temperature and fan sensors. No root needed.
///
/// Only two commands are ever sent: "key info" (9) and "read key" (5) — never "write key" (6): hog does not control fans.
/// The keys are not published by Apple and differ per chip, so the temperature keys live in data (`Resources/smc/`).
public final class SMC: Sendable {
    let connection: io_connect_t

    /// Opens the SMC; `nil` when there is none or it refuses (then every value is unmeasured).
    public init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var c: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &c) == KERN_SUCCESS else { return nil }
        connection = c
    }

    deinit { IOServiceClose(connection) }

    /// The value of a key as a number; `nil` when the key does not exist, cannot be read or has an unknown type.
    public func number(_ key: String) -> Double? {
        guard let code = Self.fourCC(key),
              let info = call(Self.request(key: code, command: Self.cmdKeyInfo)) else { return nil }
        let size = Self.uint32(info, at: Self.offKeyInfoSize), type = Self.uint32(info, at: Self.offKeyInfoType)
        guard size > 0, size <= 32,
              let out = call(Self.request(key: code, command: Self.cmdReadKey, dataSize: size)) else { return nil }
        return Self.decode(type: Self.string(type), bytes: Array(out[Self.offBytes..<Self.offBytes + Int(size)]))
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: Self.structSize)
        var outSize = Self.structSize
        let kr = input.withUnsafeBytes { inp in
            output.withUnsafeMutableBytes { out in
                IOConnectCallStructMethod(connection, Self.selector, inp.baseAddress, Self.structSize, out.baseAddress, &outSize)
            }
        }
        return kr == KERN_SUCCESS && output[Self.offResult] == 0 ? output : nil
    }

    // MARK: - The 80-byte request (`SMCKeyData_t` in C)

    /// `kSMCHandleYPCEvent`: the one method every SMC command goes through.
    static let selector: UInt32 = 2
    static let cmdReadKey: UInt8 = 5
    static let cmdKeyInfo: UInt8 = 9
    static let structSize = 80
    // Offsets with C padding: key 0, vers 4–9, pLimitData 12–27, keyInfo 28–39 (size, type, attributes),
    // result 40, status 41, data8 (command) 42, data32 44, bytes 48–79. Swift tuples do not pad like C, so it is built by hand.
    static let offKeyInfoSize = 28
    static let offKeyInfoType = 32
    static let offResult = 40
    static let offCommand = 42
    static let offBytes = 48

    static func request(key: UInt32, command: UInt8, dataSize: UInt32 = 0) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: structSize)
        putUInt32(&b, key, at: 0)
        putUInt32(&b, dataSize, at: offKeyInfoSize)
        b[offCommand] = command
        return b
    }

    /// Native (little-endian) 32-bit fields of the struct.
    static func putUInt32(_ b: inout [UInt8], _ v: UInt32, at off: Int) {
        for i in 0..<4 { b[off + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(i))) }
    }

    static func uint32(_ b: [UInt8], at off: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(b[off + $1]) << (8 * UInt32($1)) }
    }

    /// `"Tp01"` → its four-character code; `nil` unless exactly four ASCII characters.
    static func fourCC(_ key: String) -> UInt32? {
        let bytes = Array(key.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return nil }
        return bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func string(_ code: UInt32) -> String {
        String(decoding: (0..<4).map { UInt8(truncatingIfNeeded: code >> (8 * (3 - UInt32($0)))) }, as: UTF8.self)
    }

    /// Decodes a value by its SMC type. Apple Silicon uses `flt ` (native float); integers and the fixed-point types of
    /// Intel Macs are big-endian. `nil` for an unknown type or a wrong length.
    static func decode(type: String, bytes: [UInt8]) -> Double? {
        func be(_ n: Int) -> UInt64? { bytes.count == n ? bytes.reduce(0) { $0 << 8 | UInt64($1) } : nil }
        switch type {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            let v = Double(Float(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24))
            return v.isFinite ? v : nil
        // A closure, not `Double.init`: that resolves to `Double(bitPattern:)` for a `UInt64` (2 became 1e-323).
        case "ui8 ": return be(1).map { Double($0) }
        case "ui16": return be(2).map { Double($0) }
        case "ui32": return be(4).map { Double($0) }
        case "fpe2": return be(2).map { Double($0) / 4 }
        case "sp78": return be(2).map { Double(Int16(bitPattern: UInt16($0))) / 256 }
        default: return nil
        }
    }
}
