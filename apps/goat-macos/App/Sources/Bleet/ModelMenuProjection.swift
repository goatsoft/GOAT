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
        selectedDisplayName = selectedModelID.flatMap { id in
            models.first(where: { $0.id == id })?.displayName
        } ?? selectedModelID.map { ModelRef(id: $0).displayName } ?? "No model"
    }

    var selectedAvailability: String {
        guard let selectedIdentity else { return "No model configured" }
        if favourites.contains(where: { $0.id == selectedIdentity.modelID })
            || otherModels.contains(where: { $0.id == selectedIdentity.modelID }) { return "Available" }
        return "Unavailable"
    }
}
