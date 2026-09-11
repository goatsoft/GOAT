import Foundation
import Herd
import Inference
import Testing

@Suite("Model preferences")
struct ModelPreferencesTests {
    @Test("missing file loads as empty")
    func missingFileLoadsAsEmpty() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("goat-model-preferences-\(UUID().uuidString).json")
        #expect(try ModelPreferencesStore.load(from: url) == nil)
    }

    @Test("pairing identity keeps equal model IDs on separate engines distinct")
    func pairingIdentityIsExact() throws {
        let first = ModelIdentity(engineProfileID: "one", modelID: "Org/model")
        let second = ModelIdentity(engineProfileID: "two", modelID: "Org/model")
        #expect(first != second)
        let file = ModelPreferencesFile(models: [
            ModelPreference(identity: first, isFavourite: true),
            ModelPreference(identity: second, compatibilityOverride: .genericOpenAI)
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("goat-model-preferences-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try ModelPreferencesStore.save(file, to: url)
        #expect(try ModelPreferencesStore.load(from: url) == file)
    }

    @Test("duplicate pairing identities are rejected")
    func duplicatePairingsAreRejected() throws {
        let identity = ModelIdentity(engineProfileID: "one", modelID: "model")
        let file = ModelPreferencesFile(models: [
            ModelPreference(identity: identity), ModelPreference(identity: identity)
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("goat-model-preferences-\(UUID().uuidString).json")
        #expect(throws: LocalStoreError.self) {
            try ModelPreferencesStore.save(file, to: url)
        }
    }
}
