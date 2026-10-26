import Foundation

// Pure parsers for external command output. Tested with sanitized fixtures.

public enum LsofParser {
    /// `lsof -nP -iTCP -sTCP:LISTEN -F pn` → listening sockets per PID.
    public static func listening(_ text: String) -> [Int32: [ListenSocket]] {
        var result: [Int32: Set<ListenSocket>] = [:]
        var pid: Int32?
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            switch tag {
            case "p": pid = Int32(value)
            case "n":
                guard let pid, let (addr, port) = splitHostPort(String(value)) else { continue }
                result[pid, default: []].insert(ListenSocket(addr: addr, port: port))
            default: continue
            }
        }
        return result.mapValues { $0.sorted { ($0.port, $0.addr) < ($1.port, $1.addr) } }
    }

    public struct Connection: Sendable, Equatable {
        public var pid: Int32
        public var localPort: Int
        public var remotePort: Int
    }

    /// `lsof -nP -iTCP -sTCP:ESTABLISHED -F pn` → one entry per connection end held by a PID.
    public static func established(_ text: String) -> [Connection] {
        var result: [Connection] = []
        var pid: Int32?
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value)
            case "n":
                guard let pid else { continue }
                let ends = value.components(separatedBy: "->")
                guard ends.count == 2, let l = splitHostPort(ends[0]), let r = splitHostPort(ends[1]) else { continue }
                result.append(Connection(pid: pid, localPort: l.1, remotePort: r.1))
            default: continue
            }
        }
        return result
    }

    /// `*:3000`, `127.0.0.1:3000`, `[::1]:3000` → (addr, port).
    static func splitHostPort(_ s: String) -> (String, Int)? {
        guard let colon = s.lastIndex(of: ":"), let port = Int(s[s.index(after: colon)...]) else { return nil }
        var host = String(s[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return (host, port)
    }
}

public enum LaunchctlParser {
    /// `launchctl list` → label per running PID (rows with `-` as PID are not running).
    public static func list(_ text: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard cols.count == 3, let pid = Int32(cols[0]) else { continue }
            result[pid] = String(cols[2])
        }
        return result
    }

    /// Whether launchd restarts the job when hog stops it normally (design section 3.1, fact
    /// `launchd.restarts_after_stop`), read from `launchctl print` (the loaded config, not the plist on disk):
    /// - `properties` contains `keepalive` → true
    /// - semaphores only `after crash => 1` (KeepAlive {Crashed = true}) → false
    /// - `after crash => 0` (Crashed = false: restart on normal exit) or `successful exit => 0` → true
    /// - any other semaphore → nil (not classified)
    /// - no keepalive and no semaphores → false
    public static func restartsAfterStop(printOutput text: String) -> Bool? {
        var properties: [String] = []
        var semaphores: [(String, String)] = []
        var inSemaphores = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if inSemaphores {
                if line == "}" { inSemaphores = false; continue }
                let kv = line.components(separatedBy: "=>")
                if kv.count == 2 {
                    semaphores.append((kv[0].trimmingCharacters(in: .whitespaces), kv[1].trimmingCharacters(in: .whitespaces)))
                }
                continue
            }
            if line.hasPrefix("semaphores = {") { inSemaphores = true; continue }
            if line.hasPrefix("properties = ") {
                properties = line.dropFirst("properties = ".count).components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
        if properties.contains("keepalive") { return true }
        if semaphores.isEmpty { return false }
        var restarts = false
        for (name, value) in semaphores {
            switch (name, value) {
            case ("after crash", "1"): continue
            case ("after crash", "0"), ("successful exit", "0"): restarts = true
            default: return nil
            }
        }
        return restarts
    }
}

public enum CodeStatusParser {
    public struct Window: Sendable, Equatable {
        public var index: Int
        public var title: String?
        public var windowPid: Int32?
        public var extensionHostPid: Int32?
        public var fileWatcherPid: Int32?

        public init(index: Int, title: String? = nil, windowPid: Int32? = nil, extensionHostPid: Int32? = nil, fileWatcherPid: Int32? = nil) {
            self.index = index; self.title = title; self.windowPid = windowPid
            self.extensionHostPid = extensionHostPid; self.fileWatcherPid = fileWatcherPid
        }
    }

    public struct Status: Sendable, Equatable {
        public var windows: [Int: Window]
        /// Role of each VS Code process listed by name (`window`, `extension-host`, `file-watcher`, `pty-host`,
        /// `shared-process`, `gpu-process`, …). Processes with identical arguments are only told apart by this.
        public var roles: [Int32: String]
    }

    /// `code --status` → windows keyed by the `[N]` index plus a role per PID. The `Mem MB` column is ignored:
    /// it prints garbage (tens of billions of MB) on the measured machine.
    public static func parse(_ text: String) -> Status {
        var windows: [Int: Window] = [:]
        var roles: [Int32: String] = [:]
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 4, let pid = Int32(cols[2].trimmingCharacters(in: .whitespaces)) else { continue }
            let name = cols[3...].joined(separator: "\t").trimmingCharacters(in: .whitespaces)
            if let (kind, index, title) = parseName(name) {
                roles[pid] = kind
                var w = windows[index] ?? Window(index: index)
                switch kind {
                case "window": w.windowPid = pid; w.title = title
                case "extension-host": w.extensionHostPid = pid
                case "file-watcher": w.fileWatcherPid = pid
                default: break
                }
                windows[index] = w
            } else if !name.hasPrefix("/"), !name.contains(" "), name != "window" {
                roles[pid] = name  // pty-host, shared-process, gpu-process, utility-network-service, agent-host, code…
            }
        }
        return Status(windows: windows, roles: roles)
    }

    public static func windows(_ text: String) -> [Int: Window] { parse(text).windows }

    /// Without `code --status`: one window per extension host (`Code Helper (Plugin)` with `--inspect-port=0`, measured
    /// 2026-10-26), numbered by PID order, no title. Processes under it still map to their window.
    public static func fallback(_ processes: [Int32: RawProcess]) -> Status? {
        let hosts = processes.values.filter {
            ($0.exePath?.hasSuffix("/Code Helper (Plugin)") ?? false) && ($0.args?.contains("--inspect-port=0") ?? false)
        }.map(\.pid).sorted()
        guard !hosts.isEmpty else { return nil }
        var windows: [Int: Window] = [:]
        var roles: [Int32: String] = [:]
        for (i, pid) in hosts.enumerated() {
            windows[i + 1] = Window(index: i + 1, extensionHostPid: pid)
            roles[pid] = "extension-host"
        }
        return Status(windows: windows, roles: roles)
    }

    /// `window [2] (title)` → ("window", 2, "title"); `extension-host [2]` → ("extension-host", 2, nil).
    static func parseName(_ name: String) -> (String, Int, String?)? {
        guard let open = name.firstIndex(of: "["), let close = name[open...].firstIndex(of: "]"),
              let index = Int(name[name.index(after: open)..<close]) else { return nil }
        let kind = name[..<open].trimmingCharacters(in: .whitespaces)
        var title: String?
        let rest = name[name.index(after: close)...].trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("("), rest.hasSuffix(")") { title = String(rest.dropFirst().dropLast()) }
        return (kind, index, title)
    }
}

