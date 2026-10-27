import CryptoKit
import Foundation

/// What exactly would be stopped. A process is identified by PID **and** start time, so a reused PID never
/// matches (gate G3).
public struct StopIdentity: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case process, container }
    public var kind: Kind
    public var pid: Int32?
    public var startSec: Int64?
    public var startUsec: Int64?
    public var containerId: String?

    public static func process(_ pid: Int32, startSec: Int64?, startUsec: Int64?) -> StopIdentity {
        StopIdentity(kind: .process, pid: pid, startSec: startSec, startUsec: startUsec)
    }

    public static func container(_ id: String) -> StopIdentity { StopIdentity(kind: .container, containerId: id) }

    var key: String {
        switch kind {
        case .process: "process:\(pid ?? 0):\(startSec ?? 0).\(startUsec ?? 0)"
        case .container: "container:\(containerId ?? "")"
        }
    }
}

public enum StopAction: String, Codable, Sendable {
    /// SIGTERM, then wait; never escalates on its own (G4).
    case sigterm
    /// Only ever as its own plan, after a SIGTERM was not enough and a person agreed again.
    case sigkill
    case watchmanShutdown = "watchman-shutdown"
    /// Restart policy → `no` (verified), then stop (G5).
    case dockerStop = "docker-stop"
    /// Nothing is executed; the plan only tells the person how.
    case manual
}

public enum GateResult: String, Codable, Sendable { case pass, confirm, block }

public struct GateCheck: Codable, Sendable, Equatable {
    public var gate: String
    public var result: GateResult
    public var reason: String
}

/// A stop plan: shown to the person before anything happens (G7), stored so that consent given in chat binds to
/// exactly what was shown (`hog stop --yes --plan <id>`).
public struct StopPlan: Codable, Sendable, Equatable {
    public var planId: String
    public var createdAt: Date
    public var expiresAt: Date
    public var identity: StopIdentity
    public var action: StopAction
    public var label: String
    public var ownerLabel: String?
    public var itemId: String?
    public var rules: [String]
    public var reason: String?
    public var evidence: [String: FactValue]
    public var unmeasured: [String]
    public var effect: String
    /// Human-readable steps hog would take, or the manual instructions.
    public var steps: [String]
    public var gates: [GateCheck]
    /// Restart policy found on the container, recorded so it can be restored (G5, G8).
    public var previousRestartPolicy: String?

    public static let lifetime: TimeInterval = 10 * 60

    public var blocked: GateCheck? { gates.first { $0.result == .block } }
    public var needsConfirmation: Bool { gates.contains { $0.result == .confirm } }
    /// What deserves a look beyond the routine "a person agrees" (G7 on measured evidence, which pressing "Dọn" already
    /// is): another owner (G2), or no suggestion / unmeasured facts (G7). nil = safe to clean up with the others.
    public var askFirst: GateCheck? {
        gates.first { $0.gate == "G2" && $0.result == .confirm }
            ?? (reason == nil || !unmeasured.isEmpty ? gates.first { $0.gate == "G7" && $0.result == .confirm } : nil)
    }

    /// `plan_id` = hash of identity + action only (not of measurements, which change every second).
    public static func makeId(_ identity: StopIdentity, _ action: StopAction) -> String {
        let digest = SHA256.hash(data: Data("\(identity.key)|\(action.rawValue)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public func isExpired(at now: Date = Date()) -> Bool { now >= expiresAt }
}

/// Plans live in `~/.local/state/hog/plans/<plan_id>.json` and expire after 10 minutes.
public struct PlanStore: Sendable {
    public var directory: URL

    public init(directory: URL) { self.directory = directory }

    public static func standard(home: String = NSHomeDirectory()) -> PlanStore {
        PlanStore(directory: URL(fileURLWithPath: home).appendingPathComponent(".local/state/hog/plans"))
    }

    public func save(_ plan: StopPlan) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try SnapshotJSON.encoder().encode(plan)
        try data.write(to: directory.appendingPathComponent("\(plan.planId).json"), options: .atomic)
    }

    public enum LoadError: Error, Equatable { case notFound, expired, unreadable }

    public func load(_ planId: String, now: Date = Date()) throws -> StopPlan {
        guard planId.allSatisfy({ $0.isHexDigit }), !planId.isEmpty else { throw LoadError.notFound }
        let url = directory.appendingPathComponent("\(planId).json")
        guard let data = FileManager.default.contents(atPath: url.path) else { throw LoadError.notFound }
        guard let plan = try? SnapshotJSON.decoder().decode(StopPlan.self, from: data) else { throw LoadError.unreadable }
        if plan.isExpired(at: now) {
            try? FileManager.default.removeItem(at: url)
            throw LoadError.expired
        }
        return plan
    }

    public func remove(_ planId: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(planId).json"))
    }
}

/// G8: every stop is appended to `~/.local/state/hog/actions.jsonl`. If the log cannot be written, nothing is stopped.
public struct ActionLog: Sendable {
    public var file: URL

    public init(file: URL) { self.file = file }

    public static func standard(home: String = NSHomeDirectory()) -> ActionLog {
        ActionLog(file: URL(fileURLWithPath: home).appendingPathComponent(".local/state/hog/actions.jsonl"))
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var at: Date
        public var phase: String  // "start" | "end"
        public var planId: String
        public var identity: StopIdentity
        public var action: StopAction
        public var label: String
        public var gates: [GateCheck]
        public var evidence: [String: FactValue]
        public var previousRestartPolicy: String?
        public var outcome: String?
    }

    public func append(_ entry: Entry) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var line = try SnapshotJSON.encoder(pretty: false).encode(entry)
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteNoPermission) }
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}
