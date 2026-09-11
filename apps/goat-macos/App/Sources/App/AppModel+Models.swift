import Foundation
import Herd
import Inference

extension AppModel {
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
