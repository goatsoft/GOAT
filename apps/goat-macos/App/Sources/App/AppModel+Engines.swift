import Bleet
import Foundation
import Inference
import JUDAS

extension AppModel {
    // MARK: Engine lifecycle

    func discover() async {
        guard startupPhase.hasLocalState else { return }
        await refreshEngineApplicationAvailability()
        guard let profile = activeEngineProfile else {
            health = .offline("No engine selected")
            return
        }
        guard let savedURL = URL(string: profile.url) else {
            health = .offline("Invalid engine URL")
            return
        }
        let savedKey = engineCredentials[Self.keyStore(profile.id)]
        guard let intentRevision = beginEngineIntent(),
            let operation = await beginEngineOperation(for: intentRevision)
        else { return }

        let savedTarget = EngineLifecycleController.Target(
            profileID: profile.id,
            config: EngineConfig(
                baseURL: savedURL, apiKey: savedKey,
                name: profile.name, metadataDialect: profile.preset.metadataDialect,
                requestStyle: .automatic))
        if let resolution = await engineLifecycle.probe(savedTarget, for: operation),
            resolution.health.isOK || resolution.health == .authRequired
        {
            await publishEngine(
                resolution, intentRevision: intentRevision, operation: operation,
                persistDiscoveredURL: false)
            return
        }

        // A credential belongs to one explicit profile URL. Never attach it to a fallback port,
        // and never rewrite that profile to a different service behind the user's back.
        if savedKey == nil {
            var candidates = profile.preset.conventionalDiscoveryURLs
            candidates.removeAll { $0 == profile.url }
            for candidate in candidates {
                guard let url = URL(string: candidate) else { continue }
                let target = EngineLifecycleController.Target(
                    profileID: profile.id,
                    config: EngineConfig(
                        baseURL: url, apiKey: nil,
                        name: profile.name, metadataDialect: profile.preset.metadataDialect,
                        requestStyle: .automatic))
                guard let resolution = await engineLifecycle.probe(target, for: operation) else {
                    await finishEngineTransition(intentRevision: intentRevision, operation: operation)
                    return
                }
                if resolution.health.isOK || resolution.health == .authRequired {
                    await publishEngine(
                        resolution, intentRevision: intentRevision, operation: operation,
                        persistDiscoveredURL: true)
                    return
                }
            }
        }

        await publishEngine(
            target: savedTarget, health: .offline("No engine at the configured or conventional local endpoints"),
            intentRevision: intentRevision, operation: operation, persistDiscoveredURL: false)
    }

    /// Keep the active profile's URL in step when Auto-Discover lands on a different port.
    private func syncActiveURL(_ url: String, profileID: String) async {
        guard activeEngineID == profileID,
            let i = engineProfiles.firstIndex(where: { $0.id == profileID }),
            engineProfiles[i].url != url
        else { return }
        let revision = nextEngineStoreRevision()
        engineProfiles[i].url = url
        _ = await saveEngines(revision: revision)
    }

    func refreshHealth() async {
        guard let intentRevision = beginEngineIntent() else { return }
        await applyActiveEngine(intentRevision: intentRevision)
    }

    struct EngineRecoveryTrigger: Equatable {
        let ready: Bool
        let profile: EngineProfile?
        let offline: Bool
        let transitioning: Bool
        let judasMode: JudasMode
    }

    var engineRecoveryTrigger: EngineRecoveryTrigger {
        EngineRecoveryTrigger(
            ready: startupPhase.hasLocalState, profile: activeEngineProfile,
            offline: {
                if case .offline = health { return true }
                return false
            }(),
            transitioning: engineTransitioning, judasMode: judasMode)
    }

    func updateEngineRecovery(isActive: Bool) {
        let url = activeEngineProfile.flatMap { URL(string: $0.url) }
        let permitted =
            url.map {
                judasMode == .configured || (judasMode == .localNetworksOnly && LocalNetworkAddress.contains($0))
            } ?? false
        engineRecovery.update(
            enabled: isActive && startupPhase.hasLocalState && permitted,
            shouldRetry: { [weak self] in
                guard let self else { return false }
                if case .offline = self.health { return true }
                return false
            },
            canProbe: { [weak self] in
                guard let self else { return false }
                return !self.engineTransitioning && !self.modelCapabilitiesLoading && !self.shepherd.hasActiveTurn
            },
            probe: { [weak self] in await self?.refreshHealth() })
    }

    /// Record user intent synchronously on MainActor before any lifecycle task can suspend.
    /// This prevents an older operation from publishing during the Task-scheduling window.
    func beginEngineIntent() -> UInt64? {
        guard !shepherd.hasActiveTurn else {
            activity.log(.warn, "Stop the active turn before changing engines.")
            return nil
        }
        cancelModelCapabilityProbe()
        engineIntentRevision &+= 1
        engineTransitioning = true
        return engineIntentRevision
    }

