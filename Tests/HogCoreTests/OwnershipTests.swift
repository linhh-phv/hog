import Foundation
import Testing
@testable import HogCore

@Suite final class OwnershipTests {
    let home: String
    let sessionStart = Date(timeIntervalSince1970: 1_792_984_800)

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("hog-own-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home + "/work/web-app/src", withIntermediateDirectories: true)
        try Data(#"{"name":"web-app"}"#.utf8).write(to: URL(fileURLWithPath: home + "/work/web-app/package.json"))
        try FileManager.default.createDirectory(atPath: home + "/work/api/.git", withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: home) }

    func proc(_ pid: Int32, _ ppid: Int32?, _ exe: String?, cwd: String? = nil, start: Date? = nil) -> RawProcess {
        var p = RawProcess(pid: pid)
        p.ppid = ppid; p.exePath = exe; p.cwd = cwd
        if let start { p.startSec = Int64(start.timeIntervalSince1970) }
        return p
    }

    func scan() -> Scan {
        let vscode = "/Applications/Visual Studio Code.app/Contents"
        let procs: [RawProcess] = [
            proc(1, 0, "/sbin/launchd", cwd: "/"),
            proc(100, 1, vscode + "/MacOS/Code", cwd: "/"),
            proc(150, 100, vscode + "/Frameworks/Code Helper (Renderer).app/Contents/MacOS/Code Helper (Renderer)"),
            proc(200, 100, vscode + "/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"),
            proc(300, 200, home + "/.vscode/extensions/anthropic.claude-code/resources/native-binary/claude", cwd: home + "/work/api", start: sessionStart),
            proc(301, 300, "/bin/zsh", cwd: home + "/work/web-app"),
            proc(302, 301, "/opt/homebrew/bin/node", cwd: home + "/work/web-app/src"),
            proc(400, 1, "/opt/homebrew/bin/watchman", cwd: "/"),
            proc(500, 1, "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python", cwd: home + "/work/web-app"),
            proc(600, 1, "/Applications/Word.app/Contents/PlugIns/WordWidget.appex/Contents/MacOS/WordWidget", cwd: home + "/Library/Containers/x"),
            proc(700, 1, "/opt/homebrew/bin/node", cwd: nil),
            proc(800, 1, "/opt/homebrew/bin/node", cwd: "/"),
            proc(900, 1, nil, cwd: home + "/work"),
            proc(950, nil, "/usr/libexec/something"),
        ]
        let sessions = [Int32(300): ClaudeSession(pid: 300, sessionId: "s", cwd: home + "/work/api", busy: false,
                                                  statusUpdatedAt: nil, startedAt: nil, procStart: sessionStart)]
        return Scan(home: home, system: RawSystem(memTotalBytes: 0, ncpu: 8, pageSize: 16384),
                    processes: Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0) }),
                    launchd: [400: "com.github.facebook.watchman"],
                    vscode: CodeStatusParser.Status(windows: [2: CodeStatusParser.Window(index: 2, title: "web-app", windowPid: 150, extensionHostPid: 200)], roles: [150: "window", 200: "extension-host"]),
                    sessions: sessions)
    }

    @Test func descendantsOfAClaudeSessionBelongToIt() {
        let o = Ownership.resolve(scan())
        #expect(o[302]?.session == 300)
        #expect(o[302]?.window == 2)
        #expect(o[302]?.app == "Visual Studio Code")
        #expect(o[302]?.ownerId == "claude:300")
        #expect(o[302]?.project == "api", "a session's processes take the session's project")
        #expect(o[200]?.ownerId == "vscode:2")
        #expect(o[100]?.ownerId == "app:visual-studio-code")
    }

    @Test func staleSessionFileIsIgnored() {
        var s = scan()
        s.processes[300]?.startSec = Int64(sessionStart.timeIntervalSince1970) + 60  // PID reused by another process
        #expect(Ownership.resolve(s)[302]?.session == nil)
    }

    @Test func orphanDefinition() {
        let o = Ownership.resolve(scan())
        #expect(o[500]?.orphan == true, "python3 inside Xcode.app/…/Python.app is still an orphan dev server")
        #expect(o[400]?.orphan == false, "launchd job (watchman) is not an orphan")
        #expect(o[600]?.orphan == false, "widget .appex is not an orphan")
        #expect(o[800]?.orphan == false, "cwd outside home")
        #expect(o[302]?.orphan == false, "has a living parent")
        #expect(o[700]?.orphan == nil, "cwd unreadable → unknown")
        #expect(o[900]?.orphan == nil, "exe path unreadable → unknown")
        #expect(o[950]?.orphan == nil, "ppid unreadable → unknown")
    }

    @Test func withoutLaunchdDataOrphanIsUnknown() {
        var s = scan()
        s.launchd = nil
        #expect(Ownership.resolve(s)[500]?.orphan == nil)
    }

    @Test func ancestorChain() {
        let s = scan()
        let a = Ownership.ancestors(of: 302, in: s.processes)
        #expect(a.chain == [301, 300, 200, 100, 1] && a.complete)
        #expect(!Ownership.ancestors(of: 950, in: s.processes).complete)
    }

    @Test func projectMarkers() {
        var cache = ProjectCache()
        #expect(cache.name(for: home + "/work/web-app/src", home: home) == "web-app")
        #expect(cache.name(for: home + "/work/api", home: home) == "api")
        #expect(cache.name(for: home + "/work", home: home) == nil)
        #expect(cache.name(for: "/", home: home) == nil)
    }

    @Test func systemExecutables() {
        #expect(Ownership.isSystemExecutable("/usr/bin/python3") == true)
        #expect(Ownership.isSystemExecutable("/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock") == true)
        #expect(Ownership.isSystemExecutable("/usr/local/go/bin/go") == false, "user tools in /usr/local")
        #expect(Ownership.isSystemExecutable("/opt/homebrew/bin/node") == false)
        #expect(Ownership.isSystemExecutable(nil) == nil)
    }

    @Test func realOrphanIsDetected() throws {
        // A real orphan created by the test: sh starts sleep in the background and exits; launchd adopts it.
        let dir = home + "/work/web-app"
        let pidFile = home + "/orphan.pid"
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        // No pipes: a pipe inherited by the background child would block reading until it exits.
        sh.arguments = ["-c", "cd '\(dir)'; /bin/sleep 30 </dev/null >/dev/null 2>&1 & echo $! > '\(pidFile)'"]
        sh.standardInput = FileHandle.nullDevice
        sh.standardOutput = FileHandle.nullDevice
        sh.standardError = FileHandle.nullDevice
        try sh.run()
        sh.waitUntilExit()
        let pid = try #require(Int32(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGTERM) }
        Thread.sleep(forTimeInterval: 0.2)
        let raw = ProcessReader.read(pid)
        #expect(raw.ppid == 1)
        // The kernel reports /private/var/…; URL.resolvingSymlinksInPath strips /private, realpath(3) does not.
        let realHome = try #require(realpath(home, nil).map { defer { free($0) }; return String(cString: $0) })
        #expect(Ownership.isOrphan(raw, launchd: [:], home: realHome) == true)
        #expect(Ownership.isOrphan(raw, launchd: [pid: "com.example.job"], home: realHome) == false)
    }
}
