import Foundation
import Testing
@testable import HogCore

/// Task data-override-warnings: an override file that cannot be read is reported, not silently skipped, and an
/// oversized file or key table does not slow hog down.
@Suite struct DataSourceTests {
    let prov = #""provenance": {"added": "2026-11-04", "source": "measured", "verified": true}"#

    /// A fresh temporary directory, removed (permissions restored first) by `cleanUp`.
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hog-data-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanUp(_ dir: URL) {
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for n in names { chmod(dir.appendingPathComponent(n).path, 0o700) }
        }
        try? FileManager.default.removeItem(at: dir)
    }

    /// One of each kind of unreadable `*.json`, next to a good file.
    func unreadableFiles(in dir: URL, good: String) throws {
        try good.write(to: dir.appendingPathComponent("a-ok.json"), atomically: true, encoding: .utf8)
        let noAccess = dir.appendingPathComponent("b-mode000.json")
        try good.write(to: noAccess, atomically: true, encoding: .utf8)
        #expect(chmod(noAccess.path, 0) == 0)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("c-dangling.json").path,
                                                   withDestinationPath: dir.appendingPathComponent("missing").path)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("d-dir.json"), withIntermediateDirectories: false)
        let big = Data(repeating: UInt8(ascii: " "), count: DataSource.maxFileBytes + 1)
        try big.write(to: dir.appendingPathComponent("f-big.json"))
    }

    let expected = [
        "local:b-mode000.json": "Permission denied",
        "local:c-dangling.json": "broken symbolic link",
        "local:d-dir.json": "is a directory",
        "local:f-big.json": "larger than 1 MiB",
    ]

    func check(_ warnings: [DataWarning]) {
        let mine = warnings.filter { $0.file.hasPrefix("local:") }
        #expect(mine.count == expected.count, "\(mine)")
        for (file, reason) in expected {
            let w = mine.first { $0.file == file }
            #expect(w?.message.contains(reason) == true, "\(file): \(String(describing: w))")
        }
    }

    @Test func unreadableFilesAreReportedForEveryKind() throws {
        let dir = try tempDir()
        defer { cleanUp(dir) }
        // The bundled data of each kind loads without warnings, so every warning here comes from the override folder.
        let catalogDir = dir.appendingPathComponent("catalog.d")
        try FileManager.default.createDirectory(at: catalogDir, withIntermediateDirectories: false)
        let bundledEntry = try String(contentsOf: try #require(DataSource.standard("catalog").bundledDirectory)
            .appendingPathComponent("adb-server.json"), encoding: .utf8)
        try unreadableFiles(in: catalogDir, good: bundledEntry)
        let catalog = Catalog.load(DataSource(bundledDirectory: DataSource.standard("catalog").bundledDirectory, localDirectory: catalogDir))
        check(catalog.warnings)

        let smcDir = dir.appendingPathComponent("smc.d")
        try FileManager.default.createDirectory(at: smcDir, withIntermediateDirectories: false)
        try unreadableFiles(in: smcDir, good: #"{"id": "x", "chips": ["X"], "cpu_keys": ["Tp01"], "gpu_keys": [], \#(prov)}"#)
        let smc = SMCKeyTable.load(DataSource(bundledDirectory: DataSource.standard("smc").bundledDirectory, localDirectory: smcDir))
        check(smc.warnings)
        #expect(smc.entry(chip: "X")?.cpuKeys == ["Tp01"], "the readable file still loads")

        let rulesDir = dir.appendingPathComponent("rules.d")
        try FileManager.default.createDirectory(at: rulesDir, withIntermediateDirectories: false)
        try unreadableFiles(in: rulesDir, good: "{}")
        let rules = RuleSet.load(DataSource(bundledDirectory: DataSource.standard("rules").bundledDirectory, localDirectory: rulesDir))
        #expect(rules.warnings.first { $0.file == "local:a-ok.json" } != nil, "{} is not a rule")
        check(rules.warnings.filter { $0.file != "local:a-ok.json" })

        let explainDir = dir.appendingPathComponent("explain.d")
        let glossaryDir = explainDir.appendingPathComponent("glossary")
        try FileManager.default.createDirectory(at: glossaryDir, withIntermediateDirectories: true)
        try unreadableFiles(in: glossaryDir, good: "{}")
        let explain = Explanations.load(DataSource(bundledDirectory: DataSource.standard("explain").bundledDirectory, localDirectory: explainDir))
        check(explain.warnings.filter { $0.file != "local:a-ok.json" })
        #expect(explain.headlines != nil)
    }

    /// The only test with FIFOs. Reads on another thread: a blocking `open` makes it fail after 5 s instead of hanging
    /// the run (`.timeLimit` cannot interrupt a blocked system call).
    @Test func fifoDoesNotBlock() throws {
        let dir = try tempDir()
        defer { cleanUp(dir) }
        #expect(mkfifo(dir.appendingPathComponent("x.json").path, 0o600) == 0)
        #expect(mkfifo(dir.appendingPathComponent("headline.json").path, 0o600) == 0)
        final class Box: @unchecked Sendable { var warnings: [DataWarning]?; var count = -1; var explain: [DataWarning]? }
        let box = Box(), done = DispatchSemaphore(value: 0), source = DataSource(bundledDirectory: nil, localDirectory: dir)
        Thread.detachNewThread {
            let (files, warnings) = source.files()
            (box.count, box.warnings) = (files.count, warnings)
            box.explain = Explanations.load(DataSource(bundledDirectory: DataSource.standard("explain").bundledDirectory, localDirectory: dir)).warnings
            done.signal()
        }
        try #require(done.wait(timeout: .now() + 5) == .success, "reading a FIFO blocked")
        #expect(box.count == 0)
        #expect(box.warnings?.map(\.description) == ["local:headline.json: skipped: not a regular file", "local:x.json: skipped: not a regular file"])
        #expect(box.explain?.map(\.description) == ["local:headline.json: skipped: not a regular file"])
    }

    @Test func unreadableHeadlineOverrideIsReported() throws {
        let dir = try tempDir()
        defer { cleanUp(dir) }
        let headline = dir.appendingPathComponent("headline.json")
        let bundled = DataSource.standard("explain").bundledDirectory
        let cases: [(String, () throws -> Void)] = [
            ("is a directory, not a file", { try FileManager.default.createDirectory(at: headline, withIntermediateDirectories: false) }),
            ("cannot open (Permission denied)", { try "{}".write(to: headline, atomically: true, encoding: .utf8); chmod(headline.path, 0) }),
            ("broken symbolic link", { try FileManager.default.createSymbolicLink(atPath: headline.path, withDestinationPath: dir.appendingPathComponent("missing").path) }),
        ]
        for (reason, make) in cases {
            try make()
            let explain = Explanations.load(DataSource(bundledDirectory: bundled, localDirectory: dir))
            #expect(explain.warnings.map(\.description) == ["local:headline.json: skipped: \(reason)"])
            #expect(explain.headlines != nil, "falls back to the bundled headlines")
            chmod(headline.path, 0o600)
            try FileManager.default.removeItem(at: headline)
        }
    }

    @Test func unlistableFoldersAreReported() throws {
        let dir = try tempDir()
        defer { cleanUp(dir) }
        let catalog = DataSource.standard("catalog").bundledDirectory
        let noAccess = dir.appendingPathComponent("a.d")
        try FileManager.default.createDirectory(at: noAccess, withIntermediateDirectories: false)
        try "{}".write(to: noAccess.appendingPathComponent("x.json"), atomically: true, encoding: .utf8)
        #expect(chmod(noAccess.path, 0) == 0)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("b.d").path,
                                                   withDestinationPath: dir.appendingPathComponent("missing").path)
        try "{}".write(to: dir.appendingPathComponent("c.d"), atomically: true, encoding: .utf8)
        for (name, reason) in [("a.d", "cannot list (Permission denied)"), ("b.d", "broken symbolic link"), ("c.d", "not a directory")] {
            let c = Catalog.load(DataSource(bundledDirectory: catalog, localDirectory: dir.appendingPathComponent(name)))
            #expect(c.warnings.map(\.description) == ["local:\(name): skipped: \(reason)"])
            #expect(!c.entries.isEmpty, "the bundled entries still load")
        }

        // explain.d holds a folder and a file: one warning naming explain.d, whatever is wrong with it.
        let explainDir = dir.appendingPathComponent("explain.d")
        let explainCases: [(String, () throws -> Void)] = [
            ("cannot list (Permission denied)", {
                try FileManager.default.createDirectory(at: explainDir.appendingPathComponent("glossary"), withIntermediateDirectories: true)
                chmod(explainDir.path, 0)
            }),
            ("broken symbolic link", { try FileManager.default.createSymbolicLink(atPath: explainDir.path, withDestinationPath: dir.appendingPathComponent("missing").path) }),
            ("not a directory", { try "{}".write(to: explainDir, atomically: true, encoding: .utf8) }),
        ]
        for (reason, make) in explainCases {
            try make()
            let explain = Explanations.load(DataSource(bundledDirectory: DataSource.standard("explain").bundledDirectory, localDirectory: explainDir))
            #expect(explain.warnings.map(\.description) == ["local:explain.d: skipped: \(reason)"])
            #expect(explain.headlines != nil && !explain.glossary.isEmpty, "the bundled explanations still load")
            chmod(explainDir.path, 0o700)
            try FileManager.default.removeItem(at: explainDir)
        }
    }

    @Test func sizeLimitIsInclusive() throws {
        let dir = try tempDir()
        defer { cleanUp(dir) }
        let body = #"{"id": "x", "chips": ["X"], "cpu_keys": ["Tp01"], "gpu_keys": [], \#(prov)}"#
        for (name, size) in [("a.json", DataSource.maxFileBytes), ("b.json", DataSource.maxFileBytes + 1)] {
            var data = Data(body.utf8)
            data.append(Data(repeating: UInt8(ascii: " "), count: size - data.count))
            try data.write(to: dir.appendingPathComponent(name))
        }
        let (files, warnings) = DataSource(bundledDirectory: nil, localDirectory: dir).files()
        #expect(files.map(\.name) == ["local:a.json"], "exactly 1 MiB is read")
        #expect(warnings.map(\.description) == ["local:b.json: skipped: larger than 1 MiB (1048577 bytes)"])
    }

    @Test func missingFilesAreNotWarnings() throws {
        let dir = try tempDir()
        defer { cleanUp(dir) }
        #expect(try DataSource.read(dir.appendingPathComponent("absent.json")) == nil)
        let explain = Explanations.load(DataSource(bundledDirectory: DataSource.standard("explain").bundledDirectory, localDirectory: dir))
        #expect(explain.warnings.isEmpty, "no local headline.json is normal")
    }

    @Test func symlinkToAFileIsRead() throws {
        let dir = try tempDir()
        defer { cleanUp(dir) }
        let target = dir.appendingPathComponent("target")
        try #"{"id": "x", "chips": ["X"], "cpu_keys": ["Tp01"], "gpu_keys": [], \#(prov)}"#.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("x.json").path, withDestinationPath: target.path)
        let t = SMCKeyTable.load(DataSource(bundledDirectory: nil, localDirectory: dir))
        #expect(t.warnings.isEmpty)
        #expect(t.entry(chip: "X")?.cpuKeys == ["Tp01"])
    }

    @Test func smcKeyListsAreCapped() throws {
        let dir = try tempDir()
        defer { cleanUp(dir) }
        let keys = (0..<20_000).map { String(format: "\"T%03X\"", $0 % 4096) }.joined(separator: ",")
        try #"{"id": "x", "chips": ["X"], "cpu_keys": [\#(keys)], "gpu_keys": [\#(keys)], \#(prov)}"#
            .write(to: dir.appendingPathComponent("x.json"), atomically: true, encoding: .utf8)
        let t = SMCKeyTable.load(DataSource(bundledDirectory: nil, localDirectory: dir))
        let e = try #require(t.entry(chip: "X"))
        #expect(e.cpuKeys.count == SMCKeyEntry.maxKeys && e.gpuKeys.count == SMCKeyEntry.maxKeys)
        #expect(e.cpuKeys.first == "T000", "the first keys are kept")
        #expect(t.warnings.map(\.description) == [
            "local:x.json: cpu_keys has 20000 keys, only the first 64 are read",
            "local:x.json: gpu_keys has 20000 keys, only the first 64 are read",
        ])

        var reads = 0
        _ = HeatReader.heat(chip: "X", table: t) { _ in reads += 1; return nil }
        #expect(reads <= 2 * SMCKeyEntry.maxKeys + 8, "fan keys aside, at most the capped keys are read")
    }

    @Test func smcCapIsExact() throws {
        let dir = try tempDir()
        defer { cleanUp(dir) }
        func keys(_ n: Int) -> String { (0..<n).map { String(format: "\"T%03X\"", $0) }.joined(separator: ",") }
        try #"{"id": "x", "chips": ["X"], "cpu_keys": [\#(keys(64))], "gpu_keys": [\#(keys(65))], \#(prov)}"#
            .write(to: dir.appendingPathComponent("x.json"), atomically: true, encoding: .utf8)
        let t = SMCKeyTable.load(DataSource(bundledDirectory: nil, localDirectory: dir))
        #expect(t.entry(chip: "X")?.cpuKeys.count == 64 && t.entry(chip: "X")?.gpuKeys.count == 64)
        #expect(t.entry(chip: "X")?.gpuKeys.last == "T03F", "the 65th key is the one dropped")
        #expect(t.warnings.map(\.description) == ["local:x.json: gpu_keys has 65 keys, only the first 64 are read"])
    }

    @Test func bundledTablesAreUnderTheCap() {
        let t = SMCKeyTable.load(DataSource(bundledDirectory: DataSource.standard("smc").bundledDirectory, localDirectory: nil))
        #expect(!t.entries.isEmpty && t.warnings.isEmpty)
        #expect(t.entries.allSatisfy { $0.cpuKeys.count <= SMCKeyEntry.maxKeys && $0.gpuKeys.count <= SMCKeyEntry.maxKeys })
    }
}
