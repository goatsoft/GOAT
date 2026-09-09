import Foundation
import Herd
import Hindsight
import Memory

extension MemoryModel {
    func load() async {
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { [configurationStore] in
                try configurationStore.loadOrInitialize()
            }.value
            configuration = loaded.configuration
            configurationRevision = loaded.revision
            configurationError = nil
            configurationLoadState = .ready
            await reconnectSelectedHindsightProviders()
        } catch {
            configurationError = error.localizedDescription
            configurationRevision = nil
            configurationLoadState = .failed
            activity.log(.warn, "memory configuration: \(error.localizedDescription)")
        }
    }

    func setHindsightExtensionEnabled(_ enabled: Bool) async {
        builtInSettings.setHindsightEnabled(enabled)
        await reconnectSelectedHindsightProviders()
    }

    func reconnectSelectedHindsightProviders() async {
        let revision = UUID()
        hindsightReconciliationID = revision
        var selectedIDs = Set([configuration.global.providerID])
        for binding in configuration.pens.values
        where binding.enabled && penBindingMatchesActiveProvider(binding) {
            selectedIDs.insert(binding.selection.providerID)
        }
        if !builtInSettings.hindsightEnabled { selectedIDs.removeAll() }
        for (id, client) in hindsightClients where !selectedIDs.contains(id) {
            await client.disconnect()
            guard hindsightReconciliationID == revision else { return }
            hindsightStatuses[id] = .unavailable(id)
        }
        guard builtInSettings.hindsightEnabled else { return }
        let providers = configuration.providers.filter { $0.kind == .hindsight && selectedIDs.contains($0.id) }
        for provider in providers {
            guard hindsightReconciliationID == revision else { return }
            _ = await connectHindsight(provider)
        }
    }

    private func prepareSelection(_ providerID: MemoryProviderID) async -> Bool {
        guard let provider = configuration.providers.first(where: { $0.id == providerID }) else { return false }
        if provider.kind == .hindsight {
            return (await connectHindsight(provider)).state == .ready
        }
        return isProviderAvailable(providerID)
    }

    func setEnabled(_ enabled: Bool) async {
        let revision: MemoryConfigurationRevision
        if let current = configurationRevision {
            revision = current
        } else {
            await load()
            guard let loadedRevision = configurationRevision else { return }
            revision = loadedRevision
        }
        var updated = configuration
        updated.enabled = enabled
        do {
            let saved = try await Task.detached(priority: .userInitiated) { [configurationStore] in
                try configurationStore.save(updated, ifRevision: revision)
            }.value
            configuration = saved.configuration
            configurationRevision = saved.revision
            configurationError = nil
        } catch {
            configurationError = error.localizedDescription
            activity.log(.warn, "memory configuration: \(error.localizedDescription)")
        }
    }

    func setEnabled(
        _ enabled: Bool,
        forProjectID projectID: UUID?,
        projectName: String? = nil
    ) async {
        guard let projectID else {
            await setEnabled(enabled)
            return
        }
        guard enabled else {
            let changed = await mutateConfiguration { configuration in
                let id = projectID.uuidString
                let existing = configuration.pens[id]
                let providerID = existing?.selection.providerID ?? configuration.global.providerID
                configuration.pens[id] = PenMemoryBinding(
                    enabled: false,
                    selection: existing?.selection ?? .explicit(providerID),
                    history: existing?.history ?? [providerID])
            }
            if changed { await reconnectSelectedHindsightProviders() }
            return
        }

        guard let active = configuration.providers.first(where: { $0.id == configuration.global.providerID }) else {
            return
        }
        guard active.kind == .hindsight else {
            await mutateConfiguration { configuration in
                let id = projectID.uuidString
                let existing = configuration.pens[id]
                configuration.pens[id] = PenMemoryBinding(
                    enabled: true,
                    selection: .explicit(active.id),
                    history: Self.prepending(active.id, to: existing?.history ?? []))
            }
            return
        }

        await enableHindsight(
            forProjectID: projectID,
            projectName: projectName ?? "Pen",
            service: active)
    }

    private func enableHindsight(
        forProjectID projectID: UUID,
        projectName: String,
        service: MemoryProviderRecord
    ) async {
        guard builtInSettings.hindsightEnabled, let serviceConnection = service.hindsight?.connection else {
            configurationError = "Reconnect Hindsight before enabling it for this Pen."
            return
        }
        let id = projectID.uuidString
        let existing = configuration.pens[id]
        let existingRoute = existing.flatMap { binding in
            configuration.providers.first(where: { $0.id == binding.selection.providerID })
        }
        let bankID: String
        let routeProviderID: MemoryProviderID
        if let existingRoute,
            let route = existingRoute.hindsight?.penRoute,
            route.serviceProviderID == service.id
        {
            bankID = route.bankID
            routeProviderID = existingRoute.id
        } else {
            bankID = HindsightBankDefaults.penBankID(name: projectName, id: projectID)
            routeProviderID = MemoryProviderID(rawValue: "hindsight-\(projectID.uuidString.lowercased())")
        }
        guard bankID != serviceConnection.bankID else {
            configurationError = "This Pen's bank is selected as Global memory. Choose a separate Global bank first."
            return
        }
        let route = HindsightPenBankRoute(serviceProviderID: service.id, bankID: bankID)
        let routeProvider = MemoryProviderRecord(
            id: routeProviderID,
            displayName: "Hindsight",
            kind: .hindsight,
            hindsight: HindsightProviderConfiguration(penRoute: route))
        if let collision = configuration.providers.first(where: { $0.id == routeProviderID }),
            collision != routeProvider
        {
            configurationError = "This Pen's Hindsight route conflicts with an existing provider identity."
            return
        }
        do {
            let token = try CredentialStore.get(HindsightProviderClient.credentialKey(for: service.id))
            try await hindsightControlClient.ensureBank(
                apiURL: serviceConnection.apiURL,
                bankID: bankID,
                apiToken: token,
                templateJSON: HindsightBankDefaults.goatTemplate)
            let status = await hindsightClient(for: routeProviderID).connect(
                providerID: routeProviderID,
                connection: HindsightBankConnection(apiURL: serviceConnection.apiURL, bankID: bankID),
                credentialProviderID: service.id)
            hindsightStatuses[routeProviderID] = status
            guard status.state == .ready else {
                configurationError = status.error ?? "GOAT could not connect this Pen's Hindsight bank."
                return
            }
            guard builtInSettings.hindsightEnabled, configuration.global.providerID == service.id,
                configuration.providers.first(where: { $0.id == service.id })?.hindsight?.connection
                    == serviceConnection
            else {
                await hindsightClient(for: routeProviderID).disconnect()
                hindsightStatuses[routeProviderID] = .unavailable(routeProviderID)
                configurationError =
                    "The memory provider changed before this Pen finished connecting. Enable it again."
                return
            }
            let changed = await mutateConfiguration { configuration in
                if !configuration.providers.contains(where: { $0.id == routeProviderID }) {
                    configuration.providers.append(routeProvider)
                }
                configuration.pens[id] = PenMemoryBinding(
                    enabled: true,
                    selection: .explicit(routeProviderID),
                    history: Self.prepending(routeProviderID, to: existing?.history ?? []))
            }
            guard changed else {
                await hindsightClient(for: routeProviderID).disconnect()
                hindsightStatuses[routeProviderID] = .unavailable(routeProviderID)
                return
            }
            configurationError = nil
        } catch {
            configurationError = error.localizedDescription
            activity.log(.warn, "Hindsight Pen bank: \(error.localizedDescription)")
        }
    }

    func setProvider(_ providerID: MemoryProviderID, forProjectID projectID: UUID?) async {
        guard projectID == nil, await prepareSelection(providerID) else { return }
        let changed = await mutateConfiguration { configuration in
            configuration.global.providerID = providerID
            configuration.global.history = Self.prepending(providerID, to: configuration.global.history)
            // Retained for schema-1 compatibility. It is no longer a separate product setting.
            configuration.defaultPenProviderID = providerID
        }
        if changed { await reconnectSelectedHindsightProviders() }
    }

    @discardableResult
    func mutateConfiguration(_ mutation: @escaping @Sendable (inout MemoryConfiguration) -> Void) async -> Bool {
        let revision: MemoryConfigurationRevision
        if let current = configurationRevision {
            revision = current
        } else {
            await load()
            guard let loaded = configurationRevision else { return false }
            revision = loaded
        }
        var updated = configuration
        mutation(&updated)
        do {
            let saved = try await Task.detached(priority: .userInitiated) { [configurationStore] in
                try configurationStore.save(updated, ifRevision: revision)
            }.value
            configuration = saved.configuration
            configurationRevision = saved.revision
            configurationError = nil
            configurationLoadState = .ready
            return true
        } catch {
            configurationError = error.localizedDescription
            activity.log(.warn, "memory configuration: \(error.localizedDescription)")
            return false
        }
    }

    nonisolated static func prepending(_ providerID: MemoryProviderID, to history: [MemoryProviderID])
        -> [MemoryProviderID]
    {
        Array(([providerID] + history.filter { $0 != providerID }).prefix(MemoryConfiguration.maximumHistoryEntries))
    }

    func providerSortKey(_ id: MemoryProviderID) -> (Int, String) {
        switch id {
        case .localWiki: (0, id.rawValue)
        case .llmWiki: (1, id.rawValue)
        default: (2, id.rawValue)
        }
    }

}
