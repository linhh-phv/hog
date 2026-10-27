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
        #expect(texts.count == 23 * 2 + 30 * 3)
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
