import Foundation
import Testing
@testable import HogCore

/// Task temperature-fans: SMC values, the key table per chip, temperatures and fans in the snapshot.
@Suite struct HeatTests {
    let bundled = SMCKeyTable.load(DataSource(bundledDirectory: DataSource.standard("smc").bundledDirectory, localDirectory: nil))

    func floatBytes(_ x: Float) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: x.bitPattern >> (8 * UInt32($0))) } }

    @Test func decodesEachType() {
        #expect(SMC.decode(type: "flt ", bytes: floatBytes(55.5)) == 55.5)
        #expect(SMC.decode(type: "ui8 ", bytes: [2]) == 2, "not Double(bitPattern:)")
        #expect(SMC.decode(type: "ui16", bytes: [0x01, 0x02]) == 258, "big-endian")
        #expect(SMC.decode(type: "ui32", bytes: [0, 0, 0x01, 0x00]) == 256)
        #expect(SMC.decode(type: "fpe2", bytes: [0x25, 0x80]) == 2400, "0x2580 / 4")
        #expect(SMC.decode(type: "sp78", bytes: [0x37, 0x80]) == 55.5, "0x3780 / 256")
        #expect(SMC.decode(type: "sp78", bytes: [0xff, 0x00]) == -1, "signed")
    }

    @Test func wrongLengthOrTypeIsUnmeasured() {
        #expect(SMC.decode(type: "flt ", bytes: [0, 0]) == nil)
        #expect(SMC.decode(type: "ui8 ", bytes: [1, 2]) == nil)
        #expect(SMC.decode(type: "fpe2", bytes: [1]) == nil)
        #expect(SMC.decode(type: "hex_", bytes: [0, 0, 0, 0]) == nil)
        #expect(SMC.decode(type: "flt ", bytes: floatBytes(.nan)) == nil)
    }

    @Test func requestLayoutIs80BytesLikeC() {
        let key = try! #require(SMC.fourCC("Tp01"))
        #expect(key == 0x5470_3031)
        #expect(SMC.string(key) == "Tp01")
        let r = SMC.request(key: key, command: SMC.cmdReadKey, dataSize: 4)
        #expect(r.count == 80)
        #expect(SMC.uint32(r, at: 0) == key)
        #expect(SMC.uint32(r, at: 28) == 4, "keyInfo.dataSize after C padding")
        #expect(r[42] == 5, "data8 = read key")
        #expect(r.enumerated().allSatisfy { [0, 1, 2, 3, 28, 29, 30, 31, 42].contains($0.offset) || $0.element == 0 })
        #expect(SMC.fourCC("Tp1") == nil && SMC.fourCC("Tp0é") == nil && SMC.fourCC("F10Ac") == nil)
    }

    @Test func onlyReadCommands() throws {
        // hog never writes the SMC (no fan control): the only commands are key info (9) and read key (5).
        #expect(SMC.cmdKeyInfo == 9 && SMC.cmdReadKey == 5)
        let src = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/HogCoreTests/HeatTests.swift",
                                                                           with: "Sources/HogCore/Sensors/SMC.swift"), encoding: .utf8)
        #expect(!src.contains("cmdWrite") && src.components(separatedBy: "command: Self.cmd").count == 3)
    }

    @Test func bundledTablesPickTheChipExactly() {
        #expect(bundled.warnings.isEmpty, "\(bundled.warnings)")
        #expect(bundled.entry(chip: "Apple M1 Pro")?.id == "m1")
        #expect(bundled.entry(chip: "Apple M1 Pro")?.provenance.verified == true)
        #expect(bundled.entry(chip: "Apple M2 Max")?.id == "m2")
        #expect(bundled.entry(chip: "Apple M3")?.id == "m3")
        #expect(bundled.entry(chip: "Apple M4")?.id == "m4")
        #expect(bundled.entry(chip: "Apple M4 Pro")?.id == "m4-pro-max")
        for chip in ["Apple M2", "Apple M3 Pro", "Apple M4 Max"] { #expect(bundled.entry(chip: chip)?.provenance.verified == false) }
        #expect(bundled.entry(chip: "Apple M9") == nil, "unknown chip: no guess")
        #expect(bundled.entry(chip: "Apple M1 Pro Max") == nil && bundled.entry(chip: "apple m1") == nil, "exact names only")
        #expect(bundled.entry(chip: "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz") == nil)
    }

    @Test func badTableFilesAreSkipped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hog-smc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let prov = #""provenance": {"added": "2026-10-27", "source": "measured", "verified": true}"#
        let files = [
            "a-ok.json": #"{"id": "m1", "chips": ["Apple M1 Pro"], "cpu_keys": ["Tp0X"], "gpu_keys": [], \#(prov)}"#,
            "b-longkey.json": #"{"id": "x", "chips": ["X"], "cpu_keys": ["Tp001"], "gpu_keys": [], \#(prov)}"#,
            "c-unknown.json": #"{"id": "y", "chips": ["Y"], "cpu_keys": ["Tp01"], "gpu_keys": [], "fans": [], \#(prov)}"#,
            "d-nochip.json": #"{"id": "z", "chips": [], "cpu_keys": ["Tp01"], "gpu_keys": [], \#(prov)}"#,
        ]
        for (name, body) in files { try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let t = SMCKeyTable.load(DataSource(bundledDirectory: DataSource.standard("smc").bundledDirectory, localDirectory: dir))
        #expect(t.warnings.count == 3)
        #expect(t.entry(chip: "Apple M1 Pro")?.cpuKeys == ["Tp0X"], "a local file overrides the bundled one with its id")
        #expect(t.entry(chip: "Apple M1") == nil, "the override replaced m1 as a whole")
    }

    let table = SMCKeyTable(entries: [SMCKeyEntry(id: "t", chips: ["Chip"], cpuKeys: ["C1", "C2", "C3", "C4"], gpuKeys: ["G1", "G2"],
                                                  provenance: .init(added: "2026-10-27", source: "docs", verified: false))])

    @Test func averageMaxAndImplausibleValues() {
        let values: [String: Double] = ["C1": 50, "C2": 60, "C3": 0, "C4": 400, "G1": 55.55, "FNum": 0]
        let r = HeatReader.heat(chip: "Chip", table: table) { values[$0] }
        #expect(r.heat.cpuAvgC.value == 55 && r.heat.cpuMaxC.value == 60 && r.heat.cpuSensors == 2, "0 °C and 400 °C dropped")
        #expect(r.heat.gpuAvgC.value == 55.6 && r.heat.gpuSensors == 1, "missing G2 skipped; rounded to 0.1")
        #expect(r.heat.keyTable.value == "t" && r.heat.keysVerified.value == false)
        #expect(r.heat.fans.value == [], "FNum 0: no fan")
        #expect(r.status.status == .ok)
    }

    @Test func unreadableIsNull() {
        let none = HeatReader.heat(chip: "Chip", table: table) { _ in nil }
        #expect(none.heat.cpuAvgC.value == nil && none.heat.cpuMaxC.value == nil && none.heat.gpuAvgC.value == nil)
        #expect(none.heat.fans.value == nil, "FNum unreadable: not \"no fan\"")
        #expect(none.status.status == .error)

        let unknown = HeatReader.heat(chip: "Apple M9", table: table) { _ in 50 }
        #expect(unknown.heat.cpuAvgC.value == nil && unknown.heat.keyTable.value == nil, "no table: no guess, even if keys answer")
        #expect(unknown.status.status == .unavailable && unknown.status.note.value?.contains("Apple M9") == true)

        let closed = HeatReader.heat(chip: "Chip", table: table, smcOpen: false) { _ in 50 }
        #expect(closed.heat.cpuAvgC.value == nil && closed.heat.fans.value == nil && closed.status.status == .unavailable)
    }

    @Test func fans() {
        let two: [String: Double] = ["FNum": 2, "F0Ac": 2321.4, "F0Mn": 1200, "F0Mx": 5779, "F1Ac": 0, "F1Mn": 1200]
        let f = HeatReader.fans { two[$0] }
        #expect(f?.count == 2)
        #expect(f?[0] == HeatInfo.Fan(index: 0, rpm: Measured(2321), minRpm: Measured(1200), maxRpm: Measured(5779)))
        #expect(f?[1].rpm.value == 0 && f?[1].maxRpm.value == nil, "a stopped fan is 0, an unreadable max is null")
        #expect(HeatReader.fans { $0 == "FNum" ? 40 : nil } == nil, "not a fan count")
        #expect(HeatReader.fans { $0 == "FNum" ? 1 : ($0 == "F0Ac" ? -5 : nil) }?.first?.rpm.value == nil)
    }

    @Test func snapshotHasHeatAndKeepsThermal() throws {
        var system = RawSystem(memTotalBytes: 16 << 30, ncpu: 8, pageSize: 16384)
        system.pressureLevel = 1; system.thermal = .fair
        var scan = Scan(system: system, processes: [:], launchd: [:])
        scan.heat = HeatInfo(chip: Measured("Apple M1 Pro"), keyTable: Measured("m1"), keysVerified: Measured(true),
                             cpuAvgC: Measured(52.8), cpuMaxC: Measured(54.5), cpuSensors: 10,
                             fans: Measured([HeatInfo.Fan(index: 0, rpm: Measured(0))]))
        scan.dataWarnings = ["local:x.json: skipped"]
        let b = { (k: String) in DataSource(bundledDirectory: DataSource.standard(k).bundledDirectory, localDirectory: nil) }
        let s = Analyzer(catalog: .load(b("catalog")), rules: .load(b("rules")), explain: .load(b("explain")), lang: .en).analyze(scan)
        #expect(s.heat == scan.heat && s.warnings.contains("local:x.json: skipped"))
        let json = try #require(String(data: SnapshotJSON.encode(s), encoding: .utf8))
        #expect(json.contains("\"thermal\" : \"fair\""), "old field kept")
        for key in ["\"heat\"", "\"cpu_avg_c\" : 52.8", "\"gpu_avg_c\" : null", "\"keys_verified\" : true", "\"min_rpm\" : null"] {
            #expect(json.contains(key), "\(key)")
        }
        #expect(try SnapshotJSON.decode(SnapshotJSON.encode(s)).heat == s.heat)
    }

    @Test func readsThisMachineWithoutRoot() {
        // Real SMC, read-only: on an Apple Silicon Mac with a table the CPU temperature is plausible; elsewhere it is null.
        let r = HeatReader.read(table: bundled)
        if let avg = r.heat.cpuAvgC.value { #expect(HeatReader.plausibleC.contains(avg)) }
        if r.heat.keyTable.value == nil { #expect(r.heat.cpuAvgC.value == nil) }
    }
}

/// Task temperature-fans: words for degrees and fans (CLI and app share them).
@Suite struct HeatFormatTests {
    @Test func degreesAndFans() {
        #expect(Format.celsius(52.8, .en) == "53 °C")
        let h = { (fans: [HeatInfo.Fan]?) in HeatInfo(fans: Measured(fans)) }
        #expect(Format.fans(h(nil), .vi) == nil)
        #expect(Format.fans(h([]), .vi) == "không có quạt" && Format.fans(h([]), .en) == "no fan")
        let f = { (rpm: Int?, max: Int?) in HeatInfo.Fan(index: 0, rpm: Measured(rpm), maxRpm: Measured(max)) }
        #expect(Format.fans(h([f(0, 5779), f(0, 6241)]), .vi) == "quạt đứng" && Format.fans(h([f(0, nil)]), .en) == "fan stopped")
        #expect(Format.fans(h([f(0, 5779), f(2512, nil)]), .vi) == "quạt 2512 vòng/phút", "no maximum: no %")
        #expect(Format.fans(h([f(3861, 5779), f(4154, 6241)]), .vi) == "quạt 4154 vòng/phút (67 %)")
        #expect(Format.fans(h([f(nil, 5779)]), .vi) == nil, "no fan speed read: say nothing, not \"stopped\"")
    }

    @Test func fanPercentIsOfEachFansOwnMaximum() {
        let fans = [HeatInfo.Fan(index: 0, rpm: Measured(3861), maxRpm: Measured(5779)),   // 66.8 %
                    HeatInfo.Fan(index: 1, rpm: Measured(4154), maxRpm: Measured(6241))]   // 66.6 %
        #expect(fans.map(\.pct) == [67, 67])
        #expect(HeatInfo(fans: Measured([HeatInfo.Fan(index: 0, rpm: Measured(1200), maxRpm: Measured(6000)),
                                         HeatInfo.Fan(index: 1, rpm: Measured(3000), maxRpm: Measured(6000))])).fanPct == 50, "the busiest")
        #expect(HeatInfo(fans: Measured([HeatInfo.Fan(index: 0, rpm: Measured(3000), maxRpm: Measured(0))])).fanPct == nil)
        #expect(HeatInfo(fans: Measured([])).fanPct == nil && HeatInfo().fanPct == nil)
        #expect(HeatInfo(fans: Measured([HeatInfo.Fan(index: 0, rpm: Measured(0), maxRpm: Measured(5779)),
                                         HeatInfo.Fan(index: 1, rpm: Measured(2512))])).fanPct == nil, "not 0 % while a fan spins")
    }

    @Test func tagNextToDegreesIsMeasuredCooling() {
        let working = HeatInfo(cpuAvgC: Measured(88.7), fans: Measured([HeatInfo.Fan(index: 0, rpm: Measured(4154), maxRpm: Measured(6241))]))
        #expect(Format.heatTag(working, thermal: .nominal, .vi) == "quạt 67 %", "not \"mát\" at 89 °C")
        #expect(Format.heatTag(working, thermal: .fair, .en) == "fans 67 %")
        #expect(Format.heatTag(working, thermal: .serious, .vi) == "nóng")
        #expect(Format.heatTag(working, thermal: .critical, .en) == "very hot")
        let stopped = HeatInfo(fans: Measured([HeatInfo.Fan(index: 0, rpm: Measured(0), maxRpm: Measured(5779))]))
        #expect(Format.heatTag(stopped, thermal: .nominal, .vi) == "quạt đứng")
        #expect(Format.heatTag(HeatInfo(fans: Measured([])), thermal: .nominal, .vi) == "bình thường", "no fan: macOS's word")
        #expect(Format.heatTag(HeatInfo(), thermal: nil, .vi) == nil)
        #expect(Format.thermal(.nominal, .vi) == "bình thường" && Format.thermal(.nominal, .en) == "normal")
    }

    @Test func detailSaysWhereDegreesComeFrom() {
        let fans = Measured([HeatInfo.Fan(index: 0, rpm: Measured(0), minRpm: Measured(1200), maxRpm: Measured(5779))])
        let checked = Format.heatDetail(HeatInfo(chip: Measured("Apple M1 Pro"), keyTable: Measured("m1"), keysVerified: Measured(true),
                                                 cpuAvgC: Measured(52.8), cpuMaxC: Measured(54.6), cpuSensors: 10,
                                                 gpuAvgC: Measured(51.6), fans: fans), thermal: .nominal, .vi)
        #expect(checked == [
            "CPU: trung bình 53 °C, nóng nhất 55 °C (10 cảm biến)", "GPU: 52 °C", "Quạt 1: đứng (chạy 1200–5779)", "macOS: bình thường, chưa phải giảm tốc vì nóng",
            "Nguồn: cảm biến SMC không chính thức (Apple không công bố) — khoá của Apple M1 Pro đã kiểm trên máy thật.",
        ], "\(checked)")

        let unchecked = Format.heatDetail(HeatInfo(chip: Measured("Apple M3"), keyTable: Measured("m3"), keysVerified: Measured(false),
                                                   cpuAvgC: Measured(60), cpuMaxC: Measured(70), cpuSensors: 16), thermal: nil, .en)
        #expect(unchecked.last?.contains("not checked on a real Mac yet") == true)

        let unknown = Format.heatDetail(HeatInfo(chip: Measured("Apple M9"), fans: Measured([])), thermal: .fair, .vi)
        #expect(unknown == ["Máy không có quạt", "macOS: hơi nóng, chưa giảm tốc", "Chưa đo được độ C: hog chưa biết khoá cảm biến của Apple M9."])
        let spinning = Format.heatDetail(HeatInfo(cpuAvgC: Measured(88.7), cpuMaxC: Measured(93.5), cpuSensors: 10,
                                                  fans: Measured([HeatInfo.Fan(index: 1, rpm: Measured(4154), minRpm: Measured(1200), maxRpm: Measured(6241))])),
                                         thermal: .nominal, .vi)
        #expect(spinning.contains("Quạt 2: 4154 vòng/phút (67 % sức; chạy 1200–6241)"), "\(spinning)")
        let silent = Format.heatDetail(HeatInfo(chip: Measured("Apple M1"), keyTable: Measured("m1")), thermal: nil, .vi)
        #expect(silent == ["Chưa đo được độ C: cảm biến không trả lời."])
    }
}
