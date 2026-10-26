import Darwin
import Foundation

/// Runs external commands by absolute path with a timeout (design sections 3.1b and 3.2).
public enum Command {
    public struct Result: Sendable, Equatable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool
        public var tookMs: Int
        /// When the command was started (to find what it left behind after a timeout).
        public var startedAt: Date
    }

    /// Runs `path args…` in its **own process group**, killing the whole group after `timeout` seconds (SIGTERM, then
    /// SIGKILL): a timed-out command must not leave children behind (QA found `code --status` leaving orphans).
    /// Returns `nil` only when it could not be started.
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> Result? {
        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else { return nil }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        for fd in [outPipe[0], outPipe[1], errPipe[0], errPipe[1]] { posix_spawn_file_actions_addclose(&actions, fd) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)  // new group, id = child's pid

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0)=\($1)") } + [nil]
        defer { envp.forEach { free($0) } }

        let started = Date()
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, &envp)
        close(outPipe[1]); close(errPipe[1])
        guard rc == 0 else { close(outPipe[0]); close(errPipe[0]); return nil }

        let group = DispatchGroup()
        nonisolated(unsafe) var outData = Data(), errData = Data()
        let outFD = outPipe[0], errFD = errPipe[0]
        group.enter()
        DispatchQueue.global().async { outData = readAll(outFD); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = readAll(errFD); group.leave() }

        var timedOut = false
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let w = waitpid(pid, &status, WNOHANG)
            if w == pid || w == -1 { break }
            if Date() >= deadline {
                timedOut = true
                kill(-pid, SIGTERM)
                let hard = Date().addingTimeInterval(1)
                while waitpid(pid, &status, WNOHANG) == 0 && Date() < hard { usleep(20_000) }
                kill(-pid, SIGKILL)
                waitpid(pid, &status, 0)
                break
            }
            usleep(10_000)
        }
        // Readers finish once every writer in the group is gone; do not wait forever on a stray holder.
        _ = group.wait(timeout: .now() + 1)
        close(outFD); close(errFD)
        let exit: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return Result(status: exit, stdout: String(decoding: outData, as: UTF8.self), stderr: String(decoding: errData, as: UTF8.self),
                      timedOut: timedOut, tookMs: Int(Date().timeIntervalSince(started) * 1000), startedAt: started)
    }

    static func readAll(_ fd: Int32) -> Data {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 { data.append(contentsOf: buf[0..<n]) } else { break }
        }
        return data
    }
}

/// Finds external commands by absolute path. An app started from Finder does not inherit the shell `PATH`
/// (`launchctl getenv PATH` is empty), so commands are never looked up by bare name.
public struct CommandLocator: Sendable {
    public var home: String
    /// Extra candidates per command name from `~/.config/hog/config.json` (`{"commands": {"code": ["/path/code"]}}`).
    public var overrides: [String: [String]]

    public init(home: String = NSHomeDirectory(), overrides: [String: [String]]? = nil) {
        self.home = home
        self.overrides = overrides ?? Self.configOverrides(home: home)
    }

    /// `~/.config/hog/config.json` → `commands`. Missing or malformed file: no overrides.
    static func configOverrides(home: String) -> [String: [String]] {
        let url = URL(fileURLWithPath: home).appendingPathComponent(".config/hog/config.json")
        guard let data = FileManager.default.contents(atPath: url.path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commands = obj["commands"] as? [String: [String]] else { return [:] }
        return commands
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
