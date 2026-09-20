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
    public var generationPolicy: ModelGenerationPolicy?
    public var familyRuleID: String?
    public var familyEvidence: CapabilityEvidence?
    public var samplingOverride: SamplingOverride?

    public init(
        identity: ModelIdentity,
        effectiveStyle: ResolvedRequestStyle,
        source: CompatibilityResolutionSource,
        adapterIdentifier: String? = nil,
        metadataAt: Date? = nil,
        capabilities: ModelCapabilities = .unknown,
        schemaVersion: Int = Self.currentSchemaVersion,
        generationPolicy: ModelGenerationPolicy? = nil, familyRuleID: String? = nil,
        familyEvidence: CapabilityEvidence? = nil, samplingOverride: SamplingOverride? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.identity = identity
        self.effectiveStyle = effectiveStyle
        self.source = source
        self.adapterIdentifier = adapterIdentifier
        self.metadataAt = metadataAt
        self.capabilities = capabilities
        self.generationPolicy = generationPolicy
        self.familyRuleID = familyRuleID
        self.familyEvidence = familyEvidence
        self.samplingOverride = samplingOverride
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
    public var temperature: Double? { sampling.temperature }
    public let sampling: SamplingOverride
    public let samplingSource: SamplingSource
    public let omittedSamplingParameters: [String]
    public let familyRuleID: String?
    public let reasoningInstruction: String?
    public let historyPolicy: ModelGenerationPolicy.ReasoningHistory
    public let outputTokenCap: Int
    public let nativeReasoningEffort: String?
    public let replayReasoningHistory: Bool
    public let qwenEnableThinking: Bool?
    public let qwenPreserveThinking: Bool?
    public let qwenReasoningEffort: String?

    public init(request: GenerationRequest) {
        let policy = request.compatibility.generationPolicy
        let qwen =
            request.compatibility.effectiveStyle == .qwenChatTemplate
            && (policy == nil || policy?.reasoningPrompt == .qwenSoftSwitch)
        switch request.effort {
        case .graze:
            qwenEnableThinking = qwen ? false : nil
            qwenReasoningEffort = nil
        case .trot:
            qwenEnableThinking = qwen ? true : nil
            qwenReasoningEffort = nil
        case .climb:
            qwenEnableThinking = qwen ? true : nil
            qwenReasoningEffort = nil
        case .summit:
            qwenEnableThinking = qwen ? true : nil
            qwenReasoningEffort = nil
        }
        outputTokenCap = request.maxTokens ?? request.effort.outputCeiling(for: request.modelCapabilities)
        var reasoningCapabilities = request.modelCapabilities
        if let allowed = policy?.nativeReasoningEffortValues {
            reasoningCapabilities.reasoningEffortValues =
                reasoningCapabilities.reasoningEffortValues.map { $0.intersection(allowed) } ?? allowed
        }
        nativeReasoningEffort =
            qwen ? nil : reasoningCapabilities.nativeReasoningEffort(for: request.effort)
        let reasoningAllowed =
            request.modelCapabilities.reasoning.support != .unsupported
            && !request.modelCapabilities.reasoning.isConflict
        let nonThinking =
            (qwen || policy?.reasoningPrompt == .qwenSoftSwitch)
            && request.effort == .graze
        let familySampling = nonThinking ? policy?.nonThinkingSampling : policy?.sampling
        let configured = request.compatibility.samplingOverride
        let candidate =
            configured ?? familySampling
            ?? (qwen
                ? SamplingOverride(
                    temperature: nonThinking ? 0.7 : 0.6,
                    topP: nonThinking ? 0.8 : 0.95, topK: 20, minP: 0) : SamplingOverride())
        samplingSource =
            configured != nil
            ? .userOverride
            : familySampling != nil
                ? (request.compatibility.familyEvidence == .userModelFamily ? .userModelFamily : .modelFamily)
                : qwen ? .compatibilityOverride : .engineDefault
        let vetoed =
            request.modelCapabilities.supportedRequestParameters.map {
                Set(candidate.fields.keys).subtracting($0)
            } ?? []
        let omitted = vetoed.union(request.rejectedSamplingParameters)
        omittedSamplingParameters = omitted.sorted()
        sampling = candidate.isValid ? candidate.removing(omitted) : SamplingOverride()
        familyRuleID = request.compatibility.familyRuleID
        if reasoningAllowed, nativeReasoningEffort == nil, let prompt = policy?.reasoningPrompt {
            switch prompt {
            case .museStrength:
                let value =
                    [Effort.graze: "low", .trot: "medium", .climb: "high", .summit: "xhigh"][request.effort] ?? "high"
                reasoningInstruction = "Reasoning strength: \(value)."
            case .qwenSoftSwitch:
                reasoningInstruction = qwen ? nil : (nonThinking ? "/no_think" : "/think")
            }
        } else {
            reasoningInstruction = nil
        }
        let historyClaim = request.modelCapabilities.reasoningHistory
        if !reasoningAllowed || historyClaim.support == .unsupported || historyClaim.isConflict {
            historyPolicy = .omit
        } else if let declared = policy?.reasoningHistory {
            historyPolicy = declared
        } else {
            historyPolicy = !qwen && historyClaim.support == .supported ? .all : .omit
        }
        replayReasoningHistory = historyPolicy != .omit
        qwenPreserveThinking = nil
    }
}

public enum ModelCompatibilityResolver {
    public static let metadataFreshness: TimeInterval = 300

    public static func resolve(
        identity: ModelIdentity,
        override: ModelCompatibilityOverride = .automatic,
        metadata: ModelCompatibilityMetadata? = nil,
        familyProfile: KnownModelProfile? = nil,
        samplingOverride: SamplingOverride? = nil,
        now: Date = .now
    ) -> ResolvedModelCompatibility {
        var result = resolveBase(
            identity: identity, override: override, metadata: metadata,
            familyProfile: familyProfile, now: now)
        result.generationPolicy = familyProfile?.generation
        result.familyRuleID = familyProfile?.ruleID
        result.familyEvidence = familyProfile?.evidence
        result.samplingOverride = samplingOverride
        return result
    }

    private static func resolveBase(
        identity: ModelIdentity,
        override: ModelCompatibilityOverride,
        metadata: ModelCompatibilityMetadata?,
        familyProfile: KnownModelProfile?,
        now: Date
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
        // Source-backed family knowledge (built-in JSON or the user file) fills the gap when the
        // engine exposed no usable metadata. Dialect stays engine configuration (ADR-0024,
        // ADR-0086); generation policy is attached by the resolver. A concrete engine window still wins
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
