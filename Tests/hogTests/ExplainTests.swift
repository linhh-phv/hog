import Foundation
import Testing
@testable import hog
import HogCore

/// Task orphan-stop-effect: `hog explain` says what stopping costs for this process, not only for its catalog entry.
@Suite struct ExplainTests {
    let catalog = Catalog.load(DataSource(bundledDirectory: DataSource.standard("catalog").bundledDirectory, localDirectory: nil))

    func explain(orphan: FactValue, lang: Lang) -> String {
        let item = Item(id: "proc:8:1", kind: .process, label: "tsserver", catalogId: "tsserver", pids: [8], facts: ["orphan": orphan])
        let s = Snapshot(lang: lang, takenAt: Date(), hog: HogInfo(pid: 1, ancestors: [], ancestorsComplete: true, selfFootprintBytes: nil),
                         host: HostInfo(arch: "arm64", ncpu: 8, memTotalBytes: 16 << 30, uptimeS: nil), memory: MemoryInfo(), cpu: CPUInfo(),
                         headline: Headline(level: .ok, text: "", glossaryIds: []), items: [item])
        return Render(lang: lang, noColor: true).explainItem(item, s, catalog: catalog, plan: nil)
    }

    @Test func orphanSaysNothingStartsItAgain() {
        let en = explain(orphan: .bool(true), lang: .en)
        #expect(en.contains("nothing starts it again") && !en.contains("VS Code starts it again") && !en.contains("Restart TS Server"), "\(en)")
        #expect(explain(orphan: .bool(true), lang: .vi).contains("không ai bật lại"))
        // Still under VS Code, or not measured: the catalog's own advice.
        for fact in [FactValue.bool(false), .null] {
            let text = explain(orphan: fact, lang: .en)
            #expect(text.contains("VS Code starts it again") && !text.contains("nothing starts it again"), "\(fact): \(text)")
        }
    }
}
