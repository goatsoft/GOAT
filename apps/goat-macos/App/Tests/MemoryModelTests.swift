import Darwin
import Foundation
import Testing

@testable import Bleet
@testable import GOAT
@testable import Hindsight
@testable import Hoofprint
@testable import MCPClient
@testable import Memory
@testable import Shepherd
@testable import Tools

private func resolvedMemoryModelTemporaryDirectory() throws -> URL {
    let temporaryPath = FileManager.default.temporaryDirectory.path
    var resolvedPath = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard temporaryPath.withCString({ Darwin.realpath($0, &resolvedPath) }) != nil else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let bytes = resolvedPath.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
}

@MainActor
@Test func rememberActionUsesTheMessagesPenSetting() async throws {
    let model = AppModel.shared
    await model.memory.load()
    let originalChats = model.chats
    let originalConfiguration = model.memory.configuration
    defer {
        model.chats = originalChats
        model.memory.configuration = originalConfiguration
    }
    model.memory.configuration = .fresh
    let session = ChatSession(effort: .trot, modelID: "test", projectID: UUID())
    let message = ChatMessage(role: .assistant)
    message.text = "A fact to remember."
    message.complete = true
    session.messages = [message]
    model.chats = [session]

    #expect(model.memory.isEnabled)
    #expect(!model.canRemember(message, projectID: session.projectID))
    model.remember(message)
    #expect(model.messageMemorySaves[message.id] == nil)

    // Moving the same message to Global must update availability without changing selection.
    session.projectID = nil
    #expect(model.canRemember(message, projectID: session.projectID))
    message.complete = false
    #expect(!model.canRemember(message, projectID: session.projectID))
    message.complete = true
    session.messages = []
    model.remember(message)
    #expect(model.messageMemorySaves[message.id] == nil)
}

@MainActor
@Test func invalidMemoryConfigurationExposesNoMemoryCapability() async throws {
    let root = try resolvedMemoryModelTemporaryDirectory()
        .appendingPathComponent("goat-memory-model-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let configuration = root.appendingPathComponent("memory.json", isDirectory: false)
    let marker = root.appendingPathComponent("memory.marker", isDirectory: false)
    try "{ invalid JSON".write(to: configuration, atomically: true, encoding: .utf8)
    let store = MemoryConfigurationStore(configurationURL: configuration, markerURL: marker)
    let model = MemoryModel(activity: ActivityLog(), configurationStore: store)

    await model.load()

    #expect(model.configurationLoadState == .failed)
    #expect(!model.isEnabled)
    #expect(!model.isEnabled(forProjectID: nil))
    let entries = try await model.promptEntries(forProjectID: nil)
    #expect(entries.isEmpty)
}

@MainActor
@Test func newPenMemoryIsOffUntilExplicitlyEnabled() async throws {
    let root = try resolvedMemoryModelTemporaryDirectory()
        .appendingPathComponent("goat-memory-model-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = MemoryConfigurationStore(
        configurationURL: root.appendingPathComponent("memory.json"),
        markerURL: root.appendingPathComponent("memory.marker"))
    let model = MemoryModel(activity: ActivityLog(), configurationStore: store)
    let penID = UUID()

    await model.load()

    #expect(model.isEnabled(forProjectID: nil))
    #expect(!model.penMemoryIsEnabled(forProjectID: penID))
    #expect(!model.isEnabled(forProjectID: penID))

    await model.setEnabled(true, forProjectID: penID, projectName: "Test Pen")

    #expect(model.penMemoryIsEnabled(forProjectID: penID))
    #expect(model.isEnabled(forProjectID: penID))
    #expect(model.configuration.pens[penID.uuidString]?.selection == .explicit(.localWiki))
}

@MainActor
@Test func providerChangeLeavesExistingPenOffUntilExplicitRebind() async throws {
    let root = try resolvedMemoryModelTemporaryDirectory()
        .appendingPathComponent("goat-memory-model-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = MemoryConfigurationStore(
        configurationURL: root.appendingPathComponent("memory.json"),
        markerURL: root.appendingPathComponent("memory.marker"))
    let initial = try store.loadOrInitialize()
    let penID = UUID()
    var configuration = initial.configuration
    configuration.global = GlobalMemoryBinding(
        providerID: .llmWiki,
        history: [.llmWiki, .localWiki])
    configuration.defaultPenProviderID = .llmWiki
    configuration.pens[penID.uuidString] = PenMemoryBinding(
        selection: .explicit(.localWiki),
        history: [.localWiki])
    _ = try store.save(configuration, ifRevision: initial.revision)
    let model = MemoryModel(activity: ActivityLog(), configurationStore: store)

    await model.load()

    #expect(!model.penMemoryIsEnabled(forProjectID: penID))
    #expect(!model.isEnabled(forProjectID: penID))

    await model.setEnabled(true, forProjectID: penID, projectName: "Test Pen")

    #expect(model.penMemoryIsEnabled(forProjectID: penID))
    #expect(model.configuration.pens[penID.uuidString]?.selection == .explicit(.llmWiki))
    #expect(model.configuration.pens[penID.uuidString]?.history == [.llmWiki, .localWiki])
}

@Test func hindsightContractRequiresOfficialBankScopedTools() throws {
    let tools = HindsightProviderContract.requiredToolNames.sorted().map {
        MCPToolInfo(name: $0, description: "managed", inputSchemaJSON: #"{ "type": "object" }"#)
    }

    #expect(HindsightProviderContract.requiredToolNames.contains("get_bank"))
    #expect(HindsightProviderContract.requiredToolNames.contains("list_memories"))
    #expect(HindsightProviderContract.requiredToolNames.contains("get_memory"))
    #expect(HindsightProviderContract.requiredToolNames.contains("retain"))
    try HindsightProviderContract.validate(tools)
    #expect(throws: (any Error).self) {
        try HindsightProviderContract.validate(Array(tools.dropFirst()))
    }
}

@Test func hindsightBankDiscoveryDecodesBoundedOfficialResponse() throws {
    let data = Data(
        #"{"banks":[{"bank_id":"goat","name":"GOAT","fact_count":3},{"bank_id":"empty","name":null}],"total":2,"limit":100,"offset":0}"#
            .utf8)

    let banks = try HindsightControlClient.decodeBankList(data)

    #expect(
        banks == [
            HindsightBankSummary(bankID: "goat", name: "GOAT", factCount: 3),
            HindsightBankSummary(bankID: "empty", name: nil, factCount: 0),
        ])
}

