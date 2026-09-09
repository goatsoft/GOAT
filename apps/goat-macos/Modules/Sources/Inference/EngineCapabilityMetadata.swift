import Foundation
import JUDAS

/// The security boundary shared by metadata URLs, redirects, and endpoint validation.
struct EngineHTTPOrigin: Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let rawScheme = components.scheme?.lowercased(),
            rawScheme == "http" || rawScheme == "https",
            let rawHost = components.host?.lowercased(), !rawHost.isEmpty,
            components.user == nil, components.password == nil
        else { return nil }
        scheme = rawScheme
        host = rawHost
        port = components.port ?? (rawScheme == "https" ? 443 : 80)
    }

    func contains(_ url: URL) -> Bool { EngineHTTPOrigin(url: url) == self }
}

/// A small, normalized result from one metadata-only engine probe.
struct ProbedModelMetadata: Equatable, Sendable {
    var contextLength: Int?
    var capabilities: ModelCapabilities

    static let unknown = ProbedModelMetadata(contextLength: nil, capabilities: .unknown)

    func merged(with other: ProbedModelMetadata) -> ProbedModelMetadata {
        ProbedModelMetadata(
            contextLength: other.contextLength ?? contextLength,
            capabilities: capabilities.merged(with: other.capabilities))
    }

    func applying(to model: ModelRef) -> ModelRef {
        ModelRef(
            id: model.id,
            contextLength: contextLength ?? model.contextLength,
            capabilities: model.capabilities.merged(with: capabilities))
    }
}

/// Builds endpoint URLs without allowing a model ID slash to become a path separator.
enum EngineMetadataEndpoint {
    private static let pathComponentCharacters = CharacterSet.alphanumerics.union(
        CharacterSet(charactersIn: "-._~"))

    private static func encodedPathComponent(_ value: String) -> String? {
        guard
            let encoded = value.addingPercentEncoding(
                withAllowedCharacters: pathComponentCharacters)
        else { return nil }
        // RFC 3986 permits dots in a segment, but dot-only values are path navigation
        // after server normalization and must remain opaque model identifiers.
        if encoded == "." { return "%2E" }
        if encoded == ".." { return "%2E%2E" }
        return encoded
    }

    static func url(baseURL: URL, components pathComponents: [String]) -> URL? {
        guard EngineHTTPOrigin(url: baseURL) != nil,
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else {
            return nil
        }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encoded = pathComponents.compactMap(encodedPathComponent)
        guard encoded.count == pathComponents.count else { return nil }
        components.percentEncodedPath = "/" + ([basePath] + encoded).filter { !$0.isEmpty }.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func modelDetail(baseURL: URL, modelID: String) -> URL? {
        url(baseURL: baseURL, components: ["v1", "models", modelID])
    }

    static func llamaProperties(baseURL: URL, modelID: String) -> URL? {
        guard let url = url(baseURL: baseURL, components: ["props"]),
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [URLQueryItem(name: "model", value: modelID)]
        return components.url
    }
}

/// Flexible decoding for compatible servers, whose model metadata is intentionally not standard.
enum EngineCapabilityMetadataParser {
    static let maximumCatalogModels = 1_024
    static let maximumModelIDBytes = 512

    static func openAIModelList(_ data: Data) throws -> [ModelRef] {
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let entries = root.objectValue?["data"]?.arrayValue else {
            throw MetadataProbeError.malformed
        }
        guard entries.count <= maximumCatalogModels else {
            throw MetadataProbeError.catalogTooLarge
        }
        var seen: Set<String> = []
        return entries.compactMap { entry in
            guard let object = entry.objectValue,
                let id = object.string(for: ["id"]), validModelID(id),
                seen.insert(id).inserted
            else { return nil }
            let metadata = genericMetadata(object, evidence: .modelList)
            return ModelRef(
                id: id, contextLength: metadata.contextLength,
                capabilities: metadata.capabilities)
        }
    }

    static func openAIModelDetail(_ data: Data) throws -> ProbedModelMetadata {
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let object = root.objectValue else { throw MetadataProbeError.malformed }
        return genericMetadata(object, evidence: .modelDetail)
    }

