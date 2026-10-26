import Foundation
import HogCore

let args = Array(CommandLine.arguments.dropFirst())
let lang: Lang = args.contains("--en") ? .en : .vi
let fast = args.contains("--fast")
let t0 = Date()
let scan = Scanner(fast: fast).scan()
let t1 = Date()
let analyzer = Analyzer.standard(lang: lang)
let t2 = Date()
let snapshot = analyzer.analyze(scan)
let t3 = Date()
if ProcessInfo.processInfo.environment["HOG_TIMING"] == "1" {
    FileHandle.standardError.write(Data(String(format: "scan %.3f · load data %.3f · analyze %.3f\n", t1.timeIntervalSince(t0), t2.timeIntervalSince(t1), t3.timeIntervalSince(t2)).utf8))
    for s in scan.sensors { FileHandle.standardError.write(Data("  \(s.name) \(s.status.rawValue) \(s.tookMs) ms\n".utf8)) }
}
if args.contains("--json") {
    FileHandle.standardOutput.write(try SnapshotJSON.encode(snapshot))
    print()
} else {
    print(snapshot.headline.text)
    for f in snapshot.findings.prefix(12) {
        let item = snapshot.items.first { $0.id == f.itemId }
        print("- [\(f.verdict.rawValue)/\(f.confidence.rawValue)] \(item?.label ?? f.itemId): \(f.reason)")
    }
    print(String(format: "(%.2f s)", Date().timeIntervalSince(t0)))
}
