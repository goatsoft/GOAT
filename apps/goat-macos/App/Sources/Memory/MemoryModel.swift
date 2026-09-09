import Foundation
import Herd
import Hindsight
import Hoofprint
import Inference
import MCPClient
import Memory
import Observation
import Pens
import Shepherd
import Tools

enum MemoryConfigurationLoadState: Equatable {
    case loading
    case ready
    case failed
}

@MainActor
@Observable
final class MemoryModel {
    let configurationStore: MemoryConfigurationStore
    let builtInSettings: BuiltInExtensionSettings
    let activity: ActivityLog
    var configurationRevision: MemoryConfigurationRevision?
    var hindsightClients: [MemoryProviderID: HindsightProviderClient] = [:]
    var hindsightStatuses: [MemoryProviderID: HindsightProviderStatus] = [:]
    var hindsightReconciliationID = UUID()
    let hindsightControlClient = HindsightControlClient()
    let hindsightClientFactory: () -> HindsightProviderClient
    var configuration = MemoryConfiguration.fresh
    var configurationError: String?
    var configurationLoadState: MemoryConfigurationLoadState = .loading

    /// Configuration is an authority boundary. Until it has loaded and validated successfully,
    /// memory exposes no capability, even though `configuration` retains a display-safe default.
    var isEnabled: Bool { configurationLoadState == .ready && configuration.enabled }
    var isConfigurationReady: Bool { configurationLoadState == .ready }
    var providers: [MemoryProviderRecord] {
        configuration.providers
            .filter { $0.kind == .wiki || (builtInSettings.hindsightEnabled && $0.hindsight?.connection != nil) }
            .sorted { providerSortKey($0.id) < providerSortKey($1.id) }
    }
    var configuredHindsightProvider: MemoryProviderRecord? {
        guard builtInSettings.hindsightEnabled else { return nil }
        if let provider = configuration.providers.first(where: {
            $0.id == configuration.global.providerID && $0.hindsight?.connection != nil
        }) {
            return provider
        }
        return configuration.providers.first { $0.hindsight?.connection != nil }
    }

    func isEnabled(forProjectID projectID: UUID?) -> Bool {
        guard isEnabled else { return false }
        if let projectID {
            guard let binding = configuration.pens[projectID.uuidString],
                binding.enabled,
                penBindingMatchesActiveProvider(binding)
            else { return false }
        }
        return isProviderAvailable(providerID(forProjectID: projectID))
    }

    /// A provider becomes selectable only when GOAT has validated its durable contract. Hindsight
    /// remains unavailable until GOAT verifies the explicitly selected server bank.
    func isProviderAvailable(_ providerID: MemoryProviderID) -> Bool {
        guard let provider = configuration.providers.first(where: { $0.id == providerID }) else {
            return false
        }
        switch provider.kind {
        case .wiki:
            return providerID == .localWiki || providerID == .llmWiki
        case .hindsight:
            return builtInSettings.hindsightEnabled && hindsightStatuses[providerID]?.state == .ready
        }
    }

    func unavailableProviderReason(_ providerID: MemoryProviderID) -> String? {
        guard !isProviderAvailable(providerID) else { return nil }
        if !builtInSettings.hindsightEnabled,
            configuration.providers.first(where: { $0.id == providerID })?.kind == .hindsight
        {
            return "Hindsight is disabled in Extensions. Enable it there or select a local memory provider."
        }
        return hindsightStatuses[providerID]?.error
            ?? "This provider is not connected. GOAT will not read or write memory."
    }

    func providerName(forProjectID projectID: UUID?) -> String {
        let providerID = providerID(forProjectID: projectID)
        return configuration.providers.first(where: { $0.id == providerID })?.displayName ?? "Unavailable provider"
    }

    func providerID(forProjectID projectID: UUID?) -> MemoryProviderID {
        if let projectID, let binding = configuration.pens[projectID.uuidString],
            binding.enabled,
            penBindingMatchesActiveProvider(binding)
        {
            return binding.selection.providerID
        }
        return configuration.global.providerID
    }

    func penMemoryIsEnabled(forProjectID projectID: UUID) -> Bool {
        guard let binding = configuration.pens[projectID.uuidString] else { return false }
        return binding.enabled && penBindingMatchesActiveProvider(binding)
    }

    func provider(forProjectID projectID: UUID?) -> MemoryProviderRecord? {
        configuration.providers.first { $0.id == providerID(forProjectID: projectID) }
    }

    func isUsingHindsight(forProjectID projectID: UUID?) -> Bool {
        isEnabled(forProjectID: projectID)
            && provider(forProjectID: projectID)?.kind == .hindsight
            && isProviderAvailable(providerID(forProjectID: projectID))
    }

    func hindsightStatus(forProjectID projectID: UUID?) -> HindsightProviderStatus? {
        guard let projectID else { return hindsightStatuses[configuration.global.providerID] }
        guard let binding = configuration.pens[projectID.uuidString], penBindingMatchesActiveProvider(binding) else {
            return nil
        }
        return hindsightStatuses[binding.selection.providerID]
    }

    func hindsightStatus(for providerID: MemoryProviderID) -> HindsightProviderStatus? {
        hindsightStatuses[providerID]
    }

    func hindsightHasAPIKey(for providerID: MemoryProviderID) -> Bool {
        let credentialProviderID = hindsightCredentialProviderID(for: providerID) ?? providerID
        return ((try? CredentialStore.get(HindsightProviderClient.credentialKey(for: credentialProviderID))) ?? nil)
            != nil
    }