@Test func hindsightBankDiscoveryRejectsMalformedOrOversizedLists() throws {
    #expect(throws: HindsightControlError.invalidResponse) {
        try HindsightControlClient.decodeBankList(Data(#"{"banks":[]}"#.utf8))
    }
    #expect(throws: HindsightControlError.responseTooLarge) {
        try HindsightControlClient.decodeBankList(
            Data(#"{"banks":[],"total":501,"limit":100,"offset":0}"#.utf8))
    }
    #expect(throws: HindsightControlError.invalidResponse) {
        try HindsightControlClient.decodeBankList(
            Data(
                #"{"banks":[{"bank_id":"same"},{"bank_id":"same"}],"total":2,"limit":100,"offset":0}"#.utf8))
    }
}

@Test func hindsightTemplateValidationRequiresVersionOneAndBounds() throws {
    let valid = #"{"version":"1","bank":{},"mental_models":[]}"#
    #expect(try HindsightControlClient.validatedTemplateData(valid) == Data(valid.utf8))
    #expect(throws: HindsightControlError.invalidConfiguration) {
        try HindsightControlClient.validatedTemplateData(#"{"version":"2","bank":{}}"#)
    }
    #expect(throws: HindsightControlError.invalidConfiguration) {
        try HindsightControlClient.validatedTemplateData(
            #"{"version":"1","padding":""#
                + String(repeating: "x", count: HindsightControlClient.maximumTemplateBytes)
                + #""}"#)
    }
}

@Test func hindsightExistingBankCanSubmitBeforeSeparateBankTest() {
    #expect(
        HindsightConnectionValidation.canSubmitExistingBank(
            serverTestPassed: true,
            bankID: "test"))
    #expect(
        !HindsightConnectionValidation.canSubmitExistingBank(
            serverTestPassed: false,
            bankID: "test"))
    #expect(
        !HindsightConnectionValidation.canSubmitExistingBank(
            serverTestPassed: true,
            bankID: "Invalid Bank"))
}

@Test func hindsightManagedMCPIdentitySatisfiesServerNameBounds() throws {
    let config = MCPServerConfig(
        name: HindsightProviderClient.managedServerName,
        transport: .http(
            url: try #require(URL(string: "http://localhost:8888/mcp/test/")),
            headers: [:]))

    try config.validate()
    #expect(config.name == "goat-hindsight")
}

