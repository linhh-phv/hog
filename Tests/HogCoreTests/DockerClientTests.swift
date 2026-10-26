import Darwin
import Foundation
import Testing
@testable import HogCore

/// A fake Docker Engine on a unix socket owned by the test.
final class FakeDocker: @unchecked Sendable {
    let path: String
    let fd: Int32
    private let routes: [String: (Int, String)]
    private(set) var requests: [String] = []
    private let lock = NSLock()

    init(routes: [String: (Int, String)]) throws {
        // Short path: sun_path is limited to 104 bytes.
        path = "/tmp/hog-docker-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
        self.routes = routes
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in for (i, b) in path.utf8.enumerated() { buf[i] = b } }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0, listen(fd, 8) == 0 else { throw DockerClient.Failure.connect }
        Thread.detachNewThread { [self] in serve() }
    }

    private func serve() {
        while true {
            let c = accept(fd, nil, nil)
            guard c >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = read(c, &buf, buf.count)
            let req = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
            let line = req.split(separator: "\r\n").first.map(String.init) ?? ""
            lock.lock(); requests.append(line); lock.unlock()
            let parts = line.split(separator: " ")
            let key = parts.count >= 2 ? "\(parts[0]) \(parts[1])" : ""
            let (status, body) = routes[key] ?? (404, "{\"message\":\"not found\"}")
            let resp = "HTTP/1.0 \(status) X\r\nContent-Type: application/json\r\n\r\n\(body)"
            _ = resp.withCString { write(c, $0, strlen($0)) }
            close(c)
        }
    }

    var seen: [String] { lock.lock(); defer { lock.unlock() }; return requests }

    /// Closes the listener (the serve thread then exits) and removes the socket file.
    func stop() { close(fd); unlink(path) }
}

@Suite struct DockerClientTests {
    let listBody = """
    [{"Id":"abc123def4567890","Names":["/db"],"Image":"mongo:7","State":"restarting",
      "Ports":[{"PrivatePort":27017,"PublicPort":27017,"Type":"tcp"},{"PrivatePort":27017,"PublicPort":27017,"Type":"tcp"}]}]
    """
    let inspectBody = """
    {"RestartCount":4057,"HostConfig":{"RestartPolicy":{"Name":"always"}},
     "State":{"Status":"restarting","StartedAt":"2026-10-26T03:31:30.123456789Z"}}
    """

    @Test func readsContainersWithRestartFacts() throws {
        let fake = try FakeDocker(routes: ["GET /containers/json?all=1": (200, listBody),
                                           "GET /containers/abc123def4567890/json": (200, inspectBody)])
        defer { fake.stop() }
        let list = try DockerClient(socketPath: fake.path).containers()
        #expect(list.count == 1)
        let c = try #require(list.first)
        #expect(c.name == "db")
        #expect(c.state == "restarting")
        #expect(c.publishedPorts == [27017])
        #expect(c.restartCount == 4057)
        #expect(c.restartPolicy == "always")
        #expect(c.startedAt == ISO8601DateFormatter().date(from: "2026-10-26T03:31:30Z"))
        #expect(fake.seen.allSatisfy { $0.hasPrefix("GET ") }, "sensing only reads")
    }

    @Test func findSocketIgnoresDanglingSymlink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".orbstack/run"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent(".docker/run/docker.sock")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: dir.path + "/.orbstack/run/docker.sock")
        // Engine stopped: no socket anywhere under this fake home → nil (and not /var/run unless a real one exists).
        let found = DockerClient.findSocket(home: dir.path, environment: [:])
        #expect(found == nil || found == "/var/run/docker.sock")
    }

    @Test func dockerHostEnvironmentWins() throws {
        let fake = try FakeDocker(routes: [:])
        defer { fake.stop() }
        #expect(DockerClient.findSocket(home: "/nonexistent", environment: ["DOCKER_HOST": "unix://\(fake.path)"]) == fake.path)
    }

    @Test func neverStartedDateIsNil() {
        #expect(DockerClient.parseDockerDate("0001-01-01T00:00:00Z") == nil)
    }

    @Test func connectFailureIsAnError() {
        #expect(throws: DockerClient.Failure.self) {
            try DockerClient(socketPath: "/tmp/hog-no-such-\(getpid()).sock").request("GET", "/_ping")
        }
    }
}