    func beginEngineOperation(
        for intentRevision: UInt64
    ) async -> EngineLifecycleController.Operation? {
        guard engineIntentRevision == intentRevision, !shepherd.hasActiveTurn else {
            if engineIntentRevision == intentRevision { engineTransitioning = false }
            return nil
        }
        guard let operation = await engineLifecycle.begin(intentRevision: intentRevision) else {
            if engineIntentRevision == intentRevision { engineTransitioning = false }
            return nil
        }
        guard engineIntentRevision == intentRevision, !shepherd.hasActiveTurn else {
            if engineIntentRevision == intentRevision { engineTransitioning = false }
            return nil
        }
        return operation
    }

    func publishEngine(
        _ resolution: EngineLifecycleController.Resolution,
        intentRevision: UInt64,
        operation: EngineLifecycleController.Operation,
        persistDiscoveredURL: Bool
    ) async {
        await publishEngine(
            target: resolution.target, health: resolution.health, intentRevision: intentRevision,
            operation: operation,
            persistDiscoveredURL: persistDiscoveredURL)
    }

    func publishEngine(
        target: EngineLifecycleController.Target, health newHealth: EngineHealth,
        intentRevision: UInt64, operation: EngineLifecycleController.Operation,
        persistDiscoveredURL: Bool
    ) async {
        guard engineIntentRevision == intentRevision, activeEngineID == target.profileID,
            await engineLifecycle.isCurrent(operation)
        else { return }
        var ownedProbeModelID: String?
        defer {
            if engineIntentRevision == intentRevision, activeEngineID == target.profileID {
                if capabilityProbeModelID == ownedProbeModelID {
                    modelCapabilitiesLoading = false
                    capabilityProbeModelID = nil
                }
                // A cancelled current probe must not leave the app permanently send-disabled.
                engineTransitioning = false
            }
        }
        guard await engine.update(config: target.config, revision: operation.revision) else { return }
        guard engineIntentRevision == intentRevision, activeEngineID == target.profileID,
            await engineLifecycle.isCurrent(operation)
        else { return }
        let resolvedURL = target.config.baseURL.absoluteString
        endpoint = resolvedURL
        if persistDiscoveredURL {
            await syncActiveURL(resolvedURL, profileID: target.profileID)
        }
        apply(health: newHealth)
        let probedModelID = preferredCapabilityModelID(in: newHealth.models)
        if let probedModelID,
            let model = newHealth.models.first(where: { $0.id == probedModelID })
        {
            ownedProbeModelID = probedModelID
            modelCapabilitiesLoading = true
            capabilityProbeModelID = probedModelID
            let enriched = await engine.probeCapabilities(for: model)
            guard engineIntentRevision == intentRevision, activeEngineID == target.profileID,
                await engineLifecycle.isCurrent(operation), !Task.isCancelled
            else { return }
            replaceModel(enriched)
            modelCapabilitiesLoading = false
            capabilityProbeModelID = nil
            logCapabilities(enriched)
        }
        await finishEngineTransition(intentRevision: intentRevision, operation: operation)
        if let desired = preferredCapabilityModelID(in: health.models), desired != probedModelID {
            scheduleModelCapabilityProbe(modelID: desired)
        }
    }

    func finishEngineTransition(
        intentRevision: UInt64, operation: EngineLifecycleController.Operation
    ) async {
        if engineIntentRevision == intentRevision, await engineLifecycle.isCurrent(operation) {
            engineTransitioning = false
        }
    }

    // MARK: API key - stored in ~/.goat/config/credentials.json, chmod 0600 (ADR-0012).

    func apply(health h: EngineHealth) {
        let prioritized: EngineHealth
        if case .ok(let available) = h {
            let coder = available.filter(\.isCoderFocused)
            prioritized = .ok(coder + available.filter { !$0.isCoderFocused })
        } else {
            prioritized = h
        }
        let changed = prioritized != health
        health = prioritized
        if prioritized.isOK {
            if defaultModelID == nil
                || !prioritized.models.contains(where: { $0.id == defaultModelID })
            {
                defaultModelID =
                    prioritized.models.first(where: \.isCoderFocused)?.id
                    ?? prioritized.models.first?.id
            }
        }
        if changed {
            switch prioritized {
            case .ok(let models):
                activity.log(
                    .info, "engine \(shortEndpointForLog): \(models.count) model\(models.count == 1 ? "" : "s")")
            case .authRequired: activity.log(.warn, "engine \(shortEndpointForLog): needs API key")
            case .offline(let reason): activity.log(.warn, "engine offline: \(reason)")
            }
        }
    }

    private func preferredCapabilityModelID(in available: [ModelRef]) -> String? {
        if let current = currentSession?.modelID,
            available.contains(where: { $0.id == current })
        {
            return current
        }
        if let defaultModelID, available.contains(where: { $0.id == defaultModelID }) {
            return defaultModelID
        }
        return available.first(where: \.isCoderFocused)?.id ?? available.first?.id
    }

    static func selectionNeedsCapabilityProbe(
        previousModelID: String?, currentModelID: String?
    ) -> Bool {
        guard let currentModelID else { return false }
        return currentModelID != previousModelID
    }

