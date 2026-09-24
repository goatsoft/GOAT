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

private enum SubagentWorkerError: Error {
    case timeout
}

public actor SubagentWorker {
    public let id: UUID
    private let task: SubagentTaskBrief
    private let context: SubagentExecutionContext
    private let fence: SubagentCapabilityFence
    private var transportAborted = false

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

        // 2. Admission checks: engine idle, loaded model, and memory headroom
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
                totalTokens: 0,
                transcriptJSON: nil
            )
        }

        // 3. Inner deadline watchdog
        let innerTimeoutSeconds = min(
            max(context.timeoutSeconds, 1),
            SubagentLimits.ceilingTimeoutSeconds
        )

        do {
            return try await withThrowingTaskGroup(of: SubagentResult.self) { group in
                group.addTask {
                    try await self.executeLoop(timeoutSeconds: innerTimeoutSeconds)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(innerTimeoutSeconds))
                    throw SubagentWorkerError.timeout
                }

                guard let first = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return first
            }
        } catch SubagentWorkerError.timeout {
            return try await handleCancellationOrTimeout(wasTimeout: true)
        } catch is CancellationError {
            return try await handleCancellationOrTimeout(wasTimeout: false)
        } catch {
            return try await finalizeTerminal(
                status: .failed,
                summary: "Subagent execution failed: \(error.localizedDescription)",
                citations: [],
                unresolved: [SubagentUnresolvedItem(reason: "executionError", detail: error.localizedDescription)],
                roundsExecuted: 0,
                totalTokens: 0,
                transcriptJSON: nil
            )
        }
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

        guard let loadedModel = models.first(where: { model in
            (requestedModelID == nil || model.id == requestedModelID) && (model.loaded == true)
        }) else {
            return "Requested model '\(requestedModelID ?? "default")' is not loaded."
        }

        let requiredBudgetTokens = SubagentLimits.maxInputTokensPerRequest + SubagentLimits.maxGeneratedTokensPerRound
        if let contextWindow = loadedModel.contextWindow, contextWindow < requiredBudgetTokens {
            return "Model context window (\(contextWindow)) is smaller than requested subagent context budget (\(requiredBudgetTokens))."
        }

        guard let maxMem = status.modelMemoryMaximum, let usedMem = status.modelMemoryUsed else {
            return "Engine memory statistics are unavailable."
        }

        let freeMemoryBytes = maxMem - usedMem
        let minimumRequiredHeadroomBytes: Int64 = 256 * 1024 * 1024  // 256 MiB KV-cache headroom
        if freeMemoryBytes < minimumRequiredHeadroomBytes {
            return "Insufficient memory headroom: \(freeMemoryBytes / (1024 * 1024)) MiB free, minimum 256 MiB required."
        }

        return nil
    }

    private func executeLoop(timeoutSeconds: Int) async throws -> SubagentResult {
        guard let engine = context.engine else {
            return try await finalizeTerminal(
                status: .failed,
                summary: "No inference engine configured for subagent execution.",
                citations: [],
                unresolved: [SubagentUnresolvedItem(reason: "engineUnavailable", detail: "No engine configured.")],
                roundsExecuted: 0,
                totalTokens: 0,
                transcriptJSON: nil
            )
        }

        // Clamp against host context.maxRounds to honor host limit strictly
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

        // Build system prompt
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
            systemPrompt += "\nScope filter: constrain searches to paths matching: \(filter.joined(separator: ", "))"
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

            // Cumulative parent-turn and per-delegation budget checks
            let parentGen = context.turnTokenAccounting?.cumulativeGeneratedTokens ?? 0
            let parentTotal = context.turnTokenAccounting?.cumulativeTotalTokens ?? 0

            let parentGenRemaining = SubagentLimits.maxGeneratedTokensPerTurn - parentGen - generatedTokens
            let parentTotalRemaining = SubagentLimits.maxTotalTokensPerTurn - parentTotal - totalTokens
            let delegationTotalRemaining = SubagentLimits.maxTokensPerDelegation - totalTokens

            if parentGenRemaining <= 0 || parentTotalRemaining <= 0 || delegationTotalRemaining <= 0 {
                return try await finalizeTerminal(
                    status: .budgetExhausted,
                    summary: finalSummary.isEmpty
                        ? "Subagent reached token budget limit before completion." : finalSummary,
                    citations: (await fence.verifyCitations(claimed: claimedCitations)).verified,
                    unresolved: claimedUnresolved + [
                        SubagentUnresolvedItem(reason: "budgetExhausted", detail: "Exceeded token budget limit.")
                    ],
                    roundsExecuted: roundsExecuted,
                    totalTokens: totalTokens,
                    transcriptJSON: encodeTranscript(transcript)
                )
            }

            // Estimate input tokens from transcript
            var estimatedInputTokens = transcript.reduce(0) { $0 + max(1, $1.text.utf8.count / 3) }
            if estimatedInputTokens > SubagentLimits.maxInputTokensPerRequest {
                transcript = pruneTranscript(transcript)
                transcriptBytes = transcript.reduce(0) { $0 + $1.text.utf8.count }
                estimatedInputTokens = transcript.reduce(0) { $0 + max(1, $1.text.utf8.count / 3) }
                if estimatedInputTokens > SubagentLimits.maxInputTokensPerRequest {
                    return try await finalizeTerminal(
                        status: .budgetExhausted,
                        summary: "Input context exceeded limit (\(estimatedInputTokens) > \(SubagentLimits.maxInputTokensPerRequest)).",
                        citations: (await fence.verifyCitations(claimed: claimedCitations)).verified,
                        unresolved: claimedUnresolved + [
                            SubagentUnresolvedItem(reason: "budgetExhausted", detail: "Input context limit exceeded.")
                        ],
                        roundsExecuted: roundsExecuted,
                        totalTokens: totalTokens,
                        transcriptJSON: encodeTranscript(transcript)
                    )
                }
            }

            roundsExecuted += 1
            let remainingRounds = maxRounds - roundsExecuted
            let isSynthesisPass = remainingRounds == 0

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
                        SubagentUnresolvedItem(reason: "budgetExhausted", detail: "Exceeded generation token limit.")
                    ],
                    roundsExecuted: roundsExecuted - 1,
                    totalTokens: totalTokens,
                    transcriptJSON: encodeTranscript(transcript)
                )
            }

            // Synthesis pass reservation check
            if !isSynthesisPass && maxGenAllowed < 256 {
                return try await finalizeTerminal(
                    status: .budgetExhausted,
                    summary: finalSummary.isEmpty
                        ? "Subagent halted before synthesis due to low token headroom." : finalSummary,
                    citations: (await fence.verifyCitations(claimed: claimedCitations)).verified,
                    unresolved: claimedUnresolved + [
                        SubagentUnresolvedItem(reason: "budgetExhausted", detail: "Insufficient headroom reserved for synthesis.")
                    ],
                    roundsExecuted: roundsExecuted - 1,
                    totalTokens: totalTokens,
                    transcriptJSON: encodeTranscript(transcript)
                )
            }

            let availableTools = isSynthesisPass ? [] : await fence.availableToolSpecs
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
            for try await event in stream {
                try Task.checkCancellation()
                try context.lease.checkValid()

                switch event {
                case .token(let chunk):
                    assistantText += chunk
                    roundStreamTokens += max(1, chunk.utf8.count / 4)
                    if roundStreamTokens > maxGenAllowed || (transcriptBytes + assistantText.utf8.count > SubagentLimits.maxTranscriptBytes) {
                        break
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

            transcript.append(ChatTurn(role: .assistant, text: assistantText))
            transcriptBytes += assistantText.utf8.count

            if transcriptBytes > SubagentLimits.maxTranscriptBytes {
                transcript = pruneTranscript(transcript)
                transcriptBytes = transcript.reduce(0) { $0 + $1.text.utf8.count }
            }

            if isSynthesisPass || toolCalls.isEmpty {
                let parsed = parseModelResponse(assistantText)
                finalSummary = parsed.summary
                claimedCitations.append(contentsOf: parsed.citations)
                claimedUnresolved.append(contentsOf: parsed.unresolved)
                break
            }

            // Execute tool calls
            for call in toolCalls {
                try Task.checkCancellation()
                try context.lease.checkValid()

                let callRequest = ToolCallRequest(
                    tool: call.name,
                    argumentsJSON: call.argumentsJSON
                )
                let toolResult = try await fence.invoke(callRequest)
                let resultContent = toolResult.content

                transcript.append(ChatTurn(role: .tool, text: resultContent))
                transcriptBytes += resultContent.utf8.count

                if transcriptBytes > SubagentLimits.maxTranscriptBytes {
                    transcript = pruneTranscript(transcript)
                    transcriptBytes = transcript.reduce(0) { $0 + $1.text.utf8.count }
                }
            }
        }

        let verified = await fence.verifyCitations(claimed: claimedCitations)
        return try await finalizeTerminal(
            status: .completed,
            summary: finalSummary.isEmpty ? "Subagent completed read-only investigation." : finalSummary,
            citations: verified.verified,
            unresolved: claimedUnresolved + verified.unresolved,
            roundsExecuted: roundsExecuted,
            totalTokens: totalTokens,
            transcriptJSON: encodeTranscript(transcript)
        )
    }

    private func handleCancellationOrTimeout(
        wasTimeout: Bool,
        roundsExecuted: Int = 0,
        totalTokens: Int = 0,
        transcript: [ChatTurn] = [],
        partialSummary: String = "",
        claimedCitations: [SubagentCitationClaim] = [],
        claimedUnresolved: [SubagentUnresolvedItem] = []
    ) async throws -> SubagentResult {
        context.lease.revoke()

        // 5-second shutdown grace period
        let shutdownConfirmationTask = Task {
            try? await Task.sleep(for: .seconds(SubagentLimits.cancellationGracePeriodSeconds))
        }

        transportAborted = true
        shutdownConfirmationTask.cancel()

        let status: SubagentStatus = wasTimeout ? .timedOut : .cancelled
        let reason = wasTimeout ? "timedOut" : "cancelled"
        let summary =
            partialSummary.isEmpty
            ? (wasTimeout
                ? "Subagent delegation timed out before completing synthesis."
                : "Subagent delegation was cancelled by parent turn.")
            : partialSummary

        let verified = await fence.verifyCitations(claimed: claimedCitations)
        let transcriptJSON = encodeTranscript(transcript)

        return try await finalizeTerminal(
            status: status,
            summary: summary,
            citations: verified.verified,
            unresolved: claimedUnresolved + verified.unresolved + [SubagentUnresolvedItem(reason: reason, detail: summary)],
            roundsExecuted: roundsExecuted,
            totalTokens: totalTokens,
            transcriptJSON: transcriptJSON
        )
    }

    private func finalizeTerminal(
        status: SubagentStatus,
        summary: String,
        citations: [SubagentCitation],
        unresolved: [SubagentUnresolvedItem],
        roundsExecuted: Int,
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
            let citationsJson = (try? String(data: encoder.encode(receipt.citations), encoding: .utf8)) ?? "[]"
            let receiptJson = (try? String(data: encoder.encode(receipt), encoding: .utf8)) ?? "{}"

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
                   let committedStatus = SubagentStatus(rawValue: committed.status) {
                    let decoder = JSONDecoder()
                    let committedCitations = (committed.citationsJson?.data(using: .utf8)).flatMap {
                        try? decoder.decode([SubagentCitation].self, from: $0)
                    } ?? []
                    let committedReceipt = SubagentReceipt(
                        runId: committed.id,
                        status: committedStatus,
                        summary: committed.summary ?? "Run terminated concurrently.",
                        citations: committedCitations,
                        unresolved: [SubagentUnresolvedItem(reason: committed.status, detail: committed.summary)],
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
            generated: min(totalTokens, SubagentLimits.maxGeneratedTokensPerRound * max(1, roundsExecuted)),
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
                        pruned[i].text, maxBytes: 1024, notice: "\n[earlier tool output pruned]")
                )
            }
        }
        return pruned
    }

    private struct PersistedTranscriptTurn: Codable {
        let role: String
        let text: String
    }

    private func encodeTranscript(_ turns: [ChatTurn]) -> String? {
        var currentTurns = turns
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        while !currentTurns.isEmpty {
            let simplified = currentTurns.map { PersistedTranscriptTurn(role: $0.role.rawValue, text: $0.text) }
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
                        text: UTF8BoundaryTruncator.truncate(currentTurns[i].text, maxBytes: 256, notice: "\n[pruned for disk limit]")
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

        let fallback = [PersistedTranscriptTurn(role: "system", text: "[transcript pruned to stay within 512 KiB limit]")]
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

    public init() {}

    public func execute(
        task: SubagentTaskBrief,
        context: SubagentExecutionContext
    ) async throws -> SubagentResult {
        let worker = SubagentWorker(task: task, context: context)
        return try await worker.run()
    }
}

public struct SystemLanguageModelBackend: SubagentBackend {
    public let id = "systemLanguageModel"
    public let displayName = "Apple System Language Model (Deferred)"

    public init() {}

    public func execute(
        task: SubagentTaskBrief,
        context: SubagentExecutionContext
    ) async throws -> SubagentResult {
        // Deferred to Stage 2: Apple System Language Model is not yet available for subagent execution.
        // Fails closed immediately without calling the local engine fallback.
        throw CapabilityError.unavailable
    }
}
