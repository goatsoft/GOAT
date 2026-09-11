import Foundation
import Herd
import Synchronization

/// Verified metadata for a model family whose compatible engine may not expose
/// capability fields through its model catalog.
public struct KnownModelProfile: Equatable, Sendable {
    public let contextLength: Int?
    public let capabilities: ModelCapabilities
    public let inspection: EngineModelInspectionMetadata?

    public init(
        contextLength: Int?, capabilities: ModelCapabilities,
        inspection: EngineModelInspectionMetadata? = nil
    ) {
        self.contextLength = contextLength
        self.capabilities = capabilities
        self.inspection = inspection
    }
}

/// A capability rule for one model family. Rules describe published model facts only:
/// capabilities, context length and static inspection facts. Request dialects and
/// provider-specific parameters remain engine configuration (ADR-0024, ADR-0086).
///
/// Matching: a normalized model ID must contain at least one `matchAny` entry and every
/// `matchAll` entry, and none of the `exclude` entries. Claims are positive only; a rule can
/// fill a gap an engine leaves but never marks a capability unsupported.
public struct ModelFamilyRule: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let matchAny: [String]
    public let matchAll: [String]
    public let exclude: [String]
    public let contextLength: Int?
    public let capabilities: Set<String>
    public let architecture: String?
    public let modelType: String?
    public let format: String?
    public let parameterCount: Int64?

    public init(
        id: String,
        matchAny: [String],
        matchAll: [String] = [],
        exclude: [String] = [],
        contextLength: Int? = nil,
        capabilities: Set<String> = [],
        architecture: String? = nil,
        modelType: String? = nil,
        format: String? = nil,
        parameterCount: Int64? = nil
    ) {
        self.id = id
        self.matchAny = matchAny
        self.matchAll = matchAll
        self.exclude = exclude
        self.contextLength = contextLength
        self.capabilities = Set(capabilities.map(Self.normalized))
        self.architecture = architecture
        self.modelType = modelType
        self.format = format
        self.parameterCount = parameterCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, matchAny, matchAll, exclude, contextLength, capabilities
        case architecture, modelType, format, parameterCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            matchAny: try container.decode([String].self, forKey: .matchAny),
            matchAll: try container.decodeIfPresent([String].self, forKey: .matchAll) ?? [],
            exclude: try container.decodeIfPresent([String].self, forKey: .exclude) ?? [],
            contextLength: try container.decodeIfPresent(Int.self, forKey: .contextLength),
            capabilities: try container.decodeIfPresent(Set<String>.self, forKey: .capabilities) ?? [],
            architecture: try container.decodeIfPresent(String.self, forKey: .architecture),
            modelType: try container.decodeIfPresent(String.self, forKey: .modelType),
            format: try container.decodeIfPresent(String.self, forKey: .format),
            parameterCount: try container.decodeIfPresent(Int64.self, forKey: .parameterCount))
    }

    func matches(_ modelID: String) -> Bool {
        let normalizedID = Self.normalized(modelID)
        guard !normalizedID.isEmpty,
            matchAny.contains(where: { normalizedID.contains(Self.normalized($0)) }),
            matchAll.allSatisfy({ normalizedID.contains(Self.normalized($0)) })
        else { return false }

        let tokens = normalizedID.split { character in
            !character.isLetter && !character.isNumber
        }
        return !exclude.contains { exclusion in
            let normalizedExclusion = Self.normalized(exclusion)
            return tokens.contains { String($0) == normalizedExclusion }
                || normalizedID.contains(normalizedExclusion)
        }
    }

    func profile(evidence: CapabilityEvidence) -> KnownModelProfile {
        let supports = capabilities
        let inspection: EngineModelInspectionMetadata? =
            architecture == nil && modelType == nil && format == nil && parameterCount == nil
            ? nil
            : EngineModelInspectionMetadata(
                format: format, architecture: architecture, modelType: modelType,
                parameterCount: parameterCount)
        return KnownModelProfile(
            contextLength: contextLength,
            capabilities: ModelCapabilities(
                vision: Self.claim("vision", in: supports, evidence: evidence),
                tools: Self.claim("tools", in: supports, evidence: evidence),
                reasoning: Self.claim("reasoning", in: supports, evidence: evidence),
                reasoningHistory: Self.claim(
                    "reasoning_history", in: supports, evidence: evidence)),
            inspection: inspection)
    }

    private static func claim(
        _ capability: String,
        in capabilities: Set<String>,
        evidence: CapabilityEvidence
    ) -> CapabilityClaim {
        capabilities.contains(capability) ? .supported(by: evidence) : .unknown
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }
}

