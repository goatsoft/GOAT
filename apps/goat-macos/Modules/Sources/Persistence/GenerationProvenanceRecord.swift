import Foundation

/// Neutral, local-only provenance for one generated assistant response.
/// This type intentionally has no dependency on Inference, URLs, prompts, credentials or paths.
public struct GenerationProvenanceRecord: Codable, Equatable, Sendable {
    public enum Lifecycle: String, Codable, Sendable {
        case prepared
        case started
        case completed
        case failed
        case cancelled
    }

    public enum ContextLimitSource: String, Codable, Sendable {
        case reported
        case fallback
        case unknown
    }

    public enum FailureCategory: String, Codable, Sendable {
        case engine
        case persistence
        case promptBudget
        case cancelled
        case unavailableModel
        case toolFormatRecovery
        case unknown
    }

    public struct CapabilityClaim: Codable, Equatable, Sendable {
        public let support: String
        public let evidence: [String]

        public init(support: String, evidence: [String] = []) {
            self.support = support
            self.evidence = evidence.sorted()
        }
    }

    public struct TemplateControls: Codable, Equatable, Sendable {
        public let enableThinking: Bool
        public let preserveThinking: Bool
        public let reasoningEffort: String?

        public init(enableThinking: Bool, preserveThinking: Bool, reasoningEffort: String?) {
            self.enableThinking = enableThinking
            self.preserveThinking = preserveThinking
            self.reasoningEffort = reasoningEffort
        }
    }

    public let schemaVersion: Int
    public let engineProfileID: String
    public let engineDisplayName: String
    public let requestedModelID: String
    public let responseModelID: String?
    public let requestStartedAt: Date
    public let appVersion: String
    public let appBuild: String
    public let engineVersion: String?
    public let resolvedRequestStyle: String
    public let resolutionSource: String
    public let adapterIdentifier: String?
    public let selectedEffort: String
    public let actualTemperature: Double
    public let effectiveOutputTokenCap: Int
    public let nativeReasoningValue: String?
    public let reasoningHistoryReplayed: Bool
    public let templateControls: TemplateControls?
    public let effectiveContextLimit: Int?
    public let contextLimitSource: ContextLimitSource
    public let preflightTokenEstimate: Int?
    public let preflightEstimateIsEstimated: Bool
    public let capabilities: [String: CapabilityClaim]
    public let metadataAgeSeconds: Double?
    public let metadataIsFresh: Bool?
    public let lifecycle: Lifecycle
    public let finishReason: String?
    public let failureCategory: FailureCategory?

    public init(
        schemaVersion: Int = 1,
        engineProfileID: String,
        engineDisplayName: String,
        requestedModelID: String,
        responseModelID: String? = nil,
        requestStartedAt: Date,
        appVersion: String,
        appBuild: String,
        engineVersion: String? = nil,
        resolvedRequestStyle: String,
        resolutionSource: String,
        adapterIdentifier: String? = nil,
        selectedEffort: String,
        actualTemperature: Double,
        effectiveOutputTokenCap: Int,
        nativeReasoningValue: String? = nil,
        reasoningHistoryReplayed: Bool,
        templateControls: TemplateControls? = nil,
        effectiveContextLimit: Int? = nil,
        contextLimitSource: ContextLimitSource = .unknown,
        preflightTokenEstimate: Int? = nil,
        preflightEstimateIsEstimated: Bool = true,
        capabilities: [String: CapabilityClaim] = [:],
        metadataAgeSeconds: Double? = nil,
        metadataIsFresh: Bool? = nil,
        lifecycle: Lifecycle,
        finishReason: String? = nil,
        failureCategory: FailureCategory? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.engineProfileID = engineProfileID
        self.engineDisplayName = engineDisplayName
        self.requestedModelID = requestedModelID
        self.responseModelID = responseModelID
        self.requestStartedAt = requestStartedAt
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.engineVersion = engineVersion
        self.resolvedRequestStyle = resolvedRequestStyle
        self.resolutionSource = resolutionSource
        self.adapterIdentifier = adapterIdentifier
        self.selectedEffort = selectedEffort
        self.actualTemperature = actualTemperature
        self.effectiveOutputTokenCap = effectiveOutputTokenCap
        self.nativeReasoningValue = nativeReasoningValue
        self.reasoningHistoryReplayed = reasoningHistoryReplayed
        self.templateControls = templateControls
        self.effectiveContextLimit = effectiveContextLimit
        self.contextLimitSource = contextLimitSource
        self.preflightTokenEstimate = preflightTokenEstimate
        self.preflightEstimateIsEstimated = preflightEstimateIsEstimated
        self.capabilities = capabilities
        self.metadataAgeSeconds = metadataAgeSeconds
        self.metadataIsFresh = metadataIsFresh
        self.lifecycle = lifecycle
        self.finishReason = finishReason
        self.failureCategory = failureCategory
    }
}
