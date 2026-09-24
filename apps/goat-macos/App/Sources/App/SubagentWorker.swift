import Foundation
import GOATed
import Herd
import Inference
import Pens
import Persistence
import Tools

#if canImport(FoundationModels)
import FoundationModels
#endif

private actor WorkerCompletionBridge {
    private var continuation: CheckedContinuation<Result<SubagentResult, Error>?, Never>?
    private var isSettled = false
    private var isWorkFinished = false

    func complete(with result: Result<SubagentResult, Error>) {
        isWorkFinished = true
        guard !isSettled else { return }
        isSettled = true
        continuation?.resume(returning: result)
        continuation = nil
    }

    func timeout() {
        guard !isSettled else { return }
        isSettled = true
        continuation?.resume(returning: nil)
        continuation = nil
    }

    func wait() async -> Result<SubagentResult, Error>? {
        if isSettled { return nil }
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
    }

    public func run() async throws -> SubagentResult {
        try context.lease.checkValid()

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

        // 2. Absolute deadline established before admission and encompassing entire execution
        let timeoutSeconds = min(
            max(context.timeoutSeconds, SubagentLimits.minimumTimeoutSeconds),
            SubagentLimits.ceilingTimeoutSeconds
        )
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        let lease = context.lease

        let bridge = WorkerCompletionBridge()

        // Independent watchdog task: revokes lease immediately upon deadline expiry
        let watchdog = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            lease.revoke()
            await bridge.timeout()
        }

        let workTask = Task { [self] () -> Void in
            do {
                let res = try await self.executeInternal(deadline: deadline)
                await bridge.complete(with: .success(res))
            } catch {
                await bridge.complete(with: .failure(error))
            }
        }
        self.runningWorkTask = workTask

        let maybeResult: Result<SubagentResult, Error>? = await withTaskCancellationHandler {
            await bridge.wait()
        } onCancel: {
            lease.revoke()
            workTask.cancel()
            Task {
                await bridge.complete(with: .failure(CancellationError()))
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

        // Timeout expired: revoke lease immediately and cancel child
        lease.revoke()
        workTask.cancel()

        let graceDeadline =
            ContinuousClock.now + .seconds(SubagentLimits.cancellationGracePeriodSeconds)
        var cleanShutdown = false
        while ContinuousClock.now < graceDeadline {
            if await bridge.isFinished() {
                cleanShutdown = true
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        if !cleanShutdown {
            await context.quarantine?.markQuarantined()
        }

        let detail =
            cleanShutdown
            ? "Subagent delegation timed out before completing synthesis."
            : "Worker was uncooperative; engine transport quarantined."

        return try await finalizeTerminal(
            status: .timedOut,
            summary: currentSummary.isEmpty ? detail : currentSummary,
            citations: (await fence.verifyCitations(claimed: currentClaimedCitations)).verified,
            unresolved: currentClaimedUnresolved + [
                SubagentUnresolvedItem(reason: "timedOut", detail: detail)
            ],
            roundsExecuted: currentRoundsExecuted,
            generatedTokens: currentGeneratedTokens,
            totalTokens: currentTotalTokens,
            transcriptJSON: encodeTranscript(currentTranscript)
        )
    }

    private func executeInternal(deadline: ContinuousClock.Instant) async throws -> SubagentResult {
        // Admission checks: engine idle, loaded model, and memory headroom
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

        if let active = status.activeRequests, active > 0 {
            return "Engine is busy (\(active) active requests)."
        }
        if let waiting = status.waitingRequests, waiting > 0 {
            return "Engine is busy (\(waiting) waiting requests)."
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
        if let contextWindow = loadedModel.contextWindow, contextWindow < requiredBudgetTokens {
            return
                "Model context window (\(contextWindow)) is smaller than requested subagent context budget (\(requiredBudgetTokens))."
        }

        guard let maxMem = status.modelMemoryMaximum, let usedMem = status.modelMemoryUsed else {
            return "Engine memory statistics are unavailable."
        }

        let freeMemoryBytes = maxMem - usedMem
        let minimumRequiredHeadroomBytes: Int64 = 256 * 1024 * 1024  // 256 MiB KV-cache headroom
        if freeMemoryBytes < minimumRequiredHeadroomBytes {
            let freeMB = freeMemoryBytes / (1024 * 1024)
            return "Insufficient memory headroom: \(freeMB) MiB free, minimum 256 MiB required."
        }

        return nil
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
                "\nScope filter: constrain searches to paths matching: \(filter.joined(separator: ", "))"
        }
        if let schema = task.returnSchema, !schema.isEmpty {
            systemPrompt += "\nExpected result schema: \(schema)"
        }

        let userPrompt = "Execute the task: \(task.objective)"
        transcript.append(ChatTurn(role: .system, text: systemPrompt))
        transcript.append(ChatTurn(role: .user, text: userPrompt))

        var transcriptBytes = systemPrompt.utf8.count + userPrompt.utf8.count
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
                    roundsExecuted: roundsExecuted,
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
                transcriptBytes = transcript.reduce(0) { $0 + $1.text.utf8.count }
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

            let request = GenerationRequest(
                model: context.modelID ?? "default",
                turns: transcript,
                effort: context.effort,
                maxTokens: maxGenAllowed,
                tools: availableTools,
                round: roundsExecuted
            )

            var assistantText = ""
            var toolCalls: [ToolCallEvent] = []
            var roundStreamTokens = 0
            var reportedStats: GenStats?

            let stream = await engine.stream(request)
            streamLoop: for try await event in stream {
                try Task.checkCancellation()
                try context.lease.checkValid()

                switch event {
                case .token(let chunk):
                    assistantText += chunk
                    roundStreamTokens += max(1, chunk.utf8.count / 4)
                    if roundStreamTokens >= maxGenAllowed
                        || (transcriptBytes + assistantText.utf8.count > SubagentLimits.maxTranscriptBytes)
                    {
                        break streamLoop
                    }
                case .thinking:
                    break
                case .toolInput:
                    break
                case .toolCalls(let calls):
                    toolCalls.append(contentsOf: calls)
                case .done(let stats):
                    reportedStats = stats
                }
            }

            let actualGen: Int
            if let stats = reportedStats, stats.tokensAreExact, stats.tokens > 0 {
                actualGen = stats.tokens
            } else {
                actualGen = max(roundStreamTokens, assistantText.utf8.count / 4)
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
            transcriptBytes += assistantText.utf8.count

            if transcriptBytes > SubagentLimits.maxTranscriptBytes {
                transcript = pruneTranscript(transcript)
                transcriptBytes = transcript.reduce(0) { $0 + $1.text.utf8.count }
                self.currentTranscript = transcript
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
                let resultContent = toolResult.content

                transcript.append(
                    ChatTurn(
                        role: .tool,
                        text: resultContent,
                        toolCallID: call.id
                    )
                )
                self.currentTranscript = transcript
                transcriptBytes += resultContent.utf8.count

                if transcriptBytes > SubagentLimits.maxTranscriptBytes {
                    transcript = pruneTranscript(transcript)
                    transcriptBytes = transcript.reduce(0) { $0 + $1.text.utf8.count }
                    self.currentTranscript = transcript
                }
            }
        }

        let verified = await fence.verifyCitations(claimed: claimedCitations)

        // Strict limit check: do not return completed if token ceiling was exceeded
        if totalTokens > SubagentLimits.maxTokensPerDelegation
            || generatedTokens > SubagentLimits.maxGeneratedTokensPerTurn
        {
            return try await finalizeTerminal(
                status: .budgetExhausted,
                summary: finalSummary.isEmpty
                    ? "Subagent reached token budget limit." : finalSummary,
                citations: verified.verified,
                unresolved: claimedUnresolved + verified.unresolved + [
                    SubagentUnresolvedItem(
                        reason: "budgetExhausted",
                        detail: "Final token usage exceeded allocation limit."
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
            summary: finalSummary.isEmpty ? "Subagent completed read-only investigation." : finalSummary,
            citations: verified.verified,
            unresolved: claimedUnresolved + verified.unresolved,
            roundsExecuted: roundsExecuted,
            generatedTokens: generatedTokens,
            totalTokens: totalTokens,
            transcriptJSON: encodeTranscript(transcript)
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

            let updated = try await db.transitionSubagentRun(
                id: id.uuidString,
                toStatus: status.rawValue,
                roundsExecuted: roundsExecuted,
                totalTokens: totalTokens,
                transcriptBytes: transcriptJSON?.utf8.count ?? 0,
                transcriptJson: transcriptJSON,
                summary: receipt.summary,
                citationsJson: citationsJson,
                receiptJson: receiptJson,
                completedAt: .now
            )

            if !updated {
                // Lost the CAS race: return the authoritative committed state
                if let committed = try await db.subagentRun(id: id.uuidString),
                    let committedStatus = SubagentStatus(rawValue: committed.status)
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

    private func pruneTranscript(_ turns: [ChatTurn]) -> [ChatTurn] {
        var pruned = turns
        for i in 0..<pruned.count {
            if pruned[i].role == .tool && pruned[i].text.utf8.count > 1024 {
                pruned[i] = ChatTurn(
                    role: .tool,
                    text: UTF8BoundaryTruncator.truncate(
                        pruned[i].text, maxBytes: 1024, notice: "\n[earlier tool output pruned]"
                    ),
                    toolCalls: pruned[i].toolCalls,
                    toolCallID: pruned[i].toolCallID
                )
            }
        }
        return pruned
    }

    private struct PersistedToolCall: Codable, Sendable {
        let id: String
        let name: String
        let argumentsJSON: String
    }

    private struct PersistedTranscriptTurn: Codable, Sendable {
        let role: String
        let text: String
        let toolCalls: [PersistedToolCall]?
        let toolCallID: String?
    }

    private func encodeTranscript(_ turns: [ChatTurn]) -> String? {
        var currentTurns = turns
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        while !currentTurns.isEmpty {
            let simplified = currentTurns.map { turn in
                PersistedTranscriptTurn(
                    role: turn.role.rawValue,
                    text: turn.text,
                    toolCalls: turn.toolCalls.isEmpty
                        ? nil
                        : turn.toolCalls.map {
                            PersistedToolCall(
                                id: $0.id,
                                name: $0.name,
                                argumentsJSON: $0.argumentsJSON
                            )
                        },
                    toolCallID: turn.toolCallID
                )
            }
            if let data = try? encoder.encode(simplified) {
                if data.count <= SubagentLimits.maxTranscriptBytes {
                    return String(data: data, encoding: .utf8)
                }
            }

            var prunedAny = false
            for i in 0..<currentTurns.count {
                if currentTurns[i].role == .tool && currentTurns[i].text.utf8.count > 256 {
                    currentTurns[i] = ChatTurn(
                        role: .tool,
                        text: UTF8BoundaryTruncator.truncate(
                            currentTurns[i].text, maxBytes: 256,
                            notice: "\n[pruned for disk limit]"
                        ),
                        toolCalls: currentTurns[i].toolCalls,
                        toolCallID: currentTurns[i].toolCallID
                    )
                    prunedAny = true
                    break
                }
            }
            if !prunedAny {
                if currentTurns.count > 2 {
                    currentTurns.remove(at: 1)
                } else {
                    break
                }
            }
        }

        let fallback = [
            PersistedTranscriptTurn(
                role: "system",
                text: "[transcript pruned to stay within 512 KiB limit]",
                toolCalls: nil,
                toolCallID: nil
            )
        ]
        return (try? encoder.encode(fallback)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func parseModelResponse(
        _ text: String
    ) -> (summary: String, citations: [SubagentCitationClaim], unresolved: [SubagentUnresolvedItem]) {
        if let jsonRange = text.range(of: "\\{[\\s\\S]*\\}", options: .regularExpression) {
            let jsonString = String(text[jsonRange])
            if let data = jsonString.data(using: .utf8) {
                struct ParsedFormat: Codable {
                    let summary: String?
                    let citations: [SubagentCitationClaim]?
                    let unresolved: [SubagentUnresolvedItem]?
                }
                if let parsed = try? JSONDecoder().decode(ParsedFormat.self, from: data) {
                    return (
                        summary: parsed.summary ?? text,
                        citations: parsed.citations ?? [],
                        unresolved: parsed.unresolved ?? []
                    )
                }
            }
        }
        return (summary: text, citations: [], unresolved: [])
    }
}

public struct LocalEngineBackend: SubagentBackend {
    public let id = "localEngine"
    public let displayName = "Local Engine"
    private let worker: SubagentWorker?

    public init(worker: SubagentWorker? = nil) {
        self.worker = worker
    }

    public func execute(
        task: SubagentTaskBrief,
        context: SubagentExecutionContext
    ) async throws -> SubagentResult {
        if let worker {
            return try await worker.run()
        }
        let freshWorker = SubagentWorker(task: task, context: context)
        return try await freshWorker.run()
    }
}

public struct SystemLanguageModelBackend: SubagentBackend {
    public let id = "systemLanguageModel"
    public let displayName = "Apple System Language Model"

    public init() {}

    public func execute(
        task: SubagentTaskBrief,
        context: SubagentExecutionContext
    ) async throws -> SubagentResult {
        throw CapabilityError.unavailable
    }
}
