import Foundation

/// Kleene three-valued logic: `unknown` is a missing measurement (design section 6.1).
public enum Tri: Sendable, Equatable {
    case yes, no, unknown

    static func and(_ xs: [Tri]) -> Tri { xs.contains(.no) ? .no : (xs.contains(.unknown) ? .unknown : .yes) }
    static func or(_ xs: [Tri]) -> Tri { xs.contains(.yes) ? .yes : (xs.contains(.unknown) ? .unknown : .no) }
    var not: Tri { switch self { case .yes: .no; case .no: .yes; case .unknown: .unknown } }
}

public indirect enum Condition: Sendable, Equatable {
    case all([Condition])
    case any([Condition])
    case not(Condition)
    case leaf(fact: String, op: Op, value: FactValue)
    case inSet(fact: String, values: [FactValue])
    case exists(fact: String, expected: Bool)

    public enum Op: String, Sendable, CaseIterable { case eq, ne, gt, gte, lt, lte }

    /// Every fact a condition reads (for validation and confidence counting).
    var facts: [String] {
        switch self {
        case .all(let cs), .any(let cs): cs.flatMap(\.facts)
        case .not(let c): c.facts
        case .leaf(let f, _, _), .inSet(let f, _), .exists(let f, _): [f]
        }
    }
}

public enum RuleClass: String, Codable, Sendable { case advice, protect }

public struct Rule: Sendable, Equatable {
    public var id: String
    public var appliesTo: [ItemKind]
    public var ruleClass: RuleClass
    /// For `advice` rules.
    public var verdict: Verdict?
    /// For `protect` rules.
    public var level: ProtectionLevel?
    public var when: Condition
    public var reason: LocalizedText
}

/// Facts that rules may read in phase 1 (design section 6). A rule using any other name is rejected.
public enum FactNames {
    public static let all: Set<String> = [
        "orphan", "age_s", "cpu.now_pct", "cpu.avg_pct", "footprint_bytes", "resident_ratio", "net.established",
        "net.listen_count", "owner.busy", "owner.idle_s", "owner.kind", "catalog.id", "catalog.family", "catalog.detached",
        "siblings.same_catalog_other_windows", "container.restart_count", "container.restart_policy", "container.state",
        "container.uptime_s", "container.connections", "watchman.subscriptions", "launchd.label",
        "launchd.restarts_after_stop", "session.busy", "session.idle_s", "self.ancestor", "own", "exe.name", "exe.system",
    ]

    /// Facts that describe what something *is*, not a measurement of use; they do not add to confidence.
    static let structural: Set<String> = ["catalog.id", "catalog.family", "catalog.detached", "owner.kind", "exe.name",
                                          "exe.system", "own", "launchd.label", "self.ancestor"]
}

public struct RuleSet: Sendable {
    public private(set) var rules: [Rule]
    public private(set) var warnings: [DataWarning]

    public init(rules: [Rule], warnings: [DataWarning] = []) { self.rules = rules; self.warnings = warnings }

    /// Bundled rules, then local overrides (same id: local wins), except that a `hard` protection can never be
    /// replaced or weakened by a local file (design 6.3).
    public static func load(_ source: DataSource) -> RuleSet {
        var byId: [String: Rule] = [:]
        var order: [String] = []
        var warnings: [DataWarning] = []
        for file in source.files() {
            do {
                let r = try parse(file.data)
                if file.isLocal, let existing = byId[r.id], existing.ruleClass == .protect, existing.level == .hard {
                    warnings.append(DataWarning(file: file.name, message: "ignored: cannot override hard protection \(r.id)"))
                    continue
                }
                if byId[r.id] == nil { order.append(r.id) }
                byId[r.id] = r
                for lang in r.reason.missingLanguages {
                    warnings.append(DataWarning(file: file.name, message: "missing \(lang.rawValue) translation"))
                }
            } catch {
                warnings.append(DataWarning(file: file.name, message: "skipped: \(error)"))
            }
        }
        return RuleSet(rules: order.compactMap { byId[$0] }, warnings: warnings)
    }

