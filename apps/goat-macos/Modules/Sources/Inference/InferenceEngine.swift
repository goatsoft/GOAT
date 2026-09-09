import Foundation

// MARK: - Engine configuration and request types

public enum EngineMetadataDialect: String, Codable, Hashable, Sendable {
    case generic
    case lmStudio
    case ollama
    case llamaCpp
}

/// Request semantics selected for an engine, separate from its discovery adapter.
///
/// Most OpenAI-compatible servers use `.automatic`. `.qwenChatTemplate` is an
/// explicit opt-in for a local server running Qwen's chat template; it is never
/// inferred from a model ID because otherwise one model could change another
/// server's wire format.
public enum EngineRequestStyle: String, Codable, Hashable, Sendable {
    case automatic
    case qwenChatTemplate
}

public struct EngineConfig: Sendable, Equatable {
    public var name: String?
    public var baseURL: URL
    public var apiKey: String?
    public var metadataDialect: EngineMetadataDialect
    public var requestStyle: EngineRequestStyle
    public init(
        baseURL: URL, apiKey: String? = nil, name: String? = nil,
        metadataDialect: EngineMetadataDialect = .generic,
        requestStyle: EngineRequestStyle = .automatic
    ) {
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.metadataDialect = metadataDialect
        self.requestStyle = requestStyle
    }

    /// Engine roots are HTTP origins plus an optional path prefix. Credentials belong in
    /// `apiKey`, never in URL userinfo, query, or fragment components.
    public var isValidEndpoint: Bool {
        guard EngineHTTPOrigin(url: baseURL) != nil,
            let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { return false }
        return components.user == nil && components.password == nil
            && components.query == nil && components.fragment == nil
    }

    /// A local engine should fail fast so discovery keeps the app responsive. A remote engine can
    /// legitimately need an extra round trip while its Wi-Fi interface or a native server wakes,
    /// so its metadata handshake gets a modestly larger budget.
    var metadataProbeRequestTimeout: TimeInterval {
        isLoopbackEndpoint ? 2.5 : 8
    }

    var metadataProbeWallClockLimit: Duration {
        isLoopbackEndpoint ? .seconds(2) : .seconds(8)
    }

    /// Safe for diagnostics: excludes scheme, path, query, fragment, and userinfo.
    public var redactedEndpointDescription: String {
        guard let origin = EngineHTTPOrigin(url: baseURL) else { return "invalid endpoint" }
        let rawHost =
            origin.host == "127.0.0.1" || origin.host == "localhost"
                || origin.host == "::1" ? "local" : origin.host
        let host = rawHost.contains(":") ? "[\(rawHost)]" : rawHost
        return "\(host):\(origin.port)"
    }

    private var isLoopbackEndpoint: Bool {
        guard
            let host = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)?.host?
                .lowercased()
        else { return false }
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }
}

public struct ModelRef: Identifiable, Hashable, Sendable {
    public let id: String
    /// Context window in tokens, when the server reports one (`/v1/models` extras).
    public let contextLength: Int?
    public let capabilities: ModelCapabilities
    public init(
        id: String, contextLength: Int? = nil,
        capabilities: ModelCapabilities = .unknown
    ) {
        self.id = id
        self.contextLength = contextLength
        self.capabilities = capabilities
    }
    /// "mlx-community/Qwen3-30B-A3B-4bit" → "Qwen3-30B-A3B-4bit"
    public var displayName: String { id.split(separator: "/").last.map(String.init) ?? id }
    /// Presentation and ordering hint only. It never changes the request dialect.
    public var isCoderFocused: Bool { ModelNameHeuristics.isCoderFocused(id) }
    /// Heuristic only - used for a gentle hint, never to block sending.
    public var looksVisionCapable: Bool {
        let s = id.lowercased()
        if [
            "-vl", "vl-", "vision", "multimodal", "llava", "pixtral", "internvl",
            "paligemma", "moondream",
        ]
        .contains(where: s.contains) {
            return true
        }
        if s.contains("qwen"), s.contains("omni") { return true }
        if s.contains("kimi-k2.5") { return true }
        if ["glm-4v", "glm-4.5v", "glm-4.6v"].contains(where: s.contains) { return true }
        if s.contains("gemma-4-") || s.contains("gemma-3n") { return true }
        if s.contains("gemma-3-") {
            return ["-4b", "-12b", "-27b"].contains(where: s.contains)
        }
        if ["llama-4-scout", "llama-4-maverick"].contains(where: s.contains) { return true }
        return [
            "mistral-large-2512", "mistral-large-3", "mistral-medium-2508",
            "mistral-medium-3.1", "mistral-small-2503", "mistral-small-2506",
            "mistral-small-3.1", "mistral-small-3.2", "mistral-small-4",
            "ministral-3-", "ministral-3b-2512", "ministral-8b-2512",
            "ministral-14b-2512", "magistral-",
        ].contains(where: s.contains)
    }
}

public enum EngineHealth: Equatable, Sendable {
    case ok([ModelRef])
    case authRequired
    case offline(String)