    static let recentRecordLimit = 20

    func hindsightConnection(forProjectID projectID: UUID?) -> HindsightBankConnection? {
        guard builtInSettings.hindsightEnabled, let provider = provider(forProjectID: projectID) else { return nil }
        return resolvedHindsightConnection(for: provider)
    }

    /// The user-facing Hindsight UI uses its conventional control-plane port. This link never
    /// carries an API credential and opens only following the user's click, through JUDAS.
    nonisolated static func hindsightUIURL(apiURL: String) -> URL? {
        guard let base = try? HindsightProviderClient.validatedBaseURL(apiURL),
            var url = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return nil }
        url.port = 9999
        url.path = "/"
        url.query = nil
        url.fragment = nil
        return url.url
    }

    func hindsightBankURL(forProjectID projectID: UUID?) -> URL? {
        guard let connection = hindsightConnection(forProjectID: projectID) else { return nil }
        return Self.hindsightUIURL(apiURL: connection.apiURL)
    }

    func supportsMemoryGraph(forProjectID projectID: UUID?) -> Bool {
        usesLLMWiki(forProjectID: projectID) || isUsingHindsight(forProjectID: projectID)
    }

    func usesLLMWiki(forProjectID projectID: UUID?) -> Bool {
        providerID(forProjectID: projectID) == .llmWiki && isProviderAvailable(.llmWiki)
    }

    init(
        activity: ActivityLog, configurationStore: MemoryConfigurationStore = MemoryConfigurationStore(),
        builtInSettings: BuiltInExtensionSettings? = nil,
        hindsightClientFactory: @escaping () -> HindsightProviderClient = { HindsightProviderClient() }
    ) {
        self.hindsightClientFactory = hindsightClientFactory
        self.builtInSettings = builtInSettings ?? BuiltInExtensionSettings()
        self.activity = activity
        self.configurationStore = configurationStore
    }

    /// One store root per Pen. The store receives a global context because the root itself is
    /// already the Pen's ownership boundary; this avoids a hidden shared `projects/` subtree.
    private func markdownStore(forProjectID projectID: UUID?) async throws -> WikiMemoryStore {
        guard let projectID else { return WikiMemoryStore(root: Home.memoryDir) }
        let folder = try await Task.detached(priority: .userInitiated) {
            try PenStore.folder(for: projectID.uuidString)
        }.value
        guard let folder else {
            throw LocalStoreError.invalidData(path: projectID.uuidString, reason: "Pen folder is missing")
        }
        // The Pen folder owns the store. Its sole scope is named `memory`, so notes and
        // MEMORY.md sit directly at <pen>/memory rather than under a redundant global folder.
        return WikiMemoryStore(root: folder, globalDirectoryName: "memory")
    }

    func llmWikiStore(forProjectID projectID: UUID?) async throws -> LLMWikiMemoryStore {
        guard let projectID else {
            return LLMWikiMemoryStore(root: Home.memoryDir.appendingPathComponent("llm-wiki"))
        }
        let folder = try await Task.detached(priority: .userInitiated) {
            try PenStore.folder(for: projectID.uuidString)
        }.value
        guard let folder else {
            throw LocalStoreError.invalidData(path: projectID.uuidString, reason: "Pen folder is missing")
        }
        return LLMWikiMemoryStore(
            root: folder.appendingPathComponent("memory/llm-wiki", isDirectory: true))
    }

    func activeStore(forProjectID projectID: UUID?) async throws -> any EditableMemoryStore {
        try requireOperationalProvider(forProjectID: projectID)
        switch providerID(forProjectID: projectID) {
        case .localWiki:
            return try await markdownStore(forProjectID: projectID)
        case .llmWiki:
            return try await llmWikiStore(forProjectID: projectID)
        default:
            throw LocalStoreError.invalidData(
                path: Home.memoryDir.path,
                reason: unavailableProviderReason(providerID(forProjectID: projectID))
                    ?? "\(providerName(forProjectID: projectID)) is not connected")
        }
    }

    private func requireOperationalProvider(forProjectID projectID: UUID?) throws {
        guard configurationLoadState == .ready else {
            throw LocalStoreError.invalidData(
                path: Home.memoryConfigurationFile.path,
                reason: configurationError ?? "memory configuration is unavailable")
        }
        guard configuration.enabled else {
            throw LocalStoreError.invalidData(
                path: Home.memoryConfigurationFile.path,
                reason: "memory is disabled in Settings")
        }
        if let projectID, !penMemoryIsEnabled(forProjectID: projectID) {
            throw LocalStoreError.invalidData(
                path: Home.memoryConfigurationFile.path,
                reason: "memory is disabled for this Pen")
        }
        let providerID = providerID(forProjectID: projectID)
        guard isProviderAvailable(providerID) else {
            throw LocalStoreError.invalidData(
                path: Home.memoryConfigurationFile.path,
                reason: unavailableProviderReason(providerID)
                    ?? "\(providerName(forProjectID: projectID)) is unavailable")
        }
    }

    func storageContext(forProjectID projectID: UUID?) -> MemoryContext {
        MemoryContext()
    }

    func logCall(tool: String, status: String, duration: TimeInterval) {
        activity.log(.memory, "\(tool) → \(status)\(status == "ok" ? String(format: " %.1fs", duration) : "")")
    }

    func invoke(tool: String, argumentsJSON: String, context: MemoryContext) async throws -> ToolResult {
        try await MemoryToolHandler(model: self).invoke(tool: tool, argumentsJSON: argumentsJSON, context: context)
    }
}
