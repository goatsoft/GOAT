import AppKit
import CryptoKit
import Foundation
import Herd
import Hoofprint
import Inference
import JUDAS
import MCPClient
import Observation
import Persistence
import Shepherd
import Tools

/// MCP state for the app: config file, connections, tool exposure, the permission
/// gate, and the call log. Owns the `MCPServerManager` actor; UI observes this.
@MainActor
@Observable
final class MCPModel {
    let manager = MCPServerManager()
    var configs: [MCPServerConfig] = []
    var states: [String: MCPServerManager.State] = [:]
    var configError: String?
    var callLog: [CallLogEntry] = []
    var pendingPermission: PermissionRequest?

    private struct GrantIdentity: Hashable {
        let server: String
        let tool: String
        let configFingerprint: String
    }

    private struct PermissionWaiter {
        let requestID: UUID
        let continuation: CheckedContinuation<PermissionChoice, Never>
    }

    private var grantsCache: Set<GrantIdentity> = []
    private var permissionWaiter: PermissionWaiter?
    private var configWatcher: DispatchSourceFileSystemObject?
    private var configWatchReloadTask: Task<Void, Never>?
    private var configWatchReloadGeneration: UInt64 = 0
    private var db: ChatDatabase?
    private let activity: ActivityLog
    private let configWorker = MCPConfigFileWorker()
    private var configIntentRevision: UInt64 = 0
    private var settledConfigIntentRevision: UInt64 = 0
    private var reconnectRevisions: [String: UInt64] = [:]

    init(db: ChatDatabase?, activity: ActivityLog) {
        self.db = db
        self.activity = activity
    }

    /// Startup opens and validates persistence away from the main actor, then attaches it once.
    func attachDatabase(_ db: ChatDatabase?) {
        self.db = db
    }

    struct CallLogEntry: Identifiable {
        let id = UUID()
        let date: Date
        let server: String
        let tool: String
        let status: String
        let duration: TimeInterval
    }

    struct PermissionRequest: Identifiable {
        let id = UUID()
        let server: String
        let tool: String
        let arguments: String
        var allowsAlways = true
        var penName: String?
        var allowsPenScopes = false
    }

    enum PermissionChoice { case allowOnce, allowChat, allowPen, alwaysAllow, deny }

    var configFileURL: URL { Home.mcpServersFile }

    // MARK: Config lifecycle

    func load() async {
        configWatchReloadGeneration &+= 1
        configWatchReloadTask?.cancel()
        configWatchReloadTask = nil
        let revision = nextConfigIntentRevision()
        let configURL = configFileURL
        let loaded: [MCPServerConfig]
        do {
            loaded = try await configWorker.load(from: configURL)
        } catch {
            guard ownsConfigIntent(revision) else { return }
            await failClosedConfig(error, revision: revision)
            return
        }
        var loadedGrants: Set<GrantIdentity> = []
        if let db {
            let grants = (try? await db.grants()) ?? []
            guard ownsConfigIntent(revision) else { return }
            loadedGrants = Set(
                grants.lazy
                    .compactMap { grant -> GrantIdentity? in
                        guard grant.policy == "always", let fingerprint = grant.configFingerprint,
                            let config = loaded.first(where: { $0.name == grant.server }),
                            config.permissionFingerprint == fingerprint
                        else { return nil }
                        return GrantIdentity(
                            server: grant.server, tool: grant.tool,
                            configFingerprint: fingerprint)
                    })
        }
        guard ownsConfigIntent(revision) else { return }
        let pending = await manager.prepareReload(loaded)
        guard ownsConfigIntent(revision) else { return }
        configs = loaded
        grantsCache = loadedGrants
        configError = nil
        await refreshStates(for: revision)
        guard ownsConfigIntent(revision) else { return }
        // Reconciliation has already invalidated every stale live capability. Publish unchanged
        // servers immediately while pending connections continue to settle progressively.
        settleConfigIntent(revision)
        await watchConfigFile(for: revision)
        guard ownsConfigIntent(revision) else { return }
        await settleConnections(pending, revision: revision)
    }

    func refreshStates() async {
        let revision = configIntentRevision
        await refreshStates(for: revision)
    }