    static func lmStudioModel(_ data: Data, modelID: String) throws -> ProbedModelMetadata {
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let models = root.objectValue?["models"]?.arrayValue else {
            throw MetadataProbeError.malformed
        }
        guard
            let object = models.compactMap(\.objectValue).first(where: {
                $0.string(for: ["key", "id", "model"]) == modelID
            })
        else { return .unknown }

        let capabilityObject = object["capabilities"]?.objectValue
        let vision = capabilityObject?.bool(for: ["vision"])
        let trainedForTools = capabilityObject?.bool(for: ["trained_for_tool_use"])
        let reasoningValue = capabilityObject?["reasoning"]
        let reasoningObject = reasoningValue?.objectValue
        let allowed = reasoningObject?["allowed_options"]?.stringArrayValue
        var effortValues = allowed.map(reasoningValues)
        if effortValues?.isEmpty == true { effortValues = nil }

        let loadedContext = object["loaded_instances"]?.arrayValue?
            .compactMap(\.objectValue)
            .compactMap {
                $0.int(for: ["context_length", "max_context_length"])
                    ?? $0["config"]?.objectValue?.int(for: ["context_length"])
            }
            .min()
        let context = loadedContext ?? object.int(for: ["context_length", "max_context_length"])

        let reasoningClaim: CapabilityClaim
        if let explicitlySupported = reasoningValue?.boolValue {
            reasoningClaim = claim(explicitlySupported, evidence: .modelDetail)
        } else if reasoningObject != nil {
            reasoningClaim = .supported(by: .modelDetail)
        } else {
            reasoningClaim = .unknown
        }

        return ProbedModelMetadata(
            contextLength: context,
            capabilities: ModelCapabilities(
                vision: claim(vision, evidence: .modelDetail),
                // A positive training hint is useful. False is not protocol rejection because
                // LM Studio can apply a generic tool template.
                tools: trainedForTools == true ? .supported(by: .modelDetail) : .unknown,
                reasoning: reasoningClaim,
                reasoningEffortValues: effortValues))
    }

    static func ollamaShow(_ data: Data) throws -> ProbedModelMetadata {
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let object = root.objectValue else { throw MetadataProbeError.malformed }
        let names = Set(object["capabilities"]?.stringArrayValue?.map { $0.lowercased() } ?? [])
        let hasCapabilityList = object["capabilities"]?.arrayValue != nil
        let vision = hasCapabilityList ? names.contains("vision") : nil
        let tools = hasCapabilityList ? names.contains("tools") : nil
        let thinking = hasCapabilityList ? names.contains("thinking") : nil
        let context = object["model_info"]?.objectValue?
            .compactMap { key, value -> Int? in
                guard key.lowercased().hasSuffix(".context_length") else { return nil }
                return value.intValue
            }
            .filter { $0 > 0 }
            .max()

        return ProbedModelMetadata(
            contextLength: context,
            capabilities: ModelCapabilities(
                vision: claim(vision, evidence: .modelDetail),
                tools: claim(tools, evidence: .modelDetail),
                reasoning: claim(thinking, evidence: .modelDetail),
                advertisedRequestParameters: thinking == true ? ["reasoning_effort"] : [],
                reasoningEffortValues: thinking == true ? [.none, .low, .medium, .high, .max] : nil))
    }

    static func ollamaRunningContext(_ data: Data, modelID: String) throws -> Int? {
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let models = root.objectValue?["models"]?.arrayValue else {
            throw MetadataProbeError.malformed
        }
        return models.compactMap(\.objectValue).first(where: {
            $0.string(for: ["name", "model"]) == modelID
        })?.int(for: ["context_length"])
    }

    static func llamaProperties(_ data: Data) throws -> ProbedModelMetadata {
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let object = root.objectValue else { throw MetadataProbeError.malformed }
        let caps = object["chat_template_caps"]?.objectValue
        let supportsTools = caps?.bool(for: ["supports_tools"])
        let supportsToolCalls = caps?.bool(for: ["supports_tool_calls"])
        let tools: Bool?
        if supportsTools == true, supportsToolCalls == true {
            tools = true
        } else if supportsTools == false || supportsToolCalls == false {
            tools = false
        } else {
            tools = nil
        }
        let reasoningEffort = caps?.bool(for: ["supports_reasoning_effort"])
        let vision = object["modalities"]?.objectValue?.bool(for: ["vision"])
        let context = object["default_generation_settings"]?.objectValue?.int(for: ["n_ctx"])

        return ProbedModelMetadata(
            contextLength: context,
            capabilities: ModelCapabilities(
                vision: claim(vision, evidence: .modelDetail),
                tools: claim(tools, evidence: .modelDetail),
                reasoning: claim(reasoningEffort, evidence: .modelDetail),
                advertisedRequestParameters: reasoningEffort == true ? ["reasoning_effort"] : [],
                reasoningEffortValues: reasoningEffort == true ? [.none, .low, .medium, .high] : nil))
    }

