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
        let sensors = ExternalSensors(locator: CommandLocator(home: dir.path, overrides: ["code": [fake.path]]), home: dir.path)
        let first = sensors.vscode(main: (pid: 4242, start: 1))
        #expect(first.status.status == .error && first.value == nil)
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
}