@Test func hindsightAcceptsAThunderboltPrivateNetworkAddress() throws {
    #expect(
        try HindsightProviderClient.validatedBaseURL("http://192.168.253.1:8888")
            == URL(string: "http://192.168.253.1:8888"))
    #expect(throws: (any Error).self) {
        _ = try HindsightProviderClient.validatedBaseURL("http://hindsight.example.com")
    }

    let config = MCPServerConfig(
        name: HindsightProviderClient.managedServerName,
        transport: .http(
            url: try #require(URL(string: "http://192.168.253.1:8888/mcp/test/")),
            headers: [:]),
        allowsPrivateNetworkHTTP: true)
    try config.validate()
}

@Test func hindsightRetriesReadsButDoesNotReplayUnacknowledgedWrites() {
    #expect(HindsightProviderClient.canRetryAfterTransportFailure("get_bank"))
    #expect(HindsightProviderClient.canRetryAfterTransportFailure("list_memories"))
    #expect(HindsightProviderClient.canRetryAfterTransportFailure("recall"))
    #expect(!HindsightProviderClient.canRetryAfterTransportFailure("retain"))
}

@Test func hindsightSessionRetentionUsesOneStableDocumentPerChat() throws {
    let chatID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
    let request = MemoryRememberRequest(
        idempotencyKey: chatID,
        title: "Transcript",
        summary: "Completed chat",
        content: "User: hello",
        context: MemoryContext(),
        kind: .session)

    #expect(
        HindsightMemoryStore.documentID(for: request)
            == "goat-session-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
}

@Test func persistedTranscriptKeepsRecentTurnsWithinTheRetentionBound() throws {
    let chatID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
    let messages = [
        ShepherdPersistedTurn.Message(role: .user, text: String(repeating: "old ", count: 3_000)),
        ShepherdPersistedTurn.Message(role: .assistant, text: "old answer"),
        ShepherdPersistedTurn.Message(role: .user, text: "latest request"),
        ShepherdPersistedTurn.Message(role: .assistant, text: "latest answer 🐐"),
    ]
    let turn = ShepherdPersistedTurn(
        chatID: chatID,
        projectID: nil,
        commandMessageID: nil,
        title: "Bounded chat",
        createdAt: Date(timeIntervalSince1970: 0),
        kind: .regular,
        messages: messages)

    let rendered = MemoryModel.persistedTranscript(turn, maximumBytes: 1_024)

    #expect(rendered.utf8.count <= 1_024)
    #expect(rendered.contains("Earlier completed exchanges omitted"))
    #expect(rendered.contains("latest request"))
    #expect(rendered.contains("latest answer 🐐"))
}

@Test func hindsightPenBankIDsAreStableScopedAndBounded() throws {
    let id = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))

    #expect(
        HindsightBankDefaults.penBankID(name: "My Fancy Pen!", id: id)
            == "goat-my-fancy-pen-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    #expect(
        HindsightBankDefaults.penBankID(name: "   🐐   ", id: id)
            == "goat-pen-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")

    let longID = HindsightBankDefaults.penBankID(
        name: String(repeating: "A long Pen name ", count: 20),
        id: id)
    #expect(longID.utf8.count <= 128)
    #expect(
        longID.utf8.allSatisfy { byte in
            (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45
        })
}

@Test func hindsightStructuredResponsesHaveASeparateBoundedAllowance() throws {
    let json = "{\"text\":\"" + String(repeating: "a", count: 64_000) + "\"}"
    try HindsightProviderClient.validateJSON(json)
    #expect(throws: (any Error).self) {
        try HindsightProviderClient.validateJSON(json + "\n… (truncated)")
    }
    #expect(throws: (any Error).self) {
        try HindsightProviderClient.validateJSON(
            String(repeating: "a", count: HindsightProviderClient.maximumResponseBytes + 1))
    }
    #expect(throws: (any Error).self) { try HindsightProviderClient.validateJSON("not JSON") }
}

