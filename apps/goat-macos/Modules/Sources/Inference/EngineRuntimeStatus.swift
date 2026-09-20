import Foundation

/// Optional server facts, not host RAM or inferred generation progress.
public struct EngineRuntimeStatus: Sendable, Equatable {
    public let observedAt: Date
    public let version: String?
    public let modelMemoryUsed: Int64?
    public let modelMemoryMaximum: Int64?
    public let activeRequests: Int?
    public let waitingRequests: Int?
    public let models: [EngineModelRuntimeStatus]?
}

public struct EngineModelRuntimeStatus: Sendable, Equatable, Identifiable {
    public let id: String
    public let loaded: Bool?
    public let loading: Bool?
    public let contextWindow: Int?
    /// Server configuration, not a claim about an immutable model maximum.
    public let configuredOutputLimit: Int?
}

/// HTTP bounds are also enforced before decoding. Keep missing or invalid facts unavailable.
enum OMLXStatusDecoder {
    static let maximumBytes = 256 * 1_024

    static func decode(server: Data?, models: Data?, observedAt: Date = .now) -> EngineRuntimeStatus? {
        let server = server.flatMap { boundedDecode(Server.self, from: $0) }
        let catalog = models.flatMap { boundedDecode(Catalog.self, from: $0) }
        guard server != nil || catalog != nil else { return nil }
        let counts = catalog?.models?.reduce(into: [String: Int]()) { $0[$1.id, default: 0] += 1 } ?? [:]
        let rows = catalog?.models?.filter { !$0.id.isEmpty && counts[$0.id] == 1 }
        return EngineRuntimeStatus(
            observedAt: observedAt, version: server?.version,
            modelMemoryUsed: nonnegative(server?.model_memory_used),
            modelMemoryMaximum: positive(server?.model_memory_max),
            activeRequests: nonnegative(server?.active_requests),
            waitingRequests: nonnegative(server?.waiting_requests),
            models: rows?.map {
                EngineModelRuntimeStatus(
                    id: $0.id, loaded: $0.loaded, loading: $0.is_loading,
                    contextWindow: positive($0.max_context_window) ?? positive($0.model_context_length),
                    configuredOutputLimit: positive($0.max_tokens))
            })
    }

    private static func boundedDecode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        guard data.count <= maximumBytes else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func nonnegative<T: BinaryInteger>(_ value: T?) -> T? {
        value.flatMap { $0 >= 0 ? $0 : nil }
    }

    private static func positive<T: BinaryInteger>(_ value: T?) -> T? {
        value.flatMap { $0 > 0 ? $0 : nil }
    }

    private struct Server: Decodable {
        let version: String?
        let model_memory_used: Int64?
        let model_memory_max: Int64?
        let active_requests: Int?
        let waiting_requests: Int?
    }

    private struct Catalog: Decodable {
        let models: [Model]?
    }

    private struct Model: Decodable {
        let id: String
        let loaded: Bool?
        let is_loading: Bool?
        let max_context_window: Int?
        let model_context_length: Int?
        let max_tokens: Int?
    }
}

extension EngineModelRuntimeStatus {
    /// Callers bind the status response to their captured engine revision before applying it.
    func applying(to model: ModelRef) -> ModelRef {
        guard id == model.id else { return model }
        return ModelRef(
            id: model.id, contextLength: contextWindow ?? model.contextLength,
            capabilities: model.capabilities, serverOutputLimit: configuredOutputLimit,
            limitsSource: contextWindow == nil && configuredOutputLimit == nil
                ? model.limitsSource
                : "oMLX /v1/models/status"
                    + (contextWindow == nil ? " (output only)" : configuredOutputLimit == nil ? " (context only)" : ""))
    }
}
