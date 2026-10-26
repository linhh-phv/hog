import Darwin
import Foundation
import Testing
@testable import HogCore

/// Regression tests for the phase-1 QA (2026-10-26).
@Suite(.serialized) final class QAFixTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hog-qa-\(UUID().uuidString)")

    init() throws { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: dir) }

    // QA 1: a timed-out command must not leave its children behind.
    @Test func timeoutKillsTheWholeProcessGroup() throws {
        let marker = "hog-qa-\(UUID().uuidString.prefix(8))"
        let r = try #require(Command.run("/bin/sh", ["-c", "sleep 31 & sleep 32 & exec -a \(marker) sleep 33"], timeout: 0.3))
        #expect(r.timedOut)
        usleep(300_000)
        let left = ProcessReader.allPids().filter { pid in
            let p = ProcessReader.read(pid)
            return p.ppid == 1 && (p.args?.contains("31") == true || p.args?.contains("32") == true) && p.args?.first?.hasSuffix("sleep") == true
                && (p.startDate ?? .distantPast) >= r.startedAt.addingTimeInterval(-1)
        }
        #expect(left.isEmpty, "orphans left: \(left)")
    }

    // QA 1: after one timeout, `code --status` is not called again for the same VS Code instance.
    @Test func codeStatusBreaker() throws {
        let fake = dir.appendingPathComponent("code")
        try "#!/bin/sh\nsleep 30\n".write(to: fake, atomically: true, encoding: .utf8)
        chmod(fake.path, 0o755)
        var sensors = ExternalSensors(locator: CommandLocator(home: dir.path, overrides: ["code": [fake.path]]), home: dir.path)
        // Never the real cleanup in a test: it scans every process of the machine.
        nonisolated(unsafe) var cleaned = 0
        sensors.cleanUpCodeStatus = { _ in cleaned += 1 }
        let first = sensors.vscode(main: (pid: 4242, start: 1))
        #expect(first.status.status == .error && first.value == nil)
        #expect(cleaned == 1)
        let second = sensors.vscode(main: (pid: 4242, start: 1))
        #expect(second.status.status == .unavailable && second.status.tookMs == 0, "skipped while the same instance runs")
        try "#!/bin/sh\necho ok\n".write(to: fake, atomically: true, encoding: .utf8)
        #expect(sensors.vscode(main: (pid: 5555, start: 2)).status.status == .ok, "a restarted VS Code is asked again")
    }

    // QA 1: windows are still known without `code --status`.
    @Test func windowsFromExtensionHostsWithoutCodeStatus() {
        func p(_ pid: Int32, _ exe: String, _ args: [String]) -> RawProcess { var r = RawProcess(pid: pid); r.exePath = exe; r.args = args; return r }
        let helper = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        let procs: [Int32: RawProcess] = [
            300: p(300, helper, [helper, "--type=utility", "--inspect-port=0"]),
            200: p(200, helper, [helper, "--type=utility", "--inspect-port=0"]),
            400: p(400, helper, [helper, "/x/tsserver.js"]),
        ]
        let s = CodeStatusParser.fallback(procs)
        #expect(s?.windows.keys.sorted() == [1, 2])
        #expect(s?.windows[1]?.extensionHostPid == 200)
        #expect(s?.roles[300] == "extension-host" && s?.roles[400] == nil)
    }

    // Review 2: the cleanup only touches what a timed-out call caused. Signals go to real processes this test spawned;
    // what they look like (path, args) is injected, since copies of system binaries are killed by macOS.
    @Test func cleanupStopsOnlyCodeStatusStartedAfterTheCall() throws {
        let before = try Child("/bin/sleep", ["30"])
        usleep(1_200_000)
        let since = Date()
        let victim = try Child("/bin/sleep", ["30"]), noStatus = try Child("/bin/sleep", ["30"]), elsewhere = try Child("/bin/sleep", ["30"])
        usleep(200_000)
        let vscode = "/Applications/Visual Studio Code.app/Contents/MacOS/Code"
        let looks: [Int32: (String, [String])] = [before.pid: (vscode, [vscode, "--status"]), victim.pid: (vscode, [vscode, "--status"]),
                                                  noStatus.pid: (vscode, [vscode, "--other"]), elsewhere.pid: ("/Applications/X.app/Contents/MacOS/Code", ["x", "--status"])]
        let read: (Int32) -> RawProcess = { pid in
            var p = ProcessReader.read(pid)
            if let (exe, args) = looks[pid] { p.exePath = exe; p.args = args }
            return p
        }
        let tmp = dir.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let fresh = tmp.appendingPathComponent("code-stdout-new"), old = tmp.appendingPathComponent("code-stdout-old")
        try Data().write(to: fresh); try Data().write(to: old)
        try FileManager.default.setAttributes([.modificationDate: since.addingTimeInterval(-3600)], ofItemAtPath: old.path)

        let killed = ExternalSensors.cleanUpCodeStatus(since: since, pids: Array(looks.keys), tmp: tmp, read: read)
        #expect(killed == [victim.pid])
        victim.process.waitUntilExit()
        #expect(kill(before.pid, 0) == 0 && kill(noStatus.pid, 0) == 0 && kill(elsewhere.pid, 0) == 0)
        #expect(!FileManager.default.fileExists(atPath: fresh.path) && FileManager.default.fileExists(atPath: old.path))
    }

    // Review 1: containers stay in the snapshot even when many larger items exist.
    @Test func containersSurviveTheSizeCap() {
        var procs: [Int32: RawProcess] = [:]
        for i in 0..<40 {
            var p = RawProcess(pid: Int32(2000 + i)); p.ppid = 1; p.uid = getuid(); p.exePath = "/Applications/A\(i).app/Contents/MacOS/A"
            p.cwd = "/"; p.footprintBytes = 200_000_000; p.residentBytes = 200_000_000; p.startSec = Int64(Date().timeIntervalSince1970) - 60
            procs[p.pid] = p
        }
        let c = DockerClient.Container(id: "abc123def4567890", name: "mydb", image: "postgres:16", state: "running", publishedPorts: [],
                                       restartCount: 0, restartPolicy: "no", startedAt: Date())
        let s = analyzer.analyze(Scan(system: RawSystem(memTotalBytes: 0, ncpu: 8, pageSize: 16384), processes: procs, launchd: [:], containers: [c]))
        #expect(s.items.contains { $0.id == "ctr:abc123def456" && $0.label == "mydb" })
    }

    // QA 4: an orphan has no owner even when its binary is inside an .app (python3 -m http.server).
    @Test func orphanInsideAnAppHasNoOwner() {
        var p = RawProcess(pid: 3000); p.ppid = 1; p.uid = getuid()
        p.exePath = "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python"
        p.cwd = NSHomeDirectory() + "/hog-test-nonexistent-project"; p.footprintBytes = 30_000_000; p.residentBytes = 30_000_000
        p.startSec = Int64(Date().timeIntervalSince1970) - 7200; p.cpuTimeNs = 1_000_000
        let scan = Scan(system: RawSystem(memTotalBytes: 0, ncpu: 8, pageSize: 16384), processes: [3000: p], launchd: [:],
                        network: .init(listening: [3000: [ListenSocket(addr: "*", port: 8000)]], connections: []))
        let s = analyzer.analyze(scan)
        let item = s.items.first { $0.pids == [3000] }
        #expect(item?.facts["owner.kind"] == .string("none"))
        #expect(item?.facts["catalog.family"] == .string(""), "no catalog match is known, not null")
        #expect(s.findings.first { $0.itemId == item?.id }?.verdict == .mayStop)
        #expect(s.findings.first { $0.itemId == item?.id }?.unmeasured.isEmpty == true)
    }

    // QA 6: the account name is masked outside the home path too.
    @Test func userNameIsMasked() {
        #expect(Privacy.scrubUser("--sockname=/x/watchman/alice-state/sock", user: "alice") == "--sockname=/x/watchman/<user>-state/sock")
        #expect(Privacy.scrubUser("--port 3000", user: "al") == "--port 3000", "too short to mask safely")
    }

    // QA 6: ~/.config/hog/config.json `commands` is read.
    @Test func configOverridesAreLoaded() throws {
        let cfg = dir.appendingPathComponent(".config/hog")
        try FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
        try Data(#"{"commands":{"code":["/opt/vscode/bin/code"]}}"#.utf8).write(to: cfg.appendingPathComponent("config.json"))
        #expect(CommandLocator(home: dir.path).candidates("code").first == "/opt/vscode/bin/code")
        try Data("not json".utf8).write(to: cfg.appendingPathComponent("config.json"))
        #expect(CommandLocator(home: dir.path).overrides.isEmpty, "a broken config is ignored")
    }

    let analyzer: Analyzer = {
        let b = { (k: String) in DataSource(bundledDirectory: DataSource.standard(k).bundledDirectory, localDirectory: nil) }
        return Analyzer(catalog: .load(b("catalog")), rules: .load(b("rules")), explain: .load(b("explain")), lang: .en)
    }()
}
