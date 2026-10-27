import Foundation

/// Temperatures and fans from the SMC (task temperature-fans): which keys to read comes from `SMCKeyTable`, the reading
/// itself is a function so tests run without the SMC.
public enum HeatReader {
    /// A sensor outside this range is broken or not a temperature: dropped, not averaged.
    static let plausibleC: ClosedRange<Double> = 1...150
    /// `FNum` above this is not a fan count (keys are `F0Ac` … `F9Ac`).
    static let maxFans = 10

    public struct Reading: Sendable {
        public var heat: HeatInfo
        public var status: SensorStatus
    }

    /// Reads this machine: opens the SMC once, reads the chip's keys and the fans.
    public static func read(table: SMCKeyTable, chip: String? = SystemReader.chipName()) -> Reading {
        let started = Date()
        let smc = SMC()
        var r = heat(chip: chip, table: table, smcOpen: smc != nil) { smc?.number($0) }
        r.status.tookMs = Int(Date().timeIntervalSince(started) * 1000)
        return r
    }

    /// The heat for `chip` from `value(key)` (`nil` = the key could not be read).
    static func heat(chip: String?, table: SMCKeyTable, smcOpen: Bool = true, value: (String) -> Double?) -> Reading {
        var h = HeatInfo(chip: Measured(chip))
        guard smcOpen else {
            return Reading(heat: h, status: SensorStatus(name: "smc", status: .unavailable, tookMs: 0, note: "the SMC could not be opened"))
        }
        h.fans = Measured(fans(value))
        guard let chip, let entry = table.entry(chip: chip) else {
            return Reading(heat: h, status: SensorStatus(name: "smc", status: .unavailable, tookMs: 0,
                                                        note: "no temperature keys for \(chip ?? "this chip")"))
        }
        h.keyTable = Measured(entry.id)
        h.keysVerified = Measured(entry.provenance.verified)
        let cpu = entry.cpuKeys.compactMap(value).filter(plausibleC.contains)
        let gpu = entry.gpuKeys.compactMap(value).filter(plausibleC.contains)
        (h.cpuAvgC, h.cpuMaxC, h.cpuSensors) = (Measured(average(cpu)), Measured(cpu.max().map(round1)), cpu.count)
        (h.gpuAvgC, h.gpuMaxC, h.gpuSensors) = (Measured(average(gpu)), Measured(gpu.max().map(round1)), gpu.count)
        let status: SensorState = cpu.isEmpty ? .error : .ok
        return Reading(heat: h, status: SensorStatus(name: "smc", status: status, tookMs: 0,
                                                    note: cpu.isEmpty ? "no CPU temperature key of \(entry.id) could be read" : nil))
    }

    /// `[]` when `FNum` is 0 (no fan); `nil` when `FNum` cannot be read or makes no sense.
    static func fans(_ value: (String) -> Double?) -> [HeatInfo.Fan]? {
        guard let n = value("FNum"), n >= 0, n <= Double(maxFans), n == n.rounded() else { return nil }
        func rpm(_ key: String) -> Measured<Int> { Measured(value(key).flatMap { $0 >= 0 && $0 < 100_000 ? Int($0.rounded()) : nil }) }
        return (0..<Int(n)).map { i in
            HeatInfo.Fan(index: i, rpm: rpm("F\(i)Ac"), minRpm: rpm("F\(i)Mn"), maxRpm: rpm("F\(i)Mx"))
        }
    }

    static func average(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : round1(xs.reduce(0, +) / Double(xs.count)) }
    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}
