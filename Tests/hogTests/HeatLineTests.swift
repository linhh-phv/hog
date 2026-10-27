import Foundation
import Testing
@testable import hog
import HogCore

/// Task temperature-fans: the status line shows degrees and fans when measured, macOS's word either way.
@Suite struct HeatLineTests {
    func head(_ heat: HeatInfo, thermal: ThermalState = .nominal, lang: Lang = .vi) -> String {
        let s = Snapshot(lang: lang, takenAt: Date(), hog: HogInfo(pid: 1, ancestors: [], ancestorsComplete: true, selfFootprintBytes: nil),
                         host: HostInfo(arch: "arm64", ncpu: 8, memTotalBytes: 16 << 30, uptimeS: nil),
                         memory: MemoryInfo(usedBytes: Measured(8 << 30), pressure: Measured(.normal), unreadableProcessCount: 0, measuredFootprintBytes: 0),
                         cpu: CPUInfo(thermal: Measured(thermal)), heat: heat, headline: Headline(level: .ok, text: "", glossaryIds: []))
        let o = Overview.make(s, catalog: Catalog(entries: []))
        return Render(lang: lang, noColor: true).overview(o, all: false).components(separatedBy: "\n")[0]
    }

    let stopped = Measured([HeatInfo.Fan(index: 0, rpm: Measured(0)), HeatInfo.Fan(index: 1, rpm: Measured(0))])

    let working = Measured([HeatInfo.Fan(index: 0, rpm: Measured(3861), maxRpm: Measured(5779)),
                            HeatInfo.Fan(index: 1, rpm: Measured(4154), maxRpm: Measured(6241))])

    @Test func degreesThenFans() {
        #expect(head(HeatInfo(cpuAvgC: Measured(52.8), fans: stopped)).contains("nhiệt 53 °C · quạt đứng"))
        // Measured 2026-10-27: 89 °C, fans at 2/3, macOS nominal — no word that reads as "cool" next to it.
        let busy = head(HeatInfo(cpuAvgC: Measured(88.7), fans: working))
        #expect(busy.contains("nhiệt 89 °C · quạt 4154 vòng/phút (67 %)") && !busy.contains("mát") && !busy.contains("bình thường"), "\(busy)")
        let hot = head(HeatInfo(cpuAvgC: Measured(98.2), fans: working), thermal: .serious, lang: .en)
        #expect(hot.contains("heat 98 °C (hot, may slow down) · fans 4154 rpm (67 %)"), "\(hot)")
    }

    @Test func unmeasuredDegreesKeepTheWord() {
        let line = head(.unmeasured)
        #expect(line.contains("nhiệt bình thường") && !line.contains("°C") && !line.contains("quạt"), "\(line)")
        #expect(head(HeatInfo(fans: Measured([]))).contains("không có quạt"))
    }
}
