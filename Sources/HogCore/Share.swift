import Foundation

/// `hog.share/1`: what a person copies to ask Claude (outside hog) about one item (phase-2 design, section 3).
///
/// hog itself never sends anything anywhere: this is text for the clipboard or the terminal, built to be safe to paste.
/// No item or owner labels (they carry project names and window titles), no cwd, user name, home or directories, no
/// hosts, secrets masked; then every private name the scan knows (projects, working directories, window titles, user,
/// machine) is replaced wherever it still appears (`Redactor`).
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
        let redactor = Redactor(scan: scan)
        var part = ItemPart(kind: item.kind, catalogId: item.catalogId.value)
        var parents: [String] = []
        var ports: [Int] = []
        if item.kind == .container {
            let id = item.id.hasPrefix("ctr:") ? String(item.id.dropFirst(4)) : item.id
            part.image = scan.containers?.first(where: { $0.id.hasPrefix(id) }).map { redactor.names(shareImage($0.image)) }
        } else if let pid = item.pids.first, let p = scan.processes[pid] {
            part.exe = p.exePath.map { redactor.names(Privacy.scrubUser(lastComponent($0))) }
            part.args = p.args.map { shareArgs($0, home: scan.home, redactor: redactor) }
            parents = ancestors(of: p, in: scan).map(redactor.names)
            ports = Array(Set((scan.network?.listening[pid] ?? []).map(\.port))).sorted()
        }
        return ShareInfo(item: part, facts: facts, ownerKind: item.facts["owner.kind"].flatMap {
            if case .string(let s) = $0 { s } else { nil }
        }, parents: parents, listenPorts: ports)
    }

    // MARK: Arguments

    /// Secrets masked first (`Privacy.scrubArgList` reads flag/value pairs), then each word is reduced to what says what
    /// the program is: a file name or a public package name, never a directory, host, user or random id (`shareWord`).
    /// An absolute path stays one piece even with spaces (`/Applications/Visual Studio Code.app/…`); other arguments with
    /// spaces (`sh -c "cd … && npm run dev"`, `-H "X-Api-Key: v"`) are handled word by word.
    static func shareArgs(_ args: [String], home: String, redactor: Redactor = Redactor(names: [])) -> String {
        var maskNext = false
        var previous = ""
        var program = ""
        // One word: credentials by position (`-u user:pw`, a database client's `-p`/`-a`), secret headers, then `shareWord`.
        func word(_ w: String, startsCommand: Bool) -> String {
            defer { previous = w }
            if startsCommand { program = lastComponent(w) }
            if maskNext { maskNext = false; return "***" }
            if ["&&", "||", ";", "|"].contains(w) { program = ""; return w }
            // `-u user:password`, `-uuser:pw`, `--user=u:pw` (curl, wget, httpie… any program).
            if ["-u", "--user"].contains(previous), w.contains(":"), !w.hasPrefix("-") { return "***" }
            if w.hasPrefix("--user="), w.contains(":") { return "--user=***" }
            if w.hasPrefix("-u"), !w.hasPrefix("--"), w.count > 2, w.contains(":") { return "-u***" }
            if Privacy.credentialProgram(w) != nil { program = lastComponent(w) }
            if let m = Privacy.credential(Privacy.passwordShortFlags[program] ?? [], w) {
                switch m {
                case .valueNext: maskNext = true; return w
                case .attached(let masked): return masked
                }
            }
            // A header whose name is secret-looking: `X-Api-Key: v` (value next), `x-api-key:v`, `--header=X-Auth:v`.
            let (prefix, value) = w.hasPrefix("-") && w.contains("=")
                ? (String(w[...w.firstIndex(of: "=")!]), String(w[w.index(after: w.firstIndex(of: "=")!)...])) : ("", w)
            if let colon = value.firstIndex(of: ":"), Self.isHeaderName(value[..<colon]), Privacy.isSecret(String(value[..<colon])) {
                if value.index(after: colon) == value.endIndex { maskNext = true; return w }
                return prefix + value[...colon] + "***"
            }
            return shareWord(w, redactor)
        }
        let words = Privacy.scrubArgList(args, home: home).enumerated().map { i, arg -> String in
            if i == 0 { program = lastComponent(arg); previous = arg; return redactor.names(Privacy.scrubUser(lastComponent(arg))) }
            if arg.hasPrefix("/") || arg.hasPrefix("~/") {
                defer { previous = arg }
                if maskNext { maskNext = false; return "***" }
                return shareValue(arg, redactor)
            }
            if arg.hasPrefix("-"), let eq = arg.firstIndex(of: "="), arg[arg.index(after: eq)...].hasPrefix("/") || arg[arg.index(after: eq)...].hasPrefix("~/") {
                defer { previous = arg }
                return shareWord(arg, redactor)  // `--dir=/a path/with spaces`: one piece
            }
            // Words of one argument, split on any whitespace (`sh -c "…"`, newlines, tabs); after `&&`, `;`… a new command.
            let parts = arg.split(omittingEmptySubsequences: false, whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
            var startsCommand = parts.count > 1
            return parts.map { w -> String in
                defer { startsCommand = ["&&", "||", ";", "|"].contains(w) }
                return word(w, startsCommand: startsCommand)
            }.joined(separator: " ")
        }
        return Privacy.truncate(words.joined(separator: " "))
    }

    /// `X-Api-Key`, `Authorization`: letters, digits, `-`, `_` only — not an image (`ghcr.io/acme/auth-service:1`) or host.
    static func isHeaderName(_ s: Substring) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// Flag names are kept as they are (they say what the program does); only values are reduced.
    static func shareWord(_ w: String, _ redactor: Redactor = Redactor(names: [])) -> String {
        if w.hasPrefix("-"), let eq = w.firstIndex(of: "=") {
            let name = String(w[..<eq])
            let value = String(w[w.index(after: eq)...])
            return name + "=" + (Privacy.isSecret(String(name.drop(while: { $0 == "-" }))) ? "***" : shareValue(value, redactor))
        }
        if w.hasPrefix("-") { return w }
        return shareValue(w, redactor)
    }

    static func shareValue(_ v: String, _ redactor: Redactor = Redactor(names: [])) -> String {
        if v.isEmpty || v == "***" { return v }
        // NAME=value (environment: `-e DB_PASSWORD=x`, `--env=TOKEN=x`, `--set db.password=x`, inside `sh -c`).
        if let eq = v.firstIndex(of: "="), eq != v.startIndex, v[..<eq].allSatisfy({ $0.isLetter || $0.isNumber || "_.-".contains($0) }) {
            let name = String(v[..<eq])
            return name + "=" + (Privacy.isSecret(name) ? "***" : shareValue(String(v[v.index(after: eq)...]), redactor))
        }
        return redactor.names(reduce(v))
    }

    static func reduce(_ v: String) -> String {
        if let r = v.range(of: "://") { return v[..<r.lowerBound] + "://…" }  // no host, user, path or query
        // A path through a package directory first: its npm scope (`@acme/…`) is hidden there, the package name kept.
        if v.split(separator: "/").contains(where: { packageDirs.contains(String($0)) }) { return sharePath(v) }
        if let pkg = packageSpec(v) { return pkg }
        if v.contains("@") { return "…" }  // user@host, token@host, git@host:org/repo
        if v.contains("/") || v.hasPrefix("~") { return sharePath(v) }
        if looksLikeId(v) { return "…" }
        return v
    }

    /// `supabase@latest`, `vite@5.1.0` → kept; `@scope/pkg[@version]` → `@…/pkg[@version]` (the scope can be a company).
    /// Only `latest` or a version of at most three numbers (no pre-release part: `10-0-1-20` is a host) after `@` counts: `admin@localhost`, `deploy@10.0.1.20`,
    /// `root@1.example.com`, `bob@next` are users at hosts (reviewer 2026-10-26).
    static func packageSpec(_ v: String) -> String? {
        let pattern = #"^(@[A-Za-z0-9._-]+/)?([A-Za-z0-9._-]+)(@(latest|[\^~]?[0-9]+(\.[0-9]+){0,2}))?$"#
        guard let m = try? NSRegularExpression(pattern: pattern).firstMatch(in: v, range: NSRange(v.startIndex..., in: v)) else { return nil }
        let scoped = m.range(at: 1).location != NSNotFound
        let versioned = m.range(at: 3).location != NSNotFound
        guard scoped || versioned, let name = Range(m.range(at: 2), in: v) else { return nil }
        let version = Range(m.range(at: 3), in: v).map { String(v[$0]) } ?? ""
        return (scoped ? "@…/" : "") + v[name] + version
    }

    /// Directories whose next component is a public package name (a VS Code extension, an npm or Python package): the
    /// best clue to what a process is, and not the person's own directory names.
    static let packageDirs: Set<String> = ["extensions", "node_modules", "site-packages", "dist-packages", "gems"]

    /// `…/extensions/<ext>/dist/server.js` → `extensions/<ext>/…/server.js` (an npm scope is hidden: `@…/pkg`);
    /// otherwise the last component if it is a file name (`server.js`), else `…` (a directory: often the project).
    static func sharePath(_ s: String) -> String {
        let parts = s.split(separator: "/").map(String.init)
        if let i = parts.lastIndex(where: packageDirs.contains), i + 1 < parts.count {
            var pkg = parts[i + 1]
            var next = i + 2
            if pkg.hasPrefix("@") {
                pkg = next < parts.count ? "@…/" + parts[next] : "@…"
                next += 1
            }
            let tail = next < parts.count ? (next + 1 < parts.count ? "/…/" : "/") + parts[parts.count - 1] : ""
            return parts[i] + "/" + pkg + tail
        }
        let last = lastComponent(s)
        return isFileName(last) ? last : "…"
    }

    /// `server.js`, `manage.py`, `config.yaml`: a name with a known file extension. A directory named like a domain or a
    /// repository (`acme.io`, `site.test`, `billing.git`) is not one: only listed extensions count (reviewer 2026-10-26).
    static func isFileName(_ s: String) -> Bool {
        guard let dot = s.lastIndex(of: "."), dot != s.startIndex else { return false }
        return fileExtensions.contains(s[s.index(after: dot)...].lowercased())
    }

    static let fileExtensions: Set<String> = [
        "js", "mjs", "cjs", "ts", "mts", "cts", "tsx", "jsx", "py", "pyc", "rb", "go", "rs", "java", "jar", "class", "kt", "kts", "swift",
        "php", "pl", "lua", "r", "jl", "ex", "exs", "erl", "hs", "dart", "c", "h", "cc", "cpp", "hpp", "m", "mm", "zig", "wasm",
        "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd", "json", "jsonc", "yml", "yaml", "toml", "ini", "conf", "cfg", "env",
        "xml", "plist", "properties", "gradle", "txt", "md", "log", "csv", "lock", "pem", "crt", "key", "html", "css", "scss",
        "vue", "svelte", "sql", "db", "sqlite", "so", "dylib", "node", "bin", "sock", "pid",
    ]

    /// UUIDs and long random-looking tokens (browser client ids, session tokens): stable identifiers of a person.
    static func looksLikeId(_ s: String) -> Bool {
        if s.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil { return true }
        guard s.count >= 20, !s.contains("."), s.allSatisfy({ $0.isLetter || $0.isNumber || "+/=_-".contains($0) }) else { return false }
        return s.contains(where: \.isNumber) && s.contains(where: \.isLetter)
    }

    /// Image without its registry and namespace; a `<project>-<service>` name (what Compose builds) keeps only the service.
    static func shareImage(_ image: String) -> String {
        let last = lastComponent(image)
        let (repo, tag) = last.firstIndex(of: ":").map { (String(last[..<$0]), String(last[$0...])) } ?? (last, "")
        let words = repo.split(whereSeparator: { $0 == "-" || $0 == "_" })
        return words.count > 1 ? "…-" + words.last! + tag : last
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

    // MARK: Output

    public var json: String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// The text to paste: one question line in the app's language, then the data.
    public func text(_ lang: Lang) -> String {
        let known = item.catalogId.map { lang == .vi ? "hog nhận ra đây là `\($0)`." : "hog identifies this as `\($0)`." }
            ?? (lang == .vi ? "hog chưa biết thứ này là gì." : "hog does not know what this is.")
        let lead = lang == .vi
            ? "hog (trình xem tài nguyên máy macOS): \(known) Nó là gì, có nên tắt không, tắt thì mất gì? Số đo của hog, đã bỏ tên dự án, thư mục và mật khẩu:"
            : "hog (a macOS resource viewer): \(known) What is it, should I stop it, what happens if I do? hog's measurements, with project names, directories and secrets removed:"
        return lead + "\n\n```json\n" + json + "\n```\n"
    }
}

/// Second layer of `ShareInfo`: private names hog itself has seen in the scan — project names, the parts of working
/// directories under home, VS Code window titles, Claude session directories, the user and the machine — replaced by `…`
/// wherever they still appear (a positional argument such as `code acme-billing`, a binary named after its project).
struct Redactor {
    /// Longest first, so `acme-billing` is replaced before `acme`.
    let names: [String]

    /// Directory names too common to be private; replacing them would only destroy useful words.
    static let generic: Set<String> = ["src", "dist", "build", "app", "apps", "packages", "lib", "bin", "web", "server", "client",
                                       "api", "desktop", "documents", "downloads", "projects", "project", "work", "code", "dev",
                                       "repos", "git", "tmp", "library", "applications", "node_modules", "extensions", "workspace",
                                       "backend", "frontend", "docker", "tools", "scripts", "services", "service", "node", "python",
                                       "infra", "deploy", "config", "test", "tests", "docs", "data", "public", "assets", "mobile",
                                       "worktrees", "main", "master"]

    init(names: [String]) {
        self.names = Array(Set(names.filter { $0.count >= 3 && !Self.generic.contains($0.lowercased()) }))
            .sorted { ($0.count, $0) > ($1.count, $1) }
    }

    init(scan: Scan, user: String = NSUserName(), host: String = Redactor.hostName()) {
        var found: [String] = [user, String(host.split(separator: ".").first ?? "")]
        var projects = ProjectCache()
        let cwds = scan.processes.values.compactMap(\.cwd) + (scan.sessions?.values.compactMap(\.cwd) ?? [])
        // Not ~/Library (apps keep their data there: `Application Support/discord` names the app, not the person).
        for cwd in Set(cwds) where cwd.hasPrefix(scan.home + "/") && !cwd.hasPrefix(scan.home + "/Library/") {
            found += cwd.dropFirst(scan.home.count + 1).split(separator: "/").map(String.init).filter { !$0.hasPrefix(".") }
            if let p = projects.name(for: cwd, home: scan.home) {
                found.append(p)
                found += p.split(separator: "/").map { $0.hasPrefix("@") ? String($0.dropFirst()) : String($0) }  // @scope/name
            }
        }
        for w in (scan.windows ?? [:]).values {
            // "server.js — web-app (Workspace)": the open file comes first and is not private (it is often the very
            // script being asked about); the project part follows.
            var parts = (w.title ?? "").components(separatedBy: " — ")
            if parts.count > 1, let first = parts.first, ShareInfo.isFileName(first.trimmingCharacters(in: CharacterSet(charactersIn: "● ")))
                || first.hasPrefix("●") { parts.removeFirst() }
            found += parts.flatMap { $0.components(separatedBy: CharacterSet(charactersIn: "()")) }.map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != "Workspace" && !$0.contains(" ") && !ShareInfo.isFileName($0) }
        }
        self.init(names: found)
    }

    /// `gethostname`: the kernel's name, no DNS lookup (`ProcessInfo.hostName` can block for seconds).
    static func hostName() -> String {
        var buf = [CChar](repeating: 0, count: 256)
        return gethostname(&buf, buf.count) == 0 ? String(cString: buf) : ""
    }

    func names(_ s: String) -> String {
        var out = s
        for n in names {
            let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: n) + "(?![A-Za-z0-9])"
            out = out.replacingOccurrences(of: pattern, with: "…", options: [.regularExpression, .caseInsensitive])
        }
        return out
    }
}
