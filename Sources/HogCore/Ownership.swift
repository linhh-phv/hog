import Foundation

/// Who owns a process (design section 3.4).
public struct ProcessOwnership: Sendable, Equatable {
    /// Outermost `.app` bundle of the process or its nearest ancestor that has one.
    public var app: String?
    /// VS Code window index `[N]` from `code --status`.
    public var window: Int?
    /// PID of the Claude session this process is, or descends from.
    public var session: Int32?
    public var project: String?
    /// `nil` when not measurable (missing ppid, exe path, cwd or launchd data).
    public var orphan: Bool?

    /// Most specific owner id: session > window > app.
    public var ownerId: String? {
        if let session { return "claude:\(session)" }
        if let window { return "vscode:\(window)" }
        if let app { return "app:\(Ownership.slug(app))" }
        return nil
    }
}

public enum Ownership {
    /// Resolves ownership for every process in the scan.
    public static func resolve(_ scan: Scan) -> [Int32: ProcessOwnership] {
        let windowOf = windowIndexByPid(scan.windows)
        let sessionPids = matchedSessions(scan)
        var projects = ProjectCache()
        var result: [Int32: ProcessOwnership] = [:]
        for (pid, p) in scan.processes {
            var o = ProcessOwnership()
            for a in [pid] + ancestors(of: pid, in: scan.processes).chain {
                if o.app == nil, let path = scan.processes[a]?.exePath, let app = appName(path) { o.app = app }
                if o.window == nil, let w = windowOf[a] { o.window = w }
                if o.session == nil, sessionPids.contains(a) { o.session = a }
            }
            if let s = o.session, let cwd = scan.sessions?[s]?.cwd { o.project = projects.name(for: cwd, home: scan.home) }
            if o.project == nil, let cwd = p.cwd { o.project = projects.name(for: cwd, home: scan.home) }
            o.orphan = isOrphan(p, launchd: scan.launchd, home: scan.home)
            // An orphan has no owner, even if its binary sits inside an .app (Python.app): QA 2026-10-26.
            if o.orphan == true { o.app = nil }
            result[pid] = o
        }
        return result
    }

    /// Ancestors nearest first, up to launchd. `complete` is false when a link could not be read.
    public static func ancestors(of pid: Int32, in processes: [Int32: RawProcess]) -> (chain: [Int32], complete: Bool) {
        var chain: [Int32] = []
        var current = pid
        var seen: Set<Int32> = [pid]
        while true {
            guard let ppid = processes[current]?.ppid else { return (chain, false) }
            if ppid <= 0 { return (chain, true) }
            if ppid == 1 { chain.append(1); return (chain, true) }
            guard seen.insert(ppid).inserted else { return (chain, false) }
            chain.append(ppid)
            current = ppid
        }
    }

    /// Design section 3.4, step 6. All of: parent is launchd; not a launchd job; executable not inside an
    /// `.appex`/`.xpc` bundle and not under `/System`; cwd inside the home directory.
    /// Each missing measurement makes the answer `nil` instead of guessing.
    public static func isOrphan(_ p: RawProcess, launchd: [Int32: String]?, home: String) -> Bool? {
        guard let ppid = p.ppid else { return nil }
        guard ppid == 1 else { return false }
        guard let launchd else { return nil }
        if launchd[p.pid] != nil { return false }
        guard let exe = p.exePath else { return nil }
        if exe.contains(".appex/") || exe.contains(".xpc/") || exe.hasPrefix("/System/") { return false }
        if isAppMainExecutable(exe, home: home) { return false }
        guard let cwd = p.cwd else { return nil }
        return cwd.hasPrefix(home + "/")
    }

    /// The main binary of an installed app (`/Applications/X.app/Contents/MacOS/X`): a GUI app started from a terminal
    /// that was then closed is the user's app, not an orphan (QA 2026-10-26). A `Python.app` inside a framework or
    /// inside another app (what `python3` runs) does not count.
    static func isAppMainExecutable(_ exe: String, home: String) -> Bool {
        guard ["/Applications/", home + "/Applications/"].contains(where: exe.hasPrefix),
              exe.components(separatedBy: ".app/").count == 2, !exe.contains(".framework/") else { return false }
        let parts = exe.split(separator: "/")
        return parts.count >= 4 && parts[parts.count - 2] == "MacOS" && parts[parts.count - 3] == "Contents"
    }

    /// `exe.system` (design section 6): system locations, excluding `/usr/local` where user tools live.
    public static func isSystemExecutable(_ path: String?) -> Bool? {
        guard let path else { return nil }
        let prefixes = ["/System/", "/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/usr/lib/", "/usr/share/", "/Library/Apple/"]
        return prefixes.contains { path.hasPrefix($0) }
    }

    /// `exe.macos`: macOS itself (`/System`, `/Library/Apple`). Always hard-protected. Tools under `/usr/bin`, `/bin`…
    /// are `exe.system` but only protected when launchd runs them: run from a shell they are the user's own work
    /// (an `ssh -N -L` tunnel, `python3 -m http.server`).
    public static func isMacOSExecutable(_ path: String?) -> Bool? {
        guard let path else { return nil }
        return path.hasPrefix("/System/") || path.hasPrefix("/Library/Apple/")
    }

    /// Outermost `X.app` in a path → "X".
    public static func appName(_ path: String) -> String? {
        for comp in path.split(separator: "/") where comp.hasSuffix(".app") {
            return String(comp.dropLast(4))
        }
        return nil
    }

    static func slug(_ name: String) -> String {
        let s = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(s).split(separator: "-").joined(separator: "-")
    }

    static func windowIndexByPid(_ windows: [Int: CodeStatusParser.Window]?) -> [Int32: Int] {
        var m: [Int32: Int] = [:]
        for (i, w) in windows ?? [:] {
            for pid in [w.windowPid, w.extensionHostPid, w.fileWatcherPid].compactMap({ $0 }) { m[pid] = i }
        }
        return m
    }

    /// Claude sessions whose file matches the live process (procStart/startedAt vs kernel start time).
    static func matchedSessions(_ scan: Scan) -> Set<Int32> {
        Set((scan.sessions ?? [:]).compactMap { pid, s in
            ClaudeSessionParser.matches(s, processStart: scan.processes[pid]?.startDate) ? pid : nil
        })
    }
}

/// Finds a project name by walking up from a directory (design 3.4 step 5). Cached per directory.
struct ProjectCache {
    private var cache: [String: String?] = [:]

    mutating func name(for cwd: String, home: String) -> String? {
        guard cwd.hasPrefix(home + "/") else { return nil }
        var dir = cwd
        var visited: [String] = []
        var found: String?
        while dir.hasPrefix(home + "/") {
            if let hit = cache[dir] { found = hit; break }
            visited.append(dir)
            if let n = Self.marker(in: dir) { found = n; break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        for v in visited { cache[v] = found }
        return found
    }

    static func marker(in dir: String) -> String? {
        let fm = FileManager.default
        let pkg = dir + "/package.json"
        if fm.fileExists(atPath: pkg), let data = fm.contents(atPath: pkg),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let name = obj["name"] as? String, !name.isEmpty {
            return name
        }
        for m in [".git", "go.mod", "Package.swift", "pyproject.toml", "Cargo.toml"] where fm.fileExists(atPath: dir + "/" + m) {
            return (dir as NSString).lastPathComponent
        }
        return nil
    }
}
