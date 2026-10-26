import Foundation

/// A sensor result: the data (or `nil`) plus its status line for `snapshot.sensors`.
public struct Sensed<T: Sendable>: Sendable {
    public var value: T?
    public var status: SensorStatus
}

/// Sensors that call external commands or read files (design section 3.1). Each one is independent and safe to
/// run in parallel; none of them starts a service.
public struct ExternalSensors: Sendable {
    public var locator: CommandLocator
    public var home: String
    /// Watchman roots asked in parallel at most; above this `watchman.subscriptions` stays `null` (design 3.1).
    public var watchmanRootCap: Int = 64

    public init(locator: CommandLocator = CommandLocator(), home: String = NSHomeDirectory()) {
        self.locator = locator
        self.home = home
    }

    func missing(_ name: String, _ command: String) -> SensorStatus {
        SensorStatus(name: name, status: .unavailable, tookMs: 0, note: "command not found: \(command)")
    }

    func failed(_ name: String, _ r: Command.Result) -> SensorStatus {
        SensorStatus(name: name, status: .error, tookMs: r.tookMs,
                     note: r.timedOut ? "timed out" : "exit \(r.status): \(r.stderr.prefix(120))")
    }

    // MARK: lsof

    public struct Network: Sendable {
        public var listening: [Int32: [ListenSocket]]
        public var connections: [LsofParser.Connection]
    }

