import Foundation
import Inference
import Testing

@Suite("Model compatibility")
struct ModelCompatibilityTests {
    private let identity = ModelIdentity(engineProfileID: "engine", modelID: "Org/model")

    @Test("automatic resolution uses generic semantics without proven metadata")
    func automaticUsesGenericFallback() {
        let resolved = ModelCompatibilityResolver.resolve(identity: identity)
        #expect(resolved.effectiveStyle == .genericOpenAI)
        #expect(resolved.source == .genericFallback)
    }

    @Test("explicit Qwen override wins over stale metadata")
    func explicitOverrideWins() {
        let metadata = ModelCompatibilityMetadata(
            identity: identity, engineConfigurationRevision: 4,
            observedAt: Date(timeIntervalSinceNow: -600),
            effectiveStyle: .genericOpenAI, adapterIdentifier: "generic",
            capabilities: .unknown)
        let resolved = ModelCompatibilityResolver.resolve(
            identity: identity, override: .qwenChatTemplate, metadata: metadata,
            now: Date())
        #expect(resolved.effectiveStyle == .qwenChatTemplate)
        #expect(resolved.source == .explicitOverride)
    }

    @Test("fresh exact metadata can select a documented adapter")
    func freshMetadataIsUsed() {
        let now = Date(timeIntervalSince1970: 1_000)
        let metadata = ModelCompatibilityMetadata(
            identity: identity, engineConfigurationRevision: 4,
            observedAt: now.addingTimeInterval(-30), effectiveStyle: .qwenChatTemplate,
            adapterIdentifier: "documented-qwen", capabilities: .unknown)
        let resolved = ModelCompatibilityResolver.resolve(
            identity: identity, metadata: metadata, now: now)
        #expect(resolved.effectiveStyle == .qwenChatTemplate)
        #expect(resolved.source == .engineMetadata)
        #expect(resolved.adapterIdentifier == "documented-qwen")
    }
}
