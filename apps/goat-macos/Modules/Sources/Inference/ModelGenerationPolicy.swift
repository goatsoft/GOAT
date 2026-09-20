import Foundation

/// Optional values are intentional: omission lets the server resolve its configured defaults.
public struct SamplingOverride: Codable, Equatable, Hashable, Sendable {
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var minP: Double?
    public var repetitionPenalty: Double?
    public var presencePenalty: Double?

    public init(
        temperature: Double? = nil, topP: Double? = nil, topK: Int? = nil,
        minP: Double? = nil, repetitionPenalty: Double? = nil, presencePenalty: Double? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.presencePenalty = presencePenalty
    }

    public var isValid: Bool {
        (temperature.map { $0.isFinite && (0...2).contains($0) } ?? true)
            && (topP.map { $0.isFinite && $0 > 0 && $0 <= 1 } ?? true)
            && (topK.map { $0 >= 0 } ?? true)
            && (minP.map { $0.isFinite && (0...1).contains($0) } ?? true)
            && (presencePenalty.map { $0.isFinite && (-2...2).contains($0) } ?? true)
            && (repetitionPenalty.map { $0.isFinite && $0 > 0 && $0 <= 2 } ?? true)
    }

    public var fields: [String: Double] {
        var result: [String: Double] = [:]
        result["temperature"] = temperature
        result["top_p"] = topP
        result["top_k"] = topK.map(Double.init)
        result["min_p"] = minP
        result["repetition_penalty"] = repetitionPenalty
        result["presence_penalty"] = presencePenalty
        return result
    }

    public func removing(_ names: Set<String>) -> SamplingOverride {
        SamplingOverride(
            temperature: names.contains("temperature") ? nil : temperature,
            topP: names.contains("top_p") ? nil : topP,
            topK: names.contains("top_k") ? nil : topK,
            minP: names.contains("min_p") ? nil : minP,
            repetitionPenalty: names.contains("repetition_penalty") ? nil : repetitionPenalty,
            presencePenalty: names.contains("presence_penalty") ? nil : presencePenalty)
    }

    public var summary: String {
        let values = fields.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.formatted())" }
        return values.isEmpty ? "Engine default" : values.joined(separator: ", ")
    }
}

/// Published checkpoint behaviour, separate from engine-specific wire controls.
public struct ModelGenerationPolicy: Codable, Equatable, Hashable, Sendable {
    public enum ReasoningHistory: String, Codable, Sendable { case omit, currentTurn, all }
    public enum ReasoningPrompt: String, Codable, Sendable { case museStrength, qwenSoftSwitch }
    public var sampling: SamplingOverride?
    public var nonThinkingSampling: SamplingOverride?
    public var reasoningPrompt: ReasoningPrompt?
    public var reasoningHistory: ReasoningHistory?
    public var nativeReasoningEffortValues: Set<ReasoningEffortValue>?
    public var sources: [String]
    public var note: String?

    public init(
        sampling: SamplingOverride? = nil, nonThinkingSampling: SamplingOverride? = nil,
        reasoningPrompt: ReasoningPrompt? = nil, reasoningHistory: ReasoningHistory? = nil,
        sources: [String] = [], note: String? = nil,
        nativeReasoningEffortValues: Set<ReasoningEffortValue>? = nil
    ) {
        self.sampling = sampling
        self.nonThinkingSampling = nonThinkingSampling
        self.reasoningPrompt = reasoningPrompt
        self.reasoningHistory = reasoningHistory
        self.nativeReasoningEffortValues = nativeReasoningEffortValues
        self.sources = sources
        self.note = note
    }

    public var isValid: Bool {
        (sampling?.isValid ?? true) && (nonThinkingSampling?.isValid ?? true)
            && sources.allSatisfy { URL(string: $0)?.scheme == "https" }
    }
}

public enum SamplingSource: String, Codable, Sendable {
    case engineDefault, modelFamily, userModelFamily, userOverride, compatibilityOverride
}

public extension EngineError {
    /// Retry only a named sampling parameter explicitly rejected by a 400 response.
    /// Never remove arbitrary fields, tools, credentials or prompt content to recover.
    var rejectedSamplingParameter: String? {
        guard case .httpDetail(400, let detail, _) = self else { return nil }
        let lower = String(detail.prefix(4096)).lowercased()
        guard
            [
                "unsupported", "not supported", "not permitted", "unrecognized", "unknown parameter",
                "extra inputs are not permitted",
            ].contains(where: lower.contains)
        else { return nil }
        return ["temperature", "top_p", "top_k", "min_p", "repetition_penalty", "presence_penalty"].first { name in
            let pattern = "(?<![a-z_])" + name + "(?![a-z_])"
            return lower.range(of: pattern, options: .regularExpression) != nil
        }
    }
}