    @discardableResult
    func addOrUpdate(_ config: MCPServerConfig, renamedFrom old: String? = nil) async -> Bool {
        let revision = nextConfigIntentRevision()
        let refreshed: [MCPServerConfig]
        do {
            // Treat every upsert as a fresh security identity. This also removes a stale database
            // grant left by an externally deleted server before the same name is added again.
            try await revokeGrants(for: Set([old, config.name].compactMap { $0 }))
            guard ownsConfigIntent(revision) else { return true }
            refreshed = try await configWorker.upsertAndLoad(
                config, renamedFrom: old, revision: revision, in: configFileURL)
        } catch {
            guard ownsConfigIntent(revision) else { return false }
            await recoverAfterMutationFailure(error, revision: revision)
            return false
        }
        guard ownsConfigIntent(revision) else { return true }
        configs = refreshed
        configError = nil
        if let old, old != config.name { await manager.disconnect(name: old) }
        guard ownsConfigIntent(revision) else { return true }
        await reconcileConnection(named: config.name, in: refreshed)
        guard ownsConfigIntent(revision) else { return true }
        await refreshStates(for: revision)
        guard ownsConfigIntent(revision) else { return true }
        settleConfigIntent(revision)
        return true
    }

    @discardableResult
    func delete(_ name: String) async -> Bool {
        let revision = nextConfigIntentRevision()
        let refreshed: [MCPServerConfig]
        do {
            try await revokeGrants(for: [name])
            guard ownsConfigIntent(revision) else { return true }
            refreshed = try await configWorker.removeAndLoad(
                name: name, revision: revision, from: configFileURL)
        } catch {
            guard ownsConfigIntent(revision) else { return false }
            await recoverAfterMutationFailure(error, revision: revision)
            return false
        }
        guard ownsConfigIntent(revision) else { return true }
        configs = refreshed
        grantsCache = grantsCache.filter { $0.server != name }
        configError = nil
        await manager.disconnect(name: name)
        guard ownsConfigIntent(revision) else { return true }
        await refreshStates(for: revision)
        guard ownsConfigIntent(revision) else { return true }
        settleConfigIntent(revision)
        return true
    }

    @discardableResult
    func setEnabled(_ name: String, enabled: Bool) async -> Bool {
        guard configs.contains(where: { $0.name == name }) else { return false }
        let revision = nextConfigIntentRevision()
        let refreshed: [MCPServerConfig]
        do {
            refreshed = try await configWorker.setDisabledAndLoad(
                !enabled, name: name, revision: revision, in: configFileURL)
        } catch {
            guard ownsConfigIntent(revision) else { return false }
            await recoverAfterMutationFailure(error, revision: revision)
            return false
        }
        guard ownsConfigIntent(revision) else { return true }
        configs = refreshed
        configError = nil
        await reconcileConnection(named: name, in: refreshed)
        guard ownsConfigIntent(revision) else { return true }
        await refreshStates(for: revision)
        guard ownsConfigIntent(revision) else { return true }
        settleConfigIntent(revision)
        return true
    }

    func reconnect(_ name: String) async {
        cancelPendingPermission()
        let configRevision = nextConfigIntentRevision()
        let reconnectRevision = nextReconnectRevision(for: name)
        let loaded: [MCPServerConfig]
        do {
            loaded = try await configWorker.load(from: configFileURL)
        } catch {
            guard
                ownsReconnect(
                    name: name, reconnectRevision: reconnectRevision,
                    configRevision: configRevision)
            else { return }
            await failClosedConfig(error, revision: configRevision)
            return
        }
        guard
            ownsReconnect(
                name: name, reconnectRevision: reconnectRevision,
                configRevision: configRevision)
        else { return }
        // Force the selected server down first, then reconcile the complete authoritative file.
        // This also prevents a manual reconnect from publishing new file contents beside old live
        // connections for other edited or removed servers.
        await manager.disconnect(name: name)
        guard
            ownsReconnect(
                name: name, reconnectRevision: reconnectRevision,
                configRevision: configRevision)
        else { return }
        let pending = await manager.prepareReload(loaded)
        guard
            ownsReconnect(
                name: name, reconnectRevision: reconnectRevision,
                configRevision: configRevision)
        else { return }
        configs = loaded
        configError = nil
        await refreshStates(for: configRevision)
        guard
            ownsReconnect(
                name: name, reconnectRevision: reconnectRevision,
                configRevision: configRevision)
        else { return }
        settleConfigIntent(configRevision)
        await settleConnections(pending, revision: configRevision)
    }

