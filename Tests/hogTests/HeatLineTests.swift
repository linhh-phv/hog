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

    @Test func degreesWithMacOSWordAndFans() {
        let line = head(HeatInfo(cpuAvgC: Measured(52.8), cpuMaxC: Measured(54.5), fans: stopped))
        #expect(line.contains("nhiệt 53 °C (macOS: mát) · quạt đứng"), "\(line)")
        let hot = head(HeatInfo(cpuAvgC: Measured(91.2), fans: Measured([HeatInfo.Fan(index: 0, rpm: Measured(4210)),
                                                                          HeatInfo.Fan(index: 1, rpm: Measured(4530))])),
                       thermal: .serious, lang: .en)
        #expect(hot.contains("heat 91 °C (macOS: hot) · fans 4530 rpm"), "\(hot)")
    }

    @Test func unmeasuredDegreesKeepTheWord() {
        let line = head(.unmeasured)
        #expect(line.contains("nhiệt mát") && !line.contains("°C") && !line.contains("quạt"), "\(line)")
        #expect(head(HeatInfo(fans: Measured([]))).contains("không có quạt"))
    }
}
