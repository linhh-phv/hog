import Foundation
import Testing
@testable import HogCore

@Suite struct SnapshotJSONTests {
    let snapshot = SampleSnapshot.make()

    func jsonObject() throws -> [String: Any] {
        let data = try SnapshotJSON.encode(snapshot)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func matchesGoldenFile() throws {
        let data = try SnapshotJSON.encode(snapshot)
        let text = String(decoding: data, as: UTF8.self) + "\n"
        if ProcessInfo.processInfo.environment["HOG_UPDATE_GOLDEN"] == "1" {
            try text.write(to: Fixtures.sourceURL("golden/snapshot.json"), atomically: true, encoding: .utf8)
        }
        let golden = try Fixtures.text("golden/snapshot.json")
        #expect(text == golden, "snapshot JSON drifted from the contract; rerun with HOG_UPDATE_GOLDEN=1 only if intended")
    }

    @Test func roundTrips() throws {
        let decoded = try SnapshotJSON.decode(SnapshotJSON.encode(snapshot))
        #expect(decoded == snapshot)
    }

    @Test func unmeasuredValuesAreExplicitNull() throws {
        let obj = try jsonObject()
        let memory = try #require(obj["memory"] as? [String: Any])
        #expect(memory.keys.contains("system_detail"))
        #expect(memory["system_detail"] is NSNull)
        let process = try #require((obj["processes"] as? [[String: Any]])?.first)
        #expect(process["compressed_bytes"] is NSNull, "unmeasured must be null, not 0 and not missing")
        #expect(process["args"] is NSNull)
    }

    @Test func factKeysAreKeptVerbatim() throws {
        let obj = try jsonObject()
        let item = try #require((obj["items"] as? [[String: Any]])?.first)
        let facts = try #require(item["facts"] as? [String: Any])
        #expect(facts.keys.contains("age_s"))
        #expect(facts.keys.contains("cpu.avg_pct"))
        #expect(facts.keys.contains("launchd.restarts_after_stop"))
    }

    @Test func keysAreSnakeCaseAndDatesAreUTC() throws {
        let text = String(decoding: try SnapshotJSON.encode(snapshot), as: UTF8.self)
        #expect(text.contains("\"taken_at\" : \"2026-10-26T03:44:55Z\""))
        #expect(text.contains("\"mem_total_bytes\" : 17179869184"))
        #expect(!text.contains("takenAt"))
    }

    @Test func containsNoAbsoluteHomeOrEnvironment() throws {
        let text = String(decoding: try SnapshotJSON.encode(snapshot), as: UTF8.self)
        #expect(!text.contains(NSHomeDirectory()))
        #expect(!text.contains("\"env\""))
    }
}

@Suite struct PrivacyTests {
    let home = "/Users/me"

    @Test func replacesHomePrefix() {
        #expect(Privacy.scrubPath("/Users/me/work/web-app", home: home) == "~/work/web-app")
        #expect(Privacy.scrubPath("/Users/me", home: home) == "~")
        #expect(Privacy.scrubPath("/Users/meow/x", home: home) == "/Users/meow/x")
        #expect(Privacy.scrubPath("/opt/homebrew/bin/watchman", home: home) == "/opt/homebrew/bin/watchman")
    }

    @Test func masksSecretFlags() {
        let s = Privacy.scrubArgs(["node", "server.js", "--api-key=abc123", "--token", "xyz", "--port", "3000",
                                   "--dir=/Users/me/work/web-app"], home: home)
        #expect(s == "node server.js --api-key=*** --token *** --port 3000 --dir=~/work/web-app")
        #expect(!s.contains("abc123"))
        #expect(!s.contains("xyz"))
    }

    @Test func truncatesLongArgs() {
        let s = Privacy.scrubArgs(Array(repeating: "aaaaaaaaaa", count: 50), home: home)
        #expect(s.count == Privacy.maxArgsLength)
        #expect(s.hasSuffix("…"))
    }
}
