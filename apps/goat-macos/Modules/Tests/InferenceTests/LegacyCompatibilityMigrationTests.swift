import Foundation
import Herd
import Inference
import Testing

@Suite("Legacy compatibility migration")
struct LegacyCompatibilityMigrationTests {
    private func engine(_ id: String, _ style: EngineRequestStyle) -> EngineProfile {
        EngineProfile(id: id, name: id, url: "http://127.0.0.1:8000", requestStyle: style)
    }

    @Test("a non-automatic engine becomes one pending review")
    func nonAutomaticBecomesPendingReview() {
        var file = ModelPreferencesFile()
        let changed = LegacyCompatibilityMigration.migrate(
            &file, engines: [engine("qwen-engine", .qwenChatTemplate)])
        #expect(changed)
        #expect(file.legacyReviews.count == 1)
        let review = file.legacyReviews.first
        #expect(review?.engineProfileID == "qwen-engine")
        #expect(review?.legacyStyle == .qwenChatTemplate)
        #expect(review?.state == .pending)
        #expect(review?.assignedModelID == nil)
        // The legacy style is preserved as reviewable data, not copied onto any model.
        #expect(file.models.isEmpty)
    }

    @Test("automatic engines carry no legacy claim and are skipped")
    func automaticEnginesAreSkipped() {
        var file = ModelPreferencesFile()
        let changed = LegacyCompatibilityMigration.migrate(
            &file, engines: [engine("plain", .automatic)])
        #expect(!changed)
        #expect(file.legacyReviews.isEmpty)
    }

    @Test("only non-automatic engines in a mixed list are migrated")
    func mixedListMigratesOnlyNonAutomatic() {
        var file = ModelPreferencesFile()
        let changed = LegacyCompatibilityMigration.migrate(
            &file,
            engines: [
                engine("a-auto", .automatic),
                engine("b-qwen", .qwenChatTemplate),
                engine("c-auto", .automatic),
            ])
        #expect(changed)
        #expect(file.legacyReviews.map(\.engineProfileID) == ["b-qwen"])
    }

    @Test("migration is idempotent across launches")
    func migrationIsIdempotent() {
        var file = ModelPreferencesFile()
        let engines = [engine("qwen-engine", .qwenChatTemplate)]
        #expect(LegacyCompatibilityMigration.migrate(&file, engines: engines))
        // A second pass adds nothing and reports no change.
        #expect(!LegacyCompatibilityMigration.migrate(&file, engines: engines))
        #expect(file.legacyReviews.count == 1)
    }

    @Test("a resolved or discarded review is never resurrected")
    func resolvedReviewIsNotResurrected() {
        let engines = [engine("qwen-engine", .qwenChatTemplate)]
        for state: LegacyCompatibilityReview.State in [.assigned, .discarded] {
            var file = ModelPreferencesFile(
                models: [],
                legacyReviews: [
                    LegacyCompatibilityReview(
                        engineProfileID: "qwen-engine", legacyStyle: .qwenChatTemplate,
                        state: state,
                        assignedModelID: state == .assigned ? "Org/model" : nil)
                ])
            let changed = LegacyCompatibilityMigration.migrate(&file, engines: engines)
            #expect(!changed)
            #expect(file.legacyReviews.count == 1)
            #expect(file.legacyReviews.first?.state == state)
        }
    }

    @Test("legacy reviews round-trip through the preferences store")
    func legacyReviewsRoundTrip() throws {
        let file = ModelPreferencesFile(
            models: [
                ModelPreference(
                    identity: ModelIdentity(engineProfileID: "qwen-engine", modelID: "Org/model"),
                    compatibilityOverride: .qwenChatTemplate)
            ],
            legacyReviews: [
                LegacyCompatibilityReview(
                    engineProfileID: "other-engine", legacyStyle: .qwenChatTemplate),
                LegacyCompatibilityReview(
                    engineProfileID: "qwen-engine", legacyStyle: .qwenChatTemplate,
                    state: .assigned, assignedModelID: "Org/model"),
            ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("goat-legacy-reviews-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try ModelPreferencesStore.save(file, to: url)
        #expect(try ModelPreferencesStore.load(from: url) == file)
    }

    @Test("duplicate legacy review engine IDs are rejected")
    func duplicateLegacyReviewsAreRejected() {
        let file = ModelPreferencesFile(
            legacyReviews: [
                LegacyCompatibilityReview(engineProfileID: "dup", legacyStyle: .qwenChatTemplate),
                LegacyCompatibilityReview(engineProfileID: "dup", legacyStyle: .qwenChatTemplate),
            ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("goat-legacy-reviews-\(UUID().uuidString).json")
        #expect(throws: LocalStoreError.self) {
            try ModelPreferencesStore.save(file, to: url)
        }
    }
}
