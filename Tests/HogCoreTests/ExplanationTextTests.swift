import Foundation
import Testing
@testable import HogCore

/// Explanations are read in a 280–340 pt menu: short points, one per line in the data (user 2026-10-27: "hàn lâm kỹ thuật
/// quá … nên gạch đầu dòng hoặc chia đoạn ra sẽ dễ đọc hơn").
@Suite struct ExplanationTextTests {
    let b = { (k: String) in DataSource(bundledDirectory: DataSource.standard(k).bundledDirectory, localDirectory: nil) }

    @Test func pointsAreLines() {
        #expect(Format.points("Một ý.") == ["Một ý."])
        #expect(Format.points("Ý một.\nÝ hai.\n\n  Ý ba.  ") == ["Ý một.", "Ý hai.", "Ý ba."], "blank lines dropped, trimmed")
        #expect(Format.points("") == [])
    }

    @Test func everyBundledTextIsShortPoints() {
        var texts: [(String, LocalizedText)] = []
        for e in Catalog.load(b("catalog")).entries.values { texts += [("\(e.id).summary", e.summary), ("\(e.id).stop_effect", e.stopEffect)] }
        for e in Explanations.load(b("explain")).glossary.values {
            texts += [("\(e.id).plain", e.plain), ("\(e.id).how_to_read", e.howToRead), ("\(e.id).act", e.act)]
        }
        #expect(texts.count == 27 * 2 + 30 * 3)
        for (name, t) in texts {
            for lang in Lang.allCases {
                let points = Format.points(t.text(lang) ?? "")
                #expect((1...4).contains(points.count), "\(name) \(lang): \(points.count) points")
                for p in points { #expect(p.count <= 150, "\(name) \(lang): \(p.count) chars — split it into points") }
                #expect(Format.points(t.text(.vi) ?? "").count == Format.points(t.text(.en) ?? "").count, "\(name): same points in vi and en")
            }
        }
    }
}

/// From two pasted `hog.share/1` of 0-second programs (2026-10-27): not offered as unknown, and a missing command line is said.
@Suite struct JustStartedTests {
    @Test func youngProgramsAreNotUnknown() {
        func item(age: Int64?) -> Item {
            Item(id: "x", kind: .process, label: "node", pids: [1], footprintBytes: Measured(300_000_000),
                 facts: age.map { ["age_s": .int($0), "owner.kind": .string("claude-session")] } ?? ["owner.kind": .string("claude-session")])
        }
        #expect(!Presentation.isUnknownCandidate(item(age: 0)) && !Presentation.isUnknownCandidate(item(age: 9)))
        #expect(Presentation.isUnknownCandidate(item(age: 10)) && Presentation.isUnknownCandidate(item(age: 3600)))
        #expect(Presentation.isUnknownCandidate(item(age: nil)), "an unmeasured age hides nothing")
        let young = ProcessRecord(pid: 1, exe: Measured("node"), exePath: Measured("/usr/local/bin/node"), ageS: Measured(0), footprintBytes: Measured(300_000_000))
        let old = ProcessRecord(pid: 2, exe: Measured("node"), exePath: Measured("/usr/local/bin/node"), ageS: Measured(60), footprintBytes: Measured(300_000_000))
        #expect(!Overview.isUnknownProgram(young) && Overview.isUnknownProgram(old))
    }

    @Test func missingCommandLineIsNullAndSaid() throws {
        let share = ShareInfo(item: .init(kind: .process, exe: "node", args: nil), facts: [:], ownerKind: nil, parents: [], listenPorts: [])
        let text = share.text(.vi)
        #expect(text.contains("\"args\" : null"), "\(text)")
        #expect(text.contains("hog không đọc được lệnh của nó") && text.contains("hog chưa biết thứ này là gì. hog không đọc được"))
        let withArgs = ShareInfo(item: .init(kind: .process, exe: "node", args: "node x.js"), facts: [:], ownerKind: nil, parents: [], listenPorts: [])
        #expect(!withArgs.text(.en).contains("could not read") && withArgs.text(.en).contains("\"args\" : \"node x.js\""))
        let container = ShareInfo(item: .init(kind: .container, image: "postgres:16"), facts: [:], ownerKind: nil, parents: [], listenPorts: [])
        #expect(!container.text(.vi).contains("\"args\""), "a container has an image, not a command line")
    }
}
