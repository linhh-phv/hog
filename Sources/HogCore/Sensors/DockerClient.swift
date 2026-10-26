import Darwin
import Foundation

/// Minimal Docker Engine API client over a unix socket. Never uses the `docker` CLI (its shim may start the
/// engine) and never connects unless the socket file already exists (design section 3.1, 3.2).
public struct DockerClient: Sendable {
    public var socketPath: String
    public var timeout: TimeInterval

    public init(socketPath: String, timeout: TimeInterval = 3) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    /// First existing socket among the usual locations; `nil` means the engine is not running (not an error).
    public static func findSocket(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        var candidates: [String] = []
        if let host = environment["DOCKER_HOST"], host.hasPrefix("unix://") { candidates.append(String(host.dropFirst(7))) }
        candidates += [home + "/.orbstack/run/docker.sock", home + "/.docker/run/docker.sock", "/var/run/docker.sock"]
        return candidates.first(where: isSocket)
    }

    /// `stat` follows symlinks: a dangling `/var/run/docker.sock` (engine stopped) is not a socket.
    static func isSocket(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK
    }

    public struct Response: Sendable { public var status: Int; public var body: Data }

    public enum Failure: Error, Equatable { case connect, io, badResponse }

    /// One HTTP/1.0 request (so the reply is not chunked and ends at connection close).
    public func request(_ method: String, _ path: String, body: Data? = nil) throws -> Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.connect }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure.connect }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in pathBytes.enumerated() { buf[i] = b }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw Failure.connect }

        var head = "\(method) \(path) HTTP/1.0\r\nHost: docker\r\n"
        if let body { head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        if let body { out.append(body) }
        let sent = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard sent == out.count else { throw Failure.io }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 { data.append(contentsOf: buf[0..<n]) } else if n == 0 { break } else { throw Failure.io }
        }
        return try Self.parseResponse(data)
    }

    static func parseResponse(_ data: Data) throws -> Response {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { throw Failure.badResponse }
        let head = String(decoding: data[..<sep.lowerBound], as: UTF8.self)
        let parts = head.split(separator: "\r\n").first?.split(separator: " ") ?? []
        guard parts.count >= 2, let status = Int(parts[1]) else { throw Failure.badResponse }
        return Response(status: status, body: Data(data[sep.upperBound...]))
    }

    // MARK: - Reads

    public struct Container: Sendable, Equatable {
        public var id: String
        public var name: String
        public var image: String
        public var state: String
        public var publishedPorts: [Int]
        public var restartCount: Int?
        public var restartPolicy: String?
        public var startedAt: Date?
    }

    /// All containers with the fields the rules need (list + one inspect each).
    public func containers() throws -> [Container] {
        let list = try request("GET", "/containers/json?all=1")
        guard list.status == 200, let arr = try JSONSerialization.jsonObject(with: list.body) as? [[String: Any]] else {
            throw Failure.badResponse
        }
        return try arr.map { c in
            let id = c["Id"] as? String ?? ""
            let name = ((c["Names"] as? [String])?.first ?? id).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let ports = (c["Ports"] as? [[String: Any]] ?? []).compactMap { ($0["PublicPort"] as? NSNumber)?.intValue }
            var container = Container(id: id, name: name, image: c["Image"] as? String ?? "", state: c["State"] as? String ?? "",
                                      publishedPorts: Array(Set(ports)).sorted())
            let inspect = try request("GET", "/containers/\(id)/json")
            if inspect.status == 200, let obj = try JSONSerialization.jsonObject(with: inspect.body) as? [String: Any] {
                container.restartCount = (obj["RestartCount"] as? NSNumber)?.intValue
                container.restartPolicy = ((obj["HostConfig"] as? [String: Any])?["RestartPolicy"] as? [String: Any])?["Name"] as? String
                let state = obj["State"] as? [String: Any]
                if let s = state?["Status"] as? String { container.state = s }
                container.startedAt = (state?["StartedAt"] as? String).flatMap(Self.parseDockerDate)
            }
            return container
        }
    }

    /// Docker timestamps carry nanoseconds (`2026-10-26T03:31:30.123456789Z`); `0001-01-01…` means never started.
    static func parseDockerDate(_ s: String) -> Date? {
        guard !s.hasPrefix("0001-") else { return nil }
        let trimmed: String
        if let dot = s.firstIndex(of: ".") { trimmed = String(s[..<dot]) + "Z" } else { trimmed = s }
        return ISO8601DateFormatter().date(from: trimmed)
    }
}
