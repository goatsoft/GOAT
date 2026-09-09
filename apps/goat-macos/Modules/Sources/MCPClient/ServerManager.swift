import Darwin
import Foundation
import JUDAS
import MCP
import System
import Tools

public struct MCPToolInfo: Sendable, Identifiable, Equatable {
    public let name: String
    public let description: String
    public let inputSchemaJSON: String
    public var id: String { name }

    public init(name: String, description: String, inputSchemaJSON: String) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
    }
}

public enum MCPError: LocalizedError, Sendable {
    case capabilityChanged(String)
    case failed(String)
    case invalidArguments
    case notConnected(String)
    case timeout
    case unknownTool(String)

    public var errorDescription: String? {
        switch self {
        case .capabilityChanged(let name): "Server \"\(name)\" changed; review its tools and permission again."
        case .failed(let s): s
        case .invalidArguments: "Tool arguments must be a valid JSON object."
        case .notConnected(let name): "Server \"\(name)\" is not connected."
        case .timeout: "Timed out waiting for the server."
        case .unknownTool(let name): "Tool \"\(name)\" is not advertised by the connected server."
        }
    }
}

/// Owns MCP client connections. UI state is mirrored on the main actor by the app.
public actor MCPServerManager {
    public static let maximumConcurrentConnections = 4
    public static let maximumArgumentBytes = 32_000
    /// Ceiling for structured consumers; ordinary model tool results retain their 32 KB default.
    public static let maximumStructuredResultBytes = 512 * 1_024

    public struct Timeouts: Sendable {
        public var connection: TimeInterval
        public var toolDiscovery: TimeInterval
        public var invocation: TimeInterval
        public var cleanup: TimeInterval
        public var processTerminationGrace: TimeInterval

        public init(
            connection: TimeInterval = 15,
            toolDiscovery: TimeInterval = 20,
            invocation: TimeInterval = 120,
            cleanup: TimeInterval = 2,
            processTerminationGrace: TimeInterval = 0.5
        ) {
            self.connection = connection
            self.toolDiscovery = toolDiscovery
            self.invocation = invocation
            self.cleanup = cleanup
            self.processTerminationGrace = processTerminationGrace
        }
    }

    public struct State: Sendable, Equatable {
        public enum Status: String, Sendable { case connecting, connected, disconnected, failed }
        public var status: Status
        public var tools: [MCPToolInfo]
        public var error: String?
    }

    public struct CapabilitySnapshot: Sendable, Equatable {
        public let token: CapabilityToken
        public let tools: [MCPToolInfo]
    }

    /// Exact identity of one live connection. A transport-equivalent reconnect still receives a
    /// new generation so a tool planned against the old process cannot run on its replacement.
    public struct CapabilityToken: Sendable, Hashable {
        public let permissionFingerprint: String
        public let connectionGeneration: UUID

        public init(permissionFingerprint: String, connectionGeneration: UUID) {
            self.permissionFingerprint = permissionFingerprint
            self.connectionGeneration = connectionGeneration
        }
    }

    /// A connection admission token. Only the newest token for one server may publish a client.
    public struct ConnectionAttempt: Sendable {
        public let name: String
        fileprivate let config: MCPServerConfig
        fileprivate let revision: UInt64
    }

    private struct PendingConnection {
        let revision: UInt64
        let client: Client
        let process: Process?
    }

    private var clients: [String: Client] = [:]
    private var connectedConfigs: [String: MCPServerConfig] = [:]
    private var connectedGenerations: [String: UUID] = [:]
    private var processes: [String: Process] = [:]
    private var pendingConnections: [String: PendingConnection] = [:]
    private var stderrTails: [String: String] = [:]
    private var connectionRevisions: [String: UInt64] = [:]
    private var reloadRevision: UInt64 = 0
    private let judas: Judas
    private let timeouts: Timeouts
    public private(set) var states: [String: State] = [:]

    public init(timeouts: Timeouts = Timeouts(), judas: Judas = .shared) {
        self.judas = judas
        self.timeouts = timeouts
    }

    public func snapshot() -> [String: State] { states }

    /// Capabilities from live clients only. File config can change before a reconnect settles, so
    /// callers must not expose schemas from `states` without binding them to this fingerprint.
    public func capabilitySnapshots() -> [String: CapabilitySnapshot] {
        clients.reduce(into: [:]) { result, item in
            let (name, _) = item
            guard
                let config = connectedConfigs[name],
                let generation = connectedGenerations[name],
                let state = states[name],
                state.status == .connected
            else { return }
            result[name] = CapabilitySnapshot(
                token: CapabilityToken(
                    permissionFingerprint: config.permissionFingerprint,
                    connectionGeneration: generation),
                tools: state.tools)
        }
    }

    public func isToolAvailable(
        server: String,
        tool: String,
        capability: CapabilityToken
    ) -> Bool {
        guard
            clients[server] != nil,
            connectedConfigs[server]?.permissionFingerprint == capability.permissionFingerprint,
            connectedGenerations[server] == capability.connectionGeneration,
            let state = states[server],
            state.status == .connected
        else { return false }
        return state.tools.contains { $0.name == tool }
    }

    /// Reconcile running connections with the config file's contents.
    public func reload(_ configs: [MCPServerConfig]) async {
        let pending = await prepareReload(configs)
        await withTaskGroup(of: Void.self) { group in
            var nextIndex = 0
            while nextIndex < min(Self.maximumConcurrentConnections, pending.count) {
                let attempt = pending[nextIndex]
                nextIndex += 1
                group.addTask { [self] in
                    _ = await connectPrepared(attempt)
                }
            }
            while await group.next() != nil {
                guard nextIndex < pending.count else { continue }
                let attempt = pending[nextIndex]
                nextIndex += 1
                group.addTask { [self] in
                    _ = await connectPrepared(attempt)
                }
            }
        }
    }

    /// Publish the desired connection states and return only servers which need a connection.
    /// The app can then settle those servers concurrently and mirror each result as it arrives.
    public func prepareReload(_ configs: [MCPServerConfig]) async -> [ConnectionAttempt] {
        reloadRevision &+= 1
        let ownedReload = reloadRevision
        var seenNames = Set<String>()
        let uniqueConfigs = configs.filter { seenNames.insert($0.name).inserted }
        let wanted = Set(uniqueConfigs.filter { !$0.disabled }.map(\.name))
        let known = Set(uniqueConfigs.map(\.name))
        let resourceNames = Set(clients.keys).union(pendingConnections.keys)
        for name in resourceNames where !wanted.contains(name) {
            await disconnect(name: name)
            guard reloadRevision == ownedReload else { return [] }
        }
        for name in Array(states.keys) where !known.contains(name) {
            invalidateConnection(for: name)
            states.removeValue(forKey: name)
        }
        var pending: [ConnectionAttempt] = []
        for config in uniqueConfigs {
            if config.disabled {
                invalidateConnection(for: config.name)
                states[config.name] = State(status: .disconnected, tools: [], error: nil)
            } else if clients[config.name] == nil {
                if pendingConnections[config.name] != nil {
                    invalidateConnection(for: config.name)
                    await disconnectResources(name: config.name)
                    guard reloadRevision == ownedReload else { return [] }
                }
                pending.append(beginConnection(config))
            } else if connectedConfigs[config.name] != config {
                await disconnect(name: config.name)
                guard reloadRevision == ownedReload else { return [] }
                pending.append(beginConnection(config))
            }
        }
        return pending
    }

    @discardableResult
    public func connect(_ config: MCPServerConfig) async -> State {
        let attempt = beginConnection(config)
        return await connectPrepared(attempt)
            ?? states[config.name]
            ?? State(status: .disconnected, tools: [], error: nil)
    }

    /// Settle one prepared attempt. A disable, delete, reconnect, or newer reload invalidates it.
    public func connectPrepared(_ attempt: ConnectionAttempt) async -> State? {
        guard owns(attempt), !Task.isCancelled else { return nil }
        await disconnectResources(name: attempt.name)
        guard owns(attempt), !Task.isCancelled else { return nil }
        states[attempt.name] = State(status: .connecting, tools: [], error: nil)
        var spawned: Process?
        var openedClient: Client?
        do {
            let (client, process) = try await makeClient(attempt.config, attempt: attempt)
            openedClient = client
            spawned = process
            let tools = try await withTimeout(
                seconds: timeouts.toolDiscovery,
                onTimeout: { [timeouts] in
                    Self.stopProcess(process, grace: timeouts.processTerminationGrace)
                    await client.disconnect()
                },
                onCancel: { [timeouts] in
                    Self.stopProcess(process, grace: timeouts.processTerminationGrace)
                    await client.disconnect()
                }
            ) {
                try await Self.listAllTools(client)
            }
            guard owns(attempt), !Task.isCancelled else {
                clearPendingConnection(attempt, client: client)
                Self.stopProcess(process, grace: timeouts.processTerminationGrace)
                await boundedDisconnect(client)
                return nil
            }
            clearPendingConnection(attempt, client: client)
            clients[attempt.name] = client
            connectedConfigs[attempt.name] = attempt.config
            connectedGenerations[attempt.name] = UUID()
            processes[attempt.name] = process
            let state = State(status: .connected, tools: tools, error: nil)
            states[attempt.name] = state
            return state
        } catch {
            if let openedClient { clearPendingConnection(attempt, client: openedClient) }
            Self.stopProcess(spawned, grace: timeouts.processTerminationGrace)
            if let openedClient { await boundedDisconnect(openedClient) }
            guard owns(attempt), !Task.isCancelled else { return nil }
            let detail = describe(error, server: attempt.name)
            let state = State(status: .failed, tools: [], error: detail)
            states[attempt.name] = state
            return state
        }
    }

    public func disconnect(name: String) async {
        let revision = invalidateConnection(for: name)
        await disconnectResources(name: name)
        guard connectionRevisions[name] == revision else { return }
        states[name] = State(status: .disconnected, tools: [], error: nil)
    }

    private func disconnectResources(name: String) async {
        let pending = pendingConnections.removeValue(forKey: name)
        let client = clients.removeValue(forKey: name)
        connectedConfigs.removeValue(forKey: name)
        connectedGenerations.removeValue(forKey: name)
        let process = processes.removeValue(forKey: name)
        Self.stopProcess(pending?.process, grace: timeouts.processTerminationGrace)
        Self.stopProcess(process, grace: timeouts.processTerminationGrace)
        if let pending { await boundedDisconnect(pending.client) }
        if let client, client !== pending?.client { await boundedDisconnect(client) }
        stderrTails.removeValue(forKey: name)
    }

    private func beginConnection(_ config: MCPServerConfig) -> ConnectionAttempt {
        let revision = invalidateConnection(for: config.name)
        states[config.name] = State(status: .connecting, tools: [], error: nil)
        return ConnectionAttempt(name: config.name, config: config, revision: revision)
    }

    @discardableResult
    private func invalidateConnection(for name: String) -> UInt64 {
        let revision = (connectionRevisions[name] ?? 0) &+ 1
        connectionRevisions[name] = revision
        return revision
    }

    private func owns(_ attempt: ConnectionAttempt) -> Bool {
        connectionRevisions[attempt.name] == attempt.revision
    }

    /// Dry run for the Add sheet: connect, list tools, tear down. Nothing is retained.
    public func test(_ config: MCPServerConfig) async -> Result<[MCPToolInfo], MCPError> {
        var openedClient: Client?
        var spawned: Process?
        do {
            let (client, process) = try await makeClient(config)
            openedClient = client
            spawned = process
            let tools = try await withTimeout(
                seconds: timeouts.toolDiscovery,
                onTimeout: { [timeouts] in
                    Self.stopProcess(process, grace: timeouts.processTerminationGrace)
                    await client.disconnect()
                },
                onCancel: { [timeouts] in
                    Self.stopProcess(process, grace: timeouts.processTerminationGrace)
                    await client.disconnect()
                }
            ) {
                try await Self.listAllTools(client)
            }
            Self.stopProcess(process, grace: timeouts.processTerminationGrace)
            await boundedDisconnect(client)
            return .success(tools)
        } catch {
            Self.stopProcess(spawned, grace: timeouts.processTerminationGrace)
            if let openedClient { await boundedDisconnect(openedClient) }
            return .failure(.failed(describe(error, server: config.name)))
        }
    }

    public func invoke(
        server: String,
        tool: String,
        argumentsJSON: String,
        capability: CapabilityToken,
        maximumResultBytes: Int = 32_000
    ) async throws -> ToolResult {
        guard (1...Self.maximumStructuredResultBytes).contains(maximumResultBytes) else {
            throw MCPError.invalidArguments
        }
        guard let client = clients[server] else { throw MCPError.notConnected(server) }
        guard
            connectedConfigs[server]?.permissionFingerprint == capability.permissionFingerprint,
            connectedGenerations[server] == capability.connectionGeneration
        else {
            throw MCPError.capabilityChanged(server)
        }
        guard
            states[server]?.status == .connected,
            states[server]?.tools.contains(where: { $0.name == tool }) == true
        else {
            throw MCPError.unknownTool(tool)
        }
        let arguments = try Self.decodeToolArguments(argumentsJSON)

        let content: [Tool.Content]
        let isError: Bool?
        do {
            (content, isError) = try await withTimeout(seconds: timeouts.invocation) {
                try await client.callTool(name: tool, arguments: arguments)
            }
        } catch MCPError.timeout {
            discardConnection(server: server, client: client, error: MCPError.timeout.localizedDescription)
            throw MCPError.timeout
        } catch is CancellationError {
            discardConnection(server: server, client: client, error: nil)
            throw CancellationError()
        } catch {
            let detail = describe(error, server: server)
            discardConnection(server: server, client: client, error: detail)
            throw error
        }
        guard
            clients[server] === client,
            connectedConfigs[server]?.permissionFingerprint == capability.permissionFingerprint,
            connectedGenerations[server] == capability.connectionGeneration,
            states[server]?.status == .connected,
            states[server]?.tools.contains(where: { $0.name == tool }) == true
        else {
            throw MCPError.capabilityChanged(server)
        }

        let textValues = content.compactMap { part -> String? in
            guard case .text(let value, _, _) = part else { return nil }
            return value
        }
        let text = Self.boundedToolResultText(textValues, maximumBytes: maximumResultBytes)
        return ToolResult(content: text, isError: isError ?? false)
    }

    static func boundedToolResultText(
        _ values: [String], maximumBytes: Int = 32_000
    ) -> String {
        var resultBytes = Data()
        var wasTruncated = false
        for value in values {
            let needsSeparator = !resultBytes.isEmpty
            let remaining = maximumBytes - resultBytes.count - (needsSeparator ? 1 : 0)
            guard remaining > 0 else {
                wasTruncated = true
                break
            }
            if needsSeparator { resultBytes.append(0x0A) }
            let bounded = value.utf8.prefix(remaining + 1)
            if bounded.count > remaining {
                resultBytes.append(contentsOf: bounded.prefix(remaining))
                wasTruncated = true
                break
            }
            resultBytes.append(contentsOf: bounded)
        }
        var text = String(decoding: resultBytes, as: UTF8.self)
        if text.isEmpty { text = "(no text content)" }
        if wasTruncated { text += "\n… (truncated)" }
        return text
    }

    // MARK: Internals

    private func makeClient(
        _ config: MCPServerConfig,
        attempt: ConnectionAttempt? = nil
    ) async throws -> (Client, Process?) {
        try config.validate()
        let client = Client(name: "GOAT", version: "0.1.0")
        switch config.transport {
        case .http(let url, let headers):
            let transport = BoundedHTTPTransport(endpoint: url, headers: headers, serverName: config.name, judas: judas)
            try registerPendingConnection(attempt, client: client, process: nil)
            do {
                _ = try await withTimeout(
                    seconds: timeouts.connection,
                    onTimeout: { await client.disconnect() },
                    onCancel: { await client.disconnect() }
                ) {
                    try await client.connect(transport: transport)
                }
                return (client, nil)
            } catch {
                clearPendingConnection(attempt, client: client)
                Task { await client.disconnect() }
                throw error
            }

        case .stdio(let command, let args, let env):
            try judas.authorizeProcess(name: config.name)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["--", command] + args
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
            for (k, v) in env { environment[k] = v }
            process.environment = environment

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let name = config.name
            stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                guard
                    let s = String(data: data.suffix(2048), encoding: .utf8)
                else { return }
                Task { await self?.appendStderr(name, s) }
            }
            let cancellation = JudasRegistration(judas: judas) { [judas, weak self, weak process, weak client] in
                judas.record(.mcpProcess, .revoked, name: name)
                Self.stopProcess(process, grace: 0.2)
                guard let process, let client else { return }
                Task { await self?.processDidExit(name: name, process: process, client: client) }
            }
            process.terminationHandler = { [weak self, weak process, weak client] _ in
                _ = cancellation
                guard let process, let client else { return }
                Task { await self?.processDidExit(name: name, process: process, client: client) }
            }

            do {
                try process.run()
                try judas.authorizeProcess(name: config.name)
            } catch {
                _ = cancellation
                Self.stopProcess(process, grace: 0.2)
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                throw error
            }
            do {
                try registerPendingConnection(attempt, client: client, process: process)
            } catch {
                Self.stopProcess(process, grace: timeouts.processTerminationGrace)
                throw error
            }

            let transport: BoundedStdioTransport
            do {
                transport = try BoundedStdioTransport(
                    input: FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor),
                    output: FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor),
                    serverName: config.name, judas: judas
                )
            } catch {
                clearPendingConnection(attempt, client: client)
                Self.stopProcess(process, grace: timeouts.processTerminationGrace)
                Task { await client.disconnect() }
                throw error
            }
            do {
                _ = try await withTimeout(
                    seconds: timeouts.connection,
                    onTimeout: { [timeouts] in
                        Self.stopProcess(process, grace: timeouts.processTerminationGrace)
                        await client.disconnect()
                    },
                    onCancel: { [timeouts] in
                        Self.stopProcess(process, grace: timeouts.processTerminationGrace)
                        await client.disconnect()
                    }
                ) {
                    try await client.connect(transport: transport)
                }
                return (client, process)
            } catch {
                clearPendingConnection(attempt, client: client)
                Self.stopProcess(process, grace: timeouts.processTerminationGrace)
                Task { await client.disconnect() }
                throw error
            }
        }
    }

    private static func listAllTools(_ client: Client) async throws -> [MCPToolInfo] {
        let maximumPages = 16
        let maximumTools = 256
        let maximumDescriptionBytes = 16_384
        let maximumCombinedDescriptionBytes = 262_144
        let maximumSchemaBytes = 65_536
        let maximumCombinedSchemaBytes = 524_288
        var result: [MCPToolInfo] = []
        var seenNames = Set<String>()
        var seenCursors = Set<String>()
        var combinedSchemaBytes = 0
        var combinedDescriptionBytes = 0
        var cursor: String?
        var pageCount = 0
        repeat {
            pageCount += 1
            guard pageCount <= maximumPages else {
                throw MCPError.failed("MCP server returned too many tool pages.")
            }
            let (tools, nextCursor) = try await client.listTools(cursor: cursor)
            guard tools.count <= maximumTools - result.count else {
                throw MCPError.failed("MCP server returned more than \(maximumTools) tools.")
            }
            for tool in tools {
                guard
                    !tool.name.isEmpty,
                    tool.name.utf8.count <= 256,
                    !tool.name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                    seenNames.insert(tool.name).inserted
                else {
                    throw MCPError.failed("MCP server returned an invalid or duplicate tool name.")
                }
                let description = tool.description ?? ""
                guard description.utf8.count <= maximumDescriptionBytes else {
                    throw MCPError.failed("MCP server returned an oversized tool description.")
                }
                combinedDescriptionBytes += description.utf8.count
                guard combinedDescriptionBytes <= maximumCombinedDescriptionBytes else {
                    throw MCPError.failed("MCP server returned too much combined tool description data.")
                }
                let schemaData = try JSONEncoder().encode(tool.inputSchema)
                guard schemaData.count <= maximumSchemaBytes else {
                    throw MCPError.failed("MCP server returned an oversized tool schema.")
                }
                combinedSchemaBytes += schemaData.count
                guard combinedSchemaBytes <= maximumCombinedSchemaBytes else {
                    throw MCPError.failed("MCP server returned too much combined tool schema data.")
                }
                guard let schema = String(data: schemaData, encoding: .utf8) else {
                    throw MCPError.failed("MCP server returned a tool schema that could not be encoded.")
                }
                result.append(
                    MCPToolInfo(
                        name: tool.name,
                        description: description,
                        inputSchemaJSON: schema))
            }
            if let nextCursor {
                guard nextCursor.utf8.count <= 4096, seenCursors.insert(nextCursor).inserted else {
                    throw MCPError.failed("MCP server returned an invalid tool pagination cursor.")
                }
            }
            cursor = nextCursor
        } while cursor != nil
        return result
    }

    private func registerPendingConnection(
        _ attempt: ConnectionAttempt?,
        client: Client,
        process: Process?
    ) throws {
        guard let attempt else { return }
        guard owns(attempt), !Task.isCancelled else { throw CancellationError() }
        pendingConnections[attempt.name] = PendingConnection(
            revision: attempt.revision, client: client, process: process)
    }

    private func clearPendingConnection(_ attempt: ConnectionAttempt?, client: Client) {
        guard let attempt, let pending = pendingConnections[attempt.name] else { return }
        guard pending.revision == attempt.revision, pending.client === client else { return }
        pendingConnections.removeValue(forKey: attempt.name)
    }

    private func appendStderr(_ name: String, _ chunk: String) {
        let combined = (stderrTails[name] ?? "") + chunk
        stderrTails[name] = Self.utf8Suffix(combined, maximumBytes: 2_048)
    }

    private func processDidExit(name: String, process: Process, client: Client) {
        if processes[name] === process, clients[name] === client {
            discardConnection(
                server: name, client: client,
                error: describe(BoundedTransportError.connectionClosed, server: name))
            return
        }
        guard
            let pending = pendingConnections[name],
            pending.process === process,
            pending.client === client
        else { return }
        invalidateConnection(for: name)
        pendingConnections.removeValue(forKey: name)
        stderrTails.removeValue(forKey: name)
        states[name] = State(
            status: .failed, tools: [],
            error: describe(BoundedTransportError.connectionClosed, server: name))
        Task { await client.disconnect() }
    }

    private func describe(_ error: Error, server: String) -> String {
        var message = error.localizedDescription
        if let tail = stderrTails[server]?.trimmingCharacters(in: .whitespacesAndNewlines), !tail.isEmpty {
            message += " - " + Self.utf8Suffix(tail, maximumBytes: 1_024)
        }
        return String(message)
    }

    private static func utf8Suffix(_ value: String, maximumBytes: Int) -> String {
        let bytes = value.utf8
        guard bytes.count > maximumBytes else { return value }
        return String(decoding: bytes.suffix(maximumBytes), as: UTF8.self)
    }

    static func applyingHTTPHeaders(_ headers: [String: String], to request: URLRequest) -> URLRequest {
        var request = request
        for field in headers.keys.sorted() {
            request.setValue(headers[field], forHTTPHeaderField: field)
        }
        return request
    }

    static func decodeToolArguments(_ json: String) throws -> [String: Value] {
        guard json.utf8.count <= maximumArgumentBytes, let data = json.data(using: .utf8) else {
            throw MCPError.invalidArguments
        }
        do {
            return try JSONDecoder().decode([String: Value].self, from: data)
        } catch {
            throw MCPError.invalidArguments
        }
    }

    public static func argumentsAreValid(_ json: String) -> Bool {
        (try? decodeToolArguments(json)) != nil
    }

    private func boundedDisconnect(_ client: Client) async {
        _ = try? await withTimeout(seconds: timeouts.cleanup) {
            await client.disconnect()
        }
    }

    private func discardConnection(server: String, client: Client, error: String?) {
        guard clients[server] === client else { return }
        invalidateConnection(for: server)
        clients.removeValue(forKey: server)
        connectedConfigs.removeValue(forKey: server)
        connectedGenerations.removeValue(forKey: server)
        Self.stopProcess(
            processes.removeValue(forKey: server), grace: timeouts.processTerminationGrace)
        stderrTails.removeValue(forKey: server)
        states[server] = State(
            status: error == nil ? .disconnected : .failed,
            tools: [],
            error: error)
        Task { await client.disconnect() }
    }

    static func stopProcess(_ process: Process?, grace: TimeInterval) {
        guard let process else { return }
        process.terminationHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        guard process.isRunning else { return }
        process.terminate()
        let delay = max(0, grace)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            guard process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

// MARK: - Timeout helper

func withTimeout<T: Sendable>(
    seconds: Double,
    onTimeout: @Sendable @escaping () async -> Void = {},
    onCancel: @Sendable @escaping () async -> Void = {},
    _ work: @Sendable @escaping () async throws -> T
) async throws -> T {
    let race = TimeoutRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.install(continuation)

            let operationTask = Task {
                do {
                    _ = race.resolve(.success(try await work()))
                } catch {
                    _ = race.resolve(.failure(error))
                }
            }
            race.register(operationTask)

            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: .seconds(max(0, seconds)))
                    if race.resolve(.failure(MCPError.timeout)) {
                        Task { await onTimeout() }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    _ = race.resolve(.failure(error))
                }
            }
            race.register(timeoutTask)
        }
    } onCancel: {
        if race.resolve(.failure(CancellationError())) {
            Task { await onCancel() }
        }
    }
}

/// Resolves a request once across completion, timeout and cancellation.
/// All mutable state is protected by `lock`; task cancellation and resumption happen after unlocking.
private final class TimeoutRace<Output: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Output, any Error>?
    private var pendingResult: Result<Output, any Error>?
    private var tasks: [Task<Void, Never>] = []
    private var isResolved = false

    func install(_ continuation: CheckedContinuation<Output, any Error>) {
        lock.lock()
        if let result = pendingResult {
            pendingResult = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func register(_ task: Task<Void, Never>) {
        lock.lock()
        if isResolved {
            lock.unlock()
            task.cancel()
        } else {
            tasks.append(task)
            lock.unlock()
        }
    }

    @discardableResult
    func resolve(_ result: Result<Output, any Error>) -> Bool {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return false
        }
        isResolved = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil { pendingResult = result }
        let tasks = tasks
        self.tasks.removeAll()
        lock.unlock()

        for task in tasks { task.cancel() }
        continuation?.resume(with: result)
        return true
    }
}
