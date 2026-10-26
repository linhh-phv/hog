import Foundation

/// Scrubbing applied to everything that goes into a snapshot (design section 4, "Riêng tư").
public enum Privacy {
    /// Maximum length of the argument string kept in a snapshot.
    public static let maxArgsLength = 200

    /// Flag names whose values are masked: anything containing one of these words.
    static let secretWords = ["token", "key", "secret", "password", "passwd", "pwd", "pass", "auth", "credential", "bearer", "cookie"]

    /// Replaces the home directory prefix with `~`.
    public static func scrubPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Database clients whose `-p<pw>` / `-a <pw>` short flags carry a password.
    static let passwordShortFlags: [String: Set<String>] = [
        "mysql": ["-p"], "mysqldump": ["-p"], "mysqladmin": ["-p"], "mariadb": ["-p"], "redis-cli": ["-a"],
    ]

    /// Masks values of secret-looking flags, credentials in URLs, `Authorization:`/`Bearer` values and database
    /// client passwords; replaces the home directory; truncates.
    ///
    /// Handles `--flag=value`, `--flag value` and `-flag value`. The argument list is joined with spaces.
    public static func scrubArgs(_ args: [String], home: String = NSHomeDirectory()) -> String {
        truncate(scrubArgList(args, home: home).joined(separator: " "))
    }

    /// `scrubArgs` without joining: one masked string per argument.
    static func scrubArgList(_ args: [String], home: String) -> [String] {
        var out: [String] = []
        var maskNext = false
        let program = args.first.map { ($0 as NSString).lastPathComponent } ?? ""
        let pwFlags = passwordShortFlags[program] ?? []
        var maskAuth = false
        for arg in args.map(scrubInline) {
            // "Authorization:" [Bearer|Basic|Token] <secret>, split over several arguments: keep the scheme word, mask the value.
            let lower = arg.lowercased()
            if maskAuth {
                if ["bearer", "basic", "token"].contains(lower) { out.append(arg); continue }
                out.append("***"); maskAuth = false; continue
            }
            if lower.hasSuffix("authorization:") || lower.hasSuffix("cookie:") || ["bearer", "basic"].contains(lower) {
                out.append(arg); maskAuth = true; continue
            }
            if let flag = pwFlags.first(where: { arg.hasPrefix($0) }) {
                out.append(arg == flag ? arg : flag + "***")
                maskNext = arg == flag
                continue
            }
            if maskNext {
                out.append("***")
                maskNext = false
                continue
            }
            if arg.hasPrefix("-") {
                let body = arg.drop(while: { $0 == "-" })
                if let eq = body.firstIndex(of: "=") {
                    let name = body[..<eq]
                    if isSecret(String(name)) {
                        out.append(String(arg[..<arg.index(arg.startIndex, offsetBy: arg.count - body.count)]) + name + "=***")
                        continue
                    }
                } else if isSecret(String(body)) {
                    out.append(arg)
                    maskNext = true
                    continue
                }
            }
            out.append(scrubUser(scrubEmbeddedHome(arg, home: home)))
        }
        return out
    }

    /// Inside one argument: `scheme://user:pass@host` → `scheme://user:***@host`, `Authorization: Bearer x` →
    /// `Authorization: ***`, and `token=`/`key=`/`secret=`/`password=` query values.
    static func scrubInline(_ arg: String) -> String {
        var s = arg
        if let re = try? NSRegularExpression(pattern: #"([a-zA-Z][a-zA-Z0-9+.-]*://[^/:@\s]+):[^@/\s]+@"#) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1:***@")
        }
        if let re = try? NSRegularExpression(pattern: #"(?i)((?:authorization|cookie|set-cookie):\s*)(bearer\s+|basic\s+|token\s+)?\S+"#) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1$2***")
        }
        if let re = try? NSRegularExpression(pattern: #"(?i)([?&](?:[a-z_]*token|[a-z_]*key|secret|password|pass|pwd|auth)=)[^&\s]+"#) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1***")
        }
        return s
    }

    static func isSecret(_ flagName: String) -> Bool {
        let lower = flagName.lowercased()
        return secretWords.contains { lower.contains($0) }
    }

    /// Replaces the home directory inside an argument (e.g. `--dir=<home>/p`), only at a path boundary: a sibling
    /// home such as `<home>2` is left alone.
    static func scrubEmbeddedHome(_ text: String, home: String) -> String {
        guard !home.isEmpty, home != "/",
              let re = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: home) + #"(?=/|$|[\s"',;:])"#) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "~")
    }

    /// The account name also appears outside the home path (`…/watchman/<user>-state/…`, QA 2026-10-26).
    static func scrubUser(_ text: String, user: String = NSUserName()) -> String {
        guard user.count >= 3 else { return text }
        return text.replacingOccurrences(of: user, with: "<user>")
    }

    static func truncate(_ text: String) -> String {
        text.count <= maxArgsLength ? text : String(text.prefix(maxArgsLength - 1)) + "…"
    }
}
