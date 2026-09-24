import Foundation
import GOATed
import Herd
import Inference
import Pens
import Persistence
import Tools

private final class QueuedByteTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0

    func add(_ count: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        bytes += count
        return bytes
    }

    func subtract(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        bytes = max(0, bytes - count)
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }
}

final class StreamOverflowState: @unchecked Sendable {
    private let lock = NSLock()
    private var overflowError: Error?

    func recordOverflow(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        if overflowError == nil {
            overflowError = error
        }
    }

    func checkOverflow() throws {
        lock.lock()
        defer { lock.unlock() }
        if let error = overflowError {
            throw error
        }
    }

    var hasOverflow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overflowError != nil
    }
}

#if canImport(FoundationModels)
import FoundationModels
#endif

enum SubagentWorkerError: LocalizedError {
    case streamBufferOverflow

    var errorDescription: String? {
        switch self {
        case .streamBufferOverflow:
            return
                "Subagent stream buffer capacity exceeded: producer generated events faster than consumer could process."
        }
    }
}

private func isStreamBufferOverflow(_ error: Error) -> Bool {
    if case .streamBufferOverflow = error as? SubagentWorkerError {
        return true
    }
    if case .streamBufferOverflow = error as? EngineError {
        return true
    }
    return false
}

actor WorkerCompletionBridge {
    private var continuation: CheckedContinuation<Result<SubagentResult, Error>?, Never>?
    private var isSettled = false
    private var isWorkFinished = false
    private var storedResult: Result<SubagentResult, Error>?
    private var isTimedOut = false
    private var isCancelled = false

    func complete(with result: Result<SubagentResult, Error>) {
        isWorkFinished = true
        guard !isSettled else { return }
        isSettled = true
        storedResult = result
        continuation?.resume(returning: result)
        continuation = nil
    }

    func timeout() {
        guard !isSettled else { return }
        isSettled = true
        isTimedOut = true
        continuation?.resume(returning: nil)
        continuation = nil
    }

    func cancel() {
        guard !isSettled else { return }
        isSettled = true
        isCancelled = true
        continuation?.resume(returning: .failure(CancellationError()))
        continuation = nil
    }

    func wait() async -> Result<SubagentResult, Error>? {
        if let stored = storedResult {
            return stored
        }
        if isTimedOut {
            return nil
        }
        if isCancelled {
            return .failure(CancellationError())
        }
        return await withCheckedContinuation { cont in
            self.continuation = cont
        }
    }

    func isFinished() -> Bool {
        isWorkFinished
    }
}

