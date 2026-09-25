import Inference

struct ModelMenuProjection: Equatable {
    let favourites: [ModelRef]
    let otherModels: [ModelRef]
    let unavailableFavourites: [ModelPreference]
    let selectedIdentity: ModelIdentity?
    let selectedDisplayName: String

    init(
        models: [ModelRef], preferences: [ModelPreference], engineProfileID: String?,
        selectedModelID: String?
    ) {
        let catalog = engineProfileID.map {
            ModelCatalogProjection(models: models, preferences: preferences, engineProfileID: $0)
        }
        favourites = catalog?.availableFavourites ?? []
        otherModels = catalog?.availableOthers ?? []
        unavailableFavourites = catalog?.unavailableFavourites ?? []
        selectedIdentity = engineProfileID.flatMap { engineID in
            selectedModelID.map { ModelIdentity(engineProfileID: engineID, modelID: $0) }
        }
        selectedDisplayName =
            selectedModelID.flatMap { id in
                models.first(where: { $0.id == id })?.displayName
            } ?? selectedModelID.map { ModelRef(id: $0).displayName } ?? "No model"
    }

    /// The active model as a catalogue row, favourite or not, so a menu can always lead with it.
    var selectedModel: ModelRef? {
        guard let id = selectedIdentity?.modelID else { return nil }
        return (favourites + otherModels).first { $0.id == id }
    }

    var selectedAvailability: String {
        guard let selectedIdentity else { return "No model configured" }
        if favourites.contains(where: { $0.id == selectedIdentity.modelID })
            || otherModels.contains(where: { $0.id == selectedIdentity.modelID })
        {
            return "Available"
        }
        return "Unavailable"
    }
}

/// Catalogue compatibility only. Loaded state and memory admission are checked at dispatch.
struct SubagentMenuProjection {
    let workers: [ModelRef]
    let unavailableReason: String?

    init(models: [ModelRef], parentModelID: String?, hasLocalEngine: Bool) {
        workers = models.filter {
            SubagentLimits.resolvedEnvelope(for: $0.id) != nil && $0.capabilities.tools.support != .unsupported
        }
        if !hasLocalEngine {
            unavailableReason = "Choose a local engine to use subagents."
        } else if let parent = models.first(where: { $0.id == parentModelID }) {
            switch parent.capabilities.tools.support {
            case .supported: unavailableReason = nil
            case .unsupported: unavailableReason = "The parent model does not support tool calling."
            case .unknown: unavailableReason = "The parent model's tool support is not verified."
            }
        } else {
            unavailableReason = "Choose an available parent model first."
        }
    }
}