    struct Invalid: Error, CustomStringConvertible { var description: String }

    static func parse(_ data: Data) throws -> Rule {
        let obj = try StrictJSON.object(data)
        try StrictJSON.check(obj, allowed: ["id", "applies_to", "class", "verdict", "level", "when", "reason"])
        guard let id = obj["id"] as? String, !id.isEmpty else { throw Invalid(description: "missing id") }
        guard let kinds = obj["applies_to"] as? [String], !kinds.isEmpty else { throw Invalid(description: "missing applies_to") }
        let appliesTo = try kinds.map { k -> ItemKind in
            guard let kind = ItemKind(rawValue: k) else { throw Invalid(description: "unknown item kind \(k)") }
            return kind
        }
        guard let cls = (obj["class"] as? String).flatMap(RuleClass.init) else { throw Invalid(description: "class must be advice or protect") }
        var verdict: Verdict?
        var level: ProtectionLevel?
        switch cls {
        case .advice:
            guard let v = (obj["verdict"] as? String).flatMap(Verdict.init), v != .ask else {
                throw Invalid(description: "advice needs verdict may-stop, watch or info")
            }
            verdict = v
            if obj["level"] != nil { throw Invalid(description: "level is only for protect rules") }
        case .protect:
            guard let l = (obj["level"] as? String).flatMap(ProtectionLevel.init) else { throw Invalid(description: "protect needs level hard or soft") }
            level = l
            if obj["verdict"] != nil { throw Invalid(description: "verdict is only for advice rules") }
        }
        guard let whenObj = obj["when"] else { throw Invalid(description: "missing when") }
        let when = try parseCondition(whenObj, path: "when")
        guard let reasonObj = obj["reason"] as? [String: Any] else { throw Invalid(description: "reason must be {vi, en}") }
        try StrictJSON.check(reasonObj, allowed: ["vi", "en"], at: "reason")
        return Rule(id: id, appliesTo: appliesTo, ruleClass: cls, verdict: verdict, level: level, when: when,
                    reason: LocalizedText(vi: reasonObj["vi"] as? String, en: reasonObj["en"] as? String))
    }

    static func parseCondition(_ any: Any, path: String) throws -> Condition {
        guard let obj = any as? [String: Any] else { throw Invalid(description: "\(path) must be an object") }
        if let list = obj["all"] ?? obj["any"] {
            guard obj.count == 1, let items = list as? [Any], !items.isEmpty else { throw Invalid(description: "\(path): all/any take a non-empty list") }
            let cs = try items.enumerated().map { try parseCondition($1, path: "\(path)[\($0)]") }
            return obj["all"] != nil ? .all(cs) : .any(cs)
        }
        if let inner = obj["not"] {
            guard obj.count == 1 else { throw Invalid(description: "\(path): not takes one condition") }
            return .not(try parseCondition(inner, path: "\(path).not"))
        }
        guard let fact = obj["fact"] as? String else { throw Invalid(description: "\(path): expected all/any/not or a fact") }
        guard FactNames.all.contains(fact) else { throw Invalid(description: "\(path): unknown fact \(fact)") }
        let ops = obj.keys.filter { $0 != "fact" }
        guard ops.count == 1, let op = ops.first else { throw Invalid(description: "\(path): exactly one operator") }
        let raw = obj[op]!
        switch op {
        case "exists":
            guard let b = raw as? Bool else { throw Invalid(description: "\(path): exists takes true/false") }
            return .exists(fact: fact, expected: b)
        case "in":
            guard let arr = raw as? [Any] else { throw Invalid(description: "\(path): in takes a list") }
            return .inSet(fact: fact, values: try arr.map { try literal($0, path) })
        default:
            guard let o = Condition.Op(rawValue: op) else { throw Invalid(description: "\(path): unknown operator \(op)") }
            return .leaf(fact: fact, op: o, value: try literal(raw, path))
        }
    }