    public func network() -> Sensed<Network> {
        guard let lsof = locator.find("lsof") else { return Sensed(value: nil, status: missing("lsof", "lsof")) }
        guard let l = Command.run(lsof, ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pn"]),
              let e = Command.run(lsof, ["-nP", "-iTCP", "-sTCP:ESTABLISHED", "-F", "pn"]) else {
            return Sensed(value: nil, status: SensorStatus(name: "lsof", status: .error, tookMs: 0, note: "could not start lsof"))
        }
        // lsof exits 1 when nothing matched; that is a valid empty result.
        if l.timedOut || e.timedOut { return Sensed(value: nil, status: failed("lsof", l.timedOut ? l : e)) }
        return Sensed(value: Network(listening: LsofParser.listening(l.stdout), connections: LsofParser.established(e.stdout)),
                      status: SensorStatus(name: "lsof", status: .ok, tookMs: l.tookMs + e.tookMs))
    }

    // MARK: launchd

    public func launchdJobs() -> Sensed<[Int32: String]> {
        guard let launchctl = locator.find("launchctl") else { return Sensed(value: nil, status: missing("launchd", "launchctl")) }
        guard let r = Command.run(launchctl, ["list"]), r.status == 0, !r.timedOut else {
            return Sensed(value: nil, status: SensorStatus(name: "launchd", status: .error, tookMs: 0, note: "launchctl list failed"))
        }
        return Sensed(value: LaunchctlParser.list(r.stdout), status: SensorStatus(name: "launchd", status: .ok, tookMs: r.tookMs))
    }

    /// `launchctl print` for one job: the `gui/<uid>` domain, then `user/<uid>`. `nil` when both fail.
    public func launchdPrint(label: String) -> String? {
        guard let launchctl = locator.find("launchctl") else { return nil }
        let uid = getuid()
        for domain in ["gui/\(uid)", "user/\(uid)"] {
            if let r = Command.run(launchctl, ["print", "\(domain)/\(label)"]), r.status == 0, !r.timedOut { return r.stdout }
        }
        return nil
    }

    // MARK: VS Code

    /// `~/.local/state/hog/vscode-status-timeout`: identity of the VS Code main process for which `code --status`
    /// timed out. While that instance runs, hog does not call it again.
    func breakerFile() -> URL { URL(fileURLWithPath: home).appendingPathComponent(".local/state/hog/vscode-status-timeout") }

    /// `code --status` (window titles). Only call when VS Code runs: `main` is its main process identity.
    ///
    /// `code` asks LaunchServices (`open -n`) to start a `Code --status` process that is *not* our child. When it hangs,
    /// killing our process group is not enough, so hog removes exactly what it caused (same user, `--status`, started
    /// after the call) and stops calling it until VS Code restarts (QA, 2026-10-26: orphans piled up).
    public func vscode(main: (pid: Int32, start: Int64)?) -> Sensed<CodeStatusParser.Status> {
        let identity = main.map { "\($0.pid):\($0.start)" }
        if let identity, let broken = try? String(contentsOf: breakerFile(), encoding: .utf8),
           broken.trimmingCharacters(in: .whitespacesAndNewlines) == identity {
            return Sensed(value: nil, status: SensorStatus(name: "vscode", status: .unavailable, tookMs: 0,
                                                           note: "code --status timed out earlier; skipped until VS Code restarts"))
        }
        guard let code = locator.find("code") else { return Sensed(value: nil, status: missing("vscode", "code")) }
        guard let r = Command.run(code, ["--status"], timeout: 5) else {
            return Sensed(value: nil, status: SensorStatus(name: "vscode", status: .error, tookMs: 0, note: "could not start code"))
        }
        if r.timedOut {
            Self.cleanUpCodeStatus(since: r.startedAt)
            if let identity {
                try? FileManager.default.createDirectory(at: breakerFile().deletingLastPathComponent(), withIntermediateDirectories: true)
                try? identity.write(to: breakerFile(), atomically: true, encoding: .utf8)
            }
            return Sensed(value: nil, status: SensorStatus(name: "vscode", status: .error, tookMs: r.tookMs,
                                                           note: "code --status did not answer in 5 s; cleaned up, skipped until VS Code restarts"))
        }
        if r.status != 0 { return Sensed(value: nil, status: failed("vscode", r)) }
        return Sensed(value: CodeStatusParser.parse(r.stdout), status: SensorStatus(name: "vscode", status: .ok, tookMs: r.tookMs))
    }

    /// Stops the `Code --status` processes and removes the `code-stdout-*` temp files that one timed-out call left
    /// behind: only ours (same uid), only `--status`, only started after `since`.
    static func cleanUpCodeStatus(since: Date) {
        let me = getuid()
        let cutoff = since.addingTimeInterval(-1)
        var victims: [(Int32, Int64?, Int64?)] = []
        for pid in ProcessReader.allPids() {
            let p = ProcessReader.read(pid)
            guard p.uid == me, let start = p.startDate, start >= cutoff,
                  let exe = p.exePath, exe.contains("Visual Studio Code.app/Contents/MacOS/"),
                  p.args?.contains("--status") == true else { continue }
            victims.append((pid, p.startSec, p.startUsec))
            kill(pid, SIGTERM)
        }
        if !victims.isEmpty {
            usleep(500_000)
            for (pid, sec, usec) in victims {
                if let live = ProcessReader.bsdInfo(pid), live.startSec == sec, live.startUsec == usec { kill(pid, SIGKILL) }
            }
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix("code-stdout-") {
            let url = tmp.appendingPathComponent(name)
            if let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, m >= cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: Claude sessions

    public func claudeSessions() -> Sensed<[Int32: ClaudeSession]> {
        let dir = URL(fileURLWithPath: home).appendingPathComponent(".claude/sessions")
        let started = Date()
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return Sensed(value: nil, status: SensorStatus(name: "claude", status: .unavailable, tookMs: 0, note: "no ~/.claude/sessions"))
        }
        var sessions: [Int32: ClaudeSession] = [:]
        var unreadable = 0
        // Only `<pid>.json`; never the `*.key` files next to them.
        for f in files where f.pathExtension == "json" {
            if let data = try? Data(contentsOf: f), let s = ClaudeSessionParser.parse(data) { sessions[s.pid] = s } else { unreadable += 1 }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if sessions.isEmpty && unreadable > 0 {
            return Sensed(value: nil, status: SensorStatus(name: "claude", status: .unavailable, tookMs: ms,
                                                           note: "session file format not recognized"))
        }
        return Sensed(value: sessions, status: SensorStatus(name: "claude", status: .ok, tookMs: ms,
                                                            note: unreadable > 0 ? "\(unreadable) unreadable session files" : nil))
    }

    // MARK: watchman

    public struct Watchman: Sendable {
        public var roots: [String]
        /// Total subscriptions across roots; `nil` when not every root could be asked (cap or error).
        public var subscriptions: Int?
    }

    public func watchman() -> Sensed<Watchman> {
        guard let wm = locator.find("watchman") else { return Sensed(value: nil, status: missing("watchman", "watchman")) }
        // --no-spawn --no-local: never start a server. rc=1 with empty output = no server running.
        guard let r = Command.run(wm, ["--no-spawn", "--no-local", "watch-list"]) else {
            return Sensed(value: nil, status: SensorStatus(name: "watchman", status: .error, tookMs: 0, note: "could not start watchman"))
        }
        if r.status != 0 && r.stdout.isEmpty && !r.timedOut {
            return Sensed(value: nil, status: SensorStatus(name: "watchman", status: .unavailable, tookMs: r.tookMs, note: "no watchman server running"))
        }
        guard !r.timedOut, let roots = WatchmanParser.roots(r.stdout) else { return Sensed(value: nil, status: failed("watchman", r)) }
        guard roots.count <= watchmanRootCap else {
            return Sensed(value: Watchman(roots: roots, subscriptions: nil),
                          status: SensorStatus(name: "watchman", status: .ok, tookMs: r.tookMs,
                                               note: "\(roots.count) roots > cap \(watchmanRootCap): subscriptions not measured"))
        }
        let counts = Self.parallelMap(roots) { root -> Int? in
            guard let s = Command.run(wm, ["--no-spawn", "--no-local", "debug-get-subscriptions", root]), !s.timedOut else { return nil }
            return WatchmanParser.subscriptionCount(s.stdout)
        }
        let total: Int? = counts.contains(where: { $0 == nil }) ? nil : counts.reduce(0) { $0 + ($1 ?? 0) }
        return Sensed(value: Watchman(roots: roots, subscriptions: total), status: SensorStatus(name: "watchman", status: .ok, tookMs: r.tookMs))
    }

    // MARK: Docker

    public func docker() -> Sensed<[DockerClient.Container]> {
        guard let socket = DockerClient.findSocket(home: home) else {
            return Sensed(value: nil, status: SensorStatus(name: "docker", status: .unavailable, tookMs: 0,
                                                           note: "engine socket missing (engine stopped)"))
        }
        let started = Date()
        do {
            let list = try DockerClient(socketPath: socket).containers()
            return Sensed(value: list, status: SensorStatus(name: "docker", status: .ok, tookMs: Int(Date().timeIntervalSince(started) * 1000)))
        } catch {
            return Sensed(value: nil, status: SensorStatus(name: "docker", status: .error, tookMs: Int(Date().timeIntervalSince(started) * 1000),
                                                           note: "docker API: \(error)"))
        }
    }

    static func parallelMap<T: Sendable, R: Sendable>(_ items: [T], _ f: @escaping @Sendable (T) -> R) -> [R] {
        nonisolated(unsafe) var results = [R?](repeating: nil, count: items.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: items.count) { i in
            let r = f(items[i])
            lock.lock(); results[i] = r; lock.unlock()
        }
        return results.map { $0! }
    }
}
