import Foundation

/// A tri-state capability prevents missing metadata from being mistaken for support.
public enum CapabilitySupport: String, Codable, Hashable, Sendable {
    case unknown
    case unsupported
    case supported
}

/// The explicit source of a capability claim.
public enum CapabilityEvidence: String, CaseIterable, Codable, Hashable, Sendable {
    case modelList
    case modelDetail
    case engineConfiguration
    case observedResponse
}

/// One capability claim plus the server or configuration evidence behind it.
public struct CapabilityClaim: Codable, Hashable, Sendable {
    public let support: CapabilitySupport
    public let evidence: Set<CapabilityEvidence>

    public init(
        support: CapabilitySupport = .unknown,
        evidence: Set<CapabilityEvidence> = []
    ) {
        self.support = support
        self.evidence = evidence
    }

    public static let unknown = CapabilityClaim()

    public static func supported(by evidence: CapabilityEvidence) -> CapabilityClaim {
        CapabilityClaim(support: .supported, evidence: [evidence])
    }

    public static func unsupported(by evidence: CapabilityEvidence) -> CapabilityClaim {
        CapabilityClaim(support: .unsupported, evidence: [evidence])
    }

    /// Combines independent claims without allowing a conflict to enable a feature.
    /// Unknown is neutral. Conflicting explicit claims resolve to unknown with both
    /// evidence sets retained for diagnostics.
    public func merged(with other: CapabilityClaim) -> CapabilityClaim {
        let mergedEvidence = evidence.union(other.evidence)
        switch (support, other.support) {
        case (.unknown, let support), (let support, .unknown):
            return CapabilityClaim(support: support, evidence: mergedEvidence)
        case let (left, right) where left == right:
            return CapabilityClaim(support: left, evidence: mergedEvidence)
        default:
            return CapabilityClaim(support: .unknown, evidence: mergedEvidence)
        }
    }
}

