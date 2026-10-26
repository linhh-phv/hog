import Foundation
import Testing
@testable import HogCore

/// `hog ports` must list what lps 0.1.0 lists (design 10, item 9): PID, port, command and project. CWD differs on
/// purpose (home → ~) and so does `[orphan]` (new definition, design 3.4).
@Suite struct PortsParityTests {
    static var legacyScript: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("legacy/lps")
    }

    func columns(_ text: String) -> Set<[String]> {
        Set(text.split(separator: "\n").dropFirst(2).compactMap { raw -> [String]? in
            let line = Array(raw)
            guard line.count > 50 else { return nil }
            func col(_ a: Int, _ b: Int) -> String { String(line[a..<min(b, line.count)]).trimmingCharacters(in: .whitespaces) }
            return [col(0, 7), col(8, 15), col(16, 48), col(49, 71)]
        })
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: legacyScript.path)))
    func matchesLegacyLpsOnThisMachine() throws {
        let legacy = try #require(Command.run("/bin/bash", [Self.legacyScript.path], timeout: 30))
        let expected = columns(legacy.stdout)
        let rows = PortsReport.rows(Scanner(fast: true).scan())
        func trunc(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }
        let actual = Set(rows.map { [String($0.pid), String($0.port), trunc($0.command, 32), trunc($0.project, 22)] })
        // Ports can open/close between the two runs: compare only PIDs both saw.
        let pids = Set(expected.map { $0[0] }).intersection(actual.map { $0[0] })
        #expect(!pids.isEmpty || expected.isEmpty)
        #expect(expected.filter { pids.contains($0[0]) } == actual.filter { pids.contains($0[0]) })
    }
}
