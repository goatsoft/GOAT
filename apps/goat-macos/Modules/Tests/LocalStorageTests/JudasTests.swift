import Foundation
import Network
import Testing

@testable import JUDAS

@Test func judasBindsRequestsToAnExactConfiguredOrigin() throws {
    let judas = Judas()
    let origin = try #require(URL(string: "https://engine.example:8443/base"))
    try judas.authorize(
        URL(string: "https://engine.example:8443/v1/chat?token=secret"), configuredOrigin: origin, source: .engine)
    for value in [
        "https://other.example:8443", "http://engine.example:8443", "https://engine.example:8444",
        "https://user:secret@engine.example:8443", "file:///private/data", "https://engine.example:8443/#secret",
    ] {
        #expect(throws: JudasError.self) {
            try judas.authorize(URL(string: value), configuredOrigin: origin, source: .engine)
        }
    }
    let events = judas.drain().events
    #expect(events.filter { $0.action == .allowed }.count == 1)
    #expect(events.filter { $0.action == .denied }.count == 6)
    #expect(events.allSatisfy { !$0.destination.contains("secret") && !$0.destination.contains("/v1") })
}

@Test func judasRestrictsProcessesAndPreviewTogether() throws {
    let judas = Judas(mode: .localNetworksOnly)
    for value in ["http://127.0.0.1:8000", "http://localhost:8888", "http://[::1]:1234"] {
        let url = try #require(URL(string: value))
        try judas.authorize(url, configuredOrigin: url, source: .memory)
        #expect(judas.authorizePreview(url, offGrid: false))
    }
    for value in [
        "https://example.com", "http://127.0.0.1.example.com", "http://192.168.1.1.example.com",
        "http://localhost.example.com",
    ] {
        let url = try #require(URL(string: value))
        #expect(throws: JudasError.self) { try judas.authorize(url, configuredOrigin: url, source: .mcp) }
        #expect(!judas.authorizePreview(url, offGrid: false))
    }
    #expect(throws: JudasError.self) { try judas.authorizeProcess() }
    judas.setMode(.blocked)
    let local = try #require(URL(string: "http://127.0.0.1"))
    #expect(!judas.authorizePreview(local, offGrid: false))
    #expect(throws: JudasError.self) { try judas.authorize(local, configuredOrigin: local, source: .engine) }
    judas.setMode(.configured)
    try judas.authorizeProcess()
    #expect(!judas.authorizePreview(try #require(URL(string: "https://example.com")), offGrid: true))
}

@Test func judasAuditOverflowIsExplicitAndRedacted() throws {
    let judas = Judas(capacity: 2)
    let url = try #require(URL(string: "https://example.com/private-token?api_key=secret"))
    for _ in 0..<5 { judas.record(.memory, .allowed, url: url) }
    let result = judas.drain()
    #expect(result.dropped == 3)
    #expect(result.events.map(\.sequence) == [4, 5])
    #expect(result.events.allSatisfy { $0.destination == "https://example.com:443" })
    #expect(judas.drain().events.isEmpty)
}

@Test func judasRevocationCallbacksCanReenterAndLeasesExpire() {
    let judas = Judas()
    var registration: JudasRegistration? = JudasRegistration(judas: judas) {
        judas.record(.policy, .revoked)
    }
    #expect(registration != nil)
    judas.setMode(.blocked)
    #expect(judas.drain().events.filter { $0.action == .revoked }.count == 2)
    registration = nil
    judas.setMode(.configured)
    #expect(judas.drain().events.filter { $0.action == .revoked }.isEmpty)
}

@Test func judasDeniedRequestNeverReachesTransport() async throws {
    let fixture = try JudasHTTPFixture()
    defer { fixture.stop() }
    let url = try await fixture.url()
    let judas = Judas(mode: .blocked)
    let client = JudasHTTPClient(origin: url, source: .engine, judas: judas)
    await #expect(throws: JudasError.self) { _ = try await client.bytes(for: URLRequest(url: url)) }
    #expect(fixture.requestCount == 0)
}

