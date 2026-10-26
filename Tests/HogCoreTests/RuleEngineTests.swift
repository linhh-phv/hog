import Foundation
import Testing
@testable import HogCore

@Suite struct RuleParsingTests {
    func parse(_ json: String) throws -> Rule { try RuleSet.parse(Data(json.utf8)) }

    let orphanQuiet = """
    {"id":"orphan-quiet","applies_to":["process"],"class":"advice","verdict":"may-stop",
     "when":{"all":[{"fact":"orphan","eq":true},{"fact":"catalog.detached","eq":false},{"fact":"net.established","eq":0},
                    {"fact":"age_s","gte":3600},{"fact":"cpu.avg_pct","lt":1.0}]},
     "reason":{"vi":"Mồ côi {age_s}.","en":"Orphaned for {age_s}."}}
    """

    @Test func parsesTheDesignExample() throws {
        let r = try parse(orphanQuiet)
        #expect(r.id == "orphan-quiet" && r.ruleClass == .advice && r.verdict == .mayStop && r.appliesTo == [.process])
        #expect(r.when.facts == ["orphan", "catalog.detached", "net.established", "age_s", "cpu.avg_pct"])
    }

    @Test(arguments: [
        #"{"id":"x","applies_to":["process"],"class":"advice","verdict":"may-stop","when":{"fact":"orphan","eq":true},"reason":{"vi":"a","en":"b"},"extra":1}"#,
        #"{"id":"x","applies_to":["process"],"class":"advice","verdict":"may-stop","when":{"fact":"no.such.fact","eq":true},"reason":{"vi":"a","en":"b"}}"#,
        #"{"id":"x","applies_to":["process"],"class":"advice","verdict":"may-stop","when":{"fact":"orphan","like":true},"reason":{"vi":"a","en":"b"}}"#,
        #"{"id":"x","applies_to":["process"],"class":"advice","verdict":"ask","when":{"fact":"orphan","eq":true},"reason":{"vi":"a","en":"b"}}"#,
        #"{"id":"x","applies_to":["process"],"class":"protect","when":{"fact":"orphan","eq":true},"reason":{"vi":"a","en":"b"}}"#,
        #"{"id":"x","applies_to":["window"],"class":"advice","verdict":"info","when":{"fact":"orphan","eq":true},"reason":{"vi":"a","en":"b"}}"#,
        #"{"id":"x","applies_to":["process"],"class":"advice","verdict":"info","when":{"fact":"orphan","eq":true},"reason":"plain string","run":"rm -rf /"}"#,
    ])
    func rejectsInvalidRules(json: String) {
        #expect(throws: (any Error).self) { try parse(json) }
    }

    @Test func badFilesAreSkippedNotFatal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hog-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(orphanQuiet.utf8).write(to: dir.appendingPathComponent("a.json"))
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("b.json"))
        let set = RuleSet.load(DataSource(bundledDirectory: dir, localDirectory: nil))
        #expect(set.rules.map(\.id) == ["orphan-quiet"])
        #expect(set.warnings.count == 1 && set.warnings[0].file == "b.json")
    }

    @Test func localFileCannotWeakenHardProtection() throws {
        let bundled = FileManager.default.temporaryDirectory.appendingPathComponent("hog-rb-\(UUID().uuidString)")
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("hog-rl-\(UUID().uuidString)")
        for d in [bundled, local] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        defer { for d in [bundled, local] { try? FileManager.default.removeItem(at: d) } }
        let hard = #"{"id":"protect-self","applies_to":["process"],"class":"protect","level":"hard","when":{"fact":"self.ancestor","eq":true},"reason":{"vi":"a","en":"b"}}"#
        let weak = #"{"id":"protect-self","applies_to":["process"],"class":"protect","level":"soft","when":{"fact":"self.ancestor","eq":"never"},"reason":{"vi":"a","en":"b"}}"#
        try Data(hard.utf8).write(to: bundled.appendingPathComponent("protect-self.json"))
        try Data(weak.utf8).write(to: local.appendingPathComponent("protect-self.json"))
        let set = RuleSet.load(DataSource(bundledDirectory: bundled, localDirectory: local))
        #expect(set.rules.first?.level == .hard)
        #expect(set.warnings.contains { $0.message.contains("cannot override hard protection") })
    }
}

