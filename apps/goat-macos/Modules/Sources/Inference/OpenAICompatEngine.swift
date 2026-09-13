import Foundation
import JUDAS

/// HTTP/SSE client for OpenAI-compatible `/v1/chat/completions` endpoints.
/// Inference runs in the external engine (ADR-0008). Compatibility details are in docs/ENGINES.md.
public actor OpenAICompatEngine: InferenceEngine {
    public private(set) var config: EngineConfig
    private var configRevision: UInt64 = 0

    public init(config: EngineConfig) {
        self.config = config
    }

    /// Install a lifecycle-owned configuration only when it is at least as recent as the
    /// configuration already committed. The caller still performs its observable-state guard;
    /// this check closes the actor-reentrancy window at the final mutation boundary.
    @discardableResult
    public func update(config: EngineConfig, revision: UInt64) -> Bool {
        guard revision >= configRevision else { return false }
        self.config = config
        configRevision = revision
        return true
    }

    // MARK: Health

    public func health() async -> EngineHealth {
        let config = self.config
        guard config.isValidEndpoint else { return .offline("Invalid engine URL") }
        guard
            let url = EngineMetadataEndpoint.url(
                baseURL: config.baseURL, components: ["v1", "models"])
        else { return .offline("Invalid engine URL") }
        var req = URLRequest(url: url, timeoutInterval: config.metadataProbeRequestTimeout)
        if let key = config.apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, http) = try await BoundedMetadataClient.data(
                for: req, origin: config.baseURL, name: config.name, maximumBytes: 1_024 * 1_024,
                wallClockLimit: config.metadataProbeWallClockLimit)
            if http.statusCode == 401 || http.statusCode == 403 { return .authRequired }
            guard http.statusCode == 200 else { return .offline("HTTP \(http.statusCode)") }
            let models = try EngineCapabilityMetadataParser.openAIModelList(data).map { model in
                ModelRef(
                    id: model.id,
                    contextLength: model.contextLength,
                    capabilities: model.capabilities)
            }
            return .ok(models)
        } catch {
            return .offline(error.localizedDescription)
        }
    }

    /// Best-effort metadata handshake for the selected model. Failure returns the catalog
    /// snapshot unchanged so a healthy generic Chat Completions path remains usable.
    public func inspectModel(_ model: ModelRef) async -> EngineModelInspection {
        let config = self.config
        guard config.isValidEndpoint else { return EngineModelInspection(model: model) }
        let revision = configRevision

        let metadata: ProbedModelMetadata?
        switch config.metadataDialect {
        case .generic:
            metadata = await Self.probeGenericDetail(config: config, modelID: model.id)
        case .lmStudio:
            metadata = await Self.probeLMStudio(config: config, modelID: model.id)
        case .ollama:
            metadata = await Self.probeOllama(config: config, modelID: model.id)
        case .llamaCpp:
            metadata = await Self.probeLlamaCpp(config: config, modelID: model.id)
        }

        guard revision == configRevision, config == self.config, !Task.isCancelled else {
            return EngineModelInspection(model: model)
        }
        let reported = metadata?.observed(at: .now) ?? .unknown
        let enriched =
            EngineCapabilityMetadataParser
            .applyingKnownProfile(reported, for: model.id)
        return EngineModelInspection(
            model: enriched.applying(to: model), metadata: enriched.inspection)
    }

    public func probeCapabilities(for model: ModelRef) async -> ModelRef {
        await inspectModel(model).model
    }

    private static func probeGenericDetail(
        config: EngineConfig, modelID: String
    ) async -> ProbedModelMetadata? {
        guard
            let url = EngineMetadataEndpoint.modelDetail(
                baseURL: config.baseURL, modelID: modelID)
        else { return nil }
        guard let data = await metadataData(url: url, config: config) else { return nil }
        return try? EngineCapabilityMetadataParser.openAIModelDetail(data, modelID: modelID)
    }

    private static func probeLMStudio(
        config: EngineConfig, modelID: String
    ) async -> ProbedModelMetadata? {
        guard
            let url = EngineMetadataEndpoint.url(
                baseURL: config.baseURL, components: ["api", "v1", "models"]),
            let data = await metadataData(url: url, config: config)
        else { return nil }
        return try? EngineCapabilityMetadataParser.lmStudioModel(data, modelID: modelID)
    }

    private static func probeOllama(
        config: EngineConfig, modelID: String
    ) async -> ProbedModelMetadata? {
        guard
            let showURL = EngineMetadataEndpoint.url(
                baseURL: config.baseURL, components: ["api", "show"]),
            let psURL = EngineMetadataEndpoint.url(
                baseURL: config.baseURL, components: ["api", "ps"])
        else { return nil }
        let showBody = try? JSONEncoder().encode(OllamaShowRequest(model: modelID))
        async let showData = metadataData(
            url: showURL, config: config, method: "POST", body: showBody,
            maximumBytes: 1_024 * 1_024)
        async let psData = metadataData(url: psURL, config: config)

        guard let show = await showData,
            var metadata = try? EngineCapabilityMetadataParser.ollamaShow(show)
        else { return nil }
        if let running = await psData,
            let context = try? EngineCapabilityMetadataParser.ollamaRunningContext(
                running, modelID: modelID)
        {
            metadata.contextLength = context
        }
        return metadata
    }

    private static func probeLlamaCpp(
        config: EngineConfig, modelID: String
    ) async -> ProbedModelMetadata? {
        guard
            let url = EngineMetadataEndpoint.llamaProperties(
                baseURL: config.baseURL, modelID: modelID),
            let data = await metadataData(url: url, config: config)
        else { return nil }
        return try? EngineCapabilityMetadataParser.llamaProperties(data)
    }

    private static func metadataData(
        url: URL, config: EngineConfig, method: String = "GET", body: Data? = nil,
        maximumBytes: Int = 256 * 1_024
    ) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: config.metadataProbeRequestTimeout)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let key = config.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        guard
            let (data, response) = try? await BoundedMetadataClient.data(
                for: request, origin: config.baseURL, name: config.name, maximumBytes: maximumBytes,
                wallClockLimit: config.metadataProbeWallClockLimit),
            response.statusCode == 200
        else { return nil }
        return data
    }

    static func makeBody(for r: GenerationRequest) -> CompletionBody {
        let prepared = CanonicalRequestPreparation.prepare(r)
        let parameters = EffectiveGenerationParameters(request: prepared)
        let qwenControls = QwenChatTemplateControls(parameters: parameters)
        return CompletionBody(
            model: prepared.model,
            messages: prepared.turns.map { turn in
                CompletionBody.Message(
                    role: turn.role.rawValue,
                    text: turn.text,
                    thinking: turn.thinking,
                    imagesBase64: turn.images.map { $0.base64EncodedString() },
                    toolCalls: turn.toolCalls,
                    toolCallID: turn.toolCallID,
                    replayReasoning: parameters.replayReasoningHistory
                )
            },
            stream: true,
            temperature: parameters.temperature,
            maxTokens: parameters.outputTokenCap,
            tools: prepared.tools,
            reasoningEffort: parameters.nativeReasoningEffort,
            qwenChatTemplate: qwenControls
        )
    }

    /// Compatibility overload for focused request-body fixtures. Production requests carry the
    /// resolved style on `GenerationRequest` and do not read mutable engine configuration.
    static func makeBody(
        for r: GenerationRequest, requestStyle: EngineRequestStyle
    ) -> CompletionBody {
        var request = r
        request.compatibility = ResolvedModelCompatibility(
            identity: r.compatibility.identity,
            effectiveStyle: requestStyle == .qwenChatTemplate ? .qwenChatTemplate : .genericOpenAI,
            source: .explicitOverride,
            capabilities: r.modelCapabilities)
        return makeBody(for: request)
    }

    // MARK: Generation

    /// Parses a `Retry-After` header. Handles the numeric-seconds form; the HTTP-date form is
    /// treated as absent (ADR-0089). Returns nil when the header is missing or unparseable.
    /// Idle timeout for the streaming request (ADR-0089). URLRequest.timeoutInterval resets on each
    /// received byte, so this bounds how long a silent connection can hang. Recorded in ENGINES.md.
    static let streamIdleTimeoutSeconds: TimeInterval = 300

    static func parseRetryAfter(_ value: String?) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        return nil
    }

    public func stream(_ r: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
        let config = self.config
        return AsyncThrowingStream { continuation in
            let task = Task {
                var assembler = StreamAssembler(round: r.round)

                do {
                    guard config.isValidEndpoint else { throw EngineError.notConfigured }
                    var req = URLRequest(url: config.baseURL.appending(path: "v1/chat/completions"))
                    req.timeoutInterval = Self.streamIdleTimeoutSeconds
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if let key = config.apiKey, !key.isEmpty {
                        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    }
                    req.httpBody = try JSONEncoder().encode(
                        Self.makeBody(for: r))

                    let client = JudasHTTPClient(origin: config.baseURL, source: .engine, name: config.name)
                    defer { client.invalidateAndCancel() }
                    let (bytes, resp) = try await client.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else { throw EngineError.http(-1) }
                    if http.statusCode != 200 {
                        // Read the server's own explanation - a 400 should tell you why.
                        var errorBody = Data()
                        for try await byte in bytes {
                            errorBody.append(byte)
                            if errorBody.count > 4000 { break }
                        }
                        // Prefer the server's error.message; fall back to the raw body.
                        struct ServerError: Decodable {
                            struct Inner: Decodable { let message: String? }
                            let error: Inner?
                        }
                        let parsed = (try? JSONDecoder().decode(ServerError.self, from: errorBody))?.error?.message
                        let detail =
                            parsed
                            ?? (String(data: errorBody, encoding: .utf8)?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                        throw EngineError.httpDetail(
                            http.statusCode, String(detail.prefix(300)),
                            retryAfter: Self.parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After")))
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                            let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data)
                        else { continue }
                        for event in assembler.feed(chunk) { continuation.yield(event) }
                    }
                    for event in assembler.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Qwen's local OpenAI-compatible template accepts these controls under
/// `chat_template_kwargs`. The engine profile selects this exact dialect; normal
/// OpenAI-compatible requests never receive these non-standard fields.
struct QwenChatTemplateControls: Encodable {
    let enableThinking: Bool
    let preserveThinking: Bool
    let reasoningEffort: String?
    let temperature: Double

    init?(parameters: EffectiveGenerationParameters) {
        guard let enableThinking = parameters.qwenEnableThinking,
            let preserveThinking = parameters.qwenPreserveThinking
        else { return nil }
        self.enableThinking = enableThinking
        self.preserveThinking = preserveThinking
        self.reasoningEffort = parameters.qwenReasoningEffort
        self.temperature = parameters.temperature
    }

    private enum CodingKeys: String, CodingKey {
        case enableThinking = "enable_thinking"
        case preserveThinking = "preserve_thinking"
        case reasoningEffort = "reasoning_effort"
        case temperature
    }
}

private struct OllamaShowRequest: Encodable {
    let model: String
    let verbose = false
}

// MARK: - Wire types (OpenAI dialect)

/// Deterministic helpers for tool-call identifiers on the request wire (ADR-0089).
enum ToolCallIdentifier {
    /// Upper bound many OpenAI-dialect engines enforce on `tool_call_id` length.
    static let maxRequestByteLength = 40

    /// Returns an identifier no longer than `maxRequestByteLength` UTF-8 bytes. Ids within the limit
    /// are returned unchanged, so an assistant tool call and its matching tool result collapse to the
    /// same value and stay linked. A longer id is cut on a character boundary and given a stable hash
    /// suffix, so distinct long ids do not collide after truncation.
    static func requestSafe(_ id: String) -> String {
        guard id.utf8.count > maxRequestByteLength else { return id }
        let suffix = "_" + String(format: "%08x", fnv1a32(id))
        let prefixByteBudget = maxRequestByteLength - suffix.utf8.count
        var prefix = ""
        var used = 0
        for character in id {
            let width = String(character).utf8.count
            if used + width > prefixByteBudget { break }
            prefix.append(character)
            used += width
        }
        return prefix + suffix
    }

    /// FNV-1a 32-bit over the UTF-8 bytes. Deterministic across processes, unlike `Hasher`, so the
    /// truncated id is stable for tests and for matching a call to its result.
    private static func fnv1a32(_ value: String) -> UInt32 {
        var hash: UInt32 = 0x811c_9dc5
        for byte in value.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }
}

struct CompletionBody: Encodable {
    struct Message: Encodable {
        let role: String
        let text: String
        let thinking: String
        let imagesBase64: [String]
        var toolCalls: [ToolCallEvent] = []
        var toolCallID: String? = nil
        var replayReasoning = false

        private enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
            case toolCallID = "tool_call_id"
            case reasoningContent = "reasoning_content"
        }
        private enum PartKeys: String, CodingKey { case type, text, imageURL = "image_url" }
        private struct ImagePayload: Encodable { let url: String }
        private enum Part: Encodable {
            case text(String)
            case image(String)
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: PartKeys.self)
                switch self {
                case .text(let t):
                    try c.encode("text", forKey: .type)
                    try c.encode(t, forKey: .text)
                case .image(let url):
                    try c.encode("image_url", forKey: .type)
                    try c.encode(ImagePayload(url: url), forKey: .imageURL)
                }
            }
        }

        private struct ToolCallOut: Encodable {
            let id: String
            let type = "function"
            let function: Function
            struct Function: Encodable {
                let name: String
                let arguments: String
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(role, forKey: .role)
            if replayReasoning, role == ChatTurn.Role.assistant.rawValue, !thinking.isEmpty {
                try c.encode(thinking, forKey: .reasoningContent)
            }
            if let toolCallID {
                try c.encode(ToolCallIdentifier.requestSafe(toolCallID), forKey: .toolCallID)
            }
            if !toolCalls.isEmpty {
                try c.encode(
                    toolCalls.map {
                        ToolCallOut(
                            id: ToolCallIdentifier.requestSafe($0.id),
                            function: .init(name: $0.name, arguments: $0.argumentsJSON))
                    }, forKey: .toolCalls)
            }
            if imagesBase64.isEmpty {
                if text.isEmpty && !toolCalls.isEmpty {
                    try c.encodeNil(forKey: .content)
                } else {
                    try c.encode(text, forKey: .content)
                }
            } else {
                var parts: [Part] = imagesBase64.map { .image("data:image/png;base64,\($0)") }
                parts.append(.text(text))
                try c.encode(parts, forKey: .content)
            }
        }
    }

    struct ToolDef: Encodable {
        let name: String
        let description: String
        let parameters: JSONValue

        private enum CodingKeys: String, CodingKey { case type, function }
        private enum FunctionKeys: String, CodingKey { case name, description, parameters }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("function", forKey: .type)
            var f = c.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function)
            try f.encode(name, forKey: .name)
            try f.encode(description, forKey: .description)
            try f.encode(parameters, forKey: .parameters)
        }
    }

    let model: String
    let messages: [Message]
    let stream: Bool
    let temperature: Double
    let maxTokens: Int
    var tools: [ToolSpec] = []
    var reasoningEffort: String? = nil
    var qwenChatTemplate: QwenChatTemplateControls? = nil

    private enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, tools
        case maxTokens = "max_tokens"
        case streamOptions = "stream_options"
        case reasoningEffort = "reasoning_effort"
        case qwenChatTemplate = "chat_template_kwargs"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        try c.encode(messages, forKey: .messages)
        try c.encode(stream, forKey: .stream)
        if stream {
            // Request final usage statistics so token counts can use the server's measurements.
            try c.encode(["include_usage": true], forKey: .streamOptions)
        }
        try c.encode(temperature, forKey: .temperature)
        try c.encode(maxTokens, forKey: .maxTokens)
        try c.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try c.encodeIfPresent(qwenChatTemplate, forKey: .qwenChatTemplate)
        if !tools.isEmpty {
            try c.encode(
                tools.map { spec in
                    ToolDef(
                        name: spec.name,
                        description: spec.description,
                        parameters: JSONValue.parse(spec.parametersJSON) ?? .object(["type": .string("object")])
                    )
                }, forKey: .tools)
        }
    }
}

