import Foundation

/// Bilingual text (design section 5: every human-readable string has `vi` and `en`).
public struct LocalizedText: Codable, Sendable, Equatable {
    public var vi: String?
    public var en: String?

    public init(vi: String?, en: String?) { self.vi = vi; self.en = en }

    /// The text in `lang`, falling back to the other language. `nil` only when both are missing.
    public func text(_ lang: Lang) -> String? {
        switch lang {
        case .vi: vi ?? en
        case .en: en ?? vi
        }
    }

    public var missingLanguages: [Lang] {
        Lang.allCases.filter { ($0 == .vi ? vi : en)?.isEmpty ?? true }
    }
}

/// A problem with one data file. Bad files are skipped and reported, never fatal (design 6.3).
public struct DataWarning: Sendable, Equatable, CustomStringConvertible {
    public var file: String
    public var message: String
    public var description: String { "\(file): \(message)" }
}

/// Strict JSON reading for data files written by people or Claude: unknown keys are errors.
enum StrictJSON {
    struct UnknownKey: Error, CustomStringConvertible {
        var path: String
        var description: String { "unknown key \(path)" }
    }

    /// Checks that `obj` (and nested objects listed in `nested`) only use allowed keys.
    static func check(_ obj: [String: Any], allowed: Set<String>, at path: String = "") throws {
        for key in obj.keys where !allowed.contains(key) {
            throw UnknownKey(path: path.isEmpty ? key : "\(path).\(key)")
        }
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "top level must be an object"))
        }
        return obj
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}

/// Where data files come from: the copies bundled with hog, then `~/.config/hog/<kind>.d/` overrides.
public struct DataSource: Sendable {
    public var bundledDirectory: URL?
    public var localDirectory: URL?

    public init(bundledDirectory: URL?, localDirectory: URL?) {
        self.bundledDirectory = bundledDirectory
        self.localDirectory = localDirectory
    }

    /// Bundled `Resources/<kind>` plus `~/.config/hog/<kind>.d`.
    public static func standard(_ kind: String, home: String = NSHomeDirectory()) -> DataSource {
        DataSource(bundledDirectory: resourceBundle?.resourceURL?.appendingPathComponent(kind),
                   localDirectory: URL(fileURLWithPath: home).appendingPathComponent(".config/hog/\(kind).d"))
    }

    static let bundleName = "hog_HogCore.bundle"

    /// Where the bundled data was found (shown by `hog version`).
    public static var resourcePath: String? { resourceBundle?.bundleURL.path }

    /// The resource bundle. SwiftPM's `Bundle.module` looks at the *root* of an `.app` (which cannot be code-signed)
    /// and crashes when the bundle is missing, so installed locations are tried first:
    /// `Hog.app/Contents/Resources/`, next to the (symlink-resolved) executable, and `../Resources` from it — which
    /// covers the `hog` CLI installed as a symlink into `Hog.app/Contents/MacOS/`. `Bundle.module` only for dev/tests.
    static let resourceBundle: Bundle? = {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r) }
        dirs.append(Bundle.main.bundleURL)
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            dirs.append(exe.deletingLastPathComponent())
            dirs.append(exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources"))
        }
        for d in dirs {
            let url = d.appendingPathComponent(bundleName)
            if FileManager.default.fileExists(atPath: url.path), let b = Bundle(url: url) { return b }
        }
        return Bundle.module
    }()

    /// `(file name, data, isLocal)` for every `*.json`, bundled first, each group sorted by name.
    func files() -> [(name: String, data: Data, isLocal: Bool)] {
        var out: [(String, Data, Bool)] = []
        for (dir, local) in [(bundledDirectory, false), (localDirectory, true)] {
            guard let dir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names.sorted() where name.hasSuffix(".json") {
                if let data = FileManager.default.contents(atPath: dir.appendingPathComponent(name).path) {
                    out.append(((local ? "local:" : "") + name, data, local))
                }
            }
        }
        return out
    }
}
