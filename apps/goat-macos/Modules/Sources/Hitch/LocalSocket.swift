import Darwin
import Foundation

/// Filesystem-local transport only: no TCP listener, host name, URL, redirects or token file.
public enum LocalSocket {
    public static func defaultPath() -> String {
        let root =
            ProcessInfo.processInfo.environment["GOAT_HOME"]
            ?? UserDefaults(suiteName: "dev.leet.goat")?.string(forKey: "goat.home")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".goat").path
        return ((root as NSString).expandingTildeInPath as NSString).appendingPathComponent("control/goat.sock")
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard path.hasPrefix("/"), !path.utf8.contains(0), bytes.count <= MemoryLayout.size(ofValue: addr.sun_path)
        else {
            throw HitchError.unsafeEndpoint
        }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }

    static func configure(_ fd: Int32) throws {
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        var one: Int32 = 1
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else { throw HitchError.unavailable }
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0,
            fcntl(fd, F_SETFD, FD_CLOEXEC) == 0
        else { throw HitchError.unavailable }
    }
    static func checkPeer(_ fd: Int32) throws {
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(fd, &user, &group) == 0, user == geteuid() else { throw HitchError.unauthorized }
    }
    static func inspect(_ path: String, type: mode_t, mode: mode_t) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == type,
            info.st_mode & 0o777 == mode
        else { throw HitchError.unsafeEndpoint }
    }
    static func readFrame(_ fd: Int32, maximum: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while data.count <= maximum {
            guard ContinuousClock.now < deadline else { throw HitchError.timeout }
            let count = Darwin.read(fd, &buffer, min(buffer.count, maximum + 1 - data.count))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw HitchError.protocolError }
            data.append(contentsOf: buffer.prefix(count))
            // Search only the bytes just received; rescanning the accumulated frame is quadratic.
            if let end = buffer.prefix(count).firstIndex(of: 10) {
                guard end == count - 1, data.count - 1 <= maximum else { throw HitchError.protocolError }
                return data.dropLast()
            }
        }
        throw HitchError.oversized
    }
    static func writeFrame(_ data: Data, fd: Int32) throws {
        guard data.count <= 524_288 else { throw HitchError.oversized }
        let framed = data + Data([10])
        try framed.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw HitchError.protocolError }
            var offset = 0
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while offset < bytes.count {
                guard ContinuousClock.now < deadline else { throw HitchError.timeout }
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw HitchError.protocolError }
                offset += count
            }
        }
    }

    // Blocking POSIX I/O must not occupy Swift's cooperative executor. The server admits at
    // most eight clients; each owns at most one queued read or write at a time (ADR-0056).
    private static let ioQueue = DispatchQueue(
        label: "dev.leet.goat.hitch.io", qos: .userInitiated, attributes: .concurrent)

    static func readFrameAsync(_ fd: Int32, maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                continuation.resume(with: Result { try readFrame(fd, maximum: maximum) })
            }
        }
    }

    static func writeFrameAsync(_ data: Data, fd: Int32) async throws {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                continuation.resume(with: Result { try writeFrame(data, fd: fd) })
            }
        }
    }

    public static func request(_ request: HitchRequest, path: String = defaultPath()) throws -> HitchReply {
        let parent = (path as NSString).deletingLastPathComponent
        try inspect(parent, type: S_IFDIR, mode: 0o700)
        try inspect(path, type: S_IFSOCK, mode: 0o600)
        var addr = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HitchError.unavailable }
        defer { Darwin.close(fd) }
        try configure(fd)
        let status = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else { throw HitchError.unavailable }
        try checkPeer(fd)
        let data = try JSONEncoder().encode(request)
        guard data.count <= 65_536 else { throw HitchError.oversized }
        try writeFrame(data, fd: fd)
        let reply = try JSONDecoder().decode(HitchReply.self, from: readFrame(fd, maximum: 524_288))
        guard reply.version == 1, reply.id == request.id else { throw HitchError.protocolError }
        return reply
    }
}

public actor HitchServer {
    private var source: DispatchSourceRead?
    private var listener: Int32 = -1
    private var lockFD: Int32 = -1
    private var clients: Set<Int32> = []
    private var path: String?
    private var dispatcher: HitchDispatcher?
    public init() {}

    public func start(path: String, dispatcher: HitchDispatcher) throws {
        guard listener == -1 else { throw HitchError.busy }
        var addr = try LocalSocket.address(path)
        let directory = (path as NSString).deletingLastPathComponent
        if mkdir(directory, 0o700) != 0, errno != EEXIST { throw HitchError.unsafeEndpoint }
        try LocalSocket.inspect(directory, type: S_IFDIR, mode: 0o700)
        let lockFD = Darwin.open(directory + "/owner.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw HitchError.unsafeEndpoint }
        var committed = false
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer {
            if !committed {
                Darwin.close(lockFD)
                if fd >= 0 { Darwin.close(fd) }
            }
        }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG,
            lockInfo.st_uid == geteuid(), lockInfo.st_mode & 0o777 == 0o600
        else { throw HitchError.unsafeEndpoint }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw HitchError.busy }
        var old = stat()
        if lstat(path, &old) == 0 {
            try LocalSocket.inspect(path, type: S_IFSOCK, mode: 0o600)
            guard unlink(path) == 0 else { throw HitchError.unsafeEndpoint }
        } else if errno != ENOENT {
            throw HitchError.unsafeEndpoint
        }
        guard fd >= 0 else { throw HitchError.unavailable }
        try LocalSocket.configure(fd)
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw HitchError.unavailable }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw HitchError.unavailable }
        guard chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            unlink(path)
            throw HitchError.unavailable
        }
        self.path = path
        self.lockFD = lockFD
        listener = fd
        self.dispatcher = dispatcher
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in Task { await self?.acceptConnections() } }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        committed = true
        source.resume()
    }

    private func acceptConnections() {
        guard listener >= 0, let dispatcher else { return }
        for _ in 0..<16 {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            guard clients.count < 8 else {
                Darwin.close(fd)
                continue
            }
            do {
                try LocalSocket.configure(fd)
                try LocalSocket.checkPeer(fd)
            } catch {
                Darwin.close(fd)
                continue
            }
            clients.insert(fd)
            Task.detached { [weak self] in
                do {
                    let bytes = try await LocalSocket.readFrameAsync(fd, maximum: 65_536)
                    let request = try JSONDecoder().decode(HitchRequest.self, from: bytes)
                    let reply = await dispatcher.dispatch(request)
                    let encoded = try JSONEncoder().encode(reply)
                    let frame =
                        encoded.count <= 524_288
                        ? encoded
                        : try JSONEncoder().encode(
                            HitchReply(id: request.id, error: "oversized"))
                    try await LocalSocket.writeFrameAsync(frame, fd: fd)
                } catch {
                    // Close malformed or interrupted connections without attempting a second reply.
                }
                await self?.finished(fd)
                // The request owns its descriptor even if the server has been released.
                Darwin.close(fd)
            }
        }
    }
    private func finished(_ fd: Int32) {
        clients.remove(fd)
    }
    public func stop() async {
        listener = -1
        source?.cancel()
        source = nil
        for fd in clients { shutdown(fd, SHUT_RDWR) }
        if let path { unlink(path) }
        path = nil
        if lockFD >= 0 {
            // A concurrent fork can temporarily inherit the descriptor before exec closes it.
            // Explicit unlock makes shutdown independent of that child's lifetime.
            _ = flock(lockFD, LOCK_UN)
            Darwin.close(lockFD)
            lockFD = -1
        }
        let old = dispatcher
        dispatcher = nil
        await old?.stop()
    }
}
