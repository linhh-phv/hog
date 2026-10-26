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

    /// Process groups of commands still running, so a signal to hog can be passed on (they are in their own groups,
    /// so Ctrl-C would not reach them).
    nonisolated(unsafe) static var running: Set<pid_t> = []
    static let runningLock = NSLock()

    /// Call once in a command-line tool: on SIGINT/SIGTERM, kill the running command groups, then exit.
    public static func forwardSignals() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                runningLock.lock(); let groups = running; runningLock.unlock()
                for g in groups { kill(-g, SIGTERM) }
                usleep(200_000)
                for g in groups { kill(-g, SIGKILL) }
                exit(128 + sig)
            }
            source.resume()
            signalSources.append(source)
        }
    }
    nonisolated(unsafe) static var signalSources: [DispatchSourceSignal] = []

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
        runningLock.lock(); running.insert(pid); runningLock.unlock()
        defer { runningLock.lock(); running.remove(pid); runningLock.unlock() }

        let group = DispatchGroup()
        let out = Buffer(), err = Buffer()
        let outFD = outPipe[0], errFD = errPipe[0]
        let childGroup = pid
        group.enter()
        DispatchQueue.global().async { out.drain(outFD) { kill(-childGroup, SIGKILL) }; group.leave() }
        group.enter()
        DispatchQueue.global().async { err.drain(errFD) { kill(-childGroup, SIGKILL) }; group.leave() }

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
        // Readers finish once every writer in the group is gone; a stray holder in another group may keep the pipe
        // open, so after 1 s they are told to stop, and the fds are closed only once they have (a reader still blocked
        // on a closed fd number could read the next command's pipe).
        if group.wait(timeout: .now() + 1) == .timedOut {
            out.cancel(); err.cancel()
            group.wait()
        }
        close(outFD); close(errFD)
        let exit: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return Result(status: out.overflowed || err.overflowed ? 1 : exit, stdout: String(decoding: out.data, as: UTF8.self),
                      stderr: String(decoding: err.data, as: UTF8.self) + (out.overflowed || err.overflowed ? "\n(hog: output over \(maxOutput) bytes, stopped)" : ""),
                      timedOut: timedOut, tookMs: Int(Date().timeIntervalSince(started) * 1000), startedAt: started)
    }

    /// Output kept per stream; a command that writes more is killed (hog must not eat memory: QA 2026-10-26).
    public static let maxOutput = 16 * 1024 * 1024

    /// Collects a stream incrementally, so what was read is kept even when a stray process keeps the pipe open.
    final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private(set) var overflowed = false
        private var cancelled = false

        var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }

        func cancel() { lock.lock(); cancelled = true; lock.unlock() }

        /// Reads until end of file, overflow or `cancel()`; polls so a cancel is seen within 100 ms.
        func drain(_ fd: Int32, onOverflow: () -> Void) {
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            while true {
                lock.lock(); let stop = cancelled; lock.unlock()
                if stop { break }
                let ready = poll(&pfd, 1, 100)
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                guard ready > 0 else { break }
                let n = read(fd, &buf, buf.count)
                guard n > 0 else { break }
                lock.lock()
                if bytes.count + n > Command.maxOutput {
                    overflowed = true
                    lock.unlock()
                    onOverflow()
                    break
                }
                bytes.append(contentsOf: buf[0..<n])
                lock.unlock()
            }
        }
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