    /// A chat can retain a model ID from an engine that is no longer active. Resolve it through
    /// the live catalogue so every surface shows the model a generation would actually use.
    static func resolvedModelID(
        requested: String?, defaultModelID: String?, availableModels: [ModelRef]
    ) -> String? {
        if let requested { return requested }
        if let defaultModelID, availableModels.contains(where: { $0.id == defaultModelID }) {
            return defaultModelID
        }
        return availableModels.first?.id ?? requested ?? defaultModelID
    }

    func resolvedModelID(for session: ChatSession? = nil) -> String? {
        Self.resolvedModelID(
            requested: session?.modelID,
            defaultModelID: defaultModelID,
            availableModels: models)
    }

    private func replaceModel(_ enriched: ModelRef) {
        guard case .ok(var available) = health,
            let index = available.firstIndex(where: { $0.id == enriched.id })
        else { return }
        available[index] = enriched
        health = .ok(available)
    }

    private func logCapabilities(_ model: ModelRef) {
        var supported: [String] = []
        if model.capabilities.vision.support == .supported { supported.append("vision") }
        if model.capabilities.tools.support == .supported { supported.append("tools") }
        if model.capabilities.reasoning.support == .supported { supported.append("reasoning") }
        let detail = supported.isEmpty ? "generic compatibility" : supported.joined(separator: ", ")
        activity.log(.info, "capabilities \(model.displayName): \(detail)")
    }

    /// The only model-selection mutation path. Capability publication is separately revisioned.
    func selectModel(_ id: String, in session: ChatSession? = nil) {
        guard !shepherd.hasActiveTurn, !engineTransitioning,
            health.models.contains(where: { $0.id == id })
        else { return }
        defaultModelID = id
        let targetSession = session ?? currentSession
        if let targetSession {
            targetSession.modelID = id
            persistMeta(targetSession)
        }
        scheduleModelCapabilityProbe(modelID: id)
    }

    func scheduleModelCapabilityProbe(modelID: String) {
        guard !engineTransitioning, health.isOK,
            let model = health.models.first(where: { $0.id == modelID }),
            !shepherd.hasActiveTurn
        else { return }
        modelCapabilityIntentRevision &+= 1
        let intentRevision = modelCapabilityIntentRevision
        let engineRevision = engineIntentRevision
        let engineID = activeEngineID
        modelCapabilityTask?.cancel()
        modelCapabilitiesLoading = true
        capabilityProbeModelID = modelID
        modelCapabilityTask = Task {
            defer {
                finishModelCapabilityProbe(
                    intentRevision: intentRevision, engineRevision: engineRevision,
                    engineID: engineID, modelID: modelID)
            }
            let target = ModelCapabilityProbeOwnership.Target(
                engineID: engineID, modelID: modelID)
            guard
                let operation = await modelCapabilityOwnership.begin(
                    target: target, intentRevision: intentRevision)
            else { return }
            guard modelCapabilityIntentRevision == intentRevision,
                engineIntentRevision == engineRevision,
                activeEngineID == engineID, !Task.isCancelled
            else { return }
            let enriched = await engine.probeCapabilities(for: model)
            guard
                let resolution = await modelCapabilityOwnership.resolve(
                    enriched.capabilities, for: operation),
                resolution.target == target,
                modelCapabilityIntentRevision == intentRevision,
                engineIntentRevision == engineRevision,
                activeEngineID == engineID,
                capabilityProbeModelID == modelID,
                !Task.isCancelled
            else { return }
            replaceModel(enriched)
            logCapabilities(enriched)
        }
    }

    private func finishModelCapabilityProbe(
        intentRevision: UInt64, engineRevision: UInt64, engineID: String, modelID: String
    ) {
        guard modelCapabilityIntentRevision == intentRevision,
            engineIntentRevision == engineRevision, activeEngineID == engineID,
            capabilityProbeModelID == modelID
        else { return }
        modelCapabilitiesLoading = false
        capabilityProbeModelID = nil
        modelCapabilityTask = nil
    }

    private func cancelModelCapabilityProbe() {
        modelCapabilityIntentRevision &+= 1
        modelCapabilityTask?.cancel()
        modelCapabilityTask = nil
        modelCapabilitiesLoading = false
        capabilityProbeModelID = nil
    }

    private var shortEndpointForLog: String {
        guard let url = URL(string: endpoint) else { return "invalid endpoint" }
        return EngineConfig(baseURL: url).redactedEndpointDescription
    }

    func saveAPIKey(_ key: String) async {
        guard !shepherd.hasActiveTurn, let id = activeEngineProfile?.id else { return }
        let storeKey = Self.keyStore(id)
        let revision = nextCredentialRevision(for: storeKey)
        do {
            let saved = try await fileWorker.setCredential(
                key, for: storeKey, revision: revision)
            guard saved, credentialRevisions[storeKey] == revision else { return }
            if key.isEmpty {
                engineCredentials.removeValue(forKey: storeKey)
            } else {
                engineCredentials[storeKey] = key
            }
            scheduleEngineApply()
        } catch {
            dbWarning = "Credential was not saved: \(error.localizedDescription)"
        }
    }

    var hasStoredAPIKey: Bool { activeKey != nil }

}

private extension Double {
    func nonZeroOr(_ fallback: Double) -> Double { self == 0 ? fallback : self }
}
