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

    /// `(file name, data, isLocal)` for every `*.json`, bundled first, each group sorted by name. A file that cannot be
    /// read is left out with a warning, like a file with bad JSON (design 6.3).
    func files() -> (files: [(name: String, data: Data, isLocal: Bool)], warnings: [DataWarning]) {
        var out: [(String, Data, Bool)] = []
        var warnings: [DataWarning] = []
        for (dir, local) in [(bundledDirectory, false), (localDirectory, true)] {
            guard let dir else { continue }
            let names: [String]
            do {
                guard let listed = try Self.list(dir) else { continue }
                names = listed
            } catch {
                warnings.append(DataWarning(file: (local ? "local:" : "") + dir.lastPathComponent, message: "skipped: \(error)"))
                continue
            }
            for name in names.sorted() where name.hasSuffix(".json") {
                let label = (local ? "local:" : "") + name
                do {
                    if let data = try Self.read(dir.appendingPathComponent(name)) { out.append((label, data, local)) }
                } catch {
                    warnings.append(DataWarning(file: label, message: "skipped: \(error)"))
                }
            }
        }
        return (out, warnings)
    }

    /// Largest data file hog reads; the bundled ones are a few KB.
    static let maxFileBytes = 1 << 20

    struct Unreadable: Error, CustomStringConvertible { var description: String }

    static func reason(_ err: Int32) -> String { String(cString: strerror(err)) }

    /// The names in a data directory, `nil` when nothing is there. A folder that is there but cannot be listed (no
    /// permission, dangling symlink, a file) is an error: every override in it would silently stop working.
    static func list(_ dir: URL) throws -> [String]? {
        let path = dir.path
        var link = stat(), info = stat()
        guard lstat(path, &link) == 0 else {
            let err = errno
            if err == ENOENT { return nil }
            throw Unreadable(description: "cannot open (\(reason(err)))")
        }
        guard stat(path, &info) == 0 else {
            let err = errno
            if err == ENOENT { throw Unreadable(description: "broken symbolic link") }
            throw Unreadable(description: "cannot open (\(reason(err)))")
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw Unreadable(description: "not a directory") }
        guard let d = opendir(path) else { throw Unreadable(description: "cannot list (\(reason(errno)))") }
        closedir(d)
        do {
            return try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            throw Unreadable(description: "cannot list (\(error.localizedDescription))")
        }
    }

    /// The contents of a data file, `nil` when nothing is there. Only a regular file of at most `maxFileBytes` is read:
    /// a huge file would slow every scan. Opened non-blocking: a plain `open` of a FIFO waits for a writer forever.
    static func read(_ url: URL) throws -> Data? {
        let path = url.path
        var link = stat()
        guard lstat(path, &link) == 0 else {
            let err = errno
            if err == ENOENT { return nil }
            throw Unreadable(description: "cannot open (\(reason(err)))")
        }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let err = errno
            if err == ENOENT, link.st_mode & S_IFMT == S_IFLNK { throw Unreadable(description: "broken symbolic link") }
            throw Unreadable(description: "cannot open (\(reason(err)))")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Unreadable(description: "cannot read (\(reason(errno)))") }
        switch info.st_mode & S_IFMT {
        case S_IFREG: break
        case S_IFDIR: throw Unreadable(description: "is a directory, not a file")
        default: throw Unreadable(description: "not a regular file")
        }
        guard info.st_size <= maxFileBytes else {
            throw Unreadable(description: "larger than \(maxFileBytes / 1_048_576) MiB (\(info.st_size) bytes)")
        }
        do {
            return try handle.readToEnd() ?? Data()
        } catch {
            throw Unreadable(description: "cannot read (\(error.localizedDescription))")
        }
    }
}
