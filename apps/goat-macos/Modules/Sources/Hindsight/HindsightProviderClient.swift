import Foundation
import Herd
import JUDAS
import MCPClient
import Memory
import Tools

public struct HindsightBankSummary: Decodable, Identifiable, Sendable, Equatable {
    public let bankID: String
    public let name: String?
    public let factCount: Int

    public var id: String { bankID }

    enum CodingKeys: String, CodingKey {
        case bankID = "bank_id"
        case name
        case factCount = "fact_count"
    }

    public init(bankID: String, name: String?, factCount: Int) {
        self.bankID = bankID
        self.name = name
        self.factCount = factCount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bankID = try values.decode(String.self, forKey: .bankID)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        factCount = try values.decodeIfPresent(Int.self, forKey: .factCount) ?? 0
    }
}

public enum HindsightBankDefaults {
    public static let globalBankID = "goat-global"
    public static let goatTemplate = #"""
        {
          "version": "1",
          "bank": {
            "retain_mission": "Preserve durable user preferences, ongoing goals, decisions, and useful conversational context. Ignore greetings, transient status, and boilerplate.",
            "reflect_mission": "Use durable memories to help GOAT answer consistently while distinguishing remembered facts from inference.",
            "enable_observations": true,
            "observations_mission": "Track stable user preferences, recurring goals, and decisions without treating temporary conversation details as permanent."
          },
          "mental_models": [
            {
              "id": "goat-user-context",
              "name": "GOAT User Context",
              "source_query": "What stable preferences, goals, constraints, and important decisions should GOAT remember about the user?",
              "max_tokens": 2048,
              "trigger": { "refresh_after_consolidation": true }
            }
          ]
        }
        """#

    public static func penBankID(name: String, id: UUID) -> String {
        let folded = name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
        var slugBytes: [UInt8] = []
        var lastWasSeparator = true
        for byte in folded.lowercased().utf8 {
            let isLetterOrDigit = (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
            if isLetterOrDigit {
                guard slugBytes.count < 80 else { break }
                slugBytes.append(byte)
                lastWasSeparator = false
            } else if !lastWasSeparator, slugBytes.count < 80 {
                slugBytes.append(45)
                lastWasSeparator = true
            }
        }
        while slugBytes.last == 45 { slugBytes.removeLast() }
        let slug = slugBytes.isEmpty ? "pen" : String(decoding: slugBytes, as: UTF8.self)
        return "goat-\(slug)-\(id.uuidString.lowercased())"
    }
}

public enum HindsightControlError: LocalizedError, Equatable {
    case invalidConfiguration
    case bankAlreadyExists
    case responseTooLarge
    case invalidResponse
    case unauthorized
    case server(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The Hindsight server, bank, key, or template is invalid."
        case .bankAlreadyExists: "A Hindsight bank with that ID already exists. Select it instead."
        case .responseTooLarge: "The Hindsight server returned too much data."
        case .invalidResponse: "The Hindsight server returned an unexpected response."
        case .unauthorized: "The Hindsight server rejected this API key."
        case .server(let status): "The Hindsight server returned HTTP \(status)."
        }
    }
}

/// Bounded access to Hindsight's official bank control-plane endpoints. This client is used only
/// from explicit Settings actions, and it never exposes bank deletion.
public actor HindsightControlClient {
    public static let maximumResponseBytes = 256 * 1_024
    public static let maximumTemplateBytes = 64 * 1_024
    public static let maximumBankCount = 500

    private struct BankListResponse: Decodable {
        let banks: [HindsightBankSummary]
        let total: Int
    }

    public init() {}

    public func listBanks(apiURL: String, apiToken: String?) async throws -> [HindsightBankSummary] {
        let base = try HindsightProviderClient.validatedBaseURL(apiURL)
        var banks: [HindsightBankSummary] = []
        var total = 0
        repeat {
            var components = URLComponents(
                url: base.appendingPathComponent("v1/default/banks", isDirectory: false),
                resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "offset", value: String(banks.count)),
            ]
            guard let url = components?.url else { throw HindsightControlError.invalidConfiguration }
            let data = try await send(
                request(url: url, method: "GET", apiToken: apiToken),
                expectedStatus: 200..<300)
            let response = try Self.decodeBanks(data)
            total = response.total
            guard total >= 0, total <= Self.maximumBankCount,
                response.banks.count <= 100,
                !response.banks.isEmpty || banks.count >= total
            else { throw HindsightControlError.responseTooLarge }
            banks.append(contentsOf: response.banks)
            guard banks.count <= total, banks.count <= Self.maximumBankCount,
                Set(banks.map(\.bankID)).count == banks.count
            else {
                throw HindsightControlError.invalidResponse
            }
        } while banks.count < total
        return banks
    }

    public func createBank(
        apiURL: String,
        bankID: String,
        apiToken: String?,
        templateJSON: String?
    ) async throws {
        let connection = HindsightBankConnection(apiURL: apiURL, bankID: bankID)
        let base = try HindsightProviderClient.validatedBaseURL(connection)
        let banks = try await listBanks(apiURL: apiURL, apiToken: apiToken)
        guard !banks.contains(where: { $0.bankID == bankID }) else {
            throw HindsightControlError.bankAlreadyExists
        }
        let bankURL =
            base
            .appendingPathComponent("v1/default/banks", isDirectory: true)
            .appendingPathComponent(bankID, isDirectory: false)

        if let templateJSON {
            let body = try Self.validatedTemplateData(templateJSON)
            var dryRunComponents = URLComponents(
                url: bankURL.appendingPathComponent("import", isDirectory: false),
                resolvingAgainstBaseURL: false)
            dryRunComponents?.queryItems = [URLQueryItem(name: "dry_run", value: "true")]
            guard let dryRunURL = dryRunComponents?.url else {
                throw HindsightControlError.invalidConfiguration
            }
            _ = try await send(
                request(url: dryRunURL, method: "POST", apiToken: apiToken, body: body),
                expectedStatus: 200..<300)
            let refreshedBanks = try await listBanks(apiURL: apiURL, apiToken: apiToken)
            guard !refreshedBanks.contains(where: { $0.bankID == bankID }) else {
                throw HindsightControlError.bankAlreadyExists
            }
            _ = try await send(
                request(
                    url: bankURL.appendingPathComponent("import", isDirectory: false),
                    method: "POST",
                    apiToken: apiToken,
                    body: body),
                expectedStatus: 200..<300)
        } else {
            _ = try await send(
                request(url: bankURL, method: "PUT", apiToken: apiToken, body: Data("{}".utf8)),
                expectedStatus: 200..<300)
        }
    }

    /// Deterministically provisions a GOAT-owned scope bank. Existing banks are reused without
    /// mutation; a creation race is also treated as success because the ID is the route identity.
    public func ensureBank(
        apiURL: String,
        bankID: String,
        apiToken: String?,
        templateJSON: String
    ) async throws {
        let banks = try await listBanks(apiURL: apiURL, apiToken: apiToken)
        guard !banks.contains(where: { $0.bankID == bankID }) else { return }
        do {
            try await createBank(
                apiURL: apiURL,
                bankID: bankID,
                apiToken: apiToken,
                templateJSON: templateJSON)
        } catch HindsightControlError.bankAlreadyExists {
            return
        }
    }

    public func graph(connection: HindsightBankConnection, apiToken: String?) async throws -> Data {
        let base = try HindsightProviderClient.validatedBaseURL(connection)
        let endpoint = base.appendingPathComponent("v1/default/banks")
            .appendingPathComponent(connection.bankID).appendingPathComponent("graph")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: String(HindsightLimits.graphNodes))]
        guard let url = components?.url else { throw HindsightControlError.invalidConfiguration }
        return try await send(
            request(url: url, method: "GET", apiToken: apiToken), expectedStatus: 200..<300,
            maximumBytes: HindsightLimits.graphBytes)
    }

    public func knowledge(connection: HindsightBankConnection, apiToken: String?, id: String? = nil) async throws
        -> Data
    {
        let base = try HindsightProviderClient.validatedBaseURL(connection)
        var endpoint = base.appendingPathComponent("v1/default/banks")
            .appendingPathComponent(connection.bankID).appendingPathComponent("mental-models")
        if let id {
            guard HindsightLimits.validKnowledgeID(id) else { throw HindsightControlError.invalidConfiguration }
            endpoint.appendPathComponent(id)
        }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems =
            id == nil
            ? [
                URLQueryItem(name: "detail", value: "full"),
                URLQueryItem(name: "limit", value: String(HindsightLimits.knowledgePages)),
            ]
            : [URLQueryItem(name: "detail", value: "content")]
        guard let url = components?.url else { throw HindsightControlError.invalidConfiguration }
        return try await send(
            request(url: url, method: "GET", apiToken: apiToken), expectedStatus: 200..<300,
            maximumBytes: HindsightLimits.knowledgeBytes)
    }

    private func request(
        url: URL,
        method: String,
        apiToken: String?,
        body: Data? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let apiToken, !apiToken.isEmpty {
            guard apiToken.utf8.count <= 4 * 1_024,
                !apiToken.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
            else { throw HindsightControlError.invalidConfiguration }
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(
        _ request: URLRequest,
        expectedStatus: Range<Int>,
        maximumBytes: Int = HindsightControlClient.maximumResponseBytes
    ) async throws -> Data {
        guard let origin = request.url else { throw HindsightControlError.invalidConfiguration }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = JudasHTTPClient(origin: origin, source: .memory, name: "Hindsight", configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else {
            throw HindsightControlError.invalidResponse
        }
        guard expectedStatus.contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw HindsightControlError.unauthorized
            }
            throw HindsightControlError.server(response.statusCode)
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            throw HindsightControlError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 16 * 1_024))
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw HindsightControlError.responseTooLarge
            }
            data.append(byte)
        }
        return data
    }

    nonisolated static func decodeBankList(_ data: Data) throws -> [HindsightBankSummary] {
        let response = try decodeBanks(data)
        guard response.total >= 0, response.banks.count <= response.total,
            Set(response.banks.map(\.bankID)).count == response.banks.count
        else {
            throw HindsightControlError.invalidResponse
        }
        guard response.total <= maximumBankCount, response.banks.count <= 100 else {
            throw HindsightControlError.responseTooLarge
        }
        return response.banks
    }

    private nonisolated static func decodeBanks(_ data: Data) throws -> BankListResponse {
        guard data.count <= maximumResponseBytes else { throw HindsightControlError.responseTooLarge }
        do {
            let response = try JSONDecoder().decode(BankListResponse.self, from: data)
            guard response.banks.allSatisfy(validBankSummary) else {
                throw HindsightControlError.invalidResponse
            }
            return response
        } catch let error as HindsightControlError {
            throw error
        } catch {
            throw HindsightControlError.invalidResponse
        }
    }

    private nonisolated static func validBankSummary(_ bank: HindsightBankSummary) -> Bool {
        !bank.bankID.isEmpty && bank.bankID.utf8.count <= 128
            && !bank.bankID.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
            && bank.factCount >= 0
            && (bank.name?.utf8.count ?? 0) <= 512
            && !(bank.name?.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) ?? false)
    }

    public nonisolated static func validatedTemplateData(_ value: String) throws -> Data {
        guard let data = value.data(using: .utf8), data.count <= maximumTemplateBytes,
            let object = try? JSONSerialization.jsonObject(with: data),
            let manifest = object as? [String: Any],
            manifest["version"] as? String == "1"
        else { throw HindsightControlError.invalidConfiguration }
        return data
    }
}

/// GOAT uses Hindsight's official, single-bank Streamable HTTP MCP endpoint. The bank is part of
/// that endpoint's path, so no process directory can influence where memory is read or written.
enum HindsightProviderContract {
    static let requiredToolNames: Set<String> = [
        "get_bank", "get_memory", "list_memories", "recall", "reflect", "retain",
    ]

    static func validate(_ tools: [MCPToolInfo]) throws {
        let names = Set(tools.map(\.name))
        guard requiredToolNames.isSubset(of: names) else {
            throw LocalStoreError.invalidData(
                path: "Hindsight",
                reason: "the selected bank does not expose GOAT's required official Hindsight tools")
        }
    }
}

public struct HindsightProviderStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable { case unavailable, ready, failed }

    public let providerID: MemoryProviderID
    public let state: State
    public let bankID: String?
    public let apiURL: String?
    public let error: String?

    public static func unavailable(_ providerID: MemoryProviderID) -> Self {
        Self(
            providerID: providerID, state: .unavailable, bankID: nil, apiURL: nil, error: nil)
    }

    public static func failed(_ providerID: MemoryProviderID, _ error: String) -> Self {
        Self(
            providerID: providerID, state: .failed, bankID: nil, apiURL: nil, error: error)
    }
}

public enum HindsightBindingResult: Sendable {
    case success(HindsightProviderConfiguration)
    case failure(HindsightProviderStatus)
}

/// The transport seam allows lifecycle races to be exercised without a live memory server.
protocol HindsightSessionTransport: Sendable {
    func connect(_ config: MCPServerConfig) async -> MCPServerManager.State
    func disconnect(name: String) async
    func capabilitySnapshots() async -> [String: MCPServerManager.CapabilitySnapshot]
    func invoke(
        server: String, tool: String, argumentsJSON: String,
        capability: MCPServerManager.CapabilityToken, maximumResultBytes: Int
    ) async throws -> ToolResult
}
extension MCPServerManager: HindsightSessionTransport {}

/// A private, bank-scoped Hindsight client. This is not a generic GOAT MCP row and it exposes
/// only the non-destructive subset required by the memory provider.
public actor HindsightProviderClient {
    public static let maximumResponseBytes = MCPServerManager.maximumStructuredResultBytes
    private static let maximumTokenBytes = 4 * 1_024
    private static let allowedTools = HindsightProviderContract.requiredToolNames
    private static let retryableReadTools: Set<String> = [
        "get_bank", "get_memory", "list_memories", "recall", "reflect",
    ]
    /// Each provider client owns an isolated manager, so this internal identity does not need the
    /// provider UUID. Keeping it fixed also guarantees it satisfies MCP's 64-byte name bound.
    public static let managedServerName = "goat-hindsight"

    private struct Session {
        let providerID: MemoryProviderID
        let serverName: String
        let capability: MCPServerManager.CapabilityToken
        let status: HindsightProviderStatus
    }

    private struct Route {
        let providerID: MemoryProviderID
        let connection: HindsightBankConnection
        let credentialProviderID: MemoryProviderID
    }

    private let manager: any HindsightSessionTransport
    private var session: Session?
    private var route: Route?
    private var nextConnectionAt: Date?
    private var connectionRevision = UUID()
    private var connectionTask: (fingerprint: String, providerID: MemoryProviderID, task: Task<Session, Error>)?

    public init(manager: MCPServerManager = MCPServerManager()) { self.manager = manager }
    init(transport: any HindsightSessionTransport) { manager = transport }

    public func bind(
        providerID: MemoryProviderID,
        connection: HindsightBankConnection,
        apiToken: String?
    ) async -> HindsightBindingResult {
        route = nil
        do {
            try Self.validatedBaseURL(connection)
            let ready = try await start(providerID: providerID, connection: connection, apiToken: apiToken)
            guard session?.capability == ready.capability else { throw CancellationError() }
            route = Route(
                providerID: providerID,
                connection: connection,
                credentialProviderID: providerID)
            return .success(HindsightProviderConfiguration(connection: connection))
        } catch {
            return .failure(
                HindsightProviderStatus.failed(
                    providerID,
                    "Hindsight bank validation failed: \(error.localizedDescription)"))
        }
    }

    public func connect(_ provider: MemoryProviderRecord) async -> HindsightProviderStatus {
        guard provider.kind == .hindsight else {
            return .failed(provider.id, "This is not a Hindsight provider.")
        }
        guard let connection = provider.hindsight?.connection else {
            return .failed(
                provider.id,
                "This is a legacy workspace binding. Reconnect Hindsight using its server and bank instead.")
        }
        return await connect(
            providerID: provider.id,
            connection: connection,
            credentialProviderID: provider.id)
    }

    public func connect(
        providerID: MemoryProviderID,
        connection: HindsightBankConnection,
        credentialProviderID: MemoryProviderID,
        retryImmediately: Bool = false
    ) async -> HindsightProviderStatus {
        guard
            retryImmediately || session != nil || connectionTask != nil
                || (nextConnectionAt.map({ Date() >= $0 }) ?? true)
        else {
            return .failed(providerID, "Hindsight is backing off after a failed connection. Try again shortly.")
        }
        do {
            route = Route(
                providerID: providerID,
                connection: connection,
                credentialProviderID: credentialProviderID)
            let token = try CredentialStore.get(Self.credentialKey(for: credentialProviderID))
            _ = try await start(providerID: providerID, connection: connection, apiToken: token)
            nextConnectionAt = nil
            return status(for: providerID)
        } catch is CancellationError {
            return status(for: providerID)
        } catch {
            nextConnectionAt = Date().addingTimeInterval(2)
            return .failed(
                providerID,
                "GOAT could not connect to or validate the Hindsight bank. For LAN or Thunderbolt, allow GOAT in System Settings > Privacy & Security > Local Network. Check the server, bank and JUDAS policy, then reconnect."
            )
        }
    }

    public func disconnect() async {
        route = nil
        nextConnectionAt = nil
        connectionRevision = UUID()
        connectionTask?.task.cancel()
        connectionTask = nil
        session = nil
        // Invalidate pending handshakes too, even when no session has been published yet.
        await manager.disconnect(name: Self.managedServerName)
    }

    public func status(for providerID: MemoryProviderID) -> HindsightProviderStatus {
        guard let session, session.providerID == providerID else {
            return .unavailable(providerID)
        }
        return session.status
    }

    public func invoke(providerID: MemoryProviderID, tool: String, argumentsJSON: String) async throws -> ToolResult {
        guard Self.allowedTools.contains(tool) else { throw MCPError.unknownTool(tool) }
        let session: Session
        if let active = self.session, active.providerID == providerID {
            session = active
        } else if let restored = await restoreSession(for: providerID) {
            session = restored
        } else {
            throw MCPError.notConnected("Hindsight")
        }

        let result: ToolResult
        do {
            result = try await manager.invoke(
                server: session.serverName, tool: tool, argumentsJSON: argumentsJSON, capability: session.capability,
                maximumResultBytes: Self.maximumResponseBytes)
        } catch is CancellationError {
            if self.session?.capability == session.capability { self.session = nil }
            throw CancellationError()
        } catch {
            if self.session?.capability == session.capability { self.session = nil }
            if let restored = await restoreSession(for: providerID) {
                if Self.canRetryAfterTransportFailure(tool) {
                    let retried: ToolResult
                    do {
                        retried = try await invokeOnce(
                            session: restored,
                            tool: tool,
                            argumentsJSON: argumentsJSON)
                    } catch {
                        if self.session?.capability == restored.capability { self.session = nil }
                        nextConnectionAt = Date().addingTimeInterval(2)
                        throw error
                    }
                    return try Self.validatedResult(retried)
                }
                throw MCPError.failed(
                    "Hindsight is connected, but the connection ended before it acknowledged this request. It may still be processing it."
                )
            }
            nextConnectionAt = Date().addingTimeInterval(2)
            throw MCPError.failed("Hindsight became unavailable. Reconnect its bank binding before retrying.")
        }
        return try Self.validatedResult(result)
    }

    private func invokeOnce(
        session: Session,
        tool: String,
        argumentsJSON: String
    ) async throws -> ToolResult {
        let result = try await manager.invoke(
            server: session.serverName,
            tool: tool,
            argumentsJSON: argumentsJSON,
            capability: session.capability, maximumResultBytes: Self.maximumResponseBytes)
        return result
    }

    private func restoreSession(for providerID: MemoryProviderID) async -> Session? {
        guard let route, route.providerID == providerID else { return nil }
        do {
            let token = try CredentialStore.get(Self.credentialKey(for: route.credentialProviderID))
            let restored = try await start(
                providerID: providerID,
                connection: route.connection,
                apiToken: token)
            nextConnectionAt = nil
            return restored
        } catch {
            nextConnectionAt = Date().addingTimeInterval(2)
            return nil
        }
    }

    private func start(
        providerID: MemoryProviderID,
        connection: HindsightBankConnection,
        apiToken: String?
    ) async throws -> Session {
        let config = try Self.serverConfig(name: Self.managedServerName, connection: connection, apiToken: apiToken)
        if let pending = connectionTask, pending.fingerprint == config.permissionFingerprint,
            pending.providerID == providerID
        {
            let revision = connectionRevision
            let result = try await pending.task.value
            guard connectionRevision == revision else { throw CancellationError() }
            return result
        }
        connectionTask?.task.cancel()
        let revision = UUID()
        connectionRevision = revision
        // A view disappearing must not cancel a shared operational health check.
        let task = Task {
            try await self.establish(providerID, connection: connection, config: config, revision: revision)
        }
        connectionTask = (config.permissionFingerprint, providerID, task)
        do {
            let result = try await task.value
            guard connectionRevision == revision else { throw CancellationError() }
            connectionTask = nil
            return result
        } catch {
            if connectionRevision == revision {
                connectionTask = nil
                session = nil
                await manager.disconnect(name: Self.managedServerName)
            }
            throw error
        }
    }

    private func establish(
        _ providerID: MemoryProviderID, connection: HindsightBankConnection,
        config: MCPServerConfig, revision: UUID
    ) async throws -> Session {
        func checkOwnership() throws {
            try Task.checkCancellation()
            guard connectionRevision == revision else { throw CancellationError() }
        }
        try checkOwnership()
        if let active = session, active.providerID == providerID,
            active.capability.permissionFingerprint == config.permissionFingerprint
        {
            do {
                // Check the current bank without tearing down a live transport or active reads.
                _ = try Self.validatedResult(await invokeOnce(session: active, tool: "get_bank", argumentsJSON: "{}"))
                try checkOwnership()
                return active
            } catch {
                try checkOwnership()
                if session?.capability == active.capability { session = nil }
            }
        }
        let state = await manager.connect(config)
        try checkOwnership()
        guard state.status == .connected else { throw MCPError.failed(state.error ?? "Hindsight MCP did not connect.") }
        let snapshots = await manager.capabilitySnapshots()
        try checkOwnership()
        guard let capability = snapshots[config.name] else { throw MCPError.notConnected("Hindsight") }
        try HindsightProviderContract.validate(capability.tools)
        let result = try await manager.invoke(
            server: config.name, tool: "get_bank", argumentsJSON: "{}", capability: capability.token,
            maximumResultBytes: Self.maximumResponseBytes)
        _ = try Self.validatedResult(result)
        try checkOwnership()
        let status = HindsightProviderStatus(
            providerID: providerID, state: .ready, bankID: connection.bankID, apiURL: connection.apiURL, error: nil)
        let ready = Session(
            providerID: providerID, serverName: config.name, capability: capability.token, status: status)
        session = ready
        return ready
    }

    public nonisolated static func canRetryAfterTransportFailure(_ tool: String) -> Bool {
        retryableReadTools.contains(tool)
    }

    private nonisolated static func validatedResult(_ result: ToolResult) throws -> ToolResult {
        guard !result.isError else {
            let detail = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let bounded = String(detail.prefix(512))
            throw MCPError.failed(
                bounded.isEmpty ? "Hindsight rejected the request." : "Hindsight rejected the request: \(bounded)")
        }
        try validateJSON(result.content)
        return result
    }

    private static func serverConfig(
        name: String,
        connection: HindsightBankConnection,
        apiToken: String?
    ) throws -> MCPServerConfig {
        var headers: [String: String] = [:]
        if let apiToken, !apiToken.isEmpty {
            guard apiToken.utf8.count <= maximumTokenBytes,
                !apiToken.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
            else { throw MCPError.invalidArguments }
            headers["Authorization"] = "Bearer \(apiToken)"
        }
        return MCPServerConfig(
            name: name,
            transport: .http(url: try mcpURL(for: connection), headers: headers),
            allowsPrivateNetworkHTTP: true)
    }

    private static func mcpURL(for connection: HindsightBankConnection) throws -> URL {
        let base = try validatedBaseURL(connection)
        return
            base
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent(connection.bankID, isDirectory: true)
    }

    public static func validatedBaseURL(_ apiURL: String) throws -> URL {
        try validatedBaseURL(HindsightBankConnection(apiURL: apiURL, bankID: "validation"))
    }

    @discardableResult
    public static func validatedBaseURL(_ connection: HindsightBankConnection) throws -> URL {
        guard connection.bankID.utf8.count <= 128,
            !connection.bankID.isEmpty,
            connection.bankID.utf8.allSatisfy({ byte in
                (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45 || byte == 95
            }),
            connection.apiURL.utf8.count <= 2_048,
            !connection.apiURL.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
            let components = URLComponents(string: connection.apiURL),
            let scheme = components.scheme,
            scheme == "http" || scheme == "https",
            let host = components.host,
            !host.isEmpty,
            host == host.lowercased(),
            components.path.isEmpty || components.path == "/",
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.string == connection.apiURL,
            let base = components.url
        else { throw MCPError.invalidArguments }
        guard scheme == "https" || HindsightEndpointPolicy.permitsHTTP(forHost: host) else {
            throw MCPError.invalidArguments
        }
        return base
    }

    public static func validateJSON(_ text: String) throws {
        guard text.utf8.count <= maximumResponseBytes,
            !text.hasSuffix("\n… (truncated)"),
            let data = text.data(using: .utf8)
        else { throw MCPError.failed("Hindsight response exceeded the supported size or was truncated") }
        _ = try JSONSerialization.jsonObject(with: data)
    }

    public static func credentialKey(for providerID: MemoryProviderID) -> String {
        "hindsight.api-token.\(providerID.rawValue)"
    }
}
