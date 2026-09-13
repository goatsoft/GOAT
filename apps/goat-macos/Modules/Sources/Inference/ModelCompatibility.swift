import Foundation

public enum ResolvedRequestStyle: String, Codable, Sendable {
    case genericOpenAI
    case qwenChatTemplate
}

public enum CompatibilityResolutionSource: String, Codable, Sendable {
    case explicitOverride
    case engineMetadata
    case modelFamily
    case genericFallback
}

/// Metadata is accepted only for the exact pairing and configuration revision that produced it.
public struct ModelCompatibilityMetadata: Codable, Equatable, Sendable {
    public let identity: ModelIdentity
    public let engineConfigurationRevision: UInt64
    public let observedAt: Date
    public let effectiveStyle: ResolvedRequestStyle?
    public let adapterIdentifier: String?
    public let capabilities: ModelCapabilities

    public init(
        identity: ModelIdentity,
        engineConfigurationRevision: UInt64,
        observedAt: Date,
        effectiveStyle: ResolvedRequestStyle? = nil,
        adapterIdentifier: String? = nil,
        capabilities: ModelCapabilities = .unknown
    ) {
        self.identity = identity
        self.engineConfigurationRevision = engineConfigurationRevision
        self.observedAt = observedAt
        self.effectiveStyle = effectiveStyle
        self.adapterIdentifier = adapterIdentifier
        self.capabilities = capabilities
    }
}

public struct ResolvedModelCompatibility: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let identity: ModelIdentity
    public let effectiveStyle: ResolvedRequestStyle
    public let source: CompatibilityResolutionSource
    public let adapterIdentifier: String?
    public let metadataAt: Date?
    public let capabilities: ModelCapabilities

    public init(
        identity: ModelIdentity,
        effectiveStyle: ResolvedRequestStyle,
        source: CompatibilityResolutionSource,
        adapterIdentifier: String? = nil,
        metadataAt: Date? = nil,
        capabilities: ModelCapabilities = .unknown,
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.identity = identity
        self.effectiveStyle = effectiveStyle
        self.source = source
        self.adapterIdentifier = adapterIdentifier
        self.metadataAt = metadataAt
        self.capabilities = capabilities
    }
}

public struct GenerationContext: Sendable, Equatable {
    public let engineProfileID: String
    public let engineName: String
    public let engineConfigurationRevision: UInt64
    public let identity: ModelIdentity
    public let compatibility: ResolvedModelCompatibility

    public init(
        engineProfileID: String,
        engineName: String,
        engineConfigurationRevision: UInt64,
        identity: ModelIdentity,
        compatibility: ResolvedModelCompatibility
    ) {
        self.engineProfileID = engineProfileID
        self.engineName = engineName
        self.engineConfigurationRevision = engineConfigurationRevision
        self.identity = identity
        self.compatibility = compatibility
    }
}

public struct EffectiveGenerationParameters: Codable, Equatable, Sendable {
    public let temperature: Double
    public let outputTokenCap: Int
    public let nativeReasoningEffort: String?
    public let replayReasoningHistory: Bool
    public let qwenEnableThinking: Bool?
    public let qwenPreserveThinking: Bool?
    public let qwenReasoningEffort: String?

    public init(request: GenerationRequest) {
        let qwen = request.compatibility.effectiveStyle == .qwenChatTemplate
        switch request.effort {
        case .graze:
            temperature = qwen ? 0.7 : request.effort.temperature
            qwenEnableThinking = qwen ? false : nil
            qwenReasoningEffort = nil
        case .trot:
            temperature = qwen ? 1.0 : request.effort.temperature
            qwenEnableThinking = qwen ? true : nil
            qwenReasoningEffort = qwen ? "low" : nil
        case .climb:
            temperature = qwen ? 1.0 : request.effort.temperature
            qwenEnableThinking = qwen ? true : nil
            qwenReasoningEffort = qwen ? "medium" : nil
        case .summit:
            temperature = qwen ? 1.0 : request.effort.temperature
            qwenEnableThinking = qwen ? true : nil
            qwenReasoningEffort = qwen ? "xhigh" : nil
        }
        outputTokenCap = request.maxTokens ?? request.effort.outputCeiling(for: request.modelCapabilities)
        nativeReasoningEffort =
            qwen
            ? nil : request.modelCapabilities.nativeReasoningEffort(for: request.effort)
        replayReasoningHistory = qwen
        qwenPreserveThinking = qwen ? true : nil
    }
}

public enum ModelCompatibilityResolver {
    public static let metadataFreshness: TimeInterval = 300

    public static func resolve(
        identity: ModelIdentity,
        override: ModelCompatibilityOverride = .automatic,
        metadata: ModelCompatibilityMetadata? = nil,
        familyProfile: KnownModelProfile? = nil,
        now: Date = .now
    ) -> ResolvedModelCompatibility {
        let metadataMatches = metadata?.identity == identity
        switch override {
        case .genericOpenAI:
            return ResolvedModelCompatibility(
                identity: identity, effectiveStyle: .genericOpenAI,
                source: .explicitOverride,
                capabilities: metadataMatches ? metadata?.capabilities ?? .unknown : .unknown)
        case .qwenChatTemplate:
            return ResolvedModelCompatibility(
                identity: identity, effectiveStyle: .qwenChatTemplate,
                source: .explicitOverride,
                capabilities: metadataMatches ? metadata?.capabilities ?? .unknown : .unknown)
        case .automatic:
            break
        }

        if let metadata, metadataMatches,
            metadata.observedAt <= now,
            now.timeIntervalSince(metadata.observedAt) <= metadataFreshness,
            let effectiveStyle = metadata.effectiveStyle,
            metadata.adapterIdentifier?.isEmpty == false
        {
            return ResolvedModelCompatibility(
                identity: identity, effectiveStyle: effectiveStyle,
                source: .engineMetadata,
                adapterIdentifier: metadata.adapterIdentifier,
                metadataAt: metadata.observedAt,
                capabilities: metadata.capabilities)
        }
        // Verified family knowledge (built-in JSON or the user file) fills the gap when the
        // engine exposed no usable metadata. Dialect stays engine configuration (ADR-0024,
        // ADR-0086); the family supplies capabilities only. A concrete engine window still wins
        // downstream when the catalog reports one.
        if let familyProfile {
            return ResolvedModelCompatibility(
                identity: identity, effectiveStyle: .genericOpenAI,
                source: .modelFamily,
                capabilities: familyProfile.capabilities)
        }
        return ResolvedModelCompatibility(
            identity: identity, effectiveStyle: .genericOpenAI,
            source: .genericFallback,
            capabilities: metadataMatches ? metadata?.capabilities ?? .unknown : .unknown)
    }
}
