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

public enum SubagentLimits {
    public static let defaultMaxRounds = 5
    public static let ceilingMaxRounds = 10
    public static let minimumMaxRounds = 1

    public static let defaultTimeoutSeconds = 60
    public static let ceilingTimeoutSeconds = 90
    public static let minimumTimeoutSeconds = 10
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
}

public struct SubagentTaskBrief: Codable, Sendable, Equatable {
    public var objective: String
    public var pathFilter: [String]?
    public var maxRounds: Int?
    public var returnSchema: String?

    public init(
        objective: String,
        pathFilter: [String]? = nil,
        maxRounds: Int? = nil,
        returnSchema: String? = nil
    ) {
        self.objective = objective
        self.pathFilter = pathFilter
        self.maxRounds = maxRounds
        self.returnSchema = returnSchema
    }

    enum CodingKeys: String, CodingKey {
        case objective
        case pathFilter = "path_filter"
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
            if let fallbackData = try? encoder.encode(minimalFallback), fallbackData.count <= SubagentLimits.maxReceiptBytes {
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

public actor SubagentTransportQuarantine {
    private var isQuarantined = false
    private var isClosed = false

    public init() {}

    public func markQuarantined() {
        isQuarantined = true
    }

    public func confirmClosed() {
        isClosed = true
        isQuarantined = false
    }

    public var canDispatchInference: Bool {
        !isQuarantined && isClosed
    }

    public func waitUntilClosed(timeoutSeconds: Double) async -> Bool {
        if isClosed { return true }
        let start = Date()
        while Date().timeIntervalSince(start) < timeoutSeconds {
            if isClosed { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return isClosed
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
        lease: SubagentCapabilityLease
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
