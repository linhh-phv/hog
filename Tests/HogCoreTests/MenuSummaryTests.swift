import Foundation
import Testing
@testable import HogCore

@Suite struct MenuSummaryTests {
    @Test func groupsCardsAndNotesFollowTheDesignRules() throws {
        var s = SampleSnapshot.make()
        // two more windows and a second app to exercise grouping
        s.owners.append(Owner(id: "vscode:8", kind: .vscodeWindow, label: "api (Workspace)", parent: "app:vscode", totalFootprintBytes: 1_200_000_000))
        s.owners.append(Owner(id: "app:google-chrome", kind: .app, label: "Google Chrome", totalFootprintBytes: 3_400_000_000))
        s.owners.append(Owner(id: "app:discord", kind: .app, label: "Discord", totalFootprintBytes: 857_000_000))
        for i in 0..<4 {
            s.findings.append(Finding(itemId: "proc:\(i):0", verdict: i == 0 ? .info : .watch, confidence: .low, rules: ["memory-heavy"],
                                      reason: "r", evidence: [:], unmeasured: [], stop: StopAdvice(strategy: .manual, respawns: nil, effect: "")))
        }
        let m = MenuSummary.make(s)
        #expect(m.groups.map(\.label) == ["Visual Studio Code", "Google Chrome", "Watchman"])
        #expect(m.groups[0].children.map(\.label) == ["web-app (Workspace)", "api (Workspace)", "Phần chung (GPU, terminal…)"])
        #expect(m.othersBytes == m.barTotal - m.groups.reduce(0) { $0 + $1.bytes })
        #expect(m.cards.count == 3)
        #expect(m.cards[0].verdict == .mayStop && m.cards[0].action == .stop, "may-stop first, watchman is stoppable")
        #expect(!m.cards.contains { $0.verdict == .info }, "info never in the menu")
        #expect(m.moreCount == 1)
        #expect(m.notes == [MenuSummary.Note(sensor: "docker", text: "Docker — engine đang tắt (không phải lỗi).")])
    }

    @Test func manualStrategyBecomesHowTo() {
        var s = SampleSnapshot.make()
        s.findings[0].stop.strategy = .manual
        #expect(MenuSummary.make(s).cards.first?.action == .howTo)
    }

    @Test func emptySuggestions() {
        var s = SampleSnapshot.make()
        s.findings = []
        let m = MenuSummary.make(s)
        #expect(m.cards.isEmpty && m.moreCount == 0)
    }
}
