import Foundation
import Herd
import Hindsight
import Memory

extension MemoryModel {
    nonisolated static func globalBankIsDedicated(
        _ connection: HindsightBankConnection, providers: [MemoryProviderRecord],
        replacingProviderID: MemoryProviderID? = nil
    ) -> Bool {
        !providers.contains { provider in
            guard let route = provider.hindsight?.penRoute,
                let service = providers.first(where: { $0.id == route.serviceProviderID }),
                let endpoint = service.hindsight?.connection
            else { return false }
            return route.bankID == connection.bankID
                && (service.id == replacingProviderID
                    || (try? HindsightProviderClient.validatedBaseURL(endpoint.apiURL))
                        == (try? HindsightProviderClient.validatedBaseURL(connection.apiURL)))
        }
    }

    func hindsightStore(forProjectID projectID: UUID?) throws -> HindsightMemoryStore {
        let providerID = providerID(forProjectID: projectID)
        guard isUsingHindsight(forProjectID: projectID) else {
            throw LocalStoreError.invalidData(
                path: Home.memoryConfigurationFile.path,
                reason: unavailableProviderReason(providerID) ?? "Hindsight is unavailable")
        }
        if projectID == nil, let connection = hindsightConnection(forProjectID: nil),
            !Self.globalBankIsDedicated(connection, providers: configuration.providers)
        {
            throw LocalStoreError.invalidData(
                path: "Hindsight",
                reason: "This bank belongs to a Pen. Select a separate Global bank in Memory settings.")
        }
        return HindsightMemoryStore(providerID: providerID, client: hindsightClient(for: providerID))
    }

    @discardableResult
    func connectHindsight(_ provider: MemoryProviderRecord, retryImmediately: Bool = false) async
        -> HindsightProviderStatus
    {
        let reconciliationID = hindsightReconciliationID
        guard builtInSettings.hindsightEnabled else { return .unavailable(provider.id) }
        guard let connection = resolvedHindsightConnection(for: provider),
            let credentialProviderID = hindsightCredentialProviderID(for: provider.id)
        else {
            let status = HindsightProviderStatus.failed(provider.id, "This Hindsight route has no configured service.")
            hindsightStatuses[provider.id] = status
            return status
        }
        let status = await hindsightClient(for: provider.id).connect(
            providerID: provider.id,
            connection: connection,
            credentialProviderID: credentialProviderID, retryImmediately: retryImmediately)
        guard builtInSettings.hindsightEnabled, hindsightReconciliationID == reconciliationID,
            configuration.providers.contains(provider), resolvedHindsightConnection(for: provider) == connection
        else { return .unavailable(provider.id) }
        hindsightStatuses[provider.id] = status
        if status.state == .failed, let error = status.error {
            activity.log(.warn, "Hindsight provider: \(error)")
        }
        return status
    }

    func resolvedHindsightConnection(for provider: MemoryProviderRecord) -> HindsightBankConnection? {
        if let connection = provider.hindsight?.connection { return connection }
        guard let route = provider.hindsight?.penRoute,
            let service = configuration.providers.first(where: { $0.id == route.serviceProviderID }),
            let connection = service.hindsight?.connection
        else { return nil }
        return HindsightBankConnection(apiURL: connection.apiURL, bankID: route.bankID)
    }

    func hindsightCredentialProviderID(for providerID: MemoryProviderID) -> MemoryProviderID? {
        guard let provider = configuration.providers.first(where: { $0.id == providerID }) else { return nil }
        if provider.hindsight?.connection != nil { return provider.id }
        return provider.hindsight?.penRoute?.serviceProviderID
    }

    func penBindingMatchesActiveProvider(_ binding: PenMemoryBinding) -> Bool {
        guard let active = configuration.providers.first(where: { $0.id == configuration.global.providerID }) else {
            return false
        }
        switch active.kind {
        case .wiki:
            return binding.selection.providerID == active.id
        case .hindsight:
            guard
                let routeProvider = configuration.providers.first(where: {
                    $0.id == binding.selection.providerID
                })
            else { return false }
            return routeProvider.hindsight?.penRoute?.serviceProviderID == active.id
        }
    }

    @discardableResult
    func testHindsight(_ providerID: MemoryProviderID) async -> HindsightProviderStatus? {
        guard let provider = configuration.providers.first(where: { $0.id == providerID }),
            provider.kind == .hindsight
        else { return nil }
        return await connectHindsight(provider, retryImmediately: true)
    }

    /// Retry the configured scope before turn preparation without requiring its old health to be ready.
    func recoverHindsightIfNeeded(forProjectID projectID: UUID?) async {
        guard isEnabled, builtInSettings.hindsightEnabled else { return }
        if let projectID {
            guard let binding = configuration.pens[projectID.uuidString], binding.enabled,
                penBindingMatchesActiveProvider(binding)
            else { return }
        }
        let id = providerID(forProjectID: projectID)
        guard !isProviderAvailable(id), let provider = configuration.providers.first(where: { $0.id == id }),
            provider.kind == .hindsight
        else { return }
        _ = await connectHindsight(provider)
    }

