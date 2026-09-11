import Foundation

public enum ModelCheckpointRole: String, Codable, CaseIterable, Sendable {
    case standalone
    case draft
    case unknown
}

public enum ModelMetadataFreshness: String, Codable, Sendable {
    case unknown
    case fresh
    case stale
}

public struct ModelInspectionSnapshot: Codable, Equatable, Sendable {
    public let identity: ModelIdentity
    public let model: ModelRef
    public let fetchedAt: Date
    public let engineConfigurationRevision: UInt64
    public let metadataSources: [String]
    public let format: String?
    public let quantization: String?
    public let architecture: String?
    public let modelType: String?
    public let parameterCount: Int64?
    public let weightBytes: Int64?
    public let engineVersion: String?
    public let checkpointRole: ModelCheckpointRole
    public let templateIdentifier: String?
    public let parserIdentifier: String?

    public init(
        identity: ModelIdentity,
        model: ModelRef,
        fetchedAt: Date = .now,
        engineConfigurationRevision: UInt64,
        metadataSources: [String] = [],
        format: String? = nil,
        quantization: String? = nil,
        architecture: String? = nil,
        modelType: String? = nil,
        parameterCount: Int64? = nil,
        weightBytes: Int64? = nil,
        engineVersion: String? = nil,
        checkpointRole: ModelCheckpointRole = .unknown,
        templateIdentifier: String? = nil,
        parserIdentifier: String? = nil
    ) {
        self.identity = identity
        self.model = model
        self.fetchedAt = fetchedAt
        self.engineConfigurationRevision = engineConfigurationRevision
        self.metadataSources = metadataSources.sorted()
        self.format = format
        self.quantization = quantization
        self.architecture = architecture
        self.modelType = modelType
        self.parameterCount = parameterCount
        self.weightBytes = weightBytes
        self.engineVersion = engineVersion
        self.checkpointRole = checkpointRole
        self.templateIdentifier = templateIdentifier
        self.parserIdentifier = parserIdentifier
    }

    public func freshness(at now: Date = .now) -> ModelMetadataFreshness {
        guard fetchedAt <= now else { return .unknown }
        return now.timeIntervalSince(fetchedAt) <= 300 ? .fresh : .stale
    }
}

public enum ModelMetadataState: Sendable, Equatable {
    case notRequested
    case loading(previous: ModelInspectionSnapshot?)
    case loaded(snapshot: ModelInspectionSnapshot)
    case failed(message: String, previous: ModelInspectionSnapshot?)

    public var snapshot: ModelInspectionSnapshot? {
        switch self {
        case .notRequested: nil
        case .loading(let previous), .failed(_, let previous): previous
        case .loaded(let snapshot): snapshot
        }
    }

    public func freshness(at now: Date = .now) -> ModelMetadataFreshness {
        snapshot?.freshness(at: now) ?? .unknown
    }
}

public struct ModelCatalogProjection: Equatable, Sendable {
    public let availableFavourites: [ModelRef]
    public let availableOthers: [ModelRef]
    public let unavailableFavourites: [ModelPreference]

    public init(
        models: [ModelRef], preferences: [ModelPreference], engineProfileID: String
    ) {
        let preferencesByID = Dictionary(
            uniqueKeysWithValues: preferences.filter {
                $0.identity.engineProfileID == engineProfileID
            }.map { ($0.identity.modelID, $0) })
        let availableIDs = Set(models.map(\.id))
        let sortModels: ([ModelRef]) -> [ModelRef] = { values in
            values.sorted {
                if $0.displayName != $1.displayName { return $0.displayName < $1.displayName }
                return $0.id < $1.id
            }
        }
        availableFavourites = sortModels(
            models.filter { preferencesByID[$0.id]?.isFavourite == true })
        availableOthers = sortModels(
            models.filter { preferencesByID[$0.id]?.isFavourite != true })
        unavailableFavourites = preferences
            .filter {
                $0.identity.engineProfileID == engineProfileID
                    && $0.isFavourite && !availableIDs.contains($0.identity.modelID)
            }
            .sorted {
                if $0.identity.modelID != $1.identity.modelID {
                    return $0.identity.modelID < $1.identity.modelID
                }
                return $0.updatedAt < $1.updatedAt
            }
    }
}
