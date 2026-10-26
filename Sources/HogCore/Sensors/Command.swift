import Foundation

/// Runs external commands by absolute path with a timeout (design sections 3.1b and 3.2).
public enum Command {
    public struct Result: Sendable, Equatable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool
        public var tookMs: Int
    }

    /// Runs `path args…`, killing it after `timeout` seconds. Returns `nil` only when it could not be started.
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let started = Date()
        do { try process.run() } catch { return nil }

        // Read both pipes concurrently so a chatty command cannot block on a full pipe.
        let group = DispatchGroup()
        nonisolated(unsafe) var outData = Data(), errData = Data()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        var timedOut = false
        if group.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = group.wait(timeout: .now() + 1)
        }
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self),
                      timedOut: timedOut,
                      tookMs: Int(Date().timeIntervalSince(started) * 1000))
    }
}

/// Finds external commands by absolute path. An app started from Finder does not inherit the shell `PATH`
/// (`launchctl getenv PATH` is empty), so commands are never looked up by bare name.
public struct CommandLocator: Sendable {
    public var home: String
    /// Extra candidates per command name, e.g. from `~/.config/hog/config.json`. Checked first.
    public var overrides: [String: [String]]

    public init(home: String = NSHomeDirectory(), overrides: [String: [String]] = [:]) {
        self.home = home
        self.overrides = overrides
    }

    public func candidates(_ name: String) -> [String] {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", "/usr/bin", "/usr/sbin", "/bin", "/sbin"]
        if name == "code" {
            dirs.append("/Applications/Visual Studio Code.app/Contents/Resources/app/bin")
            dirs.append(home + "/Applications/Visual Studio Code.app/Contents/Resources/app/bin")
        }
        return (overrides[name] ?? []) + dirs.map { $0 + "/" + name }
    }

    public func find(_ name: String) -> String? {
        candidates(name).first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