    /// Tests an editor draft without persisting it or replacing a healthy active session. A blank
    /// key reuses the existing saved credential when editing.
    func testHindsightConfiguration(
        existingProviderID: MemoryProviderID?,
        apiURL: String,
        bankID: String,
        apiToken: String
    ) async -> HindsightProviderStatus {
        let editableProviderID = existingProviderID.flatMap { providerID in
            configuration.providers.first(where: { $0.id == providerID })?.hindsight?.connection == nil
                ? nil : providerID
        }
        let providerID =
            editableProviderID
            ?? MemoryProviderID(rawValue: "hindsight-\(UUID().uuidString.lowercased())")
        guard builtInSettings.hindsightEnabled else { return .unavailable(providerID) }
        let connection = HindsightBankConnection(apiURL: apiURL, bankID: bankID)
        do {
            let token = try effectiveHindsightToken(
                existingProviderID: existingProviderID, draft: apiToken)
            let testClient = HindsightProviderClient()
            switch await testClient.bind(
                providerID: providerID,
                connection: connection,
                apiToken: token)
            {
            case .success:
                let status = await testClient.status(for: providerID)
                await testClient.disconnect()
                // An unchanged saved draft must refresh the operational client and its card too.
                if apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    let saved = configuration.providers.first(where: { $0.id == editableProviderID }),
                    let existing = saved.hindsight?.connection,
                    existing.bankID == bankID,
                    (try? HindsightProviderClient.validatedBaseURL(existing.apiURL))
                        == (try? HindsightProviderClient.validatedBaseURL(apiURL))
                {
                    return await connectHindsight(saved, retryImmediately: true)
                }
                return status
            case .failure(let status):
                return status
            }
        } catch {
            return .failed(providerID, error.localizedDescription)
        }
    }

    /// Lists banks only after an explicit Test Server action. The control client is bounded,
    /// refuses redirects, and does not expose deletion.
    func discoverHindsightBanks(
        existingProviderID: MemoryProviderID?,
        apiURL: String,
        apiToken: String
    ) async throws -> [HindsightBankSummary] {
        guard builtInSettings.hindsightEnabled, configurationLoadState == .ready else {
            throw HindsightControlError.invalidConfiguration
        }
        let token = try effectiveHindsightToken(
            existingProviderID: existingProviderID, draft: apiToken)
        return try await hindsightControlClient.listBanks(apiURL: apiURL, apiToken: token)
    }

    /// Creates a new bank through Hindsight's official control API. The client relists banks
    /// immediately before creation to guard against accidentally updating an existing bank.
    func createHindsightBank(
        existingProviderID: MemoryProviderID?,
        apiURL: String,
        bankID: String,
        apiToken: String,
        templateJSON: String?
    ) async throws {
        guard builtInSettings.hindsightEnabled, configurationLoadState == .ready else {
            throw HindsightControlError.invalidConfiguration
        }
        let token = try effectiveHindsightToken(
            existingProviderID: existingProviderID, draft: apiToken)
        try await hindsightControlClient.createBank(
            apiURL: apiURL,
            bankID: bankID,
            apiToken: token,
            templateJSON: templateJSON)
    }