@Test func judasRejectsRedirectBeforeItReachesAnotherListener() async throws {
    let target = try JudasHTTPFixture()
    defer { target.stop() }
    let targetURL = try await target.url()
    let source = try JudasHTTPFixture(
        response:
            "HTTP/1.1 307 Temporary Redirect\r\nLocation: \(targetURL.absoluteString)secret?token=hidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    )
    defer { source.stop() }
    let origin = try await source.url()
    let judas = Judas()
    let client = JudasHTTPClient(origin: origin, source: .engine, name: "Studio Engine", judas: judas)
    var request = URLRequest(url: origin)
    request.httpMethod = "POST"
    request.httpBody = Data("private prompt".utf8)
    request.setValue("Bearer private-key", forHTTPHeaderField: "Authorization")
    let (bytes, response) = try await client.bytes(for: request)
    for try await _ in bytes {}
    #expect((response as? HTTPURLResponse)?.statusCode == 307)
    #expect(source.requestCount == 1)
    #expect(target.requestCount == 0)
    let events = judas.drain().events
    #expect(events.contains { $0.action == .redirectBlocked && $0.destination.hasPrefix("Studio Engine · ") })
    #expect(events.allSatisfy { !$0.destination.contains("hidden") && !$0.destination.contains("secret") })
}

@Test func judasPolicyChangeCancelsAnInFlightRequest() async throws {
    let fixture = try JudasHTTPFixture(response: nil)
    defer { fixture.stop() }
    let url = try await fixture.url()
    let judas = Judas()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForResource = 3
    let client = JudasHTTPClient(origin: url, source: .memory, configuration: configuration, judas: judas)
    let request = Task {
        do {
            _ = try await client.bytes(for: URLRequest(url: url))
            return false
        } catch { return (error as? URLError)?.code == .cancelled }
    }
    for _ in 0..<200 where fixture.requestCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(fixture.requestCount == 1)
    judas.setMode(.blocked)
    #expect(await request.value)
}

// The fixture protects mutable state with a lock; Network's listener/connection objects are
// thread-safe. It binds only loopback and never contacts an external endpoint.
private final class JudasHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "goat.tests.judas")
    private let lock = NSLock()
    private var count = 0
    private var connections: [NWConnection] = []
    private let response: String?

    init(response: String? = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK") throws {
        self.response = response
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    var requestCount: Int { lock.withLock { count } }

    func url() async throws -> URL {
        for _ in 0..<200 {
            if let port = listener.port, port.rawValue > 0 {
                return try #require(URL(string: "http://127.0.0.1:\(port.rawValue)/"))
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw JudasError.denied
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, _, _ in
            guard let self else { return }
            self.lock.withLock { self.count += 1 }
            guard let response = self.response else { return }
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func stop() {
        listener.cancel()
        let open = lock.withLock { connections }
        for connection in open { connection.cancel() }
    }
}

@Test func judasUnknownStoredPolicyFailsClosed() {
    #expect(JudasMode.restored(from: nil) == .configured)
    #expect(JudasMode.restored(from: "loopbackOnly") == .localNetworksOnly)
    #expect(JudasMode.restored(from: "invalid") == .blocked)
}

@Test func judasNamesConnectionsAndToolsWithoutLoggingUnsafeMetadata() throws {
    let judas = Judas()
    let origin = try #require(URL(string: "http://127.0.0.1:8001/private?api_key=secret"))
    try judas.authorize(origin, configuredOrigin: origin, source: .engine, name: "oMLX")
    judas.recordTool(.allowed, server: "Hindsight Memory", tool: "retain")
    judas.recordTool(.denied, server: "goat.pronk", tool: "pronk_adopt", isExtension: true)
    judas.recordTool(.allowed, server: "bad\nforged log", tool: "https://example.com?token=secret")
    judas.record(.memory, .completed, url: origin, name: String(repeating: "x", count: 129))
    let events = judas.drain().events
    #expect(events[0].destination == "oMLX · http://127.0.0.1:8001")
    #expect(events[1].destination == "Hindsight Memory · retain")
    #expect(events[2].destination == "goat.pronk · pronk_adopt")
    #expect(events[3].destination == "redacted name · redacted name")
    #expect(events[4].destination == "redacted name · http://127.0.0.1:8001")
    #expect(events.allSatisfy { !$0.destination.contains("secret") && !$0.destination.contains("\n") })
}

@Test func localNetworksIncludeThunderboltWithoutGrantingInternetOrDifferentOrigins() throws {
    let judas = Judas(mode: .localNetworksOnly)
    for address in [
        "http://192.168.253.1:8888", "http://10.0.0.2:8000", "http://172.31.255.254", "http://169.254.1.1",
        "http://[fd00::1]:8888", "http://[fe80::1]:8888",
    ] {
        let url = try #require(URL(string: address))
        try judas.authorize(url, configuredOrigin: url, source: .memory)
        #expect(!judas.authorizePreview(url, offGrid: true))
        #expect(throws: JudasError.self) {
            try judas.authorize(url, configuredOrigin: URL(string: "http://192.168.253.2:8888"), source: .memory)
        }
    }
    for address in ["http://8.8.8.8", "https://172.32.0.1", "https://192.169.0.1", "http://[2001:4860:4860::8888]"] {
        let url = try #require(URL(string: address))
        #expect(throws: JudasError.self) { try judas.authorize(url, configuredOrigin: url, source: .memory) }
    }
    let lan = try #require(URL(string: "http://192.168.253.1:8888"))
    judas.setMode(.blocked)
    #expect(throws: JudasError.self) { try judas.authorize(lan, configuredOrigin: lan, source: .memory) }
    #expect(JudasMode.restored(from: "loopbackOnly") == .localNetworksOnly)
    #expect(JudasMode.restored(from: "localNetworksOnly") == .localNetworksOnly)
}

@Test func localAddressClassificationRejectsPublicAndAmbiguousSpellings() {
    for host in [
        "localhost", "127.0.0.2", "10.255.255.255", "172.16.0.1", "172.31.255.254", "192.168.253.1", "169.254.1.1",
        "::1", "[::1]", "fc00::1", "fdff::1", "fe80::1%en0", "febf::1", "::ffff:192.168.253.1",
    ] {
        #expect(LocalNetworkAddress.contains(host: host))
    }
    for host in [
        "localhost.example.com", "192.168.253.1.example.com", "192.168.253.999", "192.168.001.1", "172.15.255.255",
        "172.32.0.0", "0.0.0.0", "100.64.0.1", "2130706433", "0x7f000001", "::", "fec0::1", "ff02::1", "2001:db8::1",
        "::ffff:8.8.8.8", "[fe80::1]evil", "fe80::1%", "fe80::1%en0%bad",
    ] {
        #expect(!LocalNetworkAddress.contains(host: host))
    }
}
