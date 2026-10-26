import Foundation

/// `hog.share/1`: what a person copies to ask Claude (outside hog) about one item (phase-2 design, section 3).
///
/// hog itself never sends anything anywhere: this is text for the clipboard or the terminal, and it is built to be safe to
/// paste: no item or owner labels (they can carry project names and window titles), no cwd, project, user name, home or
/// directories, secrets masked.
public struct ShareInfo: Encodable, Sendable, Equatable {
    public struct ItemPart: Encodable, Sendable, Equatable {
        public var kind: ItemKind
        public var exe: String?
        public var args: String?
        public var image: String?
        public var catalogId: String?

        enum CodingKeys: String, CodingKey { case kind, exe, args, image, catalogId = "catalog_id" }
    }

    public var schema = "hog.share/1"
    public var hogVersion = Hog.version
    public var item: ItemPart
    public var facts: [String: FactValue]
    public var ownerKind: String?
    public var parents: [String]
    public var listenPorts: [Int]

    enum CodingKeys: String, CodingKey {
        case schema, hogVersion = "hog_version", item, facts, ownerKind = "owner_kind", parents, listenPorts = "listen_ports"
    }

    /// String facts that say what something is without naming anything private.
    static let keptStringFacts: Set<String> = ["owner.kind", "catalog.family"]
    static let maxParents = 4

    public static func make(_ item: Item, scan: Scan) -> ShareInfo {
        var facts: [String: FactValue] = [:]
        for (k, v) in item.facts {
            switch v {
            case .int, .double, .bool: facts[k] = v
            case .string(let s) where keptStringFacts.contains(k) && !s.isEmpty: facts[k] = v
            default: break
            }
        }
        var part = ItemPart(kind: item.kind, catalogId: item.catalogId.value)
        var parents: [String] = []
        var ports: [Int] = []
        if item.kind == .container {
            let id = item.id.hasPrefix("ctr:") ? String(item.id.dropFirst(4)) : item.id
            part.image = scan.containers?.first(where: { $0.id.hasPrefix(id) }).map { lastComponent($0.image) }
        } else if let pid = item.pids.first, let p = scan.processes[pid] {
            part.exe = p.exePath.map(lastComponent)
            part.args = p.args.map { shareArgs($0, home: scan.home) }
            parents = ancestors(of: p, in: scan)
            ports = Array(Set((scan.network?.listening[pid] ?? []).map(\.port))).sorted()
        }
        return ShareInfo(item: part, facts: facts, ownerKind: item.facts["owner.kind"].flatMap {
            if case .string(let s) = $0 { s } else { nil }
        }, parents: parents, listenPorts: ports)
    }

    /// Secrets masked first (`Privacy.scrubArgs` reads flag/value pairs), then every argument that contains `/` keeps only
    /// what follows the last `/` (`~/work/acme/server.js` → `server.js`, `--dir=/x/y` → `--dir=y`), except the package name
    /// after a package directory (`sharePath`).
    static func shareArgs(_ args: [String], home: String) -> String {
        Privacy.truncate(Privacy.scrubArgList(args, home: home).map { t -> String in
            guard t.contains("/") else { return t }
            if let eq = t.firstIndex(of: "="), t.hasPrefix("-") {
                return String(t[...eq]) + sharePath(String(t[t.index(after: eq)...]))
            }
            return sharePath(t)
        }.joined(separator: " "))
    }

    /// Directories whose next component is a public package name (a VS Code extension, an npm or Python package): the
    /// best clue to what a process is, and not the person's own directory names.
    static let packageDirs: Set<String> = ["extensions", "node_modules", "site-packages", "dist-packages", "gems"]

    /// `…/extensions/<ext>/dist/server.js` → `extensions/<ext>/…/server.js`; otherwise the last component.
    static func sharePath(_ s: String) -> String {
        let parts = s.split(separator: "/").map(String.init)
        guard let i = parts.lastIndex(where: packageDirs.contains), i + 1 < parts.count else { return lastComponent(s) }
        let tail = i + 2 < parts.count ? (i + 3 < parts.count ? "/…/" : "/") + parts[parts.count - 1] : ""
        return parts[i] + "/" + parts[i + 1] + tail
    }

    static func lastComponent(_ s: String) -> String {
        let trimmed = s.hasSuffix("/") ? String(s.dropLast()) : s
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    /// Executable names of the parents, nearest first, at most `maxParents`; `launchd` ends the chain.
    static func ancestors(of p: RawProcess, in scan: Scan) -> [String] {
        var out: [String] = []
        var next = p.ppid
        var seen: Set<Int32> = [p.pid]
        while let ppid = next, out.count < maxParents, !seen.contains(ppid) {
            seen.insert(ppid)
            if ppid <= 1 { out.append("launchd"); break }
            guard let parent = scan.processes[ppid] else { out.append("?"); break }
            out.append(parent.exePath.map(lastComponent) ?? "?")
            next = parent.ppid
        }
        return out
    }

    public var json: String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// The text to paste: one question line in the app's language, then the data.
    public func text(_ lang: Lang) -> String {
        let lead = lang == .vi
            ? "hog (trình xem tài nguyên máy macOS) chưa biết thứ này là gì. Nó là gì, có nên tắt không, tắt thì mất gì? Số đo của hog, đã bỏ tên dự án, thư mục và mật khẩu:"
            : "hog (a macOS resource viewer) does not know what this is. What is it, should I stop it, what happens if I do? hog's measurements, with project names, directories and secrets removed:"
        return lead + "\n\n```json\n" + json + "\n```\n"
    }
}