    public var models: [ModelRef] {
        if case .ok(let m) = self { return m }
        return []
    }
    public var isOK: Bool { if case .ok = self { return true } else { return false } }
}

public struct ChatTurn: Sendable {
    public enum Role: String, Sendable, Codable { case system, user, assistant, tool }
    public let role: Role
    public let text: String
    /// Prior assistant reasoning, retained only for an explicitly selected dialect that
    /// requires it in the next request. It is never treated as ordinary transcript text.
    public let thinking: String
    public let images: [Data]  // pre-scaled PNG payloads for VLM turns
    public let toolCalls: [ToolCallEvent]  // assistant turns that requested tools
    public let toolCallID: String?  // tool turns answering a specific call
    public init(
        role: Role, text: String, thinking: String = "", images: [Data] = [],
        toolCalls: [ToolCallEvent] = [], toolCallID: String? = nil
    ) {
        self.role = role
        self.text = text
        self.thinking = thinking
        self.images = images
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

/// A tool the model may call (name is the request-side name; the app owns server mapping).
public struct ToolSpec: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parametersJSON: String
    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

public struct ToolCallEvent: Sendable, Equatable {
    public let id: String
    public let name: String
    public let argumentsJSON: String
    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct GenerationRequest: Sendable {
    public var model: String
    public var turns: [ChatTurn]
    public var effort: Effort
    public var maxTokens: Int?
    public var tools: [ToolSpec]
    /// Immutable snapshot captured with model selection, so a later switch cannot alter this request.
    public var modelCapabilities: ModelCapabilities
    public init(
        model: String, turns: [ChatTurn], effort: Effort, maxTokens: Int? = nil,
        tools: [ToolSpec] = [], modelCapabilities: ModelCapabilities = .unknown
    ) {
        self.model = model
        self.turns = turns
        self.effort = effort
        self.maxTokens = maxTokens
        self.tools = tools
        self.modelCapabilities = modelCapabilities
    }
}

public struct GenStats: Sendable, Equatable {
    private static let maximumPlausibleTokensPerSecond = 1_000_000.0

    public var ttft: TimeInterval?
    public var tokens: Int
    /// End-to-end request duration, including prompt evaluation and decode.
    public var duration: TimeInterval
    /// Prompt size from the server's `usage`, when reported - feeds the context meter.
    public var promptTokens: Int?
    /// True when `tokens` comes from server `usage`; false when it's a chunk-count estimate.
    public var tokensAreExact: Bool
    /// Decode throughput reported by the server or derived from its generation duration.
    public var generationTokensPerSecond: Double?
    public var finishReason: String?
    public var speedIsServerReported: Bool { generationTokensPerSecond != nil }
    public var toksPerSec: Double {
        if let generationTokensPerSecond { return generationTokensPerSecond }
        let decodeDuration: TimeInterval
        if let ttft, ttft >= 0, ttft < duration {
            decodeDuration = duration - ttft
        } else {
            decodeDuration = duration
        }
        guard tokens > 0, decodeDuration > 0 else { return 0 }
        return Self.sanitizedRate(Double(tokens) / decodeDuration) ?? 0
    }

    public init(
        ttft: TimeInterval?, tokens: Int, duration: TimeInterval,
        promptTokens: Int? = nil, tokensAreExact: Bool = false,
        generationTokensPerSecond: Double? = nil, finishReason: String? = nil
    ) {
        self.finishReason = finishReason
        self.ttft = ttft
        self.tokens = tokens
        self.duration = duration
        self.promptTokens = promptTokens
        self.tokensAreExact = tokensAreExact
        self.generationTokensPerSecond = Self.sanitizedRate(generationTokensPerSecond)
    }

    private static func sanitizedRate(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0,
            value <= maximumPlausibleTokensPerSecond
        else { return nil }
        return value
    }
}

public enum GenerationEvent: Sendable {
    case token(String)
    case thinking(String)
    /// Generated function-name/argument bytes, for live estimates only. Never executable.
    case toolInput(bytes: Int)
    case toolCalls([ToolCallEvent])
    case done(GenStats)
}

public enum EngineError: LocalizedError, Sendable {
    case http(Int)
    case httpDetail(Int, String)
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .http(let code):
            code == 401 || code == 403
                ? "The engine wants an API key. Add one in Settings → Engine."
                : "Engine returned HTTP \(code)."
        case .httpDetail(let code, let detail):
            code == 401 || code == 403
                ? "The engine wants an API key. Add one in Settings → Engine."
                : "Engine returned HTTP \(code)\(detail.isEmpty ? "." : " - \(detail)")"
        case .notConfigured: "No engine configured."
        }
    }
}

/// The firewall: UI and Shepherd know only this. MLX, dialects, and ports live behind it.
public protocol InferenceEngine: Actor {
    func health() async -> EngineHealth
    func probeCapabilities(for model: ModelRef) async -> ModelRef
    func stream(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error>
}

public extension InferenceEngine {
    /// Unknown is the portable fallback for engines without a metadata adapter.
    func probeCapabilities(for model: ModelRef) async -> ModelRef { model }
}