/// Normalizes a raw OpenAI-dialect SSE stream into canonical `GenerationEvent`s.
/// Handles `<think>` tags, `reasoning_content` deltas, fragmented tool calls and final
/// usage statistics (ADR-0016). Token counts use server usage when available;
/// otherwise the chunk count is reported as an estimate.
struct StreamAssembler {
    private var ttft: TimeInterval?
    private var chunkCount = 0
    private var usage: StreamChunk.Usage?
    private var finishReason: String?
    private var timings: StreamChunk.Timings?
    private var parser = ThinkTagParser()
    private var toolAccumulator = ToolCallAccumulator()
    private let start: Date
    /// The tool-loop round this stream belongs to, forwarded to fallback id generation (ADR-0089).
    private let round: Int

    init(start: Date = Date(), round: Int = 0) {
        self.start = start
        self.round = round
    }

    mutating func feed(_ chunk: StreamChunk) -> [GenerationEvent] {
        if let u = chunk.usage { usage = u }
        if let value = chunk.timings { timings = value }
        if let reason = chunk.choices.first?.finish_reason { finishReason = reason }
        guard let delta = chunk.choices.first?.delta else { return [] }
        var events: [GenerationEvent] = []
        var emittedReasoning = Set<String>()
        for reasoning in delta.reasoningSegments where !reasoning.isEmpty {
            guard emittedReasoning.insert(reasoning).inserted else { continue }
            markFirstToken()
            chunkCount += 1
            events.append(.thinking(reasoning))
        }
        for piece in delta.content?.pieces ?? [] {
            switch piece {
            case .text(let content):
                guard !content.isEmpty else { continue }
                markFirstToken()
                chunkCount += 1
                for parsed in parser.feed(content) { events.append(Self.event(for: parsed)) }
            case .thinking(let reasoning):
                guard emittedReasoning.insert(reasoning).inserted else { continue }
                guard !reasoning.isEmpty else { continue }
                markFirstToken()
                chunkCount += 1
                events.append(.thinking(reasoning))
            }
        }
        if let calls = delta.tool_calls {
            markFirstToken()
            chunkCount += calls.count
            toolAccumulator.feed(calls)
            let bytes = calls.reduce(0) {
                $0 + ($1.function?.name?.utf8.count ?? 0)
                    + ($1.function?.arguments?.utf8.count ?? 0)
            }
            if bytes > 0 { events.append(.toolInput(bytes: bytes)) }
        }
        return events
    }

