import Foundation

/// Scrubbing applied to everything that goes into a snapshot (design section 4, "Riêng tư").
public enum Privacy {
    /// Maximum length of the argument string kept in a snapshot.
    public static let maxArgsLength = 200
    /// Work bound: each argument is cut to this length, and arguments past `maxScannedLength` in total are not read
    /// (only 200 characters are kept; QA 2026-10-26: a 150 KB argument made the URL regex run for minutes).
    static let maxArgLength = 1024
    static let maxScannedLength = 8192

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
        // user:password, proxy user, client certificate passphrase, cookies (QA + reviewer 2026-10-26).
        "curl": ["-u", "--user", "-U", "--proxy-user", "-E", "--cert", "-b", "--cookie"],
        "sshpass": ["-p"],
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
        var pwFlags: Set<String> = []
        var maskAuth = false
        var budget = maxScannedLength
        let bounded = args.prefix { arg in defer { budget -= min(arg.count, maxArgLength) }; return budget > 0 }
            .map { $0.count > maxArgLength ? String($0.prefix(maxArgLength)) + "…" : $0 }
        for arg in bounded.map(scrubInline) {
            // "Authorization:" [Bearer|Basic|Token] <secret>, split over several arguments: keep the scheme word, mask the value.
            let lower = arg.lowercased()
            if maskAuth {
                if ["bearer", "basic", "token"].contains(lower) { out.append(arg); continue }
                out.append("***"); maskAuth = false; continue
            }
            if lower.hasSuffix("authorization:") || lower.hasSuffix("cookie:") || ["bearer", "basic"].contains(lower) {
                out.append(arg); maskAuth = true; continue
            }
            // Union, never replace: `curl -o mysql --proxy-user a:pw` keeps curl's flags (reviewer 2026-10-26).
            if !maskNext, let flags = credentialProgram(arg) { pwFlags.formUnion(flags) }
            if !maskNext, let m = credential(pwFlags, arg) {
                switch m {
                case .valueNext: out.append(arg); maskNext = true
                case .attached(let masked): out.append(masked)
                }
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
        // The look-behind keeps this linear on long alphanumeric runs (a start inside a scheme is never retried).
        if let re = try? NSRegularExpression(pattern: #"(?<![a-zA-Z0-9+.-])([a-zA-Z][a-zA-Z0-9+.-]*://[^/:@\s]+):[^@/\s]+@"#) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1:***@")
        }
        // To the end of the argument: `Cookie: a=1; b=2` has several values (reviewer 2026-10-26).
        if let re = try? NSRegularExpression(pattern: #"(?i)((?:authorization|cookie|set-cookie):\s*)(bearer\s+|basic\s+|token\s+)?\S.*"#) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1$2***")
        }
        if let re = try? NSRegularExpression(pattern: #"(?i)([?&](?:[a-z_]*token|[a-z_]*key|secret|password|pass|pwd|auth)=)[^&\s]+"#) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1***")
        }
        // JSON: {"password": "x"}, {"api_key":"x"} (QA 2026-10-26).
        if let re = try? NSRegularExpression(pattern: #"(?i)("[A-Za-z0-9_.-]*(?:token|key|secret|passw|pwd|pass|auth|credential|cookie)[A-Za-z0-9_.-]*"\s*:\s*)"[^"]*""#) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1\"***\"")
        }
        return s
    }

    /// The credential flags of a program named anywhere in the command (`docker exec db mysql -pX`, `sudo curl -b …`).
    static func credentialProgram(_ word: String) -> Set<String>? {
        let w = word.trimmingCharacters(in: CharacterSet(charactersIn: "'\"(`$)"))  // `'mysql`, `(mysql`, `$(curl`
        return w.hasPrefix("-") ? nil : passwordShortFlags[(w as NSString).lastPathComponent]
    }

    enum CredentialMatch: Equatable { case valueNext, attached(String) }

    /// `-p` → the next word is the secret; `-psecret`, `--user=u:pw` → masked in place (a long flag only matches itself
    /// or `flag=`: not `--user-agent`). Short flags may be combined: in `-su a:pw`, `-suadmin:pw`, `-skE c.pem:pw` the first
    /// credential flag takes the rest of the word, or the next word when nothing follows it.
    static func credential(_ flags: Set<String>, _ w: String) -> CredentialMatch? {
        guard !flags.isEmpty, w.hasPrefix("-") else { return nil }
        if flags.contains(w) { return .valueNext }
        if w.hasPrefix("--") {
            for f in flags where f.hasPrefix("--") && w.hasPrefix(f + "=") { return .attached(f + "=***") }
            return nil
        }
        let letters = Array(w.dropFirst())
        guard let i = letters.firstIndex(where: { flags.contains("-" + String($0)) }) else { return nil }
        guard letters[..<i].allSatisfy(\.isLetter) else { return nil }  // only flags before it (`-sSu`)
        return i == letters.count - 1 ? .valueNext : .attached("-" + String(letters[...i]) + "***")
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
