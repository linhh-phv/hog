import Foundation

/// "Measure detail" for processes hog cannot read natively (root / other users): one `top` run (design 3.5).
public enum SystemDetail {
    public struct Row: Sendable, Equatable {
        public var pid: Int32
        public var command: String
        public var memBytes: Int64?
        public var compressedBytes: Int64?
        public var cpuPct: Double?
    }

    /// Parses the **second** sample of `top -l 2 -s 1 -stats pid,command,mem,cmprs,cpu` (the first has no CPU).
    /// COMMAND is a fixed 16-character column that may contain spaces, so PID is the first token and the last
    /// three tokens are MEM, CMPRS, %CPU.
    public static func parseTop(_ text: String) -> [Row] {
        var samples = 0
        var rows: [Row] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("PID") { samples += 1; rows = []; continue }
            guard samples >= 2 else { continue }
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count >= 5, let pid = Int32(tokens[0]) else { continue }
            let n = tokens.count
            rows.append(Row(pid: pid, command: tokens[1..<(n - 3)].joined(separator: " "),
                            memBytes: parseSize(String(tokens[n - 3])), compressedBytes: parseSize(String(tokens[n - 2])),
                            cpuPct: Double(tokens[n - 1])))
        }
        return rows
    }

    /// `833M-`, `356M+`, `0B`, `12K`, `2G` → bytes. The `+`/`-` suffix (growing/shrinking) is dropped.
    public static func parseSize(_ s: String) -> Int64? {
        var t = s
        while let last = t.last, last == "+" || last == "-" { t.removeLast() }
        guard let unit = t.last, let value = Double(t.dropLast()) else { return Int64(t) }
        let mult: Double = switch unit {
        case "B": 1
        case "K": 1024
        case "M": 1024 * 1024
        case "G": 1024 * 1024 * 1024
        case "T": 1024 * 1024 * 1024 * 1024
        default: -1
        }
        return mult < 0 ? nil : Int64(value * mult)
    }

    /// Runs `top` once (~2 s) and returns rows for the given PIDs, largest first.
    public static func measure(pids: Set<Int32>, locator: CommandLocator = CommandLocator()) -> [Row]? {
        guard let top = locator.find("top"),
              let r = Command.run(top, ["-l", "2", "-s", "1", "-stats", "pid,command,mem,cmprs,cpu"], timeout: 10),
              r.status == 0, !r.timedOut else { return nil }
        return parseTop(r.stdout).filter { pids.contains($0.pid) }.sorted { ($0.memBytes ?? 0) > ($1.memBytes ?? 0) }
    }
}

/// `hog ports` / `hog orphans`: the lps 0.1.0 view (listening TCP ports grouped by project), with the new orphan
/// definition (design 3.4).
public enum PortsReport {
    public struct Row: Sendable, Equatable {
        public var pid: Int32
        public var port: Int
        public var command: String
        public var project: String
        public var cwd: String
        public var orphan: Bool
        public var system: Bool
    }

    static let systemPrefixes = ["/System/", "/Library/", "/usr/", "/private/var/", "/Applications/", "/sbin/", "/bin/"]

    public static func rows(_ scan: Scan, orphansOnly: Bool = false) -> [Row] {
        let own = Ownership.resolve(scan)
        var out: [Row] = []
        for (pid, sockets) in scan.network?.listening ?? [:] {
            let p = scan.processes[pid]
            let orphan = own[pid]?.orphan == true
            if orphansOnly && !orphan { continue }
            let cwd = p?.cwd ?? ""
            let project = projectName(cwd: cwd)
            let system = project == "(system)"
            let cwdDisplay = system && (cwd == "/" || cwd.isEmpty) ? "—" : Privacy.scrubPath(cwd, home: scan.home)
            let command = p?.exePath.map { ($0 as NSString).lastPathComponent } ?? "?"
            for port in Set(sockets.map(\.port)) {
                out.append(Row(pid: pid, port: port, command: command, project: project, cwd: cwdDisplay, orphan: orphan, system: system))
            }
        }
        return out.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// Same order as lps: system paths → "(system)"; walk up for `package.json#name`, then a folder with `.git`;
    /// else the cwd's basename.
    public static func projectName(cwd: String) -> String {
        if cwd.isEmpty || cwd == "/" { return "(system)" }
        if systemPrefixes.contains(where: { cwd.hasPrefix($0) }) || cwd.contains("/Library/Containers/") { return "(system)" }
        let fm = FileManager.default
        var dir = cwd
        while dir != "/" && !dir.isEmpty {
            if let data = fm.contents(atPath: dir + "/package.json"),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let name = obj["name"] as? String, !name.isEmpty {
                return name
            }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir + "/.git", isDirectory: &isDir), isDir.boolValue { return (dir as NSString).lastPathComponent }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return (cwd as NSString).lastPathComponent
    }
}
