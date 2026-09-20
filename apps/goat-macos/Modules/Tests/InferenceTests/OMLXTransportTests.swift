import Foundation
import Network
import Testing

@testable import Inference

private actor StatusHTTPFixture {
    let listener: NWListener
    let queue = DispatchQueue(label: "goat.tests.omlx")
    var requests: [String] = []
    var connections: [NWConnection] = []
    let delay: Duration
    let unsupported: Bool

    init(delay: Duration = .zero, unsupported: Bool = false) throws {
        self.delay = delay
        self.unsupported = unsupported
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws -> URL {
        listener.newConnectionHandler = { connection in
            Task { await self.accept(connection) }
        }
        listener.start(queue: queue)
        for _ in 0..<200 {
            if let port = listener.port, port.rawValue > 0 {
                return try #require(URL(string: "http://127.0.0.1:\(port.rawValue)"))
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CocoaError(.fileReadUnknown)
    }

    func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        read(connection, previous: Data())
    }

    func read(_ connection: NWConnection, previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, complete, error in
            Task {
                let combined = previous + (data ?? Data())
                let text = String(decoding: combined, as: UTF8.self)
                if text.contains("\r\n\r\n") {
                    await self.reply(connection, request: text)
                } else if !complete, error == nil, combined.count < 16384 {
                    await self.read(connection, previous: combined)
                } else {
                    connection.cancel()
                }
            }
        }
    }

    func reply(_ connection: NWConnection, request: String) async {
        requests.append(request)
        try? await Task.sleep(for: delay)
        let authenticated = request.lowercased().contains("authorization: bearer fixture-key\r\n")
        let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let code = !authenticated ? 401 : unsupported && path != "/v1/models" ? 404 : 200
        let body: String
        switch path {
        case "/api/status": body = #"{"version":"0.6.4","active_requests":0,"waiting_requests":0}"#
        case "/v1/models/status":
            body = #"{"models":[{"id":"exact/Model","max_context_window":32000,"max_tokens":1000}]}"#
        case "/v1/models": body = #"{"data":[{"id":"exact/Model"}]}"#
        default: body = "{}"
        }
        let response = Data(
            "HTTP/1.1 \(code) Fixture\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
    }
}

@Test func omlxTransportAuthenticatesBothRoutesAndJoinsExactCatalogIdentity() async throws {
    let fixture = try StatusHTTPFixture()
    let url = try await fixture.start()
    let engine = OpenAICompatEngine(config: EngineConfig(baseURL: url, apiKey: "fixture-key", metadataDialect: .omlx))
    let status = await engine.runtimeStatus()
    #expect(status?.version == "0.6.4")
    #expect(status?.models?.first?.configuredOutputLimit == 1000)
    let catalog = await engine.health()
    #expect(catalog.models.first?.serverOutputLimit == 1000)
    #expect(catalog.models.first?.contextLength == 32000)
    let requests = await fixture.requests
    #expect(requests.contains { $0.hasPrefix("GET /api/status ") })
    #expect(requests.contains { $0.hasPrefix("GET /v1/models/status ") })
    #expect(requests.allSatisfy { $0.lowercased().contains("authorization: bearer fixture-key\r\n") })
    let unauthorized = OpenAICompatEngine(config: EngineConfig(baseURL: url, metadataDialect: .omlx))
    #expect(await unauthorized.runtimeStatus() == nil)
    await fixture.stop()
}

@Test func omlxTransportDiscardsStatusAfterConfigurationChanges() async throws {
    let fixture = try StatusHTTPFixture(delay: .milliseconds(150))
    let url = try await fixture.start()
    let engine = OpenAICompatEngine(config: EngineConfig(baseURL: url, apiKey: "fixture-key", metadataDialect: .omlx))
    let pending = Task { await engine.runtimeStatus() }
    for _ in 0..<100 {
        if await fixture.requests.count >= 2 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await fixture.requests.count >= 2)
    _ = await engine.update(config: EngineConfig(baseURL: url), revision: 1)
    #expect(await pending.value == nil)
    await fixture.stop()
}

@Test func oldOMLXWithoutOptionalRoutesRetainsHealthyGenericCatalog() async throws {
    let fixture = try StatusHTTPFixture(unsupported: true)
    let url = try await fixture.start()
    let engine = OpenAICompatEngine(config: EngineConfig(baseURL: url, apiKey: "fixture-key", metadataDialect: .omlx))
    #expect(await engine.runtimeStatus() == nil)
    let health = await engine.health()
    #expect(health.isOK)
    #expect(health.models.first?.id == "exact/Model")
    #expect(health.models.first?.serverOutputLimit == nil)
    await fixture.stop()
}
