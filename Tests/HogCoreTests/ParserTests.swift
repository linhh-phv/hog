import Foundation
import Testing
@testable import HogCore

@Suite struct LsofParserTests {
    @Test func listeningSocketsPerPid() throws {
        let l = LsofParser.listening(try Fixtures.text("lsof/listen.txt"))
        #expect(l[501] == [ListenSocket(addr: "*", port: 3000)], "duplicate fds collapse into one socket")
        #expect(l[777] == [ListenSocket(addr: "127.0.0.1", port: 5432), ListenSocket(addr: "::1", port: 5432)])
        #expect(l[888]?.first?.port == 8081)
    }

    @Test func establishedConnections() throws {
        let c = LsofParser.established(try Fixtures.text("lsof/established.txt"))
        #expect(c.count == 4)
        #expect(c.filter { $0.pid == 501 && $0.localPort == 3000 }.count == 2)
        #expect(c.contains { $0.pid == 900 && $0.remotePort == 3000 })
        #expect(c.contains { $0.localPort == 54895 && $0.remotePort == 64678 }, "IPv6 with zone and brackets")
    }
}

@Suite struct LaunchctlParserTests {
    @Test func listMapsRunningPidsToLabels() throws {
        let jobs = LaunchctlParser.list(try Fixtures.text("launchctl/list.txt"))
        #expect(jobs == [4100: "com.github.facebook.watchman", 4200: "application.com.example.Editor.123"])
    }

    @Test(arguments: [
        ("print-crashed-true.txt", false as Bool?),          // KeepAlive {Crashed = true}: only after a crash
        ("print-crashed-false.txt", true),                   // Crashed = false: restarts on normal exit
        ("print-successful-exit-false.txt", true),           // SuccessfulExit = false: SIGTERM is restarted
        ("print-plain.txt", false),                          // no KeepAlive at all
        ("print-submitted-keepalive.txt", true),             // submitted job without plist, KeepAlive = true
        ("print-path-state.txt", nil),                       // not classified → unknown
    ])
    func restartsAfterStop(file: String, expected: Bool?) throws {
        #expect(LaunchctlParser.restartsAfterStop(printOutput: try Fixtures.text("launchctl/\(file)")) == expected)
    }

    @Test func inferredProgramIsNotKeepAlive() {
        // "properties = runatload | inferred program" must be split on "|", not substring-matched.
        let text = "x = {\n\tproperties = runatload | inferred program\n}\n"
        #expect(LaunchctlParser.restartsAfterStop(printOutput: text) == false)
    }
}

@Suite struct CodeStatusParserTests {
    @Test func windowsByIndexIgnoringGarbageMemory() throws {
        let w = CodeStatusParser.windows(try Fixtures.text("code-status/status.txt"))
        #expect(w.keys.sorted() == [2, 7])
        #expect(w[2]?.title == "index.ts — web-app (Workspace)")
        #expect(w[2]?.windowPid == 1100)
        #expect(w[2]?.extensionHostPid == 1200)
        #expect(w[2]?.fileWatcherPid == 1202)
        #expect(w[7]?.extensionHostPid == 1301)
    }
}

@Suite struct ClaudeSessionParserTests {
    let start = Date(timeIntervalSince1970: 1_792_984_800)

    @Test func parsesKnownKeysAndIgnoresUnknown() throws {
        let s = try #require(ClaudeSessionParser.parse(Data(contentsOf: Fixtures.url("claude/idle.json"))))
        #expect(s.pid == 1201)
        #expect(s.busy == false)
        #expect(s.cwd == "/Users/me/work/web-app")
        #expect(s.procStart == start, "procStart is a UTC lstart string")
    }

    @Test func procStartIsUTCEvenUnderAnotherTimeZone() throws {
        // CI runners are usually UTC; force a non-UTC zone so a local-time parse would fail.
        let saved = getenv("TZ").map { String(cString: $0) }
        setenv("TZ", "Asia/Ho_Chi_Minh", 1); tzset()
        defer { if let saved { setenv("TZ", saved, 1) } else { unsetenv("TZ") }; tzset() }
        #expect(TimeZone.current.secondsFromGMT() != 0)
        #expect(ClaudeSessionParser.parseLstartUTC("Mon Oct 26 03:20:00 2026") == start)
        #expect(ClaudeSessionParser.parseLstartUTC("Thu Oct  1 08:31:17 2026") != nil, "space-padded day")
    }

    @Test func matchingUsesProcStartThenStartedAt() throws {
        let idle = try #require(ClaudeSessionParser.parse(Data(contentsOf: Fixtures.url("claude/idle.json"))))
        #expect(ClaudeSessionParser.matches(idle, processStart: start))
        #expect(ClaudeSessionParser.matches(idle, processStart: start.addingTimeInterval(0.9)))
        #expect(!ClaudeSessionParser.matches(idle, processStart: start.addingTimeInterval(30)), "stale file / reused PID")
        #expect(!ClaudeSessionParser.matches(idle, processStart: nil))

        let busy = try #require(ClaudeSessionParser.parse(Data(contentsOf: Fixtures.url("claude/busy-no-procstart.json"))))
        #expect(busy.busy == true)
        #expect(busy.procStart == nil)
        #expect(ClaudeSessionParser.matches(busy, processStart: start.addingTimeInterval(3)), "startedAt within 5 s")
        #expect(!ClaudeSessionParser.matches(busy, processStart: start.addingTimeInterval(10)))
    }

    @Test func garbageIsNotASession() throws {
        #expect(ClaudeSessionParser.parse(try Data(contentsOf: Fixtures.url("claude/garbage.json"))) == nil)
    }
}

@Suite struct WatchmanParserTests {
    @Test func rootsAndSubscriptions() throws {
        #expect(WatchmanParser.roots(try Fixtures.text("watchman/watch-list.json")) == ["/Users/me/work/web-app", "/Users/me/work/api"])
        #expect(WatchmanParser.subscriptionCount(try Fixtures.text("watchman/subscriptions-empty.json")) == 0)
        #expect(WatchmanParser.subscriptionCount(try Fixtures.text("watchman/subscriptions-one.json")) == 1)
        #expect(WatchmanParser.subscriptionCount(try Fixtures.text("watchman/error.json")) == nil, "an error is not 'zero subscribers'")
        #expect(WatchmanParser.subscriptionCount("") == nil)
    }
}

@Suite struct CommandTests {
    @Test func runsAndCapturesOutput() throws {
        let r = try #require(Command.run("/bin/echo", ["hello"]))
        #expect(r.status == 0 && r.stdout == "hello\n" && !r.timedOut)
    }

    @Test func killsOnTimeout() throws {
        let r = try #require(Command.run("/bin/sleep", ["5"], timeout: 0.3))
        #expect(r.timedOut)
        #expect(r.tookMs < 3000)
    }

    @Test func missingExecutableIsNil() {
        #expect(Command.run("/nonexistent/hog-test", []) == nil)
    }

    @Test func locatorUsesAbsolutePathsAndOverrides() {
        let loc = CommandLocator(home: "/Users/me", overrides: ["sleep": ["/nonexistent/sleep"]])
        #expect(loc.candidates("sleep").first == "/nonexistent/sleep")
        #expect(loc.candidates("sleep").allSatisfy { $0.hasPrefix("/") })
        #expect(loc.find("sleep") == "/bin/sleep")
        #expect(loc.candidates("code").contains("/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"))
        #expect(loc.find("hog-command-that-does-not-exist") == nil)
    }
}