    /// End of stream: release any held partial tag, emit assembled tool calls, then stats.
    mutating func finish() -> [GenerationEvent] {
        var events = parser.flush().map(Self.event(for:))
        if !toolAccumulator.isEmpty {
            events.append(.toolCalls(toolAccumulator.events(round: round)))
        }
        let tokenCount = usage?.completion_tokens ?? chunkCount
        let serverTTFT = usage?.time_to_first_token.flatMap { value in
            value.isFinite && value >= 0 ? value : nil
        }
        let serverGenerationRate =
            usage?.generation_tokens_per_second
            ?? timings?.predicted_per_second
            ?? usage?.generation_duration.flatMap { duration in
                guard duration.isFinite, duration > 0 else { return nil }
                return Double(tokenCount) / duration
            }
            ?? timings?.predicted_ms.flatMap { milliseconds in
                guard milliseconds.isFinite, milliseconds > 0 else { return nil }
                return Double(tokenCount) / (milliseconds / 1_000)
            }
        events.append(
            .done(
                GenStats(
                    ttft: serverTTFT ?? ttft,
                    tokens: tokenCount,
                    duration: Date().timeIntervalSince(start),
                    promptTokens: usage?.prompt_tokens,
                    tokensAreExact: usage?.completion_tokens != nil,
                    generationTokensPerSecond: serverGenerationRate,
                    finishReason: finishReason,
                    cachedPromptTokens: usage?.cachedPromptTokens
                )))
        return events
    }

