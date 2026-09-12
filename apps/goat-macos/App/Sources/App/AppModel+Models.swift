import Bleet
import Foundation
import Herd
import Inference

extension AppModel {
    func selectEffort(_ effort: Effort, in session: ChatSession? = nil) {
        guard !shepherd.hasActiveTurn, !engineTransitioning else { return }
        guard let target = session ?? currentSession else { return }
        target.effort = effort
        persistMeta(target)
    }

    func setModelFavourite(_ isFavourite: Bool, for identity: ModelIdentity) async -> Bool {
        guard validModelIdentity(identity) else { return false }
        var next = modelPreferences
        if let index = next.firstIndex(where: { $0.identity == identity }) {
            next[index].isFavourite = isFavourite
            next[index].updatedAt = .now
        } else {
            next.append(ModelPreference(identity: identity, isFavourite: isFavourite))
        }
        return await commitModelPreferences(models: next, reviews: legacyCompatibilityReviews)
    }

    func setCompatibilityOverride(
        _ compatibilityOverride: ModelCompatibilityOverride, for identity: ModelIdentity
    ) async -> Bool {
        guard validModelIdentity(identity), !shepherd.hasActiveTurn else { return false }
        var next = modelPreferences
        if let index = next.firstIndex(where: { $0.identity == identity }) {
            next[index].compatibilityOverride = compatibilityOverride
            next[index].updatedAt = .now
        } else {
            next.append(
                ModelPreference(
                    identity: identity, compatibilityOverride: compatibilityOverride))
        }
        return await commitModelPreferences(models: next, reviews: legacyCompatibilityReviews)
    }

    /// A user-asserted context window (ADR-0085). Nil clears the override. Values below 1,024
    /// are rejected because no usable prompt fits under them.
    func setContextWindowOverride(_ tokens: Int?, for identity: ModelIdentity) async -> Bool {
        guard validModelIdentity(identity), !shepherd.hasActiveTurn else { return false }
        if let tokens, tokens < 1_024 { return false }
        var next = modelPreferences
        if let index = next.firstIndex(where: { $0.identity == identity }) {
            next[index].contextWindowOverride = tokens
            next[index].updatedAt = .now
        } else if tokens != nil {
            next.append(ModelPreference(identity: identity, contextWindowOverride: tokens))
        } else {
            return true
        }
        return await commitModelPreferences(models: next, reviews: legacyCompatibilityReviews)
    }

    func resolveLegacyCompatibility(for engineProfileID: String, assignTo modelID: String?) async -> Bool {
        guard !shepherd.hasActiveTurn,
            let reviewIndex = legacyCompatibilityReviews.firstIndex(where: {
                $0.engineProfileID == engineProfileID && $0.state == .pending
            })
        else { return false }
        if let modelID {
            let identity = ModelIdentity(engineProfileID: engineProfileID, modelID: modelID)
            guard validModelIdentity(identity) else { return false }
            var nextModels = modelPreferences
            if let index = nextModels.firstIndex(where: { $0.identity == identity }) {
                nextModels[index].compatibilityOverride = .qwenChatTemplate
                nextModels[index].updatedAt = .now
            } else {
                nextModels.append(
                    ModelPreference(
                        identity: identity, compatibilityOverride: .qwenChatTemplate))
            }
            var nextReviews = legacyCompatibilityReviews
            nextReviews[reviewIndex].state = .assigned
            nextReviews[reviewIndex].assignedModelID = modelID
            return await commitModelPreferences(models: nextModels, reviews: nextReviews)
        }
        return await discardLegacyCompatibility(for: engineProfileID)
    }

    func discardLegacyCompatibility(for engineProfileID: String) async -> Bool {
        guard !shepherd.hasActiveTurn,
            let reviewIndex = legacyCompatibilityReviews.firstIndex(where: {
                $0.engineProfileID == engineProfileID && $0.state == .pending
            })
        else { return false }
        var nextReviews = legacyCompatibilityReviews
        nextReviews[reviewIndex].state = .discarded
        nextReviews[reviewIndex].assignedModelID = nil
        return await commitModelPreferences(models: modelPreferences, reviews: nextReviews)
    }

    func invalidateModelCompatibility(for engineProfileID: String) async -> Bool {
        let next = modelPreferences.map { preference in
            guard preference.identity.engineProfileID == engineProfileID else { return preference }
            var updated = preference
            updated.compatibilityOverride = .automatic
            updated.updatedAt = .now
            return updated
        }
        return await commitModelPreferences(models: next, reviews: legacyCompatibilityReviews)
    }

    func removeModelPreferences(for engineProfileID: String) async -> Bool {
        let next = modelPreferences.filter { $0.identity.engineProfileID != engineProfileID }
        let reviews = legacyCompatibilityReviews.filter { $0.engineProfileID != engineProfileID }
        return await commitModelPreferences(models: next, reviews: reviews)
    }

