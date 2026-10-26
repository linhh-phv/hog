import Foundation

// The JSON snapshot contract: design section 4. Field names are camelCase here and snake_case in JSON
// (`SnapshotJSON` sets the key strategy). Every measurable value is `Measured<…>` so it is written as
// `null` when it could not be measured.

public struct Snapshot: Codable, Sendable, Equatable {
    public var schema: String = Hog.snapshotSchema
    public var lang: Lang
    public var takenAt: Date
    public var hog: HogInfo
    public var host: HostInfo
    public var memory: MemoryInfo
    public var cpu: CPUInfo
    public var headline: Headline
    public var sensors: [SensorStatus]
    public var owners: [Owner]
    public var processes: [ProcessRecord]
    public var items: [Item]
    public var findings: [Finding]
    public var warnings: [String]

    public init(lang: Lang, takenAt: Date, hog: HogInfo, host: HostInfo, memory: MemoryInfo, cpu: CPUInfo,
                headline: Headline, sensors: [SensorStatus] = [], owners: [Owner] = [], processes: [ProcessRecord] = [],
                items: [Item] = [], findings: [Finding] = [], warnings: [String] = []) {
        self.lang = lang; self.takenAt = takenAt; self.hog = hog; self.host = host; self.memory = memory
        self.cpu = cpu; self.headline = headline; self.sensors = sensors; self.owners = owners
        self.processes = processes; self.items = items; self.findings = findings; self.warnings = warnings
    }
}

public enum Lang: String, Codable, Sendable, CaseIterable { case vi, en }

public struct HogInfo: Codable, Sendable, Equatable {
    public var version: String
    public var pid: Int32
    /// Ancestors of the hog process, nearest first. Used by gate G1 (never stop your own caller).
    public var ancestors: [Int32]
    /// True when the ancestor chain could not be read up to launchd; G1 then blocks the unknown part.
    public var ancestorsComplete: Bool
    public var selfFootprintBytes: Measured<Int64>

    public init(version: String = Hog.version, pid: Int32, ancestors: [Int32], ancestorsComplete: Bool,
                selfFootprintBytes: Measured<Int64>) {
        self.version = version; self.pid = pid; self.ancestors = ancestors
        self.ancestorsComplete = ancestorsComplete; self.selfFootprintBytes = selfFootprintBytes
    }
}

public struct HostInfo: Codable, Sendable, Equatable {
    public var os: String
    public var arch: String
    public var ncpu: Int
    public var memTotalBytes: Int64
    public var uptimeS: Measured<Int64>

    public init(os: String = "darwin", arch: String, ncpu: Int, memTotalBytes: Int64, uptimeS: Measured<Int64>) {
        self.os = os; self.arch = arch; self.ncpu = ncpu; self.memTotalBytes = memTotalBytes; self.uptimeS = uptimeS
    }
}

public enum Pressure: String, Codable, Sendable { case normal, warn, critical }

public struct MemoryInfo: Codable, Sendable, Equatable {
    public var freeBytes: Measured<Int64>
    public var wiredBytes: Measured<Int64>
    /// Physical RAM taken by the compressor ("Pages occupied by compressor"; matches `top`).
    public var compressorBytes: Measured<Int64>
    /// Logical data stored compressed ("Pages stored in compressor"); about twice `compressorBytes`.
    public var compressedStoredBytes: Measured<Int64>
    public var swapUsedBytes: Measured<Int64>
    public var swapTotalBytes: Measured<Int64>
    public var pressure: Measured<Pressure>
    /// Processes whose memory could not be read (other users / root). No estimate is made (design 3.5).
    public var unreadableProcessCount: Int
    /// Filled only by "measure system detail" (one `top` run); `null` otherwise.
    public var systemDetail: Measured<[SystemProcess]>

    public init(freeBytes: Measured<Int64> = nil, wiredBytes: Measured<Int64> = nil, compressorBytes: Measured<Int64> = nil,
                compressedStoredBytes: Measured<Int64> = nil, swapUsedBytes: Measured<Int64> = nil,
                swapTotalBytes: Measured<Int64> = nil, pressure: Measured<Pressure> = nil, unreadableProcessCount: Int = 0,
                systemDetail: Measured<[SystemProcess]> = nil) {
        self.freeBytes = freeBytes; self.wiredBytes = wiredBytes; self.compressorBytes = compressorBytes
        self.compressedStoredBytes = compressedStoredBytes; self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes; self.pressure = pressure
        self.unreadableProcessCount = unreadableProcessCount; self.systemDetail = systemDetail
    }
}

