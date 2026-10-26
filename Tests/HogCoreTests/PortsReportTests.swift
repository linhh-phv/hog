import Foundation
import Testing
@testable import HogCore

/// `hog ports` keeps lps 0.1.0's project naming. Parity with the bash lps was verified on a real machine on
/// 2026-10-26 (15/15 rows: PID, port, command, project) before legacy/ was removed; these tests pin its rules.
@Suite final class PortsReportTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hog-ports-\(UUID().uuidString)").path

    init() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/web/src", withIntermediateDirectories: true)
        try Data(#"{"name":"web-app"}"#.utf8).write(to: URL(fileURLWithPath: root + "/web/package.json"))
        try fm.createDirectory(atPath: root + "/api/.git", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/api/cmd", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/plain/dir", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/noname", withIntermediateDirectories: true)
        try Data(#"{"version":"1.0.0"}"#.utf8).write(to: URL(fileURLWithPath: root + "/noname/package.json"))
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    @Test func projectNamingFollowsLps() {
        #expect(PortsReport.projectName(cwd: root + "/web/src") == "web-app", "package.json name, walking up")
        #expect(PortsReport.projectName(cwd: root + "/api/cmd") == "api", "folder that holds .git")
        #expect(PortsReport.projectName(cwd: root + "/plain/dir") == "dir", "else the cwd's basename")
        #expect(PortsReport.projectName(cwd: root + "/noname") == "noname", "package.json without a name is skipped")
    }

    @Test func systemLocationsAreSystem() {
        for cwd in ["/", "", "/System/Library/x", "/usr/libexec", "/Applications/X.app", "/Users/me/Library/Containers/x/Data"] {
            #expect(PortsReport.projectName(cwd: cwd) == "(system)", "\(cwd)")
        }
    }

    @Test func rowsPerPortSortedLikeLps() throws {
        var p1 = RawProcess(pid: 10); p1.ppid = 5; p1.exePath = "/opt/homebrew/bin/node"; p1.cwd = root + "/web"
        var p2 = RawProcess(pid: 11); p2.ppid = 1; p2.exePath = "/usr/libexec/rapportd"; p2.cwd = "/"
        let scan = Scan(home: root, system: RawSystem(memTotalBytes: 0, ncpu: 1, pageSize: 16384), processes: [10: p1, 11: p2],
                        launchd: [11: "com.apple.rapportd"],
                        network: .init(listening: [10: [ListenSocket(addr: "*", port: 3000), ListenSocket(addr: "::1", port: 3000)],
                                                   11: [ListenSocket(addr: "*", port: 49152)]], connections: []))
        let rows = PortsReport.rows(scan)
        #expect(rows.map(\.port) == [3000, 49152], "one row per port, IPv4/IPv6 duplicates collapse")
        #expect(rows[0].project == "web-app" && rows[0].command == "node" && rows[0].cwd == "~/web")
        #expect(rows[1].project == "(system)" && rows[1].cwd == "—" && !rows[1].orphan)
    }
}