/// One Claude Code session from `~/.claude/sessions/<pid>.json` (internal format, read tolerantly).
public struct ClaudeSession: Sendable, Equatable {
    public var pid: Int32
    public var sessionId: String?
    public var cwd: String?
    public var busy: Bool?
    public var statusUpdatedAt: Date?
    public var startedAt: Date?
    /// `procStart` is a `ps lstart`-style string in **UTC** (measured: 0 s off from the kernel start time).
    public var procStart: Date?
}

public enum ClaudeSessionParser {
    public static func parse(_ data: Data) -> ClaudeSession? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (obj["pid"] as? NSNumber)?.int32Value else { return nil }
        func ms(_ key: String) -> Date? {
            (obj[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        }
        var busy: Bool?
        switch obj["status"] as? String {
        case "busy": busy = true
        case "idle": busy = false
        default: busy = nil
        }
        return ClaudeSession(pid: pid, sessionId: obj["sessionId"] as? String, cwd: obj["cwd"] as? String, busy: busy,
                             statusUpdatedAt: ms("statusUpdatedAt"), startedAt: ms("startedAt"),
                             procStart: (obj["procStart"] as? String).flatMap(parseLstartUTC))
    }

    /// `Mon Oct 26 03:31:30 2026` (day may be space-padded) read as UTC.
    public static func parseLstartUTC(_ s: String) -> Date? {
        let collapsed = s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f.date(from: collapsed)
    }

    /// Whether a session file belongs to the live process: `procStart` within 1 s of the kernel start time,
    /// or, without `procStart`, `startedAt` within 5 s. Guards against stale files and reused PIDs.
    public static func matches(_ s: ClaudeSession, processStart: Date?) -> Bool {
        guard let processStart else { return false }
        if let p = s.procStart { return abs(p.timeIntervalSince(processStart)) <= 1 }
        if let st = s.startedAt { return abs(st.timeIntervalSince(processStart)) <= 5 }
        return false
    }
}

public enum WatchmanParser {
    public static func roots(_ text: String) -> [String]? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return obj["roots"] as? [String]
    }

    public static func subscriptionCount(_ text: String) -> Int? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              obj["error"] == nil, let subs = obj["subscriptions"] as? [Any] else { return nil }
        return subs.count
    }
}