public struct SystemProcess: Codable, Sendable, Equatable {
    public var pid: Int32
    public var exe: String
    public var footprintBytes: Measured<Int64>
    public var compressedBytes: Measured<Int64>
    public var cpuPct: Measured<Double>
}

public struct CPUInfo: Codable, Sendable, Equatable {
    public var userPct: Measured<Double>
    public var sysPct: Measured<Double>
    public var idlePct: Measured<Double>
    public var load: Measured<[Double]>

    public init(userPct: Measured<Double> = nil, sysPct: Measured<Double> = nil, idlePct: Measured<Double> = nil,
                load: Measured<[Double]> = nil) {
        self.userPct = userPct; self.sysPct = sysPct; self.idlePct = idlePct; self.load = load
    }
}

public enum HeadlineLevel: String, Codable, Sendable { case ok, warn, critical }

public struct Headline: Codable, Sendable, Equatable {
    public var level: HeadlineLevel
    public var text: String
    public var glossaryIds: [String]

    public init(level: HeadlineLevel, text: String, glossaryIds: [String]) {
        self.level = level; self.text = text; self.glossaryIds = glossaryIds
    }
}

public enum SensorState: String, Codable, Sendable { case ok, unavailable, skipped, error }

public struct SensorStatus: Codable, Sendable, Equatable {
    public var name: String
    public var status: SensorState
    public var tookMs: Int
    public var note: Measured<String>

    public init(name: String, status: SensorState, tookMs: Int, note: String? = nil) {
        self.name = name; self.status = status; self.tookMs = tookMs; self.note = Measured(note)
    }
}

public enum OwnerKind: String, Codable, Sendable { case app, vscodeWindow = "vscode-window", claudeSession = "claude-session", none }

public struct Owner: Codable, Sendable, Equatable {
    public var id: String
    public var kind: OwnerKind
    public var label: String
    public var parent: Measured<String>
    public var project: Measured<String>
    public var selfFootprintBytes: Int64
    public var totalFootprintBytes: Int64
    public var totalCpuPct: Measured<Double>

    public init(id: String, kind: OwnerKind, label: String, parent: String? = nil, project: String? = nil,
                selfFootprintBytes: Int64 = 0, totalFootprintBytes: Int64 = 0, totalCpuPct: Measured<Double> = nil) {
        self.id = id; self.kind = kind; self.label = label; self.parent = Measured(parent); self.project = Measured(project)
        self.selfFootprintBytes = selfFootprintBytes; self.totalFootprintBytes = totalFootprintBytes; self.totalCpuPct = totalCpuPct
    }
}

public struct ProcessCPU: Codable, Sendable, Equatable {
    public var nowPct: Measured<Double>
    public var avgPct: Measured<Double>
    public init(nowPct: Measured<Double> = nil, avgPct: Measured<Double> = nil) { self.nowPct = nowPct; self.avgPct = avgPct }
}

public struct ListenSocket: Codable, Sendable, Equatable, Hashable {
    public var proto: String
    public var addr: String
    public var port: Int
    public init(proto: String = "tcp", addr: String, port: Int) { self.proto = proto; self.addr = addr; self.port = port }
}

public struct ProcessNet: Codable, Sendable, Equatable {
    public var listen: [ListenSocket]
    public var established: Measured<Int>
    public init(listen: [ListenSocket] = [], established: Measured<Int> = nil) { self.listen = listen; self.established = established }
}

public struct ProcessRecord: Codable, Sendable, Equatable {
    public var pid: Int32
    public var ppid: Measured<Int32>
    public var own: Measured<Bool>
    public var exe: Measured<String>
    public var exePath: Measured<String>
    public var args: Measured<String>
    public var startedAt: Measured<Date>
    public var ageS: Measured<Int64>
    public var footprintBytes: Measured<Int64>
    public var residentBytes: Measured<Int64>
    public var residentRatio: Measured<Double>
    public var compressedBytes: Measured<Int64>
    public var cpu: ProcessCPU
    public var cwd: Measured<String>
    public var project: Measured<String>
    public var orphan: Measured<Bool>
    public var net: ProcessNet
    public var catalogId: Measured<String>
    public var ownerId: Measured<String>
    public var itemId: Measured<String>

