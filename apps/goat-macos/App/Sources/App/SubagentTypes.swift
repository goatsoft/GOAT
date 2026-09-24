import CryptoKit
import Foundation
import GOATed
import Inference
import Pens
import Persistence
import Tools

public enum SubagentBackendID: String, Codable, CaseIterable, Sendable {
    case localEngine
    case systemLanguageModel

    public static var allCases: [SubagentBackendID] {
        [.localEngine]
    }

    public var displayName: String {
        switch self {
        case .localEngine: "Local Engine"
        case .systemLanguageModel: "Apple System Language Model (Deferred)"
        }
    }

    public var isSupportedInStage1: Bool {
        switch self {
        case .localEngine: true
        case .systemLanguageModel: false
        }
    }
}

public enum SubagentStatus: String, Codable, Sendable {
    case running
    case completed
    case timedOut
    case budgetExhausted
    case cancelled
    case interrupted
    case failed
}

public struct Stage1ModelEnvelope: Sendable, Equatable {
    public let layers: Int
    public let kvHeads: Int
    public let headDimension: Int
    public let bytesPerElement: Int
    public let maxContextWindow: Int

    public init(
        layers: Int,
        kvHeads: Int,
        headDimension: Int,
        bytesPerElement: Int = 2,
        maxContextWindow: Int = 131_072
    ) {
        self.layers = layers
        self.kvHeads = kvHeads
        self.headDimension = headDimension
        self.bytesPerElement = bytesPerElement
        self.maxContextWindow = maxContextWindow
    }

    public var bytesPerToken: Int64 {
        Int64(layers * kvHeads * headDimension * 2 * bytesPerElement)
    }
}

public enum SubagentLimits {
    public static let defaultMaxRounds = 5
    public static let ceilingMaxRounds = 10
    public static let minimumMaxRounds = 1

    public static let defaultTimeoutSeconds = 60
    public static let ceilingTimeoutSeconds = 90
    public static let minimumTimeoutSeconds = 1
    public static let outerBudgetSeconds = 120
    public static let cancellationGracePeriodSeconds = 5

    public static let maxInputTokensPerRequest = 12_288
    public static let maxGeneratedTokensPerRound = 2_048
    public static let maxTokensPerDelegation = 16_384
    public static let maxGeneratedTokensPerTurn = 8_192
    public static let maxTotalTokensPerTurn = 32_768

    public static let maxToolOutputBytes = 32 * 1_024  // 32 KiB
    public static let maxTranscriptBytes = 512 * 1_024  // 512 KiB
    public static let maxReceiptBytes = 16 * 1_024  // 16 KiB
    public static let maxSummaryBytes = 8 * 1_024  // 8 KiB
    public static let maxUnresolvedBytes = 2 * 1_024  // 2 KiB

    public static let maxDelegationsPerTurn = 3
    public static let maximumSupportedContextWindow = 131_072

    public static let streamBufferCapacity = 32
    public static let maxStreamEventBytes = 1024 * 1024  // 1 MiB
    public static let maxStreamBufferBytes = 2 * 1024 * 1024  // 2 MiB

    public static let supportedModelEnvelopes: [String: Stage1ModelEnvelope] = [
        "qwen2.5-7b-instruct": Stage1ModelEnvelope(layers: 28, kvHeads: 4, headDimension: 128),
        "qwen2.5-7b": Stage1ModelEnvelope(layers: 28, kvHeads: 4, headDimension: 128),
        "qwen2.5-coder-7b-instruct": Stage1ModelEnvelope(layers: 28, kvHeads: 4, headDimension: 128),
        "qwen2.5-coder-7b": Stage1ModelEnvelope(layers: 28, kvHeads: 4, headDimension: 128),
        "qwen2.5-14b-instruct": Stage1ModelEnvelope(layers: 48, kvHeads: 8, headDimension: 128),
        "qwen2.5-14b": Stage1ModelEnvelope(layers: 48, kvHeads: 8, headDimension: 128),
        "llama-3.1-8b-instruct": Stage1ModelEnvelope(layers: 32, kvHeads: 8, headDimension: 128),
        "llama-3.1-8b": Stage1ModelEnvelope(layers: 32, kvHeads: 8, headDimension: 128),
        "llama-3-8b-instruct": Stage1ModelEnvelope(layers: 32, kvHeads: 8, headDimension: 128),
        "llama-3-8b": Stage1ModelEnvelope(layers: 32, kvHeads: 8, headDimension: 128),
        "mistral-7b-instruct": Stage1ModelEnvelope(layers: 32, kvHeads: 8, headDimension: 128),
        "mistral-7b-instruct-v0.3": Stage1ModelEnvelope(layers: 32, kvHeads: 8, headDimension: 128),
        "gemma-2-9b-it": Stage1ModelEnvelope(layers: 42, kvHeads: 8, headDimension: 256),
        "gemma-2-9b": Stage1ModelEnvelope(layers: 42, kvHeads: 8, headDimension: 256),
    ]