public actor SubagentWorker {
    public let id: UUID
    private let task: SubagentTaskBrief
    private let context: SubagentExecutionContext
    private let fence: SubagentCapabilityFence
    private var transportAborted = false

    private var currentRoundsExecuted = 0
    private var currentGeneratedTokens = 0
    private var currentTotalTokens = 0
    private var currentTranscript: [ChatTurn] = []
    private var currentClaimedCitations: [SubagentCitationClaim] = []
    private var currentClaimedUnresolved: [SubagentUnresolvedItem] = []
    private var currentSummary = ""
    private var runningWorkTask: Task<Void, Never>?
    private let bridge = WorkerCompletionBridge()

    public init(id: UUID = UUID(), task: SubagentTaskBrief, context: SubagentExecutionContext) {
        self.id = id
        self.task = task
        self.context = context
        if let auth = context.authority {
            self.fence = SubagentCapabilityFence(authority: auth, lease: context.lease)
        } else {
            self.fence = SubagentCapabilityFence(fileTools: context.fileTools, lease: context.lease)
        }
    }

    public func cancel() {
        context.lease.revoke()
        runningWorkTask?.cancel()
        Task {
            await bridge.cancel()
        }
    }

    public func run() async throws -> SubagentResult {
        try context.lease.checkValid()

        // Absolute deadline established before initial database insert and admission
        let timeoutSeconds = min(
            max(context.timeoutSeconds, SubagentLimits.minimumTimeoutSeconds),
            SubagentLimits.ceilingTimeoutSeconds
        )
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        let lease = context.lease

        // Independent watchdog task: revokes lease immediately upon deadline expiry
        let watchdog = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            lease.revoke()
            if let self {
                await self.bridge.timeout()
            }
        }

        let workTask = Task { [self] () -> Void in
            do {
                let res = try await self.executeInternal(deadline: deadline)
                await self.bridge.complete(with: .success(res))
            } catch {
                await self.bridge.complete(with: .failure(error))
            }
        }
        self.runningWorkTask = workTask

        let maybeResult: Result<SubagentResult, Error>? = await withTaskCancellationHandler {
            await self.bridge.wait()
        } onCancel: {
            lease.revoke()
            workTask.cancel()
            Task { [weak self] in
                if let self {
                    await self.bridge.cancel()
                }
            }
        }

        watchdog.cancel()

        if let result = maybeResult {
            switch result {
            case .success(let subagentResult):
                return subagentResult
            case .failure(let error):
                lease.revoke()
                workTask.cancel()
                if let q = context.quarantine {
                    let closed = await q.awaitClosure(timeoutSeconds: SubagentLimits.cancellationGracePeriodSeconds)
                    if !closed {
                        q.markQuarantined()
                    }
                }
                if error is CancellationError {
                    return try await finalizeTerminal(
                        status: .cancelled,
                        summary: "Subagent delegation was cancelled by parent turn.",
                        citations: (await fence.verifyCitations(claimed: currentClaimedCitations)).verified,
                        unresolved: currentClaimedUnresolved + [
                            SubagentUnresolvedItem(
                                reason: "cancelled",
                                detail: "Subagent delegation was cancelled by parent turn."
                            )
                        ],
                        roundsExecuted: currentRoundsExecuted,
                        generatedTokens: currentGeneratedTokens,
                        totalTokens: currentTotalTokens,
                        transcriptJSON: encodeTranscript(currentTranscript)
                    )
                } else if isStreamBufferOverflow(error) {
                    return try await finalizeTerminal(
                        status: .failed,
                        summary:
                            "Subagent stream buffer capacity exceeded: producer generated events faster than consumer could process.",
                        citations: [],
                        unresolved: [
                            SubagentUnresolvedItem(
                                reason: "streamBufferOverflow",
                                detail: "Stream buffer capacity exceeded."
                            )
                        ],
                        roundsExecuted: currentRoundsExecuted,
                        generatedTokens: currentGeneratedTokens,
                        totalTokens: currentTotalTokens,
                        transcriptJSON: encodeTranscript(currentTranscript)
                    )
                } else {
                    return try await finalizeTerminal(
                        status: .failed,
                        summary: "Subagent execution failed: \(error.localizedDescription)",
                        citations: [],
                        unresolved: [
                            SubagentUnresolvedItem(
                                reason: "executionError",
                                detail: error.localizedDescription
                            )
                        ],
                        roundsExecuted: currentRoundsExecuted,
                        generatedTokens: currentGeneratedTokens,
                        totalTokens: currentTotalTokens,
                        transcriptJSON: encodeTranscript(currentTranscript)
                    )
                }
            }
        }

        // Timeout path
        lease.revoke()
        workTask.cancel()
        if let q = context.quarantine {
            let closed = await q.awaitClosure(timeoutSeconds: SubagentLimits.cancellationGracePeriodSeconds)
            if !closed {
                q.markQuarantined()
            }
        }
        return try await finalizeTerminal(
            status: .timedOut,
            summary: "Subagent execution timed out after \(timeoutSeconds) seconds.",
            citations: (await fence.verifyCitations(claimed: currentClaimedCitations)).verified,
            unresolved: currentClaimedUnresolved + [
                SubagentUnresolvedItem(
                    reason: "timeout",
                    detail: "Subagent execution exceeded the deadline of \(timeoutSeconds) seconds."
                )
            ],
            roundsExecuted: currentRoundsExecuted,
            generatedTokens: currentGeneratedTokens,
            totalTokens: currentTotalTokens,
            transcriptJSON: encodeTranscript(currentTranscript)
        )
    }

    private func finalizeTerminal(
        status: SubagentStatus,
        summary: String,
        citations: [SubagentCitation],
        unresolved: [SubagentUnresolvedItem],
        roundsExecuted: Int,
        generatedTokens: Int,
        totalTokens: Int,
        transcriptJSON: String?
    ) async throws -> SubagentResult {
        let receipt = SubagentReceipt(
            runId: id.uuidString,
            status: status,
            summary: summary,
            citations: citations,
            unresolved: unresolved,
            roundsExecuted: roundsExecuted,
            totalTokens: totalTokens
        ).boundedReceipt()

        if let db = context.database {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let citationsJson =
                (try? String(data: encoder.encode(receipt.citations), encoding: .utf8)) ?? "[]"
            let receiptJson =
                (try? String(data: encoder.encode(receipt), encoding: .utf8)) ?? "{}"

            let runIDString = id.uuidString
            let statusRaw = status.rawValue
            let summaryText = receipt.summary
            let transcriptCount = transcriptJSON?.utf8.count ?? 0

            // Perform terminal status transition in a detached context to shield from cancellation
            // of the calling task, while properly propagating real persistence errors.
            let updatedResult = await Task.detached { () -> Result<Bool, Error> in
                do {
                    let res = try await db.transitionSubagentRun(
                        id: runIDString,
                        toStatus: statusRaw,
                        roundsExecuted: roundsExecuted,
                        totalTokens: totalTokens,
                        transcriptBytes: transcriptCount,
                        transcriptJson: transcriptJSON,
                        summary: summaryText,
                        citationsJson: citationsJson,
                        receiptJson: receiptJson,
                        completedAt: .now
                    )
                    return .success(res)
                } catch {
                    return .failure(error)
                }
            }.value

            let updated = try updatedResult.get()

            if !updated {
                // Lost the CAS race: reload the authoritative committed state
                let committedResult = await Task.detached { () -> Result<SubagentRunRecord?, Error> in
                    do {
                        let rec = try await db.subagentRun(id: runIDString)
                        return .success(rec)
                    } catch {
                        return .failure(error)
                    }
                }.value

                let committed = try committedResult.get()

                if let committed,
                    let committedStatus = SubagentStatus(rawValue: committed.status),
                    committedStatus != .running
                {
                    let decoder = JSONDecoder()
                    let committedCitations =
                        (committed.citationsJson?.data(using: .utf8)).flatMap {
                            try? decoder.decode([SubagentCitation].self, from: $0)
                        } ?? []
                    let committedReceipt = SubagentReceipt(
                        runId: committed.id,
                        status: committedStatus,
                        summary: committed.summary ?? "Run terminated concurrently.",
                        citations: committedCitations,
                        unresolved: [
                            SubagentUnresolvedItem(
                                reason: committed.status,
                                detail: committed.summary
                            )
                        ],
                        roundsExecuted: committed.roundsExecuted,
                        totalTokens: committed.totalTokens
                    ).boundedReceipt()

                    return SubagentResult(
                        receipt: committedReceipt,
                        transcriptJSON: committed.transcriptJson,
                        roundsExecuted: committed.roundsExecuted,
                        totalTokens: committed.totalTokens
                    )
                } else {
                    // Chat cascade deletion, missing row, or record is not in a terminal state: fail closed
                    throw CapabilityError.revoked
                }
            }
        }

        context.turnTokenAccounting?.recordDelegation(
            generated: generatedTokens,
            total: totalTokens
        )

        return SubagentResult(
            receipt: receipt,
            transcriptJSON: transcriptJSON,
            roundsExecuted: roundsExecuted,
            totalTokens: totalTokens
        )
    }

    private func executeInternal(deadline: ContinuousClock.Instant) async throws -> SubagentResult {
        // 1. Persist initial running state in database (fail-closed if durable write fails)
        if let db = context.database {
            let taskJson = (try? String(data: JSONEncoder().encode(task), encoding: .utf8)) ?? "{}"
            let initialRecord = SubagentRunRecord(
                id: id.uuidString,
                chatId: context.chatID.uuidString,
                parentTurnId: context.turnID.uuidString,
                status: SubagentStatus.running.rawValue,
                taskBriefJson: taskJson,
                roundsExecuted: 0,
                totalTokens: 0,
                transcriptBytes: 0,
                createdAt: .now
            )
            do {
                try await db.save(initialRecord)
            } catch {
                throw CapabilityError.unavailable
            }
        }

        // 2. Admission checks: engine idle, loaded model, context window, and memory headroom
        if let rejectionReason = await checkAdmission() {
            return try await finalizeTerminal(
                status: .failed,
                summary: "Subagent admission rejected: \(rejectionReason)",
                citations: [],
                unresolved: [
                    SubagentUnresolvedItem(
                        reason: "admissionDenied",
                        detail: rejectionReason
                    )
                ],
                roundsExecuted: 0,
                generatedTokens: 0,
                totalTokens: 0,
                transcriptJSON: nil
            )
        }

        return try await executeLoop(deadline: deadline)
    }

    private func checkAdmission() async -> String? {
        guard let engine = context.engine else {
            return "No inference engine configured for subagent execution."
        }

        guard let status = await engine.runtimeStatus() else {
            return "Engine runtime status is unavailable."
        }

        guard let active = status.activeRequests, active == 0 else {
            if let active = status.activeRequests, active > 0 {
                return "Engine is busy (\(active) active requests)."
            }
            return "Engine active requests count is unknown."
        }
        guard let waiting = status.waitingRequests, waiting == 0 else {
            if let waiting = status.waitingRequests, waiting > 0 {
                return "Engine is busy (\(waiting) waiting requests)."
            }
            return "Engine waiting requests count is unknown."
        }

        let requestedModelID = context.modelID
        guard let models = status.models, !models.isEmpty else {
            return "Engine does not report loaded model information."
        }

        guard
            let loadedModel = models.first(where: { model in
                (requestedModelID == nil || model.id == requestedModelID) && (model.loaded == true)
            })
        else {
            return "Requested model '\(requestedModelID ?? "default")' is not loaded."
        }

        let requiredBudgetTokens =
            SubagentLimits.maxInputTokensPerRequest + SubagentLimits.maxGeneratedTokensPerRound
        guard let contextWindow = loadedModel.contextWindow else {
            return "Model context window is unknown."
        }
        if contextWindow < requiredBudgetTokens {
            return
                "Model context window (\(contextWindow)) is smaller than requested subagent context budget (\(requiredBudgetTokens))."
        }
        if contextWindow > SubagentLimits.maximumSupportedContextWindow {
            return
                "Model context window (\(contextWindow)) exceeds validated Stage 1 limit (\(SubagentLimits.maximumSupportedContextWindow))."
        }

        guard let envelope = SubagentLimits.resolvedEnvelope(for: loadedModel.id) else {
            return
                "Model '\(loadedModel.id)' is an unverified or aliased model outside the validated Stage 1 model allowlist."
        }

        if contextWindow > envelope.maxContextWindow {
            return
                "Model context window (\(contextWindow)) exceeds validated Stage 1 limit (\(envelope.maxContextWindow))."
        }

        guard let maxMem = status.modelMemoryMaximum, let usedMem = status.modelMemoryUsed else {
            return "Engine memory statistics are unavailable."
        }

        let freeMemoryBytes = maxMem - usedMem
        // KV-cache headroom calculation based on actual requested allocation and verified architecture bounds (ADR-0096):
        // Child request allocation is bounded by requiredBudgetTokens (14,336 tokens).
        let requestedTokens = min(contextWindow, requiredBudgetTokens)
        let kvBytesPerToken = envelope.bytesPerToken
        let kvCacheBytes: Int64 = Int64(requestedTokens) * kvBytesPerToken
        let runtimeOverheadBytes: Int64 = 256 * 1024 * 1024
        let minimumRequiredHeadroomBytes: Int64 = kvCacheBytes + runtimeOverheadBytes
        if freeMemoryBytes < minimumRequiredHeadroomBytes {
            let freeMB = max(0, freeMemoryBytes / (1024 * 1024))
            let requiredMB = minimumRequiredHeadroomBytes / (1024 * 1024)
            return "Insufficient memory headroom: \(freeMB) MiB free, minimum \(requiredMB) MiB required."
        }

        return nil
    }

    private func clampUTF8Prefix(_ str: String, maxBytes: Int) -> String {
        guard str.utf8.count > maxBytes else { return str }
        guard maxBytes > 0 else { return "" }
        var count = 0
        var endIdx = str.startIndex
        for idx in str.indices {
            let charBytes = String(str[idx]).utf8.count
            if count + charBytes > maxBytes { break }
            count += charBytes
            endIdx = str.index(after: idx)
        }
        return String(str[..<endIdx])
    }

    private func chatTurnBytes(_ turn: ChatTurn) -> Int {
        var bytes = turn.text.utf8.count
        for call in turn.toolCalls {
            bytes += call.id.utf8.count + call.name.utf8.count + call.argumentsJSON.utf8.count
        }
        return bytes
    }

    private func totalTranscriptBytes(_ turns: [ChatTurn]) -> Int {
        turns.reduce(0) { $0 + chatTurnBytes($1) }
    }

    private func estimateInputTokens(turns: [ChatTurn], tools: [ToolSpec]) -> Int {
        var tokens = 0
        for turn in turns {
            tokens += max(1, turn.text.utf8.count / 3)
            for call in turn.toolCalls {
                tokens += max(1, call.name.utf8.count / 3)
                tokens += max(1, call.argumentsJSON.utf8.count / 3)
            }
        }
        for tool in tools {
            tokens += max(1, tool.name.utf8.count / 3)
            tokens += max(1, tool.description.utf8.count / 3)
            tokens += max(1, tool.parametersJSON.utf8.count / 3)
        }
        return tokens
    }

    private func executeLoop(deadline: ContinuousClock.Instant) async throws -> SubagentResult {
        guard let engine = context.engine else {
            return try await finalizeTerminal(
                status: .failed,
                summary: "No inference engine configured for subagent execution.",
                citations: [],
                unresolved: [
                    SubagentUnresolvedItem(
                        reason: "engineUnavailable",
                        detail: "No engine configured."
                    )
                ],
                roundsExecuted: 0,
                generatedTokens: 0,
                totalTokens: 0,
                transcriptJSON: nil
            )
        }

        let effectiveRoundsCap = context.maxRounds
        let maxRounds: Int
        if let requested = task.maxRounds {
            maxRounds = min(max(requested, SubagentLimits.minimumMaxRounds), effectiveRoundsCap)
        } else {
            maxRounds = effectiveRoundsCap
        }

        var transcript: [ChatTurn] = []
        var roundsExecuted = 0
        var generatedTokens = 0
        var totalTokens = 0

        var systemPrompt = """
            You are a focused, read-only subagent assistant.
            Objective: \(task.objective)
            Inspect files and gather evidence strictly within the Pen workspace using the available read-only tools.
            When finished, output a concise summary of your findings along with verified citations.
            Format your final response as valid JSON:
            {
              "summary": "<summary of findings>",
              "citations": [
                {"path": "path/to/file", "start_line": 1, "end_line": 10}
              ],
              "unresolved": [
                {"path": "optional/path", "reason": "reason", "detail": "explanation"}
              ]
            }
            """
        if let filter = task.pathFilter, !filter.isEmpty {
            systemPrompt +=
                "\nScope limited strictly to these paths/patterns: \(filter.joined(separator: ", "))"
        }
        if let schema = task.returnSchema, !schema.isEmpty {
            systemPrompt += "\nRequired return schema: \(schema)"
        }

        transcript.append(ChatTurn(role: .system, text: systemPrompt))
        let userPrompt = "Investigate and report back: \(task.objective)"
        transcript.append(ChatTurn(role: .user, text: userPrompt))

        self.currentTranscript = transcript

        var transcriptBytes = totalTranscriptBytes(transcript)
        var finalSummary = ""
        var claimedCitations: [SubagentCitationClaim] = []
        var claimedUnresolved: [SubagentUnresolvedItem] = []

        while roundsExecuted < maxRounds {
            try Task.checkCancellation()
            try context.lease.checkValid()

            let parentGen = context.turnTokenAccounting?.cumulativeGeneratedTokens ?? 0
            let parentTotal = context.turnTokenAccounting?.cumulativeTotalTokens ?? 0

            let parentGenRemaining =
                SubagentLimits.maxGeneratedTokensPerTurn - parentGen - generatedTokens
            let parentTotalRemaining =
                SubagentLimits.maxTotalTokensPerTurn - parentTotal - totalTokens
            let delegationTotalRemaining =
                SubagentLimits.maxTokensPerDelegation - totalTokens

            if parentGenRemaining <= 0 || parentTotalRemaining <= 0 || delegationTotalRemaining <= 0 {
                return try await finalizeTerminal(
                    status: .budgetExhausted,
                    summary: finalSummary.isEmpty
                        ? "Subagent reached token budget limit before completion." : finalSummary,
                    citations: (await fence.verifyCitations(claimed: claimedCitations)).verified,
                    unresolved: claimedUnresolved + [
                        SubagentUnresolvedItem(
                            reason: "budgetExhausted",
                            detail: "Exceeded token budget limit."
                        )
                    ],
                    roundsExecuted: roundsExecuted - 1,
                    generatedTokens: generatedTokens,
                    totalTokens: totalTokens,
                    transcriptJSON: encodeTranscript(transcript)
                )
            }

            roundsExecuted += 1
            let remainingRounds = maxRounds - roundsExecuted
            let isSynthesisPass = remainingRounds == 0

            let availableTools = isSynthesisPass ? [] : await fence.availableToolSpecs

            var estimatedInputTokens = estimateInputTokens(turns: transcript, tools: availableTools)
            if estimatedInputTokens > SubagentLimits.maxInputTokensPerRequest {
                transcript = pruneTranscript(transcript)
                transcriptBytes = totalTranscriptBytes(transcript)
                estimatedInputTokens = estimateInputTokens(turns: transcript, tools: availableTools)
                if estimatedInputTokens > SubagentLimits.maxInputTokensPerRequest {
                    return try await finalizeTerminal(
                        status: .budgetExhausted,
                        summary:
                            "Input context exceeded limit (\(estimatedInputTokens) > \(SubagentLimits.maxInputTokensPerRequest)).",
                        citations: (await fence.verifyCitations(claimed: claimedCitations)).verified,
                        unresolved: claimedUnresolved + [
                            SubagentUnresolvedItem(
                                reason: "budgetExhausted",
                                detail: "Input context limit exceeded."
                            )
                        ],
                        roundsExecuted: roundsExecuted - 1,
                        generatedTokens: generatedTokens,
                        totalTokens: totalTokens,
                        transcriptJSON: encodeTranscript(transcript)
                    )
                }
            }

            let maxGenAllowed = min(
                SubagentLimits.maxGeneratedTokensPerRound,
                parentGenRemaining,
                max(0, parentTotalRemaining - estimatedInputTokens),
                max(0, delegationTotalRemaining - estimatedInputTokens)
            )

            if maxGenAllowed <= 0 {
                return try await finalizeTerminal(
                    status: .budgetExhausted,
                    summary: finalSummary.isEmpty
                        ? "Subagent reached token budget limit before completion." : finalSummary,
                    citations: (await fence.verifyCitations(claimed: claimedCitations)).verified,
                    unresolved: claimedUnresolved + [
                        SubagentUnresolvedItem(
                            reason: "budgetExhausted",
                            detail: "Exceeded generation token limit."
                        )
                    ],
                    roundsExecuted: roundsExecuted - 1,
                    generatedTokens: generatedTokens,
                    totalTokens: totalTokens,
                    transcriptJSON: encodeTranscript(transcript)
                )
            }

            if !isSynthesisPass && maxGenAllowed < 256 {
                return try await finalizeTerminal(
                    status: .budgetExhausted,
                    summary: finalSummary.isEmpty
                        ? "Subagent halted before synthesis due to low token headroom." : finalSummary,
                    citations: (await fence.verifyCitations(claimed: claimedCitations)).verified,
                    unresolved: claimedUnresolved + [
                        SubagentUnresolvedItem(
                            reason: "budgetExhausted",
                            detail: "Insufficient headroom reserved for synthesis."
                        )
                    ],
                    roundsExecuted: roundsExecuted - 1,
                    generatedTokens: generatedTokens,
                    totalTokens: totalTokens,
                    transcriptJSON: encodeTranscript(transcript)
                )
            }

            let roundPromptTokens = estimatedInputTokens
            self.currentTotalTokens = totalTokens + roundPromptTokens
            self.currentRoundsExecuted = roundsExecuted

            let quarantine = context.quarantine
            quarantine?.markTransportActive()

            let closureHandle = GenerationTransportClosureHandle()
            closureHandle.onAcknowledge { [weak quarantine] in
                quarantine?.markTransportClosed()
            }

            var request = GenerationRequest(
                model: context.modelID ?? "qwen2.5-7b-instruct",
                turns: transcript,
                effort: context.effort,
                maxTokens: maxGenAllowed,
                tools: availableTools,
                round: roundsExecuted,
                onTransportClosed: {
                    closureHandle.acknowledge()
                },
                transportClosureHandle: closureHandle
            )

            var assistantText = ""
            var toolCalls: [ToolCallEvent] = []
            var roundStreamTokens = 0
            var toolInputTokens = 0
            var roundRetainedBytes = 0
            var reportedStats: GenStats?
            var streamTruncatedDueToBudget = false

            let producerStream = await engine.stream(request)

            let queuedByteTracker = QueuedByteTracker()
            let overflowState = StreamOverflowState()
            let (consumerStream, continuation) =
                AsyncThrowingStream<GenerationEvent, Error>.makeStream(
                    bufferingPolicy: .bufferingNewest(SubagentLimits.streamBufferCapacity)
                )
            let forwarderTask = Task {
                do {
                    forwarderLoop: for try await event in producerStream {
                        try Task.checkCancellation()

                        let eventBytes: Int
                        switch event {
                        case .token(let chunk):
                            eventBytes = chunk.utf8.count
                        case .thinking(let th):
                            eventBytes = th.utf8.count
                        case .toolInput(let bytes):
                            eventBytes = bytes
                        case .toolCalls(let calls):
                            eventBytes = calls.reduce(0) {
                                $0 + $1.id.utf8.count + $1.name.utf8.count + $1.argumentsJSON.utf8.count
                            }
                        case .done:
                            eventBytes = 0
                        }

                        if eventBytes > SubagentLimits.maxStreamEventBytes {
                            overflowState.recordOverflow(SubagentWorkerError.streamBufferOverflow)
                            continuation.finish(throwing: SubagentWorkerError.streamBufferOverflow)
                            break forwarderLoop
                        }

                        let currentlyQueued = queuedByteTracker.add(eventBytes)
                        if currentlyQueued > SubagentLimits.maxStreamBufferBytes {
                            overflowState.recordOverflow(SubagentWorkerError.streamBufferOverflow)
                            continuation.finish(throwing: SubagentWorkerError.streamBufferOverflow)
                            break forwarderLoop
                        }

                        switch continuation.yield(event) {
                        case .enqueued:
                            break
                        case .dropped:
                            overflowState.recordOverflow(SubagentWorkerError.streamBufferOverflow)
                            continuation.finish(throwing: SubagentWorkerError.streamBufferOverflow)
                            break forwarderLoop
                        case .terminated:
                            break forwarderLoop
                        @unknown default:
                            break
                        }
                    }
                    if !overflowState.hasOverflow {
                        continuation.finish()
                    }
                } catch {
                    if isStreamBufferOverflow(error) {
                        overflowState.recordOverflow(SubagentWorkerError.streamBufferOverflow)
                    }
                    continuation.finish(throwing: error)
                }
            }

            do {
                streamLoop: for try await event in consumerStream {
                    try Task.checkCancellation()
                    try context.lease.checkValid()
                    try overflowState.checkOverflow()

                    let dequeuedBytes: Int
                    switch event {
                    case .token(let chunk):
                        dequeuedBytes = chunk.utf8.count
                    case .thinking(let th):
                        dequeuedBytes = th.utf8.count
                    case .toolInput(let bytes):
                        dequeuedBytes = bytes
                    case .toolCalls(let calls):
                        dequeuedBytes = calls.reduce(0) {
                            $0 + $1.id.utf8.count + $1.name.utf8.count + $1.argumentsJSON.utf8.count
                        }
                    case .done:
                        dequeuedBytes = 0
                    }
                    queuedByteTracker.subtract(dequeuedBytes)

                    switch event {
                    case .token(let chunk):
                        let chunkBytes = chunk.utf8.count
                        let remainingBytes = SubagentLimits.maxTranscriptBytes - (transcriptBytes + roundRetainedBytes)
                        if remainingBytes <= 0 {
                            streamTruncatedDueToBudget = true
                            break streamLoop
                        }
                        let chunkToAppend: String
                        if chunkBytes > remainingBytes {
                            chunkToAppend = clampUTF8Prefix(chunk, maxBytes: remainingBytes)
                            streamTruncatedDueToBudget = true
                        } else {
                            chunkToAppend = chunk
                        }
                        assistantText += chunkToAppend
                        roundRetainedBytes += chunkToAppend.utf8.count
                        roundStreamTokens += max(1, chunkToAppend.utf8.count / 4)

                        self.currentGeneratedTokens = generatedTokens + roundStreamTokens
                        self.currentTotalTokens = totalTokens + roundPromptTokens + roundStreamTokens
                        self.currentTranscript =
                            transcript + [ChatTurn(role: .assistant, text: assistantText, toolCalls: toolCalls)]

                        if streamTruncatedDueToBudget || roundStreamTokens >= maxGenAllowed {
                            streamTruncatedDueToBudget = true
                            break streamLoop
                        }
                    case .thinking:
                        break
                    case .toolInput(let bytes):
                        let inputTokens = max(1, bytes / 4)
                        toolInputTokens += inputTokens
                        roundStreamTokens += inputTokens
                        self.currentGeneratedTokens = generatedTokens + roundStreamTokens
                        self.currentTotalTokens = totalTokens + roundPromptTokens + roundStreamTokens

                        if roundStreamTokens >= maxGenAllowed {
                            streamTruncatedDueToBudget = true
                            break streamLoop
                        }
                    case .toolCalls(let calls):
                        for call in calls {
                            let callBytes = call.id.utf8.count + call.name.utf8.count + call.argumentsJSON.utf8.count
                            if transcriptBytes + roundRetainedBytes + callBytes > SubagentLimits.maxTranscriptBytes {
                                streamTruncatedDueToBudget = true
                                break streamLoop
                            }
                            toolCalls.append(call)
                            roundRetainedBytes += callBytes
                            let singleCallTokens = max(1, (call.name.utf8.count + call.argumentsJSON.utf8.count) / 4)
                            if toolInputTokens > 0 {
                                if singleCallTokens > toolInputTokens {
                                    roundStreamTokens += (singleCallTokens - toolInputTokens)
                                    toolInputTokens = 0
                                } else {
                                    toolInputTokens -= singleCallTokens
                                }
                            } else {
                                roundStreamTokens += singleCallTokens
                            }
                        }
                        self.currentGeneratedTokens = generatedTokens + roundStreamTokens
                        self.currentTotalTokens = totalTokens + roundPromptTokens + roundStreamTokens
                        self.currentTranscript =
                            transcript + [ChatTurn(role: .assistant, text: assistantText, toolCalls: toolCalls)]

                        if streamTruncatedDueToBudget || roundStreamTokens >= maxGenAllowed {
                            streamTruncatedDueToBudget = true
                            break streamLoop
                        }
                    case .done(let stats):
                        reportedStats = stats
                        try overflowState.checkOverflow()
                    // Do not break early: continue draining consumerStream so any pending streamBufferOverflow
                    // error queued after dropped events is thrown rather than silently masked by .done.
                    }
                }
                try Task.checkCancellation()
                try overflowState.checkOverflow()
            } catch {
                forwarderTask.cancel()
                if let quarantine {
                    let closed = await closureHandle.waitForClosure(
                        timeoutSeconds: SubagentLimits.cancellationGracePeriodSeconds)
                    if !closed {
                        quarantine.markQuarantined()
                    }
                }
                throw error
            }

            forwarderTask.cancel()
            if let quarantine {
                let closed = await closureHandle.waitForClosure(
                    timeoutSeconds: SubagentLimits.cancellationGracePeriodSeconds)
                if !closed {
                    quarantine.markQuarantined()
                }
            }

            let actualGen: Int
            if let stats = reportedStats, stats.tokensAreExact, stats.tokens > 0 {
                actualGen = stats.tokens
            } else {
                actualGen = max(roundStreamTokens, roundRetainedBytes / 4)
            }

            let actualPrompt: Int
            if let stats = reportedStats, let p = stats.promptTokens, p > 0 {
                actualPrompt = p
            } else {
                actualPrompt = estimatedInputTokens
            }

            generatedTokens += actualGen
            totalTokens += actualGen + actualPrompt

            self.currentRoundsExecuted = roundsExecuted
            self.currentGeneratedTokens = generatedTokens
            self.currentTotalTokens = totalTokens

            transcript.append(
                ChatTurn(
                    role: .assistant,
                    text: assistantText,
                    toolCalls: toolCalls
                )
            )
            self.currentTranscript = transcript
            transcriptBytes = totalTranscriptBytes(transcript)

            if transcriptBytes > SubagentLimits.maxTranscriptBytes {
                transcript = pruneTranscript(transcript)
                transcriptBytes = totalTranscriptBytes(transcript)
                self.currentTranscript = transcript
            }

            if streamTruncatedDueToBudget {
                return try await finalizeTerminal(
                    status: .budgetExhausted,
                    summary: finalSummary.isEmpty
                        ? "Subagent reached budget limit during streaming." : finalSummary,
                    citations: (await fence.verifyCitations(claimed: claimedCitations)).verified,
                    unresolved: claimedUnresolved + [
                        SubagentUnresolvedItem(
                            reason: "budgetExhausted",
                            detail: "Generation was truncated due to budget limit."
                        )
                    ],
                    roundsExecuted: roundsExecuted,
                    generatedTokens: generatedTokens,
                    totalTokens: totalTokens,
                    transcriptJSON: encodeTranscript(transcript)
                )
            }

            if isSynthesisPass || toolCalls.isEmpty {
                let parsed = parseModelResponse(assistantText)
                finalSummary = parsed.summary
                claimedCitations.append(contentsOf: parsed.citations)
                claimedUnresolved.append(contentsOf: parsed.unresolved)
                self.currentSummary = finalSummary
                self.currentClaimedCitations = claimedCitations
                self.currentClaimedUnresolved = claimedUnresolved
                break
            }

            for call in toolCalls {
                try Task.checkCancellation()
                try context.lease.checkValid()

                let callRequest = ToolCallRequest(
                    tool: call.name,
                    argumentsJSON: call.argumentsJSON
                )
                let toolResult = try await fence.invoke(callRequest)
                var resultContent = toolResult.content
                if resultContent.utf8.count > 32 * 1024 {
                    resultContent = clampUTF8Prefix(resultContent, maxBytes: 32 * 1024)
                }

                if transcriptBytes + resultContent.utf8.count > SubagentLimits.maxTranscriptBytes {
                    transcript = pruneTranscript(transcript)
                    transcriptBytes = totalTranscriptBytes(transcript)
                }
                let remaining = max(0, SubagentLimits.maxTranscriptBytes - transcriptBytes)
                if resultContent.utf8.count > remaining {
                    resultContent = clampUTF8Prefix(resultContent, maxBytes: remaining)
                }

                transcript.append(
                    ChatTurn(
                        role: .tool,
                        text: resultContent,
                        toolCallID: call.id
                    )
                )
                self.currentTranscript = transcript
                transcriptBytes = totalTranscriptBytes(transcript)

                if transcriptBytes > SubagentLimits.maxTranscriptBytes {
                    transcript = pruneTranscript(transcript)
                    transcriptBytes = totalTranscriptBytes(transcript)
                    self.currentTranscript = transcript
                }
            }
        }

        let verified = await fence.verifyCitations(claimed: claimedCitations)

        // Strict limit check: do not return completed if token ceiling was exceeded
        let parentGen = context.turnTokenAccounting?.cumulativeGeneratedTokens ?? 0
        let parentTotal = context.turnTokenAccounting?.cumulativeTotalTokens ?? 0
        if totalTokens > SubagentLimits.maxTokensPerDelegation
            || (parentGen + generatedTokens) > SubagentLimits.maxGeneratedTokensPerTurn
            || (parentTotal + totalTokens) > SubagentLimits.maxTotalTokensPerTurn
        {
            return try await finalizeTerminal(
                status: .budgetExhausted,
                summary: finalSummary.isEmpty
                    ? "Subagent exceeded token limits before finalizing." : finalSummary,
                citations: verified.verified,
                unresolved: claimedUnresolved + [
                    SubagentUnresolvedItem(
                        reason: "budgetExhausted",
                        detail: "Strict token limits exceeded."
                    )
                ],
                roundsExecuted: roundsExecuted,
                generatedTokens: generatedTokens,
                totalTokens: totalTokens,
                transcriptJSON: encodeTranscript(transcript)
            )
        }

        return try await finalizeTerminal(
            status: .completed,
            summary: finalSummary,
            citations: verified.verified,
            unresolved: claimedUnresolved + verified.unresolved,
            roundsExecuted: roundsExecuted,
            generatedTokens: generatedTokens,
            totalTokens: totalTokens,
            transcriptJSON: encodeTranscript(transcript)
        )
    }

    private func pruneTranscript(_ turns: [ChatTurn]) -> [ChatTurn] {
        Self.pruneTranscript(turns)
    }

    private func parseModelResponse(_ text: String) -> (
        summary: String,
        citations: [SubagentCitationClaim],
        unresolved: [SubagentUnresolvedItem]
    ) {
        Self.parseModelResponse(text)
    }

    private func encodeTranscript(_ turns: [ChatTurn]) -> String? {
        Self.encodeTranscript(turns)
    }

    static func pruneTranscript(_ turns: [ChatTurn]) -> [ChatTurn] {
        var pruned = turns
        for i in 0..<pruned.count {
            if pruned[i].role == .tool && pruned[i].text.utf8.count > 1024 {
                pruned[i] = ChatTurn(
                    role: .tool,
                    text: UTF8BoundaryTruncator.truncate(pruned[i].text, maxBytes: 1024),
                    toolCallID: pruned[i].toolCallID
                )
            }
        }
        return pruned
    }

    static func parseModelResponse(_ text: String) -> (
        summary: String,
        citations: [SubagentCitationClaim],
        unresolved: [SubagentUnresolvedItem]
    ) {
        struct ModelOutputEnvelope: Codable {
            var summary: String?
            var citations: [SubagentCitationClaim]?
            var unresolved: [SubagentUnresolvedItem]?
        }

        let decoder = JSONDecoder()

        if let data = text.data(using: .utf8),
            let decoded = try? decoder.decode(ModelOutputEnvelope.self, from: data)
        {
            return (
                summary: decoded.summary ?? text,
                citations: decoded.citations ?? [],
                unresolved: decoded.unresolved ?? []
            )
        }

        if let start = text.range(of: "{"),
            let end = text.range(of: "}", options: .backwards),
            start.lowerBound < end.upperBound
        {
            let jsonSubstring = text[start.lowerBound..<end.upperBound]
            if let data = jsonSubstring.data(using: .utf8),
                let decoded = try? decoder.decode(ModelOutputEnvelope.self, from: data)
            {
                return (
                    summary: decoded.summary ?? text,
                    citations: decoded.citations ?? [],
                    unresolved: decoded.unresolved ?? []
                )
            }
        }

        return (
            summary: text,
            citations: [],
            unresolved: []
        )
    }

    static func encodeTranscript(_ turns: [ChatTurn]) -> String? {
        struct SimpleToolCall: Codable {
            let id: String
            let name: String
            let argumentsJSON: String
        }
        struct SimpleTurn: Codable {
            let role: String
            let text: String
            let toolCalls: [SimpleToolCall]?
            let toolCallID: String?
        }

        func sanitizeCall(_ call: ToolCallEvent) -> SimpleToolCall {
            SimpleToolCall(
                id: UTF8BoundaryTruncator.truncate(call.id, maxBytes: 256, notice: ""),
                name: UTF8BoundaryTruncator.truncate(call.name, maxBytes: 256, notice: ""),
                argumentsJSON: UTF8BoundaryTruncator.truncate(call.argumentsJSON, maxBytes: 1024, notice: "")
            )
        }

        func sanitizeTurn(_ turn: ChatTurn, maxTextBytes: Int) -> SimpleTurn {
            SimpleTurn(
                role: turn.role.rawValue,
                text: UTF8BoundaryTruncator.truncate(turn.text, maxBytes: maxTextBytes, notice: ""),
                toolCalls: turn.toolCalls.isEmpty ? nil : turn.toolCalls.map(sanitizeCall),
                toolCallID: turn.toolCallID.map { UTF8BoundaryTruncator.truncate($0, maxBytes: 256, notice: "") }
            )
        }

        var candidateTurns = turns
        let encoder = JSONEncoder()

        // 1. Try encoding with full turns and sanitized fields
        for maxText in [16 * 1024, 4 * 1024, 1024, 256] {
            let simplified = candidateTurns.map { sanitizeTurn($0, maxTextBytes: maxText) }
            if let data = try? encoder.encode(simplified), data.count <= SubagentLimits.maxTranscriptBytes {
                return String(data: data, encoding: .utf8)
            }
            if candidateTurns.count > 2 {
                candidateTurns = pruneTranscript(candidateTurns)
            }
        }

        // 2. Drop older turns progressively until only the last 2 turns remain
        while candidateTurns.count > 2 {
            candidateTurns.remove(at: 1)
            let simplified = candidateTurns.map { sanitizeTurn($0, maxTextBytes: 512) }
            if let data = try? encoder.encode(simplified), data.count <= SubagentLimits.maxTranscriptBytes {
                return String(data: data, encoding: .utf8)
            }
        }

        // 3. Fallback: minimal turns with very tight text bounds
        for maxText in [256, 64] {
            let minimal = candidateTurns.map { sanitizeTurn($0, maxTextBytes: maxText) }
            if let data = try? encoder.encode(minimal), data.count <= SubagentLimits.maxTranscriptBytes {
                return String(data: data, encoding: .utf8)
            }
        }

        // 4. Guaranteed valid static JSON fallback - never truncate raw JSON bytes
        return "[{\"role\":\"system\",\"text\":\"[transcript truncated]\"}]"
    }
}

public struct LocalEngineBackend: SubagentBackend {
    public let id: String = "local_engine"
    public let displayName: String = "Local Engine"
    private let worker: SubagentWorker

    public init(worker: SubagentWorker) {
        self.worker = worker
    }

    public func execute(
        task: SubagentTaskBrief,
        context: SubagentExecutionContext
    ) async throws -> SubagentResult {
        try await worker.run()
    }
}

public struct SystemLanguageModelBackend: SubagentBackend {
    public let id: String = "system_language_model"
    public let displayName: String = "Apple System Language Model"

    public init() {}

    public func execute(
        task: SubagentTaskBrief,
        context: SubagentExecutionContext
    ) async throws -> SubagentResult {
        throw CapabilityError.unavailable
    }
}