    public init(pid: Int32, ppid: Measured<Int32> = nil, own: Measured<Bool> = nil, exe: Measured<String> = nil,
                exePath: Measured<String> = nil, args: Measured<String> = nil, startedAt: Measured<Date> = nil,
                ageS: Measured<Int64> = nil, footprintBytes: Measured<Int64> = nil, residentBytes: Measured<Int64> = nil,
                residentRatio: Measured<Double> = nil, compressedBytes: Measured<Int64> = nil, cpu: ProcessCPU = ProcessCPU(),
                cwd: Measured<String> = nil, project: Measured<String> = nil, orphan: Measured<Bool> = nil,
                net: ProcessNet = ProcessNet(), catalogId: Measured<String> = nil, ownerId: Measured<String> = nil,
                itemId: Measured<String> = nil) {
        self.pid = pid; self.ppid = ppid; self.own = own; self.exe = exe; self.exePath = exePath; self.args = args
        self.startedAt = startedAt; self.ageS = ageS; self.footprintBytes = footprintBytes; self.residentBytes = residentBytes
        self.residentRatio = residentRatio; self.compressedBytes = compressedBytes; self.cpu = cpu; self.cwd = cwd
        self.project = project; self.orphan = orphan; self.net = net; self.catalogId = catalogId; self.ownerId = ownerId
        self.itemId = itemId
    }
}

public enum ItemKind: String, Codable, Sendable { case process, claudeSession = "claude-session", container }

public enum ProtectionLevel: String, Codable, Sendable { case hard, soft }

public struct Protection: Codable, Sendable, Equatable {
    public var level: ProtectionLevel
    public var rules: [String]
    public init(level: ProtectionLevel, rules: [String]) { self.level = level; self.rules = rules }
}

public struct Item: Codable, Sendable, Equatable {
    public var id: String
    public var kind: ItemKind
    public var label: String
    public var catalogId: Measured<String>
    public var pids: [Int32]
    public var ownerId: Measured<String>
    public var footprintBytes: Measured<Int64>
    public var residentRatio: Measured<Double>
    public var protection: Measured<Protection>
    public var facts: [String: FactValue]

    public init(id: String, kind: ItemKind, label: String, catalogId: String? = nil, pids: [Int32], ownerId: String? = nil,
                footprintBytes: Measured<Int64> = nil, residentRatio: Measured<Double> = nil,
                protection: Protection? = nil, facts: [String: FactValue] = [:]) {
        self.id = id; self.kind = kind; self.label = label; self.catalogId = Measured(catalogId); self.pids = pids
        self.ownerId = Measured(ownerId); self.footprintBytes = footprintBytes; self.residentRatio = residentRatio
        self.protection = Measured(protection); self.facts = facts
    }
}

public enum Verdict: String, Codable, Sendable, Comparable {
    case info, watch, ask, mayStop = "may-stop"

    private var rank: Int { switch self { case .info: 0; case .watch: 1; case .ask: 2; case .mayStop: 2 } }
    public static func < (a: Verdict, b: Verdict) -> Bool { a.rank < b.rank }
}

public enum Confidence: String, Codable, Sendable { case low, medium, high }

public enum Respawns: String, Codable, Sendable { case never, byParent = "by-parent", onDemand = "on-demand", supervisor }

public enum StopStrategy: String, Codable, Sendable, CaseIterable {
    case signal, watchmanShutdown = "watchman-shutdown", dockerContainer = "docker-container", manual
}

public struct StopAdvice: Codable, Sendable, Equatable {
    public var strategy: StopStrategy
    public var respawns: Measured<Respawns>
    public var effect: String
    public init(strategy: StopStrategy, respawns: Respawns?, effect: String) {
        self.strategy = strategy; self.respawns = Measured(respawns); self.effect = effect
    }
}

public struct Finding: Codable, Sendable, Equatable {
    public var itemId: String
    public var verdict: Verdict
    public var confidence: Confidence
    public var rules: [String]
    public var reason: String
    public var evidence: [String: FactValue]
    public var unmeasured: [String]
    public var stop: StopAdvice
    public var blockedBy: [String]

    public init(itemId: String, verdict: Verdict, confidence: Confidence, rules: [String], reason: String,
                evidence: [String: FactValue], unmeasured: [String], stop: StopAdvice, blockedBy: [String] = []) {
        self.itemId = itemId; self.verdict = verdict; self.confidence = confidence; self.rules = rules; self.reason = reason
        self.evidence = evidence; self.unmeasured = unmeasured; self.stop = stop; self.blockedBy = blockedBy
    }
}