    public static func resolvedEnvelope(for modelID: String) -> Stage1ModelEnvelope? {
        let normalized =
            modelID.lowercased()
            .split(separator: "/")
            .last.map(String.init) ?? modelID.lowercased()
        if let env = supportedModelEnvelopes[normalized] {
            return env
        }
        for (key, env) in supportedModelEnvelopes {
            if normalized == key || normalized.hasPrefix(key + ":") {
                return env
            }
        }
        return nil
    }
}

/// Static eligibility is shared by tool advertisement and settings. Runtime admission
/// still verifies loaded state, request counts and memory immediately before dispatch.
public enum SubagentAvailability {
    public static func unavailableReason(hasLocalEngine: Bool, modelID: String?) -> String? {
        guard hasLocalEngine else { return "Choose a local engine to use investigations." }
        guard let modelID, !modelID.isEmpty else { return "Choose a model to use investigations." }
        guard SubagentLimits.resolvedEnvelope(for: modelID) != nil else {
            return "The selected model is not yet supported for investigations. Choose a supported model."
        }
        return nil
    }
}

public struct SubagentTaskBrief: Codable, Sendable, Equatable {
    public var objective: String
    public var scopeHint: [String]?
    public var maxRounds: Int?
    public var returnSchema: String?

    public init(
        objective: String,
        scopeHint: [String]? = nil,
        maxRounds: Int? = nil,
        returnSchema: String? = nil
    ) {
        self.objective = objective
        self.scopeHint = scopeHint
        self.maxRounds = maxRounds
        self.returnSchema = returnSchema
    }

    enum CodingKeys: String, CodingKey {
        case objective
        case scopeHint = "scope_hint"
        case maxRounds = "max_rounds"
        case returnSchema = "return_schema"
    }
}

public struct SubagentCitationClaim: Codable, Sendable, Equatable {
    public var path: String
    public var startLine: Int
    public var endLine: Int

    public init(path: String, startLine: Int, endLine: Int) {
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
    }

    enum CodingKeys: String, CodingKey {
        case path
        case startLine = "start_line"
        case endLine = "end_line"
    }
}

public struct SubagentCitation: Codable, Sendable, Equatable {
    public var path: String
    public var startLine: Int
    public var endLine: Int
    public var sliceHash: String

    public init(path: String, startLine: Int, endLine: Int, sliceHash: String = "") {
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.sliceHash = sliceHash
    }

    enum CodingKeys: String, CodingKey {
        case path
        case startLine = "start_line"
        case endLine = "end_line"
        case sliceHash = "slice_hash"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try container.decode(String.self, forKey: .path)
        self.startLine = try container.decode(Int.self, forKey: .startLine)
        self.endLine = try container.decode(Int.self, forKey: .endLine)
        self.sliceHash = try container.decodeIfPresent(String.self, forKey: .sliceHash) ?? ""
    }
}

public struct SubagentUnresolvedItem: Codable, Sendable, Equatable {
    public var path: String?
    public var reason: String
    public var detail: String?

    public init(path: String? = nil, reason: String, detail: String? = nil) {
        self.path = path
        self.reason = reason
        self.detail = detail
    }
}

public struct SubagentReceipt: Codable, Sendable, Equatable {
    public var runId: String
    public var status: SubagentStatus
    public var summary: String
    public var citations: [SubagentCitation]
    public var unresolved: [SubagentUnresolvedItem]
    public var roundsExecuted: Int
    public var totalTokens: Int