    func test(_ config: MCPServerConfig) async -> Result<[MCPToolInfo], MCPError> {
        await manager.test(config)
    }

    /// Where GOAT can pull existing MCP server definitions from. Imported servers always arrive
    /// disabled (they run with your permissions and their tool schemas spend context budget).
    enum ImportSource: String, CaseIterable, Identifiable {
        case claude, codex
        var id: String { rawValue }
        var label: String { self == .claude ? "Claude Desktop" : "Codex" }
        var url: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .claude:
                return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
            case .codex: return home.appendingPathComponent(".codex/config.toml")
            }
        }
    }

    func importFromClaudeDesktop() async -> Int { await runImport(from: .claude) }

    func runImport(from source: ImportSource) async -> Int {
        let revision = nextConfigIntentRevision()
        do {
            guard await configWorker.fileExists(at: source.url) else {
                guard ownsConfigIntent(revision) else { return 0 }
                configError = "No \(source.label) config found."
                settleConfigIntent(revision)
                return 0
            }
            guard ownsConfigIntent(revision) else { return 0 }
            let format: MCPConfigFileWorker.ImportFormat =
                switch source {
                case .claude: .claudeDesktop
                case .codex: .codex
                }
            let imported = try await configWorker.importServers(
                from: source.url, format: format, revision: revision,
                into: configFileURL)
            guard ownsConfigIntent(revision) else { return imported.count }
            await load()
            return imported.count
        } catch {
            guard ownsConfigIntent(revision) else { return 0 }
            await recoverAfterMutationFailure(error, revision: revision)
            return 0
        }
    }

    func openConfigFile() {
        let url = configFileURL
        let revision = configIntentRevision
        Task {
            do {
                try await configWorker.ensureFileExists(at: url)
                guard ownsConfigIntent(revision) else { return }
                NSWorkspace.shared.open(url)
            } catch {
                guard ownsConfigIntent(revision) else { return }
                await failClosedConfig(error, revision: revision)
            }
        }
    }

    private func watchConfigFile(for revision: UInt64) async {
        let fd = await configWorker.openEventDescriptor(for: configFileURL)
        guard fd >= 0 else { return }
        guard ownsConfigIntent(revision) else {
            await configWorker.closeEventDescriptor(fd)
            return
        }
        configWatcher?.cancel()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.scheduleConfigWatchReload()
            }
        }
        source.setCancelHandler {
            Task.detached(priority: .utility) { close(fd) }
        }
        source.resume()
        configWatcher = source
    }

    private func scheduleConfigWatchReload() {
        configWatchReloadGeneration &+= 1
        let generation = configWatchReloadGeneration
        configWatchReloadTask?.cancel()
        configWatchReloadTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard
                let self,
                !Task.isCancelled,
                configWatchReloadGeneration == generation
            else { return }
            configWatchReloadTask = nil
            await load()  // also re-arms the watcher
        }
    }

    private func nextConfigIntentRevision() -> UInt64 {
        configIntentRevision &+= 1
        // A permission decision is valid only for the capability snapshot which presented it.
        // Config reloads and mutations deny an outstanding sheet before changing that snapshot.
        cancelPendingPermission()
        return configIntentRevision
    }

    private func ownsConfigIntent(_ revision: UInt64) -> Bool {
        configIntentRevision == revision && !Task.isCancelled
    }

    private func settleConfigIntent(_ revision: UInt64) {
        guard ownsConfigIntent(revision) else { return }
        settledConfigIntentRevision = revision
    }

    private func configCapabilitiesAreSettled(for revision: UInt64) -> Bool {
        settledConfigIntentRevision == revision && ownsConfigIntent(revision)
    }

    private func nextReconnectRevision(for name: String) -> UInt64 {
        let revision = (reconnectRevisions[name] ?? 0) &+ 1
        reconnectRevisions[name] = revision
        return revision
    }

    private func ownsReconnect(
        name: String, reconnectRevision: UInt64, configRevision: UInt64
    ) -> Bool {
        reconnectRevisions[name] == reconnectRevision && ownsConfigIntent(configRevision)
    }

    private func refreshStates(for revision: UInt64) async {
        let snapshot = await manager.snapshot()
        guard ownsConfigIntent(revision) else { return }
        states = snapshot
    }

    /// Connect a bounded number of servers at once so a large config cannot create an unbounded
    /// process/network burst. Each completed server is mirrored while the rest keep loading.
    private func settleConnections(
        _ attempts: [MCPServerManager.ConnectionAttempt], revision: UInt64
    ) async {
        await withTaskGroup(of: Bool.self) { group in
            var nextIndex = 0
            while nextIndex < min(MCPServerManager.maximumConcurrentConnections, attempts.count) {
                let attempt = attempts[nextIndex]
                nextIndex += 1
                group.addTask { [manager] in
                    await manager.connectPrepared(attempt) != nil
                }
            }

            while let didSettle = await group.next() {
                guard ownsConfigIntent(revision) else {
                    group.cancelAll()
                    return
                }
                if didSettle { await refreshStates(for: revision) }
                guard ownsConfigIntent(revision) else {
                    group.cancelAll()
                    return
                }
                guard nextIndex < attempts.count else { continue }
                let attempt = attempts[nextIndex]
                nextIndex += 1
                group.addTask { [manager] in
                    await manager.connectPrepared(attempt) != nil
                }
            }
        }
    }

    private func reconcileConnection(named name: String, in configs: [MCPServerConfig]) async {
        guard let authoritative = configs.first(where: { $0.name == name }), !authoritative.disabled else {
            await manager.disconnect(name: name)
            return
        }
        await manager.connect(authoritative)
    }

    private func revokeGrants(for servers: Set<String>) async throws {
        guard !servers.isEmpty else { return }
        if let db {
            for server in servers { try await db.deleteGrants(server: server) }
        }
        grantsCache = grantsCache.filter { !servers.contains($0.server) }
    }

    private func failClosedConfig(_ error: Error, revision: UInt64) async {
        guard ownsConfigIntent(revision) else { return }
        cancelPendingPermission()
        configs = []
        grantsCache = []
        configError = "mcp-servers.json: \(error.localizedDescription)"
        _ = await manager.prepareReload([])
        guard ownsConfigIntent(revision) else { return }
        await refreshStates(for: revision)
        guard ownsConfigIntent(revision) else { return }
        await watchConfigFile(for: revision)
        guard ownsConfigIntent(revision) else { return }
        settleConfigIntent(revision)
    }

    /// A rejected app mutation does not prove the authoritative config is corrupt. Re-read it and
    /// preserve healthy connections; only a failed authoritative read takes the global fail-closed
    /// path used by external edits and startup.
    private func recoverAfterMutationFailure(_ mutationError: Error, revision: UInt64) async {
        guard ownsConfigIntent(revision) else { return }
        let loaded: [MCPServerConfig]
        do {
            loaded = try await configWorker.load(from: configFileURL)
        } catch {
            guard ownsConfigIntent(revision) else { return }
            await failClosedConfig(error, revision: revision)
            return
        }
        guard ownsConfigIntent(revision) else { return }
        let pending = await manager.prepareReload(loaded)
        guard ownsConfigIntent(revision) else { return }
        configs = loaded
        configError = mutationError.localizedDescription
        await refreshStates(for: revision)
        guard ownsConfigIntent(revision) else { return }
        settleConfigIntent(revision)
        await settleConnections(pending, revision: revision)
    }

    // MARK: Tool exposure

    nonisolated static func requestToolName(server: String, tool: String) -> String {
        let label = asciiIdentifierFragment(tool)
        let digest = SHA256.hash(data: Data("\(server)\u{0}\(tool)".utf8))
        let suffix = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "mcp_\(label)_\(suffix)"
    }

    nonisolated private static func asciiIdentifierFragment(_ value: String) -> String {
        let characters = value.unicodeScalars.prefix(20).map { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122: return Character(String(scalar))
            default: return "_"
            }
        }
        let fragment = String(characters)
        return fragment.isEmpty ? "tool" : fragment
    }

    // MARK: Permission gate

    private func permissionDecision(
        route: ShepherdToolRoute, arguments: String
    ) async -> Bool {
        guard case .mcp(let capability) = route.origin else { return false }
        let preview = await Task.detached(priority: .userInitiated) {
            Self.permissionPreview(arguments)
        }.value
        guard let preview else {
            activity.log(
                .warn,
                "MCP blocked malformed or oversized arguments for \(route.server) · \(route.tool)")
            return false
        }
        guard await availableConfig(for: route) != nil else { return false }
        let identity = GrantIdentity(
            server: route.server, tool: route.tool,
            configFingerprint: capability.permissionFingerprint)
        if grantsCache.contains(identity) { return true }

        let choice = await requestPermission(
            PermissionRequest(server: route.server, tool: route.tool, arguments: preview))
        guard let currentConfig = await availableConfig(for: route),
            currentConfig.permissionFingerprint == identity.configFingerprint
        else { return false }
        switch choice {
        case .deny, .allowChat, .allowPen:
            return false
        case .allowOnce:
            return true
        case .alwaysAllow:
            guard let db else { return true }
            do {
                try await db.setGrant(
                    ToolGrantRecord(
                        server: route.server, tool: route.tool, policy: "always",
                        configFingerprint: identity.configFingerprint))
                guard let persistedConfig = await availableConfig(for: route),
                    persistedConfig.permissionFingerprint == identity.configFingerprint
                else { return false }
                grantsCache.insert(identity)
            } catch {
                activity.log(
                    .warn,
                    "MCP permission was allowed once but could not be remembered: \(error.localizedDescription)")
            }
            return true
        }
    }

    /// The router owns native grant scopes; this shared surface only collects the user's choice.
    func approvePenWrite(tool: String, preview: String, penName: String, allowsScopes: Bool) async -> PermissionChoice {
        let choice = await requestPermission(
            PermissionRequest(
                server: "Herder", tool: tool, arguments: preview, allowsAlways: false,
                penName: penName, allowsPenScopes: allowsScopes))
        return Task.isCancelled ? .deny : choice
    }

    private func requestPermission(_ request: PermissionRequest) async -> PermissionChoice {
        // Shepherd is sequential, but deny an orphaned waiter defensively before publishing another
        // permission surface. Request IDs stop an old sheet from resolving the replacement.
        if let orphaned = permissionWaiter {
            permissionWaiter = nil
            pendingPermission = nil
            orphaned.continuation.resume(returning: .deny)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<PermissionChoice, Never>) in
                permissionWaiter = PermissionWaiter(
                    requestID: request.id, continuation: continuation)
                pendingPermission = request
                if Task.isCancelled { resolvePermission(.deny, requestID: request.id) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolvePermission(.deny, requestID: request.id)
            }
        }
    }

    func resolvePermission(_ choice: PermissionChoice, requestID: UUID) {
        guard let waiter = permissionWaiter, waiter.requestID == requestID else { return }
        permissionWaiter = nil
        if pendingPermission?.id == requestID { pendingPermission = nil }
        waiter.continuation.resume(returning: choice)
    }

    /// Deny any permission request left hanging (used when generation is stopped).
    func cancelPendingPermission() {
        guard let requestID = permissionWaiter?.requestID else { return }
        resolvePermission(.deny, requestID: requestID)
    }

    private func availableConfig(for route: ShepherdToolRoute) async -> MCPServerConfig? {
        guard case .mcp(let capability) = route.origin else { return nil }
        let revision = configIntentRevision
        guard configCapabilitiesAreSettled(for: revision) else { return nil }
        guard
            let config = configs.first(where: {
                $0.name == route.server && !$0.disabled
                    && $0.permissionFingerprint == capability.permissionFingerprint
            })
        else {
            return nil
        }
        let available = await manager.isToolAvailable(
            server: route.server, tool: route.tool,
            capability: capability)
        guard configCapabilitiesAreSettled(for: revision), available else { return nil }
        return config
    }

    func logCall(server: String, tool: String, status: String, duration: TimeInterval) {
        callLog.insert(CallLogEntry(date: .now, server: server, tool: tool, status: status, duration: duration), at: 0)
        if callLog.count > 50 { callLog.removeLast(callLog.count - 50) }
        let timing = status == "ok" ? String(format: " %.1fs", duration) : ""
        activity.log(.mcp, "\(server) · \(tool) → \(status)\(timing)")
    }

    /// Produces a complete permission surface off the main actor. If pretty printing would expand
    /// too far, the original validated JSON is shown in full instead of hiding executable fields.
    nonisolated static func permissionPreview(_ value: String) -> String? {
        guard MCPServerManager.argumentsAreValid(value), let data = value.data(using: .utf8) else {
            return nil
        }
        guard
            let obj = try? JSONSerialization.jsonObject(with: data),
            let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
            let out = String(data: pretty, encoding: .utf8)
        else { return value }
        return out.utf8.count <= 64_000 ? out : value
    }
}