public struct ModelFamilyRegistryDocument: Codable, Equatable, Sendable {
    public let schema: Int
    public let families: [ModelFamilyRule]

    public init(schema: Int = 1, families: [ModelFamilyRule]) {
        self.schema = schema
        self.families = families
    }
}

/// Resolves built-in and user-editable family knowledge. The user file lives in GOAT Home
/// (`~/.goat/config/model-families.json`, ADR-0009) and is re-read when its modification
/// date changes, so catalog refresh picks up edits without rebuilding GOAT or re-reading the
/// file for every model in a catalog.
public enum ModelFamilyRegistry {
    public static let userFileName = "model-families.json"

    private struct Cache {
        var url: URL?
        var modified: Date?
        var rules: [ModelFamilyRule] = []
    }

    private static let cache = Mutex(Cache())

    /// The default user file: GOAT Home's config directory (ADR-0009).
    public static func userConfigurationURL() -> URL? {
        Home.configDir.appendingPathComponent(userFileName, isDirectory: false)
    }

    public static func profile(
        for modelID: String,
        userFileURL: URL? = userConfigurationURL()
    ) -> KnownModelProfile? {
        if let builtIn = builtInRules.first(where: { $0.matches(modelID) }) {
            return builtIn.profile(evidence: .modelFamily)
        }
        guard let userRule = cachedUserRules(from: userFileURL).first(where: { $0.matches(modelID) })
        else { return nil }
        return userRule.profile(evidence: .userModelFamily)
    }

    public static func loadUserRules(
        from url: URL? = userConfigurationURL()
    ) -> [ModelFamilyRule] {
        guard let url,
            let data = try? Data(contentsOf: url),
            let document = try? JSONDecoder().decode(ModelFamilyRegistryDocument.self, from: data),
            document.schema == 1
        else { return [] }
        return document.families.filter { !$0.id.isEmpty && !$0.matchAny.isEmpty }
    }

    private static func cachedUserRules(from url: URL?) -> [ModelFamilyRule] {
        guard let url else { return [] }
        let modified =
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        return cache.withLock { cache in
            if cache.url == url, cache.modified == modified { return cache.rules }
            let rules = modified == nil ? [] : loadUserRules(from: url)
            cache = Cache(url: url, modified: modified, rules: rules)
            return rules
        }
    }