    public init(
        runId: String,
        status: SubagentStatus,
        summary: String,
        citations: [SubagentCitation] = [],
        unresolved: [SubagentUnresolvedItem] = [],
        roundsExecuted: Int = 0,
        totalTokens: Int = 0
    ) {
        self.runId = runId
        self.status = status
        self.summary = summary
        self.citations = citations
        self.unresolved = unresolved
        self.roundsExecuted = roundsExecuted
        self.totalTokens = totalTokens
    }

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case status
        case summary
        case citations
        case unresolved
        case roundsExecuted = "rounds_executed"
        case totalTokens = "total_tokens"
    }
}

public enum UTF8BoundaryTruncator {
    public static func truncate(_ text: String, maxBytes: Int, notice: String = " [truncated]") -> String {
        let utf8 = text.utf8
        guard utf8.count > maxBytes else { return text }
        let noticeBytes = notice.utf8.count
        guard maxBytes > noticeBytes else {
            return String(decoding: utf8.prefix(maxBytes), as: UTF8.self)
        }
        let targetBytes = maxBytes - noticeBytes
        let index = text.utf8.index(text.startIndex, offsetBy: targetBytes)
        let charIndex = text.indices.last(where: { $0 <= index }) ?? text.startIndex
        return String(text[..<charIndex]) + notice
    }
}

extension SubagentReceipt {
    public func boundedReceipt() -> SubagentReceipt {
        var bounded = self
        bounded.summary = UTF8BoundaryTruncator.truncate(bounded.summary, maxBytes: SubagentLimits.maxSummaryBytes)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(bounded.unresolved), data.count > SubagentLimits.maxUnresolvedBytes {
            while bounded.unresolved.count > 1,
                let currentData = try? encoder.encode(bounded.unresolved),
                currentData.count > SubagentLimits.maxUnresolvedBytes
            {
                bounded.unresolved.removeLast()
            }
            if let currentData = try? encoder.encode(bounded.unresolved),
                currentData.count > SubagentLimits.maxUnresolvedBytes
            {
                bounded.unresolved = [
                    SubagentUnresolvedItem(
                        reason: "truncated",
                        detail: UTF8BoundaryTruncator.truncate(
                            bounded.unresolved.first?.detail ?? "unresolved items truncated",
                            maxBytes: 500
                        )
                    )
                ]
            }
        }

        if let receiptData = try? encoder.encode(bounded), receiptData.count > SubagentLimits.maxReceiptBytes {
            while bounded.citations.count > 1,
                let currentData = try? encoder.encode(bounded),
                currentData.count > SubagentLimits.maxReceiptBytes
            {
                bounded.citations.removeLast()
            }
        }

        if let receiptData = try? encoder.encode(bounded), receiptData.count > SubagentLimits.maxReceiptBytes {
            let minimalFallback = SubagentReceipt(
                runId: bounded.runId,
                status: bounded.status,
                summary: UTF8BoundaryTruncator.truncate(bounded.summary, maxBytes: 128),
                citations: Array(bounded.citations.prefix(1)).map {
                    SubagentCitation(
                        path: UTF8BoundaryTruncator.truncate($0.path, maxBytes: 64),
                        startLine: $0.startLine,
                        endLine: $0.endLine,
                        sliceHash: $0.sliceHash
                    )
                },
                unresolved: [],
                roundsExecuted: bounded.roundsExecuted,
                totalTokens: bounded.totalTokens
            )
            if let fallbackData = try? encoder.encode(minimalFallback),
                fallbackData.count <= SubagentLimits.maxReceiptBytes
            {
                return minimalFallback
            }
            return SubagentReceipt(
                runId: bounded.runId,
                status: bounded.status,
                summary: UTF8BoundaryTruncator.truncate(bounded.summary, maxBytes: 64),
                citations: [],
                unresolved: [],
                roundsExecuted: bounded.roundsExecuted,
                totalTokens: bounded.totalTokens
            )
        }

        return bounded
    }
}

public protocol SubagentHostAuthority: Sendable {
    func validateHostAuthority() async throws
    func currentPenFileTools() async throws -> PenFileTools
}

public struct SubagentTurnAuthority: SubagentHostAuthority {
    private let validator: @Sendable () async throws -> PenFileTools

    public init(validator: @escaping @Sendable () async throws -> PenFileTools) {
        self.validator = validator
    }

