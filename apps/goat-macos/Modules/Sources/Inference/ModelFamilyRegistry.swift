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
        // A user file wins over the shipped built-ins so an owner can patch or correct a family
        // ahead of a release without rebuilding GOAT; a matching user rule replaces the built-in
        // outright rather than merging with it. Built-ins are the fallback.
        if let userRule = cachedUserRules(from: userFileURL).first(where: { $0.matches(modelID) }) {
            return userRule.profile(evidence: .userModelFamily)
        }
        guard let builtIn = builtInRules.first(where: { $0.matches(modelID) })
        else { return nil }
        return builtIn.profile(evidence: .modelFamily)
    }

    public static func loadUserRules(
        from url: URL? = userConfigurationURL()
    ) -> [ModelFamilyRule] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return decodeRules(from: data)
    }

    /// Decode a registry document from JSON, keeping only well-formed rules. Shared by the
    /// bundled built-ins and the user file so both honour the same schema and validation.
    static func decodeRules(from data: Data) -> [ModelFamilyRule] {
        guard let document = try? JSONDecoder().decode(ModelFamilyRegistryDocument.self, from: data),
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

    /// Curated, positive-only knowledge for common local model families, loaded from the
    /// bundled `model-families.builtin.json` resource in the registry's own document format
    /// (ADR-0009, ADR-0086). Ordered specific to general; the first matching rule wins. Editing
    /// the shipped set is a JSON change, not a Swift one, and a user file in GOAT Home adds or
    /// overrides families without rebuilding. Context lengths are declared only where the family
    /// publishes one stable figure; an engine-reported window always wins on merge.
    static let builtInRules: [ModelFamilyRule] = {
        guard
            let url = Bundle.module.url(
                forResource: "model-families.builtin", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else {
            assertionFailure("model-families.builtin.json missing from Inference resources")
            return []
        }
        return decodeRules(from: data)
    }()
}
