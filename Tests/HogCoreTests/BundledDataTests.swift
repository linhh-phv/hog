import Foundation
import Testing
@testable import HogCore

/// The data shipped with hog must load cleanly, in both languages.
@Suite struct BundledDataTests {
    let catalog = Catalog.load(DataSource(bundledDirectory: Bundle.module.resourceURL.flatMap { _ in DataSource.standard("catalog").bundledDirectory }, localDirectory: nil))
    let rules = RuleSet.load(DataSource(bundledDirectory: DataSource.standard("rules").bundledDirectory, localDirectory: nil))
    let explain = Explanations.load(DataSource(bundledDirectory: DataSource.standard("explain").bundledDirectory, localDirectory: nil))

    @Test func catalogLoadsWithoutWarnings() {
        #expect(catalog.warnings.isEmpty, "\(catalog.warnings)")
        #expect(catalog.entries.count == 23)
        #expect(catalog.entries.values.filter { $0.detachedByDesign == true }.map(\.id).sorted() == ["gradle-daemon", "screen", "tmux-server"])
    }

    @Test func rulesLoadWithoutWarnings() {
        #expect(rules.warnings.isEmpty, "\(rules.warnings)")
        let ids = Set(rules.rules.map(\.id))
        for id in ["protect-self", "protect-foreign", "protect-busy-owner", "protect-busy-session", "orphan-quiet",
                   "dormant-large", "claude-session-abandoned", "container-crash-loop", "container-restart-high",
                   "container-no-clients", "watchman-no-subscribers", "launchd-restarts", "duplicate-language-server",
                   "memory-heavy"] {
            #expect(ids.contains(id), "missing rule \(id)")
        }
        #expect(rules.rules.filter { $0.level == .hard }.map(\.id).sorted() == ["protect-foreign", "protect-self"])
    }

    @Test func reasonPlaceholdersAreRealFacts() throws {
        let placeholder = try Regex(#"\{([a-z_.]+)\}"#)
        for r in rules.rules {
            for text in [r.reason.vi, r.reason.en].compactMap({ $0 }) {
                for m in text.matches(of: placeholder) {
                    let name = String(text[m.range].dropFirst().dropLast())
                    #expect(FactNames.all.union(FactNames.derived).contains(name), "rule \(r.id) uses unknown placeholder {\(name)}")
                }
            }
        }
    }

    @Test func explanationsLoadAndHeadlinesReferenceRealGlossary() throws {
        #expect(explain.warnings.isEmpty, "\(explain.warnings)")
        #expect(explain.glossary.count == 28)
        let h = try #require(explain.headlines)
        for t in [h.okClean, h.okSuggest, h.warn, h.critical, h.unknown, h.hot, h.busy] {
            #expect(t.text.missingLanguages.isEmpty)
            for id in t.glossaryIds { #expect(explain.glossary[id] != nil, "headline uses unknown glossary id \(id)") }
        }
    }

    @Test func everyCatalogEntryHasBothLanguages() {
        for e in catalog.entries.values {
            #expect((e.name.missingLanguages + e.summary.missingLanguages + e.stopEffect.missingLanguages).isEmpty, "\(e.id)")
        }
    }

    @Test func realVSCodeHelpersAreRecognized() {
        // Argument shapes measured on a real machine (2026-10-26), with fake paths.
        #expect(catalog.match(MatchSubject(exeName: "Code Helper (Plugin)", args: "Code Helper (Plugin) --max-old-space-size=3072 /x/typescript/lib/tsserver.js --useNodeIpc")) == "tsserver")
        #expect(catalog.match(MatchSubject(exeName: "Code Helper (Plugin)", args: "Code Helper (Plugin) /x/typingsInstaller.js --typesMapLocation /x/typesMap.json")) == "typings-installer")
        #expect(catalog.match(MatchSubject(exeName: "Code Helper (Plugin)", args: "Code Helper (Plugin) --type=utility --utility-sub-type=node.mojom.NodeService --inspect-port=0")) == "vscode-extension-host")
        #expect(catalog.match(MatchSubject(exeName: "Code Helper", args: "Code Helper --type=utility --utility-sub-type=node.mojom.NodeService", vscodeRole: "file-watcher")) == "vscode-file-watcher")
        #expect(catalog.match(MatchSubject(exeName: "Code Helper", args: "Code Helper --type=gpu-process")) == "vscode-gpu")
        #expect(catalog.match(MatchSubject(exeName: "claude", exePath: "/Users/me/.vscode/extensions/anthropic.claude-code-2.1.300-darwin-arm64/resources/native-binary/claude")) == "claude-code-session")
        #expect(catalog.match(MatchSubject(exeName: "watchman", exePath: "/opt/homebrew/bin/watchman")) == "watchman")
        #expect(catalog.match(MatchSubject(containerImage: "mongo:7")) == "docker-container")
        #expect(catalog.match(MatchSubject(exeName: "node", args: "node server.js")) == nil)
    }
}

@Suite struct ProtectForeignTests {
    let rules = RuleSet.load(DataSource(bundledDirectory: DataSource.standard("rules").bundledDirectory, localDirectory: nil)).rules

    func level(_ facts: [String: FactValue]) -> ProtectionLevel? {
        var f: [String: FactValue] = ["own": .bool(true), "exe.macos": .bool(false), "exe.system": .bool(false),
                                      "exe.name": .string("x"), "launchd.label": .null, "launchd.job": .bool(false),
                                      "self.ancestor": .bool(false), "self.window": .bool(false),
                                      "owner.kind": .string("none"), "owner.busy": .bool(false)]
        for (k, v) in facts { f[k] = v }
        return RuleEngine.run(rules, kind: .process, facts: f).protection?.level
    }

    @Test func usersOwnCommandsFromUsrBinAreNotHardProtected() {
        // e.g. a forgotten `ssh -N -L` tunnel or `/bin/sleep` started from a shell
        #expect(level(["exe.system": .bool(true), "exe.name": .string("ssh")]) == nil)
    }

    @Test func macOSItselfAndLaunchdManagedSystemToolsAreProtected() {
        #expect(level(["exe.macos": .bool(true), "exe.name": .string("Dock")]) == .hard)
        #expect(level(["exe.system": .bool(true), "launchd.job": .bool(true), "launchd.label": .string("com.apple.cfprefsd.xpc.agent")]) == .hard)
        #expect(level(["exe.system": .bool(true), "launchd.job": .null]) == .hard, "launchd sensor failed → unknown → protect")
        #expect(level(["self.window": .bool(true)]) == .hard, "the VS Code window running hog")
        #expect(level(["own": .bool(false)]) == .hard)
        #expect(level(["own": .null]) == .hard, "unknown owner → protect")
    }
}
