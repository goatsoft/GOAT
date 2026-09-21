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

extension AppTests.Hindsight {
    @Suite struct HindsightBrowserTests {

        @Test func hindsightMapUsesServerLinksAndDropsDanglingEdges() throws {
            let data = Data(
                #"{"nodes":[{"data":{"id":"a","label":"First","text":"Full memory"}},{"data":{"id":"b","label":"Second"}}],"edges":[{"data":{"source":"a","target":"b","linkType":"semantic"}},{"data":{"source":"a","target":"b","linkType":"entity"}},{"data":{"source":"a","target":"missing","linkType":"temporal"}}],"total_units":200}"#
                    .utf8)
            let graph = try HindsightGraph.decode(data)
            #expect(graph.isHindsight)
            #expect(graph.isTruncated)
            #expect(graph.nodes.count == 2)
            #expect(graph.edges.count == 2)
            #expect(graph.nodes.first?.summary == "Full memory")
            #expect(graph.edges.first?.sourceID.rawValue == "hindsight:a")
            #expect(graph.nodes.allSatisfy { abs($0.position.x) <= 1 && abs($0.position.y) <= 1 })
            #expect(try HindsightGraph.decode(data) == graph)
        }

        @Test func hindsightMapRejectsDuplicateIDsAndOversizedGraphs() throws {
            let duplicate = Data(
                #"{"nodes":[{"data":{"id":"a","label":"One"}},{"data":{"id":"a","label":"Two"}}],"edges":[],"total_units":2}"#
                    .utf8)
            #expect(throws: (any Error).self) { try HindsightGraph.decode(duplicate) }
            let nodes = (0...HindsightGraph.maximumNodes).map { ["data": ["id": String($0), "label": "Memory"]] }
            let oversized = try JSONSerialization.data(withJSONObject: [
                "nodes": nodes, "edges": [], "total_units": nodes.count,
            ])
            #expect(throws: (any Error).self) { try HindsightGraph.decode(oversized) }
        }