    static func literal(_ any: Any, _ path: String) throws -> FactValue {
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            if CFNumberIsFloatType(n) { return .double(n.doubleValue) }
            return .int(n.int64Value)
        }
        if let s = any as? String { return .string(s) }
        throw Invalid(description: "\(path): literal must be a number, string or boolean")
    }
}

/// Evaluates rules against item facts (design section 6.1).
public enum RuleEngine {
    public static func evaluate(_ c: Condition, _ facts: [String: FactValue]) -> Tri {
        switch c {
        case .all(let cs): return Tri.and(cs.map { evaluate($0, facts) })
        case .any(let cs): return Tri.or(cs.map { evaluate($0, facts) })
        case .not(let c): return evaluate(c, facts).not
        case .exists(let f, let expected):
            let present = !(facts[f] ?? .null).isNull
            return present == expected ? .yes : .no
        case .inSet(let f, let values):
            let v = facts[f] ?? .null
            if v.isNull { return .unknown }
            return values.contains(v) ? .yes : .no
        case .leaf(let f, let op, let rhs):
            let v = facts[f] ?? .null
            if v.isNull { return .unknown }
            switch op {
            case .eq: return v == rhs ? .yes : .no
            case .ne: return v == rhs ? .no : .yes
            default:
                guard let a = v.number, let b = rhs.number else { return .no }
                let r: Bool = switch op {
                case .gt: a > b
                case .gte: a >= b
                case .lt: a < b
                case .lte: a <= b
                default: false
                }
                return r ? .yes : .no
            }
        }
    }

    public struct Outcome: Sendable, Equatable {
        public var fired: [Rule]
        public var protection: Protection?
        /// Verdict after protection is applied; `nil` when no advice rule fired.
        public var verdict: Verdict?
        public var confidence: Confidence
        /// Measurement facts that were `unknown` in advice rules that did not fire because of them.
        public var unmeasured: [String]
        public var blockedBy: [String]
    }

    public static func run(_ rules: [Rule], kind: ItemKind, facts: [String: FactValue]) -> Outcome {
        var advice: [Rule] = []
        var protectHard: [String] = []
        var protectSoft: [String] = []
        var unmeasured: Set<String> = []
        var supporting: Set<String> = []
        for r in rules where r.appliesTo.contains(kind) {
            let t = evaluate(r.when, facts)
            switch r.ruleClass {
            case .protect:
                if t != .no { if r.level == .hard { protectHard.append(r.id) } else { protectSoft.append(r.id) } }
            case .advice:
                if t == .yes {
                    advice.append(r)
                    supporting.formUnion(trueMeasurements(r.when, facts))
                } else if t == .unknown {
                    unmeasured.formUnion(r.when.facts.filter { (facts[$0] ?? .null).isNull })
                }
            }
        }
        let protection: Protection? = !protectHard.isEmpty ? Protection(level: .hard, rules: protectHard)
            : (!protectSoft.isEmpty ? Protection(level: .soft, rules: protectSoft) : nil)
        var verdict = advice.compactMap(\.verdict).max()
        var blocked: [String] = []
        if verdict == .mayStop, let p = protection {
            switch p.level {
            case .hard: verdict = .info; blocked = p.rules
            case .soft: verdict = .ask
            }
        }
        let n = supporting.count
        let confidence: Confidence = n >= 3 ? .high : (n == 2 ? .medium : .low)
        return Outcome(fired: advice, protection: protection, verdict: verdict, confidence: confidence,
                       unmeasured: unmeasured.sorted(), blockedBy: blocked)
    }

    /// Measurement facts (not structural ones) that held in a condition tree evaluated true.
    static func trueMeasurements(_ c: Condition, _ facts: [String: FactValue]) -> Set<String> {
        switch c {
        case .all(let cs), .any(let cs):
            return cs.filter { evaluate($0, facts) == .yes }.reduce(into: Set<String>()) { $0.formUnion(trueMeasurements($1, facts)) }
        case .not: return []
        case .leaf(let f, _, _), .inSet(let f, _), .exists(let f, _):
            return FactNames.structural.contains(f) || evaluate(c, facts) != .yes ? [] : [f]
        }
    }
}