// MARK: - Shepherd's view of MCP

extension MCPModel: ShepherdToolSource {
    func availableToolSpecs(
        forChatID _: UUID,
        projectID _: UUID?,
        includeMCP: Bool,
        excludedMCPServers: Set<String>
    ) async -> ([ToolSpec], [String: ShepherdToolRoute]) {
        guard includeMCP else { return ([], [:]) }
        let revision = configIntentRevision
        guard configCapabilitiesAreSettled(for: revision) else { return ([], [:]) }
        let liveCapabilities = await manager.capabilitySnapshots()
        guard configCapabilitiesAreSettled(for: revision) else { return ([], [:]) }
        var specs: [ToolSpec] = []
        var mapping: [String: ShepherdToolRoute] = [:]
        for server in liveCapabilities.keys.sorted() {
            guard !excludedMCPServers.contains(server) else { continue }
            guard let live = liveCapabilities[server],
                configs.contains(where: {
                    $0.name == server && !$0.disabled
                        && $0.permissionFingerprint == live.token.permissionFingerprint
                })
            else { continue }
            for tool in live.tools.sorted(by: { $0.name < $1.name }) {
                guard !Self.isOwnerAdministrationTool(tool.name) else { continue }
                let name = Self.requestToolName(server: server, tool: tool.name)
                guard mapping[name] == nil else {
                    activity.log(.warn, "MCP tool identity collision blocked for \(server) · \(tool.name)")
                    continue
                }
                specs.append(
                    ToolSpec(
                        name: name,
                        description: "[\(server)] \(tool.description)",
                        parametersJSON: tool.inputSchemaJSON
                    ))
                mapping[name] = ShepherdToolRoute(
                    server: server, tool: tool.name, origin: .mcp(live.token))
            }
        }
        return (specs, mapping)
    }