        @Test func globalHindsightBankCannotReuseAPenRoute() {
            let serviceID = MemoryProviderID(rawValue: "hindsight-service")
            let connection = HindsightBankConnection(apiURL: "http://localhost:8888", bankID: "pen-bank")
            let service = MemoryProviderRecord(
                id: serviceID, displayName: "Hindsight", kind: .hindsight,
                hindsight: HindsightProviderConfiguration(connection: connection))
            let pen = MemoryProviderRecord(
                id: MemoryProviderID(rawValue: "pen-route"), displayName: "Pen", kind: .hindsight,
                hindsight: HindsightProviderConfiguration(
                    penRoute: HindsightPenBankRoute(serviceProviderID: serviceID, bankID: "pen-bank")))
            #expect(!MemoryModel.globalBankIsDedicated(connection, providers: [service, pen]))
            #expect(
                MemoryModel.globalBankIsDedicated(
                    HindsightBankConnection(apiURL: connection.apiURL, bankID: "goat-global"),
                    providers: [service, pen]))
            #expect(
                !MemoryModel.globalBankIsDedicated(
                    HindsightBankConnection(apiURL: "http://127.0.0.1:8888", bankID: "pen-bank"),
                    providers: [service, pen], replacingProviderID: serviceID))
        }

        @Test func hindsightUILinkUsesConfiguredHostWithoutAPIPathOrCredentials() {
            #expect(
                MemoryModel.hindsightUIURL(apiURL: "http://localhost:8888")?.absoluteString == "http://localhost:9999/")
            #expect(
                MemoryModel.hindsightUIURL(apiURL: "https://memory.example")?.absoluteString
                    == "https://memory.example:9999/")
            #expect(MemoryModel.hindsightUIURL(apiURL: "file:///tmp/memory") == nil)
            #expect(MemoryModel.hindsightUIURL(apiURL: "https://memory.example/api") == nil)
            #expect(MemoryModel.hindsightUIURL(apiURL: "https://user:secret@example.com") == nil)
        }

        @Test func denseHindsightMapHasItsOwnBoundedResponseBudget() throws {
            let nodes = (0..<49).map { ["data": ["id": String($0), "label": "Memory"]] }
            let edges = (0..<2_000).map { index in
                [
                    "data": [
                        "source": String(index / 49), "target": String(index % 49),
                        "linkType": "entity", "entityName": String(repeating: "e", count: 100),
                    ]
                ]
            }
            let data = try JSONSerialization.data(withJSONObject: ["nodes": nodes, "edges": edges, "total_units": 49])
            #expect(data.count > HindsightControlClient.maximumResponseBytes)
            let graph = try HindsightGraph.decode(data)
            #expect(graph.nodes.count == 49)
            #expect(graph.edges.count == HindsightGraph.maximumEdges)
            #expect(graph.isTruncated)
            #expect(throws: HindsightControlError.responseTooLarge) {
                try HindsightGraph.decode(Data(repeating: 32, count: HindsightGraph.maximumResponseBytes + 1))
            }
        }

        @Test func hindsightAssociationsKeepTheirTypesAndCausalMotionUsesCauseToEffect() throws {
            let payload: [String: Any] = [
                "nodes": ["a", "b"].map { ["data": ["id": $0, "label": $0]] },
                "edges": [
                    ["source": "a", "target": "b", "linkType": "semantic"],
                    ["source": "b", "target": "a", "linkType": "semantic"],
                    ["source": "a", "target": "b", "linkType": "temporal"],
                    ["source": "a", "target": "b", "linkType": "entity"],
                    ["source": "a", "target": "b", "linkType": "caused_by"],
                    ["source": "a", "target": "b", "linkType": "future-relation"],
                ].map { ["data": $0] },
                "total_units": 2,
            ]
            let graph = try HindsightGraph.decode(JSONSerialization.data(withJSONObject: payload))
            #expect(graph.edges.count == 5)
            for type in [MemoryGraphRelationship.semantic, .temporal, .entity] {
                let edge = try #require(graph.edges.first { $0.relationship == type })
                #expect(edge.flows.count == 2)
                #expect(Set(edge.flows.map(\.fromID)) == Set(graph.nodes.map(\.id)))
            }
            let causal = try #require(graph.edges.first { $0.relationship == .causedBy })
            #expect(causal.sourceID.rawValue == "hindsight:a")  // Stored effect remains unchanged.
            #expect(causal.flows == [MemoryGraphFlow(fromID: causal.targetID, toID: causal.sourceID)])
            #expect(graph.edges.first { $0.relationship == .unknown }?.flows.isEmpty == true)
            #expect(MemoryGraphRelationship.hindsightType("wikiLink") == .unknown)
        }

        @Test func directedGraphTracersFollowCitationsAndLegacyCausalMeaning() {
            let source = MemoryEntryID(rawValue: "source")
            let target = MemoryEntryID(rawValue: "target")
            for type in [MemoryGraphRelationship.wikiLink, .citation, .causes, .enables, .prevents] {
                let edge = MemoryGraphEdge(
                    sourceID: source, targetID: target, directLink: type != .citation, relationship: type)
                #expect(edge.flows == [MemoryGraphFlow(fromID: source, toID: target)])
            }
        }

        @Test func graphTracersRespectTheirBudgetFocusAndBothDirectionsOfAssociations() {
            let ids = (0..<30).map { MemoryEntryID(rawValue: String($0)) }
            let edges = ids.dropFirst().map {
                MemoryGraphEdge(sourceID: ids[0], targetID: $0, directLink: true, relationship: .semantic)
            }
            let flows = MemoryGraphFlow.preview(edges: edges + edges, visibleIDs: Set(ids), focus: ids[0])
            #expect(MemoryGraphFlow.preview(edges: edges, visibleIDs: Set(ids), focus: nil).isEmpty)
            #expect(flows.count == MemoryGraphFlow.maximumDots)
            #expect(Set(flows).count == flows.count)
            #expect(flows.allSatisfy { flows.contains(MemoryGraphFlow(fromID: $0.toID, toID: $0.fromID)) })
            let focused = MemoryGraphFlow.preview(edges: edges, visibleIDs: Set(ids), focus: ids[1])
            #expect(focused.count == 2)
            #expect(focused.allSatisfy { $0.fromID == ids[1] || $0.toID == ids[1] })
            #expect(MemoryGraphFlow.preview(edges: edges, visibleIDs: [ids[0]], focus: ids[0]).isEmpty)
        }
    }
}

private func resolvedMemoryModelTemporaryDirectory() throws -> URL {
    let temporaryPath = FileManager.default.temporaryDirectory.path
    var resolvedPath = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard temporaryPath.withCString({ Darwin.realpath($0, &resolvedPath) }) != nil else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let bytes = resolvedPath.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
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

extension AppTests.Hindsight {
    @Suite struct HindsightClientTests {

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
            let old = Task {
                await client.bind(providerID: healthTestID, connection: healthTestConnection, apiToken: nil)
            }
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
            let pending = Task {
                await client.bind(providerID: healthTestID, connection: healthTestConnection, apiToken: nil)
            }
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
            let view = Task {
                await client.bind(providerID: healthTestID, connection: healthTestConnection, apiToken: nil)
            }
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
    }
}