/// Reasoning effort values currently used by popular OpenAI-compatible engines.
public enum ReasoningEffortValue: String, CaseIterable, Codable, Hashable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    fileprivate var rank: Int {
        switch self {
        case .none: 0
        case .minimal: 1
        case .low: 2
        case .medium: 3
        case .high: 4
        case .xhigh: 5
        case .max: 6
        case .ultra: 7
        }
    }

    public init?(wireValue: String) {
        self.init(rawValue: wireValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

/// Capabilities explicitly reported for one model by its active engine.
public struct ModelCapabilities: Codable, Hashable, Sendable {
    public var vision: CapabilityClaim
    public var tools: CapabilityClaim
    public var reasoning: CapabilityClaim
    /// Whether the selected engine has explicitly been configured to replay prior
    /// assistant reasoning in its native message field.
    public var reasoningHistory: CapabilityClaim

    /// Wire parameter names explicitly advertised by the engine.
    public private(set) var advertisedRequestParameters: Set<String>

    /// Explicitly advertised values. Nil means the engine advertised the parameter
    /// without listing values. An empty set means it explicitly listed no usable values.
    public var reasoningEffortValues: Set<ReasoningEffortValue>?

    public init(
        vision: CapabilityClaim = .unknown,
        tools: CapabilityClaim = .unknown,
        reasoning: CapabilityClaim = .unknown,
        reasoningHistory: CapabilityClaim = .unknown,
        advertisedRequestParameters: Set<String> = [],
        reasoningEffortValues: Set<ReasoningEffortValue>? = nil
    ) {
        self.vision = vision
        self.tools = tools
        self.reasoning = reasoning
        self.reasoningHistory = reasoningHistory
        self.advertisedRequestParameters = Set(
            advertisedRequestParameters.compactMap(Self.normalizedParameterName))
        self.reasoningEffortValues = reasoningEffortValues
    }

    public static let unknown = ModelCapabilities()

    public func advertisesRequestParameter(_ name: String) -> Bool {
        guard let normalized = Self.normalizedParameterName(name) else { return false }
        return advertisedRequestParameters.contains(normalized)
    }

    /// Merges model-list and model-detail metadata conservatively.
    /// Explicit parameter advertisements accumulate. Two explicit effort lists are
    /// intersected so a disagreement cannot cause GOAT to send an unconfirmed value.
    public func merged(with other: ModelCapabilities) -> ModelCapabilities {
        ModelCapabilities(
            vision: vision.merged(with: other.vision),
            tools: tools.merged(with: other.tools),
            reasoning: reasoning.merged(with: other.reasoning),
            reasoningHistory: reasoningHistory.merged(with: other.reasoningHistory),
            advertisedRequestParameters: advertisedRequestParameters.union(
                other.advertisedRequestParameters),
            reasoningEffortValues: Self.mergeAllowedValues(
                reasoningEffortValues, other.reasoningEffortValues))
    }

    /// Maps GOAT's portable effort dial to advertised values. Graze/Summit use
    /// the supported extremes; Trot/Climb use the nearest medium/high value.
    /// The native field stays disabled unless `reasoning_effort` was advertised.
    public func reasoningEffort(for effort: Effort) -> ReasoningEffortValue? {
        guard advertisesRequestParameter("reasoning_effort") else { return nil }
        // Unknown includes conflicting explicit claims. Native fields require positive,
        // unambiguous evidence rather than merely the absence of a rejection.
        guard reasoning.support == .supported else { return nil }

        let allowed = reasoningEffortValues ?? [.low, .medium, .high]
        guard !allowed.isEmpty else { return nil }

        let ordered = allowed.sorted { $0.rank < $1.rank }
        let target: ReasoningEffortValue
        switch effort {
        case .graze: return ordered.first
        case .trot: target = .medium
        case .climb: target = .high
        case .summit: return ordered.last
        }

        return allowed.min { left, right in
            let leftDistance = abs(left.rank - target.rank)
            let rightDistance = abs(right.rank - target.rank)
            if leftDistance == rightDistance {
                return left.rank < right.rank
            }
            return leftDistance < rightDistance
        }
    }

    public func nativeReasoningEffort(for effort: Effort) -> String? {
        reasoningEffort(for: effort)?.rawValue
    }

    public var replaysReasoningHistory: Bool {
        reasoningHistory.support == .supported
    }

    /// An engine profile is explicit user configuration, so it can safely enable a
    /// non-standard history field without treating a model name as protocol evidence.
    public func applying(requestStyle: EngineRequestStyle) -> ModelCapabilities {
        guard requestStyle == .qwenChatTemplate else { return self }
        return merged(
            with: ModelCapabilities(
                reasoningHistory: .supported(by: .engineConfiguration)))
    }

    private static func normalizedParameterName(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func mergeAllowedValues(
        _ left: Set<ReasoningEffortValue>?,
        _ right: Set<ReasoningEffortValue>?
    ) -> Set<ReasoningEffortValue>? {
        switch (left, right) {
        case (nil, nil): nil
        case (.some(let values), nil), (nil, .some(let values)): values
        case (.some(let left), .some(let right)): left.intersection(right)
        }
    }
}

/// Model-name hints are presentation and ordering signals only. They never enable
/// a request field or override explicit engine capability metadata.
public enum ModelNameHeuristics {
    public static func isCoderFocused(_ modelID: String) -> Bool {
        let tokens = modelID.lowercased().split { character in
            !character.isLetter && !character.isNumber
        }
        let tokenSet = Set(tokens.map(String.init))
        let collapsed = tokens.joined()

        if [
            "devstral", "codestral", "starcoder", "codellama", "codegemma",
            "opencoder", "wizardcoder", "magicoder", "santacoder", "codeqwen",
            "deepseekcoder",
        ]
        .contains(where: collapsed.contains) {
            return true
        }
        if tokenSet.contains("kimi"), tokenSet.contains("dev") { return true }
        if tokenSet.contains("qwen"), tokenSet.contains("coder") { return true }
        if tokenSet.contains("deepseek"), tokenSet.contains("coder") { return true }
        if tokenSet.contains("granite"), !tokenSet.isDisjoint(with: ["code", "coder"]) {
            return true
        }

        // Exact components are safe generic hints. This deliberately avoids substring
        // matches such as "encoder", "codec", and "decode".
        return !tokenSet.isDisjoint(with: ["code", "coder", "coding"])
    }
}

/// Owns the latest model-capability probe across actor suspension points.
public actor ModelCapabilityProbeOwnership {
    public struct Target: Hashable, Sendable {
        public let engineID: String
        public let modelID: String

        public init(engineID: String, modelID: String) {
            self.engineID = engineID
            self.modelID = modelID
        }
    }

    public struct Operation: Hashable, Sendable {
        public let revision: UInt64
        public let target: Target

        fileprivate init(revision: UInt64, target: Target) {
            self.revision = revision
            self.target = target
        }
    }

    public struct Resolution: Hashable, Sendable {
        public let revision: UInt64
        public let target: Target
        public let capabilities: ModelCapabilities

        fileprivate init(
            revision: UInt64,
            target: Target,
            capabilities: ModelCapabilities
        ) {
            self.revision = revision
            self.target = target
            self.capabilities = capabilities
        }
    }

    private var latestRevision: UInt64 = 0
    private var latestIntentRevision: UInt64 = 0

    public init() {}

    public func begin(target: Target) -> Operation {
        latestIntentRevision &+= 1
        return Operation(revision: advanceRevision(), target: target)
    }

    /// Rejects caller intents that arrive at the actor out of order.
    public func begin(target: Target, intentRevision: UInt64) -> Operation? {
        guard intentRevision > latestIntentRevision else { return nil }
        latestIntentRevision = intentRevision
        return Operation(revision: advanceRevision(), target: target)
    }

    /// Returns a result only while its engine and model selection still owns the probe.
    public func resolve(
        _ capabilities: ModelCapabilities,
        for operation: Operation
    ) -> Resolution? {
        guard !Task.isCancelled, operation.revision == latestRevision else { return nil }
        return Resolution(
            revision: operation.revision,
            target: operation.target,
            capabilities: capabilities)
    }

    @discardableResult
    public func invalidate() -> UInt64 {
        advanceRevision()
    }

    public func isCurrent(_ operation: Operation) -> Bool {
        operation.revision == latestRevision
    }

    public func isCurrent(_ resolution: Resolution) -> Bool {
        resolution.revision == latestRevision
    }

    public var revision: UInt64 { latestRevision }

    @discardableResult
    private func advanceRevision() -> UInt64 {
        latestRevision &+= 1
        return latestRevision
    }
}