    /// Saves one explicit server and bank binding. New connections become the active Global
    /// provider because the setup dialog is opened by choosing the Hindsight provider card.
    @discardableResult
    func saveHindsightConfiguration(
        existingProviderID: MemoryProviderID?,
        apiURL: String,
        bankID: String,
        apiToken: String,
        activate: Bool,
        initialMemory: String
    ) async -> Bool {
        guard builtInSettings.hindsightEnabled, configurationLoadState == .ready else { return false }
        let editableProviderID = existingProviderID.flatMap { providerID in
            configuration.providers.first(where: { $0.id == providerID })?.hindsight?.connection == nil
                ? nil : providerID
        }
        let providerID =
            editableProviderID
            ?? MemoryProviderID(rawValue: "hindsight-\(UUID().uuidString.lowercased())")
        let connection = HindsightBankConnection(apiURL: apiURL, bankID: bankID)
        let credentialKey = HindsightProviderClient.credentialKey(for: providerID)
        let priorProvider = configuration.providers.first { $0.id == providerID }
        let client = hindsightClient(for: providerID)
        var previousToken: String?
        var didBind = false
        do {
            guard
                Self.globalBankIsDedicated(
                    connection, providers: configuration.providers, replacingProviderID: providerID)
            else {
                throw LocalStoreError.invalidData(
                    path: "Hindsight",
                    reason: "This bank belongs to a Pen. Choose a separate Global bank.")
            }
            previousToken = try CredentialStore.get(credentialKey)
            let effectiveToken = try effectiveHindsightToken(
                existingProviderID: existingProviderID, draft: apiToken)
            switch await client.bind(
                providerID: providerID,
                connection: connection,
                apiToken: effectiveToken?.isEmpty == false ? effectiveToken : nil)
            {
            case .success(let binding):
                didBind = true
                let provider = MemoryProviderRecord(
                    id: providerID,
                    displayName: priorProvider?.displayName ?? "Hindsight",
                    kind: .hindsight,
                    hindsight: binding)
                try CredentialStore.set(effectiveToken ?? "", for: credentialKey)
                guard
                    await mutateConfiguration({ configuration in
                        if let index = configuration.providers.firstIndex(where: { $0.id == providerID }) {
                            configuration.providers[index] = provider
                        } else {
                            configuration.providers.append(provider)
                        }
                        if activate {
                            configuration.global.providerID = providerID
                            configuration.global.history = Self.prepending(
                                providerID, to: configuration.global.history)
                            configuration.defaultPenProviderID = providerID
                        }
                    })
                else {
                    try CredentialStore.set(previousToken ?? "", for: credentialKey)
                    await client.disconnect()
                    if let priorProvider { _ = await connectHindsight(priorProvider) }
                    return false
                }
                hindsightStatuses[providerID] = await client.status(for: providerID)
                await reconnectSelectedHindsightProviders()
                let starter = initialMemory.trimmingCharacters(in: .whitespacesAndNewlines)
                if !starter.isEmpty {
                    do {
                        _ = try await HindsightMemoryStore(providerID: providerID, client: client)
                            .remember(
                                MemoryRememberRequest(
                                    idempotencyKey: UUID(),
                                    title: "Initial GOAT memory",
                                    summary: String(starter.prefix(512)),
                                    content: starter,
                                    context: MemoryContext()))
                    } catch {
                        configurationError =
                            "Hindsight connected, but the initial memory was not accepted: \(error.localizedDescription)"
                        hindsightStatuses[providerID] = await client.status(for: providerID)
                        activity.log(.warn, configurationError ?? "Hindsight initial memory failed.")
                    }
                }
                return true
            case .failure(let status):
                hindsightStatuses[providerID] = status
                configurationError = status.error
                return false
            }
        } catch {
            if didBind {
                try? CredentialStore.set(previousToken ?? "", for: credentialKey)
                await client.disconnect()
                if let priorProvider { _ = await connectHindsight(priorProvider) }
            }
            configurationError = error.localizedDescription
            activity.log(.warn, "Hindsight provider: \(error.localizedDescription)")
            return false
        }
    }

    private func effectiveHindsightToken(
        existingProviderID: MemoryProviderID?,
        draft: String
    ) throws -> String? {
        let token = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { return token }
        guard let existingProviderID,
            let saved = try CredentialStore.get(
                HindsightProviderClient.credentialKey(for: existingProviderID)),
            !saved.isEmpty
        else { return nil }
        return saved
    }

    /// Removes every local Hindsight connection and credential. Server banks are never mutated.
    /// Configuration normalization returns affected scopes to local Markdown.
    @discardableResult
    func removeHindsightConfiguration(_ providerID: MemoryProviderID) async -> Bool {
        guard
            let provider = configuration.providers.first(where: { $0.id == providerID }),
            provider.kind == .hindsight
        else { return false }
        let providerIDs = configuration.providers.filter { $0.kind == .hindsight }.map(\.id)
        var previousTokens: [MemoryProviderID: String] = [:]
        do {
            for id in providerIDs {
                let key = HindsightProviderClient.credentialKey(for: id)
                if let token = try CredentialStore.get(key) { previousTokens[id] = token }
                try CredentialStore.delete(key)
            }
            guard
                await mutateConfiguration({ configuration in
                    for id in providerIDs { configuration.removeHindsightProvider(id) }
                })
            else {
                for (id, token) in previousTokens {
                    try CredentialStore.set(token, for: HindsightProviderClient.credentialKey(for: id))
                }
                return false
            }
        } catch {
            for (id, token) in previousTokens {
                try? CredentialStore.set(token, for: HindsightProviderClient.credentialKey(for: id))
            }
            configurationError = error.localizedDescription
            activity.log(.warn, "Hindsight credential: \(error.localizedDescription)")
            return false
        }
        for id in providerIDs {
            if let client = hindsightClients.removeValue(forKey: id) { await client.disconnect() }
            hindsightStatuses.removeValue(forKey: id)
        }
        return true
    }

    func hindsightClient(for providerID: MemoryProviderID) -> HindsightProviderClient {
        if let client = hindsightClients[providerID] { return client }
        let client = hindsightClientFactory()
        hindsightClients[providerID] = client
        return client
    }

}