@Suite struct RuleEngineTests {
    let orphanQuiet = try! RuleSet.parse(Data(RuleParsingTests().orphanQuiet.utf8))
    let protectBusy = try! RuleSet.parse(Data(#"{"id":"protect-busy-owner","applies_to":["process","container"],"class":"protect","level":"soft","when":{"all":[{"fact":"owner.kind","ne":"none"},{"any":[{"fact":"owner.busy","eq":true},{"fact":"owner.idle_s","lt":600}]}]},"reason":{"vi":"a","en":"b"}}"#.utf8))
    let protectSelf = try! RuleSet.parse(Data(#"{"id":"protect-self","applies_to":["process"],"class":"protect","level":"hard","when":{"fact":"self.ancestor","eq":true},"reason":{"vi":"a","en":"b"}}"#.utf8))

    var quietOrphan: [String: FactValue] {
        ["orphan": .bool(true), "catalog.detached": .bool(false), "net.established": .int(0), "age_s": .int(7200),
         "cpu.avg_pct": .double(0.2), "owner.kind": .string("none"), "owner.busy": .bool(false), "self.ancestor": .bool(false)]
    }

    @Test func operators() {
        let f: [String: FactValue] = ["age_s": .int(10), "exe.name": .string("node"), "orphan": .bool(true)]
        #expect(RuleEngine.evaluate(.leaf(fact: "age_s", op: .gt, value: .int(5)), f) == .yes)
        #expect(RuleEngine.evaluate(.leaf(fact: "age_s", op: .lte, value: .double(9.5)), f) == .no)
        #expect(RuleEngine.evaluate(.leaf(fact: "exe.name", op: .ne, value: .string("python")), f) == .yes)
        #expect(RuleEngine.evaluate(.inSet(fact: "exe.name", values: [.string("node"), .string("deno")]), f) == .yes)
        #expect(RuleEngine.evaluate(.exists(fact: "cpu.avg_pct", expected: false), f) == .yes)
        #expect(RuleEngine.evaluate(.leaf(fact: "cpu.avg_pct", op: .lt, value: .int(1)), f) == .unknown)
    }

    @Test func kleeneLogic() {
        let f: [String: FactValue] = ["orphan": .bool(true), "age_s": .null]
        let t = Condition.leaf(fact: "orphan", op: .eq, value: .bool(true))
        let u = Condition.leaf(fact: "age_s", op: .gt, value: .int(1))
        let n = Condition.leaf(fact: "orphan", op: .eq, value: .bool(false))
        #expect(RuleEngine.evaluate(.all([t, u]), f) == .unknown)
        #expect(RuleEngine.evaluate(.all([n, u]), f) == .no)
        #expect(RuleEngine.evaluate(.any([t, u]), f) == .yes)
        #expect(RuleEngine.evaluate(.any([n, u]), f) == .unknown)
        #expect(RuleEngine.evaluate(.not(u), f) == .unknown, "not cannot turn a missing measurement into evidence")
    }

    @Test func adviceFiresOnlyOnMeasuredTruth() {
        let out = RuleEngine.run([orphanQuiet], kind: .process, facts: quietOrphan)
        #expect(out.verdict == .mayStop)
        #expect(out.confidence == .high, "orphan + 0 connections + age + cpu = 4 measurements")

        var missing = quietOrphan
        missing["net.established"] = .null
        let out2 = RuleEngine.run([orphanQuiet], kind: .process, facts: missing)
        #expect(out2.verdict == nil, "unknown never supports a stop")
        #expect(out2.unmeasured == ["net.established"])
    }

    @Test func protectFiresOnUnknown() {
        var f = quietOrphan
        f["owner.kind"] = .string("vscode-window")
        f["owner.busy"] = .null
        f["owner.idle_s"] = .null
        let out = RuleEngine.run([orphanQuiet, protectBusy], kind: .process, facts: f)
        #expect(out.protection == Protection(level: .soft, rules: ["protect-busy-owner"]))
        #expect(out.verdict == .ask, "soft protection turns may-stop into ask")
    }

    @Test func hardProtectionBlocks() {
        var f = quietOrphan
        f["self.ancestor"] = .bool(true)
        let out = RuleEngine.run([orphanQuiet, protectSelf], kind: .process, facts: f)
        #expect(out.protection?.level == .hard)
        #expect(out.verdict == .info)
        #expect(out.blockedBy == ["protect-self"])
    }

    @Test func rulesOnlyApplyToTheirKind() {
        #expect(RuleEngine.run([orphanQuiet], kind: .container, facts: quietOrphan).verdict == nil)
    }
}

@Suite struct CatalogTests {
    func entry(_ id: String, _ match: String, extra: String = "") -> String {
        """
        {"id":"\(id)","name":{"vi":"\(id)","en":"\(id)"},"family":"tool","summary":{"vi":"x","en":"x"},
         "stop_effect":{"vi":"y","en":"y"},"respawns":"never","stop":{"strategy":"signal"},"match":[\(match)],
         "provenance":{"added":"2026-10-26","source":"measured","verified":true}\(extra)}
        """
    }

    @Test func mostSpecificClauseWins() throws {
        let c = Catalog(entries: [
            try Catalog.parse(Data(entry("node", #"{"exe":"node"}"#).utf8)),
            try Catalog.parse(Data(entry("next-dev", #"{"exe":"node","args_contains":"next dev"}"#).utf8)),
            try Catalog.parse(Data(entry("tsserver", #"{"args_contains":"tsserver.js"},{"args_contains":"typesMap.json","parent_catalog":"x"}"#).utf8)),
        ])
        #expect(c.match(MatchSubject(exeName: "node", args: "node node_modules/.bin/next dev")) == "next-dev")
        #expect(c.match(MatchSubject(exeName: "node", args: "node server.js")) == "node")
        #expect(c.match(MatchSubject(exeName: "Code Helper (Plugin)", args: "… tsserver.js --useNodeIpc")) == "tsserver")
        #expect(c.match(MatchSubject(exeName: "python3")) == nil)
    }

    @Test func rejectsUnknownKeysAndCommands() {
        #expect(throws: (any Error).self) { try Catalog.parse(Data(entry("x", #"{"exe":"x"}"#, extra: #","command":"rm -rf ~""#).utf8)) }
        #expect(throws: (any Error).self) { try Catalog.parse(Data(entry("x", #"{"exe":"x","shell":"y"}"#).utf8)) }
        #expect(throws: (any Error).self) { try Catalog.parse(Data(entry("x", #"{}"#).utf8)) }
        #expect(throws: (any Error).self) {
            try Catalog.parse(Data(entry("x", #"{"exe":"x"}"#).replacingOccurrences(of: "\"signal\"", with: "\"exec-anything\"").utf8))
        }
    }
}

@Suite struct FormatTests {
    @Test func bytesAndDurationsPerLanguage() {
        #expect(Format.bytes(1_380_000_000, .vi) == "1,3 GB")
        #expect(Format.bytes(1_380_000_000, .en) == "1.3 GB")
        #expect(Format.bytes(6_300_000, .vi) == "6 MB")
        #expect(Format.duration(934_563, .vi) == "11 ngày")
        #expect(Format.duration(934_563, .en) == "11 days")
        #expect(Format.duration(7_200, .vi) == "2 giờ")
        #expect(Format.duration(60, .en) == "1 minute")
    }

    @Test func fillsReasonTemplates() {
        let s = Format.fill("Giữ {footprint_bytes}, chạy {age_s}, CPU {cpu.avg_pct}, còn {resident_ratio} trong RAM, kết nối {net.established}.",
                            facts: ["footprint_bytes": .int(1_380_000_000), "age_s": .int(934_563), "cpu.avg_pct": .double(0.0),
                                    "resident_ratio": .double(0.005), "net.established": .null], lang: .vi)
        #expect(s == "Giữ 1,3 GB, chạy 11 ngày, CPU 0,0 %, còn 0,5 % trong RAM, kết nối chưa đo.")
    }
}
