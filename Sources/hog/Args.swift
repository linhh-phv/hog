import Foundation
import HogCore

/// Exit codes (design section 8).
enum Exit: Int32 {
    case ok = 0, error = 1, usage = 2, needsConfirmation = 3, blocked = 4
}

struct UsageError: Error, CustomStringConvertible { var description: String }

/// Command line: `hog [command] [args…] [flags]`. Hand-written: no third-party dependencies.
struct Args {
    var command = "status"
    var positional: [String] = []
    var json = false
    var pretty = false
    var brief = false
    var fast = false
    var full = false
    var lang: Lang
    var yes = false
    var plan: String?
    var noColor = false
    var share = false
    var all = false

    init(_ argv: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        lang = Self.defaultLang(environment)
        var rest = argv[...]
        var sawCommand = false
        while let a = rest.popFirst() {
            switch a {
            case "--json": json = true
            case "--pretty": pretty = true
            case "--brief": brief = true
            case "--fast": fast = true
            case "--full": full = true
            case "--yes", "-y": yes = true
            case "--no-color": noColor = true
            case "--share": share = true
            case "--all", "-a": all = true
            case "--plan":
                guard let v = rest.popFirst() else { throw UsageError(description: "--plan needs a plan id") }
                plan = v
            case "--lang":
                guard let v = rest.popFirst(), let l = Lang(rawValue: v) else { throw UsageError(description: "--lang takes vi or en") }
                lang = l
            case "--vi": lang = .vi
            case "--en": lang = .en
            case "-h", "--help": command = "help"; sawCommand = true
            case "-v", "--version": command = "version"; sawCommand = true
            default:
                if a.hasPrefix("-") { throw UsageError(description: "unknown flag \(a)") }
                if !sawCommand { command = a; sawCommand = true } else { positional.append(a) }
            }
        }
        if share && command != "explain" { throw UsageError(description: "--share only works with `hog explain <item>`") }
        if yes && plan == nil { throw UsageError(description: "--yes only works with --plan <id> (see `hog stop`)") }
    }

    /// `HOG_LANG`, else the first preferred language of the machine.
    static func defaultLang(_ env: [String: String]) -> Lang {
        if let l = env["HOG_LANG"].flatMap(Lang.init(rawValue:)) { return l }
        return (Locale.preferredLanguages.first ?? "en").hasPrefix("vi") ? .vi : .en
    }
}
