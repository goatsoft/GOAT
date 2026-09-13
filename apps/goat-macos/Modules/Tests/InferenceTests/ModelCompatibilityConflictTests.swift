import Foundation
import Inference
import Testing

@Suite("Model compatibility conflict resolution")
struct ModelCompatibilityConflictTests {
    private let identity = ModelIdentity(engineProfileID: "engine", modelID: "Org/model")
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func metadata(
        style: ResolvedRequestStyle, adapter: String = "adapter",
        age: TimeInterval = -30, capabilities: ModelCapabilities = .unknown,
        identity: ModelIdentity? = nil
    ) -> ModelCompatibilityMetadata {
        ModelCompatibilityMetadata(
            identity: identity ?? self.identity, engineConfigurationRevision: 1,
            observedAt: now.addingTimeInterval(age), effectiveStyle: style,
            adapterIdentifier: adapter, capabilities: capabilities)
    }

    private func family(vision: Bool) -> KnownModelProfile {
        KnownModelProfile(
            contextLength: 8_192,
            capabilities: ModelCapabilities(
                vision: vision ? .supported(by: .modelFamily) : .unknown))
    }

    @Test("an explicit override wins over fresh conflicting metadata")
    func explicitOverrideBeatsFreshMetadata() {
        let resolved = ModelCompatibilityResolver.resolve(
            identity: identity, override: .genericOpenAI,
            metadata: metadata(style: .qwenChatTemplate), now: now)
        #expect(resolved.effectiveStyle == .genericOpenAI)
        #expect(resolved.source == .explicitOverride)
    }

    @Test("an explicit override still carries capabilities from matching metadata")
    func explicitOverrideCarriesMatchingCapabilities() {
        let caps = ModelCapabilities(vision: .supported(by: .observedResponse))
        let resolved = ModelCompatibilityResolver.resolve(
            identity: identity, override: .qwenChatTemplate,
            metadata: metadata(style: .genericOpenAI, capabilities: caps), now: now)
        #expect(resolved.source == .explicitOverride)
        #expect(resolved.capabilities.vision.support == .supported)
    }

    @Test("automatic prefers fresh engine metadata over family knowledge")
    func automaticPrefersMetadataOverFamily() {
        let resolved = ModelCompatibilityResolver.resolve(
            identity: identity, metadata: metadata(style: .qwenChatTemplate),
            familyProfile: family(vision: true), now: now)
        #expect(resolved.source == .engineMetadata)
        #expect(resolved.effectiveStyle == .qwenChatTemplate)
    }

    @Test("automatic ignores metadata for a different pairing and uses family")
    func automaticIgnoresMismatchedMetadata() {
        let other = ModelIdentity(engineProfileID: "engine", modelID: "Org/other")
        let resolved = ModelCompatibilityResolver.resolve(
            identity: identity,
            metadata: metadata(style: .qwenChatTemplate, identity: other),
            familyProfile: family(vision: true), now: now)
        #expect(resolved.source == .modelFamily)
        #expect(resolved.effectiveStyle == .genericOpenAI)
        #expect(resolved.capabilities.vision.support == .supported)
    }

    @Test("automatic ignores stale metadata and falls back to family")
    func automaticIgnoresStaleMetadata() {
        let resolved = ModelCompatibilityResolver.resolve(
            identity: identity,
            metadata: metadata(style: .qwenChatTemplate, age: -600),
            familyProfile: family(vision: false), now: now)
        #expect(resolved.source == .modelFamily)
        #expect(resolved.effectiveStyle == .genericOpenAI)
    }

    @Test("automatic with no usable evidence falls back to generic")
    func automaticFallsBackToGeneric() {
        let resolved = ModelCompatibilityResolver.resolve(identity: identity, now: now)
        #expect(resolved.source == .genericFallback)
        #expect(resolved.effectiveStyle == .genericOpenAI)
    }
}