    /// Re-list the active engine's models. Routine polling passes `allowReconnect: false` so it
    /// never begins a connection: when the engine is already connected this re-lists with a
    /// lightweight health call that leaves the lifecycle untouched, and when it is offline it does
    /// nothing - reconnection is owned by EngineRecoveryController. Explicit user refreshes keep
    /// the default `allowReconnect: true`, which falls back to a full `discover()` when offline.
    func refreshModelCatalog(allowReconnect: Bool = true) async {
        guard startupPhase.hasLocalState, activeEngineProfile != nil, !shepherd.hasActiveTurn,
            !modelCatalogRefreshing
        else {
            return
        }
        modelCatalogRefreshing = true
        defer { modelCatalogRefreshing = false }
        if case .ok = health, !engineTransitioning {
            let refreshed = await engine.health()
            guard !shepherd.hasActiveTurn, !engineTransitioning else { return }
            apply(health: refreshed)
            return
        }
        guard allowReconnect else { return }
        await discover()
    }

    struct ModelCatalogPollingTrigger: Equatable {
        let ready: Bool
        let sceneActive: Bool
        let engineProfileID: String?
    }

    func modelCatalogPollingTrigger(sceneActive: Bool) -> ModelCatalogPollingTrigger {
        ModelCatalogPollingTrigger(
            ready: startupPhase.hasLocalState,
            sceneActive: sceneActive,
            engineProfileID: activeEngineProfile?.id)
    }

    func modelCatalogPollingLoop(sceneActive: Bool) async {
        guard sceneActive, startupPhase.hasLocalState, activeEngineProfile != nil else { return }
        while !Task.isCancelled {
            await refreshModelCatalog(allowReconnect: false)
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
        }
    }

    func inspectModel(_ identity: ModelIdentity) async {
        modelInspectionTask?.cancel()
        modelInspectionRevision &+= 1
        let revision = modelInspectionRevision
        let previous = modelInspectionStates[identity]?.snapshot
        modelInspectionStates[identity] = .loading(previous: previous)
        guard let profile = activeEngineProfile,
            profile.id == identity.engineProfileID,
            let model = models.first(where: { $0.id == identity.modelID })
        else {
            modelInspectionStates[identity] =
                .failed(message: "This model is not available in the current catalog.", previous: previous)
            return
        }
        let configurationRevision = engineIntentRevision
        modelInspectionTask = Task { [weak self] in
            guard let self else { return }
            let inspection = await self.engine.inspectModel(model)
            guard !Task.isCancelled else { return }
            await self.publishInspection(
                identity: identity, model: inspection.model, metadata: inspection.metadata,
                configurationRevision: configurationRevision,
                revision: revision)
        }
        await modelInspectionTask?.value
        if modelInspectionRevision == revision { modelInspectionTask = nil }
    }

    private func publishInspection(
        identity: ModelIdentity, model: ModelRef, metadata: EngineModelInspectionMetadata?,
        configurationRevision: UInt64, revision: UInt64
    ) {
        guard modelInspectionRevision == revision,
            activeEngineProfile?.id == identity.engineProfileID,
            engineIntentRevision == configurationRevision,
            models.contains(where: { $0.id == identity.modelID })
        else { return }
        let sources = Set(
            [
                model.capabilities.vision.evidence.map(\.rawValue),
                model.capabilities.tools.evidence.map(\.rawValue),
                model.capabilities.reasoning.evidence.map(\.rawValue),
            ].flatMap { $0 }
        ).sorted()
        let snapshot = ModelInspectionSnapshot(
            identity: identity, model: model, fetchedAt: .now,
            engineConfigurationRevision: configurationRevision,
            metadataSources: sources,
            format: metadata?.format,
            quantization: metadata?.quantization,
            architecture: metadata?.architecture,
            modelType: metadata?.modelType,
            parameterCount: metadata?.parameterCount,
            weightBytes: metadata?.weightBytes,
            engineVersion: metadata?.engineVersion,
            checkpointRole: ModelCheckpointRole(rawValue: metadata?.checkpointRole ?? "") ?? .unknown,
            templateIdentifier: metadata?.templateIdentifier,
            parserIdentifier: metadata?.parserIdentifier)
        modelInspectionStates[identity] = .loaded(snapshot: snapshot)
    }

    var modelCatalogProjection: ModelCatalogProjection? {
        guard let engineID = activeEngineProfile?.id else { return nil }
        return ModelCatalogProjection(
            models: models, preferences: modelPreferences, engineProfileID: engineID)
    }

    private func validModelIdentity(_ identity: ModelIdentity) -> Bool {
        !identity.engineProfileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !identity.modelID.isEmpty
            && engineProfiles.contains(where: { $0.id == identity.engineProfileID })
    }

    private func commitModelPreferences(
        models: [ModelPreference], reviews: [LegacyCompatibilityReview]
    ) async -> Bool {
        let previousModels = modelPreferences
        let previousReviews = legacyCompatibilityReviews
        let previousDurable = durableModelPreferences
        modelPreferences = models
        legacyCompatibilityReviews = reviews
        modelPreferencesSaveError = nil
        modelPreferencesRevision &+= 1
        let revision = modelPreferencesRevision
        let file = ModelPreferencesFile(models: models, legacyReviews: reviews)
        do {
            let saved = try await fileWorker.saveModelPreferences(
                file, to: Home.modelPreferencesFile, revision: revision)
            guard saved, modelPreferencesRevision == revision else { return false }
            durableModelPreferences = file
            return true
        } catch {
            if modelPreferencesRevision == revision {
                modelPreferences = previousModels
                legacyCompatibilityReviews = previousReviews
                durableModelPreferences = previousDurable
                modelPreferencesSaveError = error.localizedDescription
            }
            return false
        }
    }
}