    public func validateHostAuthority() async throws {
        _ = try await validator()
    }

    public func currentPenFileTools() async throws -> PenFileTools {
        try await validator()
    }
}

public final class SubagentTransportQuarantine: @unchecked Sendable {
    private let lock = NSLock()
    private var quarantined = false
    private var transportActive = false
    private var waiters: [UUID: GenerationTransportClosureRegistration] = [:]

    public init() {}

    public var isQuarantined: Bool {
        lock.lock()
        defer { lock.unlock() }
        return quarantined
    }

    public var isTransportActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return transportActive
    }

    public func markTransportActive() {
        lock.lock()
        defer { lock.unlock() }
        transportActive = true
    }

    public func markTransportClosed() {
        lock.lock()
        transportActive = false
        if quarantined {
            quarantined = false
        }
        let pending = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()

        for waiter in pending {
            waiter.resume()
        }
    }

    public func markQuarantined() {
        lock.lock()
        defer { lock.unlock() }
        quarantined = true
    }

    public func clearQuarantine() {
        lock.lock()
        defer { lock.unlock() }
        quarantined = false
    }

    public func waitForClosure() async {
        let registration = GenerationTransportClosureRegistration()

        let shouldWait: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if !transportActive {
                return false
            }
            waiters[registration.id] = registration
            return true
        }()
        guard shouldWait else { return }

        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                let inserted = registration.setContinuation(cont)
                if !inserted {
                    cont.resume()
                }
            }
        } onCancel: {
            lock.lock()
            waiters.removeValue(forKey: registration.id)
            lock.unlock()
            if let cont = registration.cancel() {
                cont.resume()
            }
        }
    }

    public func awaitClosure(timeoutSeconds: Int) async -> Bool {
        let (active, isQuar): (Bool, Bool) = {
            lock.lock()
            defer { lock.unlock() }
            return (transportActive, quarantined)
        }()
        if isQuar { return false }
        guard active else { return true }

        let result = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.waitForClosure()
                return true
            }
            group.addTask {
                if timeoutSeconds > 0 {
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                }
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !result {
            markQuarantined()
        }
        return result
    }
}

/// An inference engine decorator that gates engine dispatch behind confirmed transport closure
/// and quarantine state from subagent delegations (ADR-0096).
public actor QuarantineGuardedEngine: InferenceEngine {
    private let underlying: any InferenceEngine
    private let quarantine: SubagentTransportQuarantine

    public init(underlying: any InferenceEngine, quarantine: SubagentTransportQuarantine) {
        self.underlying = underlying
        self.quarantine = quarantine
    }

    public func health() async -> EngineHealth {
        await underlying.health()
    }

    public func runtimeStatus() async -> EngineRuntimeStatus? {
        await underlying.runtimeStatus()
    }

    public func probeCapabilities(for model: ModelRef) async -> ModelRef {
        await underlying.probeCapabilities(for: model)
    }

    public func inspectModel(_ model: ModelRef) async -> EngineModelInspection {
        await underlying.inspectModel(model)
    }

    public func stream(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
        if quarantine.isQuarantined {
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: EngineError.httpDetail(
                        503,
                        "Engine transport is quarantined due to unclosed subagent transport",
                        retryAfter: TimeInterval(SubagentLimits.cancellationGracePeriodSeconds)
                    )
                )
            }
        }
        if quarantine.isTransportActive {
            let closed = await quarantine.awaitClosure(timeoutSeconds: SubagentLimits.cancellationGracePeriodSeconds)
            if !closed {
                quarantine.markQuarantined()
                return AsyncThrowingStream { continuation in
                    continuation.finish(
                        throwing: EngineError.httpDetail(
                            503,
                            "Engine transport is quarantined due to unclosed subagent transport",
                            retryAfter: TimeInterval(SubagentLimits.cancellationGracePeriodSeconds)
                        )
                    )
                }
            }
        }
        return await underlying.stream(request)
    }

}