/// Controllable transport: exercises client/session ownership without contacting a memory bank.
private actor HindsightHealthTransport: HindsightSessionTransport {
    var connections = 0
    var disconnects = 0
    var rejectLists = false
    var failNextTool: String?
    var calls: [String: Int] = [:]
    var rejectConnections = false
    var holdNextBankCheck = false
    var heldCheck: CheckedContinuation<Void, Never>?
    var capability: MCPServerManager.CapabilityToken?
    let tools = HindsightProviderContract.requiredToolNames.sorted().map {
        MCPToolInfo(name: $0, description: $0, inputSchemaJSON: "{}")
    }
    func connect(_ config: MCPServerConfig) async -> MCPServerManager.State {
        connections += 1
        try? await Task.sleep(for: .milliseconds(40))
        if rejectConnections { return .init(status: .failed, tools: [], error: "Offline") }
        capability = .init(permissionFingerprint: config.permissionFingerprint, connectionGeneration: UUID())
        return .init(status: .connected, tools: tools, error: nil)
    }
    func disconnect(name: String) {
        disconnects += 1
        capability = nil
    }
    func capabilitySnapshots() -> [String: MCPServerManager.CapabilitySnapshot] {
        guard let capability else { return [:] }
        return [HindsightProviderClient.managedServerName: .init(token: capability, tools: tools)]
    }
    func invoke(
        server: String, tool: String, argumentsJSON: String,
        capability: MCPServerManager.CapabilityToken, maximumResultBytes: Int
    ) async throws -> ToolResult {
        guard self.capability == capability else { throw MCPError.notConnected(server) }
        calls[tool, default: 0] += 1
        if failNextTool == tool {
            failNextTool = nil
            self.capability = nil
            throw MCPError.timeout
        }
        if tool == "get_bank", holdNextBankCheck {
            holdNextBankCheck = false
            await withCheckedContinuation { heldCheck = $0 }
        }
        if tool == "list_memories", rejectLists { return ToolResult(content: "Bank is processing", isError: true) }
        return ToolResult(content: tool == "list_memories" ? "{\"items\":[]}" : "{}")
    }
    func setRejectLists(_ value: Bool) { rejectLists = value }
    func failTransportOnce(for tool: String) { failNextTool = tool }
    func setRejectConnections(_ value: Bool) { rejectConnections = value }
    func holdCheck() { holdNextBankCheck = true }
    func releaseCheck() {
        heldCheck?.resume()
        heldCheck = nil
    }
    func waitForHeldCheck() async throws {
        for _ in 0..<200 {
            if heldCheck != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MCPError.timeout
    }
}

private let healthTestID = MemoryProviderID(rawValue: "hindsight-00000000-0000-0000-0000-000000000075")
private let healthTestConnection = HindsightBankConnection(apiURL: "http://127.0.0.1:8888", bankID: "goat-health-test")

@Test func hindsightConcurrentChecksShareOneHandshake() async {
    let transport = HindsightHealthTransport()
    let client = HindsightProviderClient(transport: transport)
    let ready = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<12 {
            group.addTask {
                if case .success = await client.bind(
                    providerID: healthTestID, connection: healthTestConnection, apiToken: nil)
                {
                    return true
                }
                return false
            }
        }
        var allReady = true
        for await result in group { allReady = allReady && result }
        return allReady
    }
    #expect(ready)
    #expect(await transport.connections == 1)
    #expect(await transport.disconnects == 0)
    _ = await client.bind(providerID: healthTestID, connection: healthTestConnection, apiToken: nil)
    #expect(await transport.connections == 1, "A healthy check must reuse the live connection")
}

@Test func hindsightLateHealthCheckCannotReplaceANewerBank() async throws {
    let transport = HindsightHealthTransport()
    let client = HindsightProviderClient(transport: transport)
    _ = await client.bind(providerID: healthTestID, connection: healthTestConnection, apiToken: nil)
    await transport.holdCheck()
    let old = Task { await client.bind(providerID: healthTestID, connection: healthTestConnection, apiToken: nil) }
    try await transport.waitForHeldCheck()
    let changed = HindsightBankConnection(apiURL: healthTestConnection.apiURL, bankID: "new-bank")
    _ = await client.bind(providerID: healthTestID, connection: changed, apiToken: nil)
    await transport.releaseCheck()
    _ = await old.value
    let status = await client.status(for: healthTestID)
    #expect(status.state == .ready)
    #expect(status.bankID == "new-bank")
    #expect(await transport.disconnects == 0)
}