    /// Curated, positive-only knowledge for common local model families. Ordered specific
    /// to general; the first matching rule wins. Context lengths are declared only where the
    /// family publishes one stable figure; an engine-reported window always wins on merge.
    static let builtInRules: [ModelFamilyRule] = [
        ModelFamilyRule(
            id: "muse-glimmer",
            matchAny: ["muse-glimmer-30b", "meta-models/muse-glimmer-30b"],
            exclude: ["text"],
            contextLength: 131_072,
            capabilities: ["vision", "tools", "reasoning"],
            architecture: "Muse-Glimmer", modelType: "multimodal",
            parameterCount: 30_000_000_000),

        // DeepSeek (before Qwen: R1 distills carry a Qwen base name but behave as R1)
        ModelFamilyRule(
            id: "deepseek-r1", matchAny: ["deepseek-r1"], capabilities: ["reasoning"]),
        ModelFamilyRule(
            id: "deepseek-v3-hybrid", matchAny: ["deepseek-v3.1", "deepseek-v3.2"],
            capabilities: ["tools", "reasoning"]),
        ModelFamilyRule(
            id: "deepseek-v3", matchAny: ["deepseek-v3"], capabilities: ["tools"]),

        // Qwen
        ModelFamilyRule(
            id: "qwen3-coder", matchAny: ["qwen3-coder"], capabilities: ["tools"]),
        ModelFamilyRule(
            id: "qwen3-vl-thinking", matchAny: ["qwen3-vl"], matchAll: ["thinking"],
            capabilities: ["vision", "tools", "reasoning"]),
        ModelFamilyRule(
            id: "qwen3-vl", matchAny: ["qwen3-vl"], capabilities: ["vision", "tools"]),
        ModelFamilyRule(
            id: "qwen3-thinking", matchAny: ["qwen3"], matchAll: ["thinking"],
            exclude: ["vl", "embedding", "reranker", "guard"],
            capabilities: ["tools", "reasoning"]),
        ModelFamilyRule(
            id: "qwen3-instruct", matchAny: ["qwen3"], matchAll: ["instruct"],
            exclude: ["vl", "coder", "embedding", "reranker", "guard"],
            capabilities: ["tools"]),
        ModelFamilyRule(
            id: "qwen3", matchAny: ["qwen3"],
            exclude: ["vl", "coder", "embedding", "reranker", "omni", "guard", "tts", "asr"],
            capabilities: ["tools", "reasoning"]),
        ModelFamilyRule(
            id: "qwen2.5-vl", matchAny: ["qwen2.5-vl", "qwen2-vl"], capabilities: ["vision", "tools"]),
        ModelFamilyRule(
            id: "qwen2.5", matchAny: ["qwen2.5"],
            exclude: ["vl", "omni", "math", "embedding", "reranker", "audio"],
            capabilities: ["tools"]),

        // OpenAI open weights
        ModelFamilyRule(
            id: "gpt-oss", matchAny: ["gpt-oss"], contextLength: 131_072,
            capabilities: ["tools", "reasoning"]),

        // Zhipu GLM
        ModelFamilyRule(
            id: "glm-vision", matchAny: ["glm-4.1v", "glm-4.5v", "glm-4.6v", "glm-4.7v", "glm-5v"],
            capabilities: ["vision", "tools", "reasoning"]),
        ModelFamilyRule(
            id: "glm", matchAny: ["glm-4.5", "glm-4.6", "glm-4.7", "glm-5"],
            capabilities: ["tools", "reasoning"]),

        // Meta Llama
        ModelFamilyRule(
            id: "llama-4", matchAny: ["llama-4"], capabilities: ["vision", "tools"]),
        ModelFamilyRule(
            id: "llama-3.2-vision", matchAny: ["llama-3.2"], matchAll: ["vision"],
            contextLength: 131_072, capabilities: ["vision"]),
        ModelFamilyRule(
            id: "llama-3", matchAny: ["llama-3.1", "llama-3.2", "llama-3.3"],
            exclude: ["guard"], contextLength: 131_072, capabilities: ["tools"]),

        // Google Gemma (no native tool-call format; tools stay unknown)
        ModelFamilyRule(
            id: "gemma-3-multimodal", matchAny: ["gemma-3-4b", "gemma-3-12b", "gemma-3-27b"],
            contextLength: 131_072, capabilities: ["vision"]),
        ModelFamilyRule(
            id: "gemma-3n", matchAny: ["gemma-3n"], capabilities: ["vision"]),

        // Mistral
        ModelFamilyRule(
            id: "mistral-small-3",
            matchAny: ["mistral-small-3.1", "mistral-small-3.2", "mistral-small-2503", "mistral-small-2506"],
            contextLength: 131_072, capabilities: ["vision", "tools"]),
        ModelFamilyRule(
            id: "magistral", matchAny: ["magistral"], capabilities: ["tools", "reasoning"]),
        ModelFamilyRule(
            id: "devstral", matchAny: ["devstral"], capabilities: ["tools"]),

        // Moonshot Kimi
        ModelFamilyRule(
            id: "kimi-k2.5", matchAny: ["kimi-k2.5"], capabilities: ["vision", "tools", "reasoning"]),
        ModelFamilyRule(
            id: "kimi-k2-thinking", matchAny: ["kimi-k2"], matchAll: ["thinking"],
            capabilities: ["tools", "reasoning"]),
        ModelFamilyRule(
            id: "kimi-k2", matchAny: ["kimi-k2"], capabilities: ["tools"]),

        // MiniMax
        ModelFamilyRule(
            id: "minimax-m2", matchAny: ["minimax-m2"], capabilities: ["tools", "reasoning"]),

        // Microsoft Phi
        ModelFamilyRule(
            id: "phi-4-multimodal", matchAny: ["phi-4-multimodal"], capabilities: ["vision"]),
        ModelFamilyRule(
            id: "phi-4-reasoning", matchAny: ["phi-4-reasoning", "phi-4-mini-reasoning"],
            capabilities: ["reasoning"]),
        ModelFamilyRule(
            id: "phi-4-mini", matchAny: ["phi-4-mini"], capabilities: ["tools"]),

        // Others with documented native tool calling
        ModelFamilyRule(
            id: "seed-oss", matchAny: ["seed-oss"], capabilities: ["tools", "reasoning"]),
        ModelFamilyRule(
            id: "granite-4", matchAny: ["granite-4"], capabilities: ["tools"]),
    ]
}

/// Family knowledge is separate from name heuristics and is merged conservatively
/// with active engine metadata. Built-ins take precedence over user additions.
public enum KnownModelProfiles {
    public static func profile(for modelID: String) -> KnownModelProfile? {
        ModelFamilyRegistry.profile(for: modelID)
    }
}