public final class SubagentTurnTokenAccounting: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDelegationsCount: Int = 0
    private var storedCumulativeGeneratedTokens: Int = 0
    private var storedCumulativeTotalTokens: Int = 0

    public init() {}

    public var delegationsCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedDelegationsCount
    }

    public var cumulativeGeneratedTokens: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCumulativeGeneratedTokens
    }

    public var cumulativeTotalTokens: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCumulativeTotalTokens
    }

    public func recordDelegation(generated: Int, total: Int) {
        lock.lock()
        defer { lock.unlock() }
        storedDelegationsCount += 1
        storedCumulativeGeneratedTokens += generated
        storedCumulativeTotalTokens += total
    }

    public var canDelegate: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedDelegationsCount < SubagentLimits.maxDelegationsPerTurn
            && storedCumulativeGeneratedTokens < SubagentLimits.maxGeneratedTokensPerTurn
            && storedCumulativeTotalTokens < SubagentLimits.maxTotalTokensPerTurn
    }
}

public final class SubagentCapabilityLease: @unchecked Sendable {
    private let lock = NSLock()
    private var storedIsRevoked = false

    public init() {}

    public var isRevoked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedIsRevoked
    }

    public func revoke() {
        lock.lock()
        defer { lock.unlock() }
        storedIsRevoked = true
    }

    public func checkValid() throws {
        if isRevoked {
            throw CapabilityError.revoked
        }
    }
}

public struct SubagentExecutionContext: Sendable {
    public var chatID: UUID
    public var turnID: UUID
    public var projectID: UUID?
    public var workspace: URL
    public var fileTools: PenFileTools
    public var authority: (any SubagentHostAuthority)?
    public var engine: (any InferenceEngine)?
    public var modelID: String?
    public var effort: Effort
    public var maxRounds: Int
    public var timeoutSeconds: Int
    public var database: ChatDatabase?
    public var turnTokenAccounting: SubagentTurnTokenAccounting?
    public var lease: SubagentCapabilityLease
    public var quarantine: SubagentTransportQuarantine?

    public init(
        chatID: UUID,
        turnID: UUID,
        projectID: UUID?,
        workspace: URL,
        fileTools: PenFileTools,
        authority: (any SubagentHostAuthority)? = nil,
        engine: (any InferenceEngine)? = nil,
        modelID: String? = nil,
        effort: Effort = .trot,
        maxRounds: Int = SubagentLimits.defaultMaxRounds,
        timeoutSeconds: Int = SubagentLimits.defaultTimeoutSeconds,
        database: ChatDatabase? = nil,
        turnTokenAccounting: SubagentTurnTokenAccounting? = nil,
        lease: SubagentCapabilityLease,
        quarantine: SubagentTransportQuarantine? = nil
    ) {
        self.chatID = chatID
        self.turnID = turnID
        self.projectID = projectID
        self.workspace = workspace
        self.fileTools = fileTools
        self.authority = authority
        self.engine = engine
        self.modelID = modelID
        self.effort = effort
        self.maxRounds = maxRounds
        self.timeoutSeconds = timeoutSeconds
        self.database = database
        self.turnTokenAccounting = turnTokenAccounting
        self.lease = lease
        self.quarantine = quarantine
    }
}

public struct SubagentResult: Sendable {
    public var receipt: SubagentReceipt
    public var transcriptJSON: String?
    public var roundsExecuted: Int
    public var totalTokens: Int

    public init(
        receipt: SubagentReceipt,
        transcriptJSON: String? = nil,
        roundsExecuted: Int = 0,
        totalTokens: Int = 0
    ) {
        self.receipt = receipt
        self.transcriptJSON = transcriptJSON
        self.roundsExecuted = roundsExecuted
        self.totalTokens = totalTokens
    }
}

public protocol SubagentBackend: Sendable {
    var id: String { get }
    var displayName: String { get }
    func execute(
        task: SubagentTaskBrief,
        context: SubagentExecutionContext
    ) async throws -> SubagentResult
}

public struct SubagentConfiguration: Sendable, Equatable {
    public var enabled: Bool
    public var maxRounds: Int
    public var timeoutSeconds: Int
    public var preferredBackend: SubagentBackendID

    public init(
        enabled: Bool = true,
        maxRounds: Int = SubagentLimits.defaultMaxRounds,
        timeoutSeconds: Int = SubagentLimits.defaultTimeoutSeconds,
        preferredBackend: SubagentBackendID = .localEngine
    ) {
        self.enabled = enabled
        self.maxRounds = maxRounds
        self.timeoutSeconds = timeoutSeconds
        self.preferredBackend = preferredBackend
    }
}
