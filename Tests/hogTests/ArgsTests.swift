import Testing
@testable import hog
import HogCore

@Suite struct ArgsTests {
    @Test func yesRequiresPlan() {
        #expect(throws: UsageError.self) { try Args(["stop", "123", "--yes"], environment: [:]) }
        let a = try? Args(["stop", "--yes", "--plan", "abcd"], environment: [:])
        #expect(a?.yes == true && a?.plan == "abcd" && a?.command == "stop")
    }

    @Test func languageAndFlags() throws {
        let a = try Args(["--json", "--fast", "--lang", "vi"], environment: [:])
        #expect(a.json && a.fast && a.lang == .vi && a.command == "status")
        #expect(try Args([], environment: ["HOG_LANG": "en"]).lang == .en)
        #expect(throws: UsageError.self) { try Args(["--lang", "fr"], environment: [:]) }
        #expect(throws: UsageError.self) { try Args(["--bogus"], environment: [:]) }
    }

    @Test func positionals() throws {
        let a = try Args(["explain", "resident-ratio"], environment: [:])
        #expect(a.command == "explain" && a.positional == ["resident-ratio"])
    }

    @Test func shareOnlyWithExplain() throws {
        let a = try Args(["explain", "proc:1:2", "--share"], environment: [:])
        #expect(a.share && a.command == "explain")
        #expect(throws: UsageError.self) { try Args(["--share"], environment: [:]) }
        #expect(throws: UsageError.self) { try Args(["stop", "1", "--share"], environment: [:]) }
    }

    @Test func shareWithATermIsAUsageError() throws {
        var cli = CLI(try Args(["explain", "age", "--share"], environment: [:]))
        nonisolated(unsafe) var errors: [String] = []
        cli.err = { errors.append($0) }
        cli.out = { _ in }
        #expect(cli.run() == .usage)
        #expect(errors.first?.contains("--share") == true)
    }
}