    /// Known command-policy tools are administration surfaces, not model capabilities.
    nonisolated static func isOwnerAdministrationTool(_ name: String) -> Bool {
        [
            "add_to_whitelist", "remove_from_whitelist", "update_security_level",
            "approve_command", "deny_command",
        ].contains(name.lowercased())
    }

    func memoryEntries(forProjectID _: UUID?) async throws -> [PromptMemoryEntry] { [] }

    func extensionPromptSections(
        forChatID _: UUID,
        projectID _: UUID?,
        canLoadSkills _: Bool,
        requestedSkillName _: String?
    ) async -> [String] { [] }

    func turnDidPersist(_: ShepherdPersistedTurn) async -> ShepherdPersistedTurnReceipt? { nil }

    func requestName(server: String, tool: String) -> String {
        Self.requestToolName(server: server, tool: tool)
    }

    func authorizeAndInvoke(
        route: ShepherdToolRoute, argumentsJSON: String
    ) async throws -> ToolResult? {
        guard case .mcp(let capability) = route.origin else {
            throw MCPError.unknownTool(route.tool)
        }
        guard !Self.isOwnerAdministrationTool(route.tool) else {
            Judas.shared.recordTool(.denied, server: route.server, tool: route.tool)
            throw MCPError.failed(
                "Security administration is owner-only. The model cannot change command policy or approve its own pending commands. Ask the user to manage the server configuration."
            )
        }
        guard await permissionDecision(route: route, arguments: argumentsJSON) else {
            Judas.shared.recordTool(.denied, server: route.server, tool: route.tool)
            return nil
        }
        Judas.shared.recordTool(.allowed, server: route.server, tool: route.tool)
        do {
            return try await manager.invoke(
                server: route.server, tool: route.tool, argumentsJSON: argumentsJSON,
                capability: capability)
        } catch {
            // Invocation failures can retire the exact client. Mirror that state so Settings shows
            // Retry and subsequent turns stop advertising the dead capability.
            await refreshStates()
            if case MCPError.timeout = error {
                throw MCPError.failed(
                    "Tool timed out; its outcome is unknown. The connection was closed. Do not retry the action automatically or claim it succeeded. Ask the user to inspect the workspace and reconnect the server in MCP Settings before continuing. Interactive commands may be waiting for input that this tool cannot supply."
                )
            }
            throw error
        }
    }
}
