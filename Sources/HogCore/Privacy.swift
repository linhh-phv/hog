import Foundation

/// Scrubbing applied to everything that goes into a snapshot (design section 4, "Riêng tư").
public enum Privacy {
    /// Maximum length of the argument string kept in a snapshot.
    public static let maxArgsLength = 200

    /// Flag names whose values are masked: anything containing one of these words.
    static let secretWords = ["token", "key", "secret", "password", "auth"]

    /// Replaces the home directory prefix with `~`.
    public static func scrubPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Masks values of secret-looking flags, replaces the home prefix, and truncates.
    ///
    /// Handles `--flag=value`, `--flag value` and `-flag value`. The argument list is joined with spaces.
    public static func scrubArgs(_ args: [String], home: String = NSHomeDirectory()) -> String {
        var out: [String] = []
        var maskNext = false
        for arg in args {
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
            out.append(scrubEmbeddedHome(arg, home: home))
        }
        return truncate(out.joined(separator: " "))
    }

    static func isSecret(_ flagName: String) -> Bool {
        let lower = flagName.lowercased()
        return secretWords.contains { lower.contains($0) }
    }

    /// Replaces every occurrence of the home directory inside an argument (e.g. `--dir=/Users/x/p`).
    static func scrubEmbeddedHome(_ text: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }

    static func truncate(_ text: String) -> String {
        text.count <= maxArgsLength ? text : String(text.prefix(maxArgsLength - 1)) + "…"
    }
}