    private static func genericMetadata(
        _ object: [String: JSONValue], evidence: CapabilityEvidence
    ) -> ProbedModelMetadata {
        let parameters = Set(
            (object["supported_parameters"]?.stringArrayValue
                ?? object["supported_request_parameters"]?.stringArrayValue ?? [])
        )
        let capabilities = object["capabilities"]
        let capabilityObject = capabilities?.objectValue
        let capabilityNames = Set(capabilities?.stringArrayValue?.map { $0.lowercased() } ?? [])

        var vision =
            capabilityObject?.bool(for: ["vision", "multimodal"])
            ?? object.bool(for: ["vision", "supports_vision"])
        if vision == nil,
            capabilityNames.contains("vision") || capabilityNames.contains("multimodal")
        {
            vision = true
        }
        if vision == nil,
            let modalities = object["input_modalities"]?.stringArrayValue
                ?? object["modalities"]?.stringArrayValue
        {
            vision = modalities.contains { ["image", "images", "vision"].contains($0.lowercased()) }
        }

        var tools =
            capabilityObject?.bool(for: ["tools", "tool_calling", "function_calling"])
            ?? object.bool(for: ["supports_tools", "tool_calling"])
        if tools == nil,
            capabilityNames.contains("tools") || capabilityNames.contains("tool_calling")
        {
            tools = true
        }

        let reasoningValue = capabilityObject?["reasoning"] ?? object["reasoning"]
        var reasoning = reasoningValue?.boolValue
        let reasoningObject = reasoningValue?.objectValue
        if reasoning == nil, reasoningObject != nil { reasoning = true }
        if reasoning == nil,
            capabilityNames.contains("reasoning") || capabilityNames.contains("thinking")
        {
            reasoning = true
        }
        if reasoning == nil, parameters.contains(where: { $0.lowercased() == "reasoning_effort" }) {
            reasoning = true
        }

        let effortStrings =
            object["reasoning_effort_values"]?.stringArrayValue
            ?? object["reasoning_effort_levels"]?.stringArrayValue
            ?? object["supported_reasoning_efforts"]?.stringArrayValue
            ?? reasoningObject?["allowed_options"]?.stringArrayValue
        let effortValues = effortStrings.map(reasoningValues)

        return ProbedModelMetadata(
            contextLength: object.int(
                for: ["context_length", "max_context_length", "max_model_len", "effective_max_context"]),
            capabilities: ModelCapabilities(
                vision: claim(vision, evidence: evidence),
                tools: claim(tools, evidence: evidence),
                reasoning: claim(reasoning, evidence: evidence),
                advertisedRequestParameters: parameters,
                reasoningEffortValues: effortValues))
    }

    private static func reasoningValues(_ strings: [String]) -> Set<ReasoningEffortValue> {
        Set(
            strings.compactMap { value in
                if value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "off" {
                    return ReasoningEffortValue.none
                }
                return ReasoningEffortValue(wireValue: value)
            })
    }

    private static func validModelID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= maximumModelIDBytes else { return false }
        return id.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func claim(
        _ value: Bool?, evidence: CapabilityEvidence
    ) -> CapabilityClaim {
        guard let value else { return .unknown }
        return value ? .supported(by: evidence) : .unsupported(by: evidence)
    }
}

enum MetadataProbeError: Error, LocalizedError {
    case malformed
    case catalogTooLarge
    case responseTooLarge
    case noHTTPResponse
    case timedOut

    var errorDescription: String? {
        switch self {
        case .malformed:
            "The engine returned invalid metadata"
        case .catalogTooLarge:
            "The engine returned too many models"
        case .responseTooLarge:
            "The engine metadata response was too large"
        case .noHTTPResponse:
            "The engine did not return an HTTP response"
        case .timedOut:
            "Timed out waiting for the engine"
        }
    }
}

enum MetadataDeadline {
    static func run<Value: Sendable>(
        after duration: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw MetadataProbeError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw MetadataProbeError.timedOut
            }
            return first
        }
    }
}

enum BoundedMetadataClient {
    static func isolatedConfiguration(requestTimeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        return configuration
    }

    static func data(
        for request: URLRequest, origin: URL, name: String? = nil, maximumBytes: Int = 256 * 1_024,
        wallClockLimit: Duration = .seconds(2)
    ) async throws -> (Data, HTTPURLResponse) {
        guard EngineHTTPOrigin(url: origin) != nil else {
            throw MetadataProbeError.malformed
        }
        var uncachedRequest = request
        uncachedRequest.cachePolicy = .reloadIgnoringLocalCacheData
        let preparedRequest = uncachedRequest

        let configuration = isolatedConfiguration(requestTimeout: request.timeoutInterval)
        let session = JudasHTTPClient(origin: origin, source: .engine, name: name, configuration: configuration)
        defer { session.invalidateAndCancel() }

        return try await MetadataDeadline.run(after: wallClockLimit) {
            let (bytes, response) = try await session.bytes(for: preparedRequest)
            guard let http = response as? HTTPURLResponse else {
                bytes.task.cancel()
                throw MetadataProbeError.noHTTPResponse
            }
            if response.expectedContentLength > Int64(maximumBytes) {
                bytes.task.cancel()
                throw MetadataProbeError.responseTooLarge
            }
            var data = Data()
            data.reserveCapacity(min(maximumBytes, 16 * 1_024))
            for try await byte in bytes {
                guard data.count < maximumBytes else {
                    bytes.task.cancel()
                    throw MetadataProbeError.responseTooLarge
                }
                data.append(byte)
            }
            return (data, http)
        }
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var stringArrayValue: [String]? { arrayValue?.compactMap(\.stringValue) }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .number(let value):
            guard value.isFinite, value > 0, value <= Double(Int.max) else { return nil }
            return Int(value)
        case .string(let value):
            return Int(value).flatMap { $0 > 0 ? $0 : nil }
        default:
            return nil
        }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func string(for keys: [String]) -> String? {
        keys.lazy.compactMap { self[$0]?.stringValue }.first
    }

    func bool(for keys: [String]) -> Bool? {
        keys.lazy.compactMap { self[$0]?.boolValue }.first
    }

    func int(for keys: [String]) -> Int? {
        keys.lazy.compactMap { self[$0]?.intValue }.first
    }
}