    private mutating func markFirstToken() {
        if ttft == nil { ttft = Date().timeIntervalSince(start) }
    }

    private static func event(for piece: ThinkTagParser.Piece) -> GenerationEvent {
        switch piece {
        case .text(let t): .token(t)
        case .thinking(let t): .thinking(t)
        }
    }
}

/// Reassembles OpenAI streaming tool_call fragments (keyed by index) into complete calls.
struct ToolCallAccumulator {
    private var items: [Int: (id: String, name: String, args: String)] = [:]

    mutating func feed(_ deltas: [StreamChunk.Choice.Delta.ToolCallDelta]) {
        for d in deltas {
            var current = items[d.index] ?? ("", "", "")
            if let id = d.id, !id.isEmpty { current.id = id }
            if let name = d.function?.name, !name.isEmpty { current.name += name }
            if let args = d.function?.arguments { current.args += args }
            items[d.index] = current
        }
    }

    var isEmpty: Bool { items.isEmpty }

    /// Assembled calls in index order. Fallback identifiers are `call_<round>_<index>` so they stay
    /// unique across the tool-loop rounds of one turn (ADR-0089).
    func events(round: Int) -> [ToolCallEvent] {
        items.sorted { $0.key < $1.key }.map { index, item in
            ToolCallEvent(
                id: item.id.isEmpty ? "call_\(round)_\(index)" : item.id,
                name: item.name,
                argumentsJSON: item.args.isEmpty ? "{}" : item.args
            )
        }
    }
}

struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            struct Content: Decodable {
                enum Piece {
                    case text(String)
                    case thinking(String)
                }

                private struct Part: Decodable {
                    struct ThinkingText: Decodable { let text: String? }

                    let type: String?
                    let text: String?
                    let thinking: [ThinkingText]?
                }

                let pieces: [Piece]

                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let text = try? container.decode(String.self) {
                        pieces = text.isEmpty ? [] : [.text(text)]
                        return
                    }
                    let parts = try container.decode([Part].self)
                    pieces = parts.flatMap { part -> [Piece] in
                        switch part.type {
                        case "text":
                            return part.text.flatMap { $0.isEmpty ? nil : [.text($0)] } ?? []
                        case "thinking":
                            let text = part.thinking?.compactMap(\.text).joined() ?? part.text ?? ""
                            return text.isEmpty ? [] : [.thinking(text)]
                        default:
                            // References, citations, and future non-text parts are
                            // intentionally ignored instead of failing the stream.
                            return []
                        }
                    }
                }
            }

            struct ToolCallDelta: Decodable {
                struct FunctionDelta: Decodable {
                    let name: String?
                    let arguments: String?
                }
                let index: Int
                let id: String?
                let function: FunctionDelta?
            }
            let content: Content?
            let reasoningContent: String?
            let reasoning: String?
            let thinking: String?
            let tool_calls: [ToolCallDelta]?

            private enum CodingKeys: String, CodingKey {
                case content, reasoning, thinking
                case reasoningContent = "reasoning_content"
                case tool_calls
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                content = try? container.decode(Content.self, forKey: .content)
                reasoningContent = try? container.decode(String.self, forKey: .reasoningContent)
                reasoning = try? container.decode(String.self, forKey: .reasoning)
                thinking = try? container.decode(String.self, forKey: .thinking)
                tool_calls = try container.decodeIfPresent([ToolCallDelta].self, forKey: .tool_calls)
            }

            var reasoningSegments: [String] {
                if let reasoningContent, !reasoningContent.isEmpty { return [reasoningContent] }
                if let reasoning, !reasoning.isEmpty { return [reasoning] }
                if let thinking, !thinking.isEmpty { return [thinking] }
                return []
            }
        }
        let delta: Delta?
        let finish_reason: String?
    }
    struct Usage: Decodable {
        struct PromptTokensDetails: Decodable {
            let cached_tokens: Int?
        }
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let time_to_first_token: Double?
        let generation_duration: Double?
        let generation_tokens_per_second: Double?
        /// OpenAI-style prefix-cache accounting; several local servers report it too.
        let prompt_tokens_details: PromptTokensDetails?
        /// llama.cpp and some MLX servers report the cached prefix at the top level.
        let cached_tokens: Int?
        let prompt_cache_hit_tokens: Int?

        var cachedPromptTokens: Int? {
            [prompt_tokens_details?.cached_tokens, cached_tokens, prompt_cache_hit_tokens]
                .compactMap { $0 }.first(where: { $0 >= 0 })
        }
    }
    struct Timings: Decodable {
        let predicted_ms: Double?
        let predicted_per_second: Double?
    }
    let choices: [Choice]
    let usage: Usage?
    let timings: Timings?
}
