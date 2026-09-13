import Foundation
import Inference
import Testing

@Suite("Model inspection")
struct ModelInspectionTests {
    @Test("catalog projection separates favourites and sorts by display name")
    func projectionSortsAndSeparates() {
        let models = [ModelRef(id: "org/Zed"), ModelRef(id: "org/Alpha"), ModelRef(id: "other/Alpha")]
        let preferences = [
            ModelPreference(
                identity: ModelIdentity(engineProfileID: "engine", modelID: "org/Zed"),
                isFavourite: true),
            ModelPreference(
                identity: ModelIdentity(engineProfileID: "engine", modelID: "missing"),
                isFavourite: true),
        ]
        let projection = ModelCatalogProjection(
            models: models, preferences: preferences, engineProfileID: "engine")
        #expect(projection.availableFavourites.map(\.id) == ["org/Zed"])
        #expect(projection.availableOthers.map(\.id) == ["org/Alpha", "other/Alpha"])
        #expect(projection.unavailableFavourites.map(\.identity.modelID) == ["missing"])
    }

    @Test("metadata expiry does not erase the snapshot")
    func metadataExpiryPreservesSnapshot() {
        let snapshot = ModelInspectionSnapshot(
            identity: ModelIdentity(engineProfileID: "engine", modelID: "model"),
            model: ModelRef(id: "model"),
            fetchedAt: Date(timeIntervalSince1970: 100), engineConfigurationRevision: 1)
        let state = ModelMetadataState.loaded(snapshot: snapshot)
        #expect(state.freshness(at: Date(timeIntervalSince1970: 500)) == .stale)
        #expect(state.snapshot == snapshot)
    }
}
