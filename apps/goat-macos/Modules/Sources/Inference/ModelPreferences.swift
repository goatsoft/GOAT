import Foundation
import Herd

/// Stable identity for one model on one configured engine profile.
public struct ModelIdentity: Codable, Hashable, Sendable {
    public var engineProfileID: String
    public var modelID: String

    public init(engineProfileID: String, modelID: String) {
        self.engineProfileID = engineProfileID
        self.modelID = modelID
    }
}

/// Per-pair request semantics. Automatic deliberately carries no adapter-specific claim.
public enum ModelCompatibilityOverride: String, Codable, CaseIterable, Sendable {
    case automatic
    case genericOpenAI
    case qwenChatTemplate
}

public struct ModelPreference: Codable, Equatable, Sendable {
    public var identity: ModelIdentity
    public var isFavourite: Bool
    public var compatibilityOverride: ModelCompatibilityOverride
    /// A user-asserted context window for prompt budgeting (ADR-0085). It fills a missing
    /// engine window or lowers a reported one; it never raises an engine-reported window.
    public var contextWindowOverride: Int?
    public var updatedAt: Date

    public init(
        identity: ModelIdentity,
        isFavourite: Bool = false,
        compatibilityOverride: ModelCompatibilityOverride = .automatic,
        contextWindowOverride: Int? = nil,
        updatedAt: Date = .now
    ) {
        self.identity = identity
        self.isFavourite = isFavourite
        self.compatibilityOverride = compatibilityOverride
        self.contextWindowOverride = contextWindowOverride
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case identity, isFavourite, compatibilityOverride, contextWindowOverride, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            identity: try container.decode(ModelIdentity.self, forKey: .identity),
            isFavourite: try container.decodeIfPresent(Bool.self, forKey: .isFavourite) ?? false,
            compatibilityOverride: try container.decodeIfPresent(
                ModelCompatibilityOverride.self, forKey: .compatibilityOverride) ?? .automatic,
            contextWindowOverride: try container.decodeIfPresent(Int.self, forKey: .contextWindowOverride),
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now)
    }

    /// The window the budgeter should use for `reported`, honouring the override rule above.
    public func effectiveContextLength(reported: Int?) -> Int? {
        guard let override = contextWindowOverride, override > 0 else { return reported }
        guard let reported, reported > 0 else { return override }
        return min(reported, override)
    }
}

public struct LegacyCompatibilityReview: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case pending
        case assigned
        case discarded
    }

    public var engineProfileID: String
    public var legacyStyle: EngineRequestStyle
    public var state: State
    public var assignedModelID: String?

    public init(
        engineProfileID: String,
        legacyStyle: EngineRequestStyle,
        state: State = .pending,
        assignedModelID: String? = nil
    ) {
        self.engineProfileID = engineProfileID
        self.legacyStyle = legacyStyle
        self.state = state
        self.assignedModelID = assignedModelID
    }
}

public struct ModelPreferencesFile: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var models: [ModelPreference]
    public var legacyReviews: [LegacyCompatibilityReview]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        models: [ModelPreference] = [],
        legacyReviews: [LegacyCompatibilityReview] = []
    ) {
        self.schemaVersion = schemaVersion
        self.models = models
        self.legacyReviews = legacyReviews
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case models
        case legacyReviews
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        models = try container.decodeIfPresent([ModelPreference].self, forKey: .models) ?? []
        legacyReviews =
            try container.decodeIfPresent([LegacyCompatibilityReview].self, forKey: .legacyReviews)
            ?? []
    }
}

public enum ModelPreferencesStore {
    public static func load(from url: URL) throws -> ModelPreferencesFile? {
        guard let data = try LocalFileStore.dataIfPresent(at: url) else { return nil }
        let file: ModelPreferencesFile
        do {
            file = try JSONDecoder().decode(ModelPreferencesFile.self, from: data)
        } catch {
            throw LocalStoreError.invalidData(
                path: url.path,
                reason: "model preferences could not be decoded: \(error.localizedDescription)")
        }
        try validate(file, at: url)
        return file
    }

    public static func save(_ file: ModelPreferencesFile, to url: URL) throws {
        try validate(file, at: url)
        var sorted = file
        sorted.models.sort { lhs, rhs in
            if lhs.identity.engineProfileID != rhs.identity.engineProfileID {
                return lhs.identity.engineProfileID < rhs.identity.engineProfileID
            }
            return lhs.identity.modelID < rhs.identity.modelID
        }
        sorted.legacyReviews.sort { $0.engineProfileID < $1.engineProfileID }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(sorted)
        } catch {
            throw LocalStoreError.invalidData(
                path: url.path,
                reason: "model preferences could not be encoded: \(error.localizedDescription)")
        }
        guard data.count <= LocalFileStore.maximumManagedFileBytes else {
            throw LocalStoreError.invalidData(
                path: url.path, reason: "model preferences exceed the permitted byte count")
        }
        try LocalFileStore.writeOwnerOnly(data, to: url)
    }

    private static func validate(_ file: ModelPreferencesFile, at url: URL) throws {
        guard file.schemaVersion == ModelPreferencesFile.currentSchemaVersion else {
            throw LocalStoreError.invalidData(
                path: url.path,
                reason: "unsupported model preferences schema version \(file.schemaVersion)")
        }
        let identities = file.models.map(\.identity)
        guard
            identities.allSatisfy({
                !$0.engineProfileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !$0.modelID.isEmpty
            })
        else {
            throw LocalStoreError.invalidData(
                path: url.path, reason: "model preference engine and model IDs must be non-empty")
        }
        guard Set(identities).count == identities.count else {
            throw LocalStoreError.invalidData(
                path: url.path, reason: "model preference pairing identities must be unique")
        }
        let reviewIDs = file.legacyReviews.map(\.engineProfileID)
        guard reviewIDs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
            Set(reviewIDs).count == reviewIDs.count
        else {
            throw LocalStoreError.invalidData(
                path: url.path, reason: "legacy compatibility reviews must have unique engine IDs")
        }
        guard file.legacyReviews.allSatisfy({ $0.assignedModelID?.isEmpty != true }) else {
            throw LocalStoreError.invalidData(
                path: url.path, reason: "assigned legacy model IDs must be non-empty")
        }
    }
}