@Test func hindsightDisconnectDuringHealthCheckCannotResurrectSession() async throws {
    let transport = HindsightHealthTransport()
    let client = HindsightProviderClient(transport: transport)
    _ = await client.bind(providerID: healthTestID, connection: healthTestConnection, apiToken: nil)
    await transport.holdCheck()
    let pending = Task { await client.bind(providerID: healthTestID, connection: healthTestConnection, apiToken: nil) }
    try await transport.waitForHeldCheck()
    await client.disconnect()
    await transport.releaseCheck()
    _ = await pending.value
    #expect(await client.status(for: healthTestID).state == .unavailable)
}

@Test func hindsightCancelledViewDoesNotCancelSharedHealthCheck() async throws {
    let transport = HindsightHealthTransport()
    let client = HindsightProviderClient(transport: transport)
    _ = await client.bind(providerID: healthTestID, connection: healthTestConnection, apiToken: nil)
    await transport.holdCheck()
    let view = Task { await client.bind(providerID: healthTestID, connection: healthTestConnection, apiToken: nil) }
    try await transport.waitForHeldCheck()
    view.cancel()
    await transport.releaseCheck()
    _ = await view.value
    #expect(await client.status(for: healthTestID).state == .ready)
    #expect(await transport.disconnects == 0)
}

@MainActor @Test func hindsightRequestFailureDoesNotPoisonProviderHealthAndOfflineRecovers() async throws {
    let root = try resolvedMemoryModelTemporaryDirectory().appendingPathComponent("goat-health-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaultsName = "goat-health-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let transport = HindsightHealthTransport()
    let client = HindsightProviderClient(transport: transport)
    let model = MemoryModel(
        activity: ActivityLog(),
        configurationStore: MemoryConfigurationStore(
            configurationURL: root.appendingPathComponent("memory.json"),
            markerURL: root.appendingPathComponent("marker")),
        builtInSettings: BuiltInExtensionSettings(defaults: defaults), hindsightClientFactory: { client })
    await model.load()
    model.configuration.providers.append(
        MemoryProviderRecord(
            id: healthTestID, displayName: "Hindsight", kind: .hindsight,
            hindsight: HindsightProviderConfiguration(connection: healthTestConnection)))
    model.configuration.global.providerID = healthTestID
    _ = await model.testHindsight(healthTestID)
    #expect(model.isProviderAvailable(healthTestID))
    await transport.setRejectLists(true)
    do {
        _ = try await model.promptEntries(forProjectID: nil)
        Issue.record("Expected the individual memory request to fail")
    } catch {}
    #expect(model.isProviderAvailable(healthTestID), "A busy bank must not disable the saved provider")
    await transport.setRejectLists(false)
    #expect(try await model.promptEntries(forProjectID: nil).isEmpty)
    await client.disconnect()
    await model.recoverHindsightIfNeeded(forProjectID: nil)
    await transport.setRejectConnections(true)
    _ = await model.testHindsight(healthTestID)
    #expect(!model.isProviderAvailable(healthTestID))
    await transport.setRejectConnections(false)
    // Explicit retry bypasses the brief backoff after the endpoint recovers.
    _ = await model.testHindsight(healthTestID)
    #expect(model.isProviderAvailable(healthTestID))
    await model.setHindsightExtensionEnabled(false)
    await model.recoverHindsightIfNeeded(forProjectID: nil)
    #expect(!model.isProviderAvailable(healthTestID), "Recovery must not bypass a disabled extension")
}

@Test func hindsightRecoveredReadRejectionKeepsSessionHealthyAndWritesAreNotReplayed() async throws {
    let transport = HindsightHealthTransport()
    let client = HindsightProviderClient(transport: transport)
    _ = await client.bind(providerID: healthTestID, connection: healthTestConnection, apiToken: nil)
    await transport.setRejectLists(true)
    await transport.failTransportOnce(for: "list_memories")
    do {
        _ = try await client.invoke(providerID: healthTestID, tool: "list_memories", argumentsJSON: "{}")
        Issue.record("Expected the retried read to report its tool error")
    } catch {}
    #expect(await client.status(for: healthTestID).state == .ready)
    #expect(await transport.calls["list_memories"] == 2)
    await transport.failTransportOnce(for: "retain")
    do {
        _ = try await client.invoke(providerID: healthTestID, tool: "retain", argumentsJSON: "{}")
        Issue.record("An unacknowledged write must be reported")
    } catch {}
    #expect(await transport.calls["retain"] == 1, "Never replay a write that the server may have accepted")
    #expect(await client.status(for: healthTestID).state == .ready)
}
