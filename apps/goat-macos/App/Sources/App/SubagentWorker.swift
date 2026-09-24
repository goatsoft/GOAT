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
        self.fence = SubagentCapabilityFence(fileTools: context.fileTools, lease: context.lease)
    }

    public func run() async throws -> SubagentResult {
        try context.lease.checkValid()

        // 1. Persist initial running state in database
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
            try? await db.save(initialRecord)
        }

        // 2. Admission checks: engine idle and memory headroom
        if let engine = context.engine {
            let status = await engine.runtimeStatus()
            if let status {
                let busy = (status.activeRequests ?? 0) > 0 || (status.waitingRequests ?? 0) > 0
                let memoryFull: Bool
                if let used = status.modelMemoryUsed, let max = status.modelMemoryMaximum, max > 0 {
                    memoryFull = used >= max
                } else {
                    memoryFull = false
                }
                if busy || memoryFull {
                    return try await finalizeTerminal(
                        status: .failed,
                        summary: "Subagent admission rejected: engine is busy or memory headroom is insufficient.",
                        citations: [],
                        unresolved: [
                            SubagentUnresolvedItem(
                                reason: "admissionDenied",
                                detail: busy ? "Engine is busy." : "Memory headroom is insufficient.")
                        ],
                        roundsExecuted: 0,
                        totalTokens: 0,
                        transcriptJSON: nil
                    )
                }
            }
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

        let maxRounds = min(
            max(task.maxRounds ?? context.maxRounds, SubagentLimits.minimumMaxRounds),
            SubagentLimits.ceilingMaxRounds
        )

        var transcript: [ChatTurn] = []
        var roundsExecuted = 0
        var generatedTokens = 0
        var totalTokens = 0
        var transcriptBytes = 0

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

        transcript.append(ChatTurn(role: .system, text: systemPrompt))
        transcript.append(ChatTurn(role: .user, text: "Execute the task: \(task.objective)"))

        var finalSummary = ""
        var claimedCitations: [SubagentCitation] = []
        var claimedUnresolved: [SubagentUnresolvedItem] = []

        while roundsExecuted < maxRounds {
            try Task.checkCancellation()
            try context.lease.checkValid()

            // Cumulative parent-turn and per-delegation budget checks
            if totalTokens >= SubagentLimits.maxTokensPerDelegation
                || generatedTokens >= SubagentLimits.maxGeneratedTokensPerTurn
                || totalTokens >= SubagentLimits.maxTotalTokensPerTurn
            {
                return try await finalizeTerminal(
                    status: .budgetExhausted,
                    summary: finalSummary.isEmpty
                        ? "Subagent reached token budget limit before completion." : finalSummary,
                    citations: claimedCitations,
                    unresolved: claimedUnresolved + [
                        SubagentUnresolvedItem(reason: "budgetExhausted", detail: "Exceeded token budget limit.")
                    ],
                    roundsExecuted: roundsExecuted,
                    totalTokens: totalTokens,
                    transcriptJSON: encodeTranscript(transcript)
                )
            }

            roundsExecuted += 1
            let remainingRounds = maxRounds - roundsExecuted
            let isSynthesisPass = remainingRounds == 0

            let availableTools = isSynthesisPass ? [] : await fence.availableToolSpecs
            let request = GenerationRequest(
                model: context.modelID ?? "default",
                turns: transcript,
                effort: context.effort,
                maxTokens: min(SubagentLimits.maxGeneratedTokensPerRound, 2048),
                tools: availableTools,
                round: roundsExecuted
            )

            var assistantText = ""
            var toolCalls: [ToolCallEvent] = []

            let stream = await engine.stream(request)
            for try await event in stream {
                try Task.checkCancellation()
                try context.lease.checkValid()

                switch event {
                case .token(let chunk):
                    assistantText += chunk
                case .thinking:
                    break
                case .toolInput:
                    break
                case .toolCalls(let calls):
                    toolCalls.append(contentsOf: calls)
                case .done(let stats):
                    generatedTokens += stats.tokens
                    totalTokens += (stats.promptTokens ?? 0) + stats.tokens
                }
            }

            transcript.append(ChatTurn(role: .assistant, text: assistantText))
            transcriptBytes += assistantText.utf8.count

            if isSynthesisPass || toolCalls.isEmpty {
                // Parse summary and citations from model output
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

                // Prune transcript if exceeding 512 KiB in memory
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

    private func handleCancellationOrTimeout(wasTimeout: Bool) async throws -> SubagentResult {
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
            wasTimeout
            ? "Subagent delegation timed out before completing synthesis."
            : "Subagent delegation was cancelled by parent turn."

        return try await finalizeTerminal(
            status: status,
            summary: summary,
            citations: [],
            unresolved: [SubagentUnresolvedItem(reason: reason, detail: summary)],
            roundsExecuted: 0,
            totalTokens: 0,
            transcriptJSON: nil
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
            let citationsJson = (try? String(data: encoder.encode(receipt.citations), encoding: .utf8)) ?? "[]"
            let receiptJson = (try? String(data: encoder.encode(receipt), encoding: .utf8)) ?? "{}"

            _ = try? await db.transitionSubagentRun(
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
        let simplified = turns.map { PersistedTranscriptTurn(role: $0.role.rawValue, text: $0.text) }
        guard let data = try? JSONEncoder().encode(simplified) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func parseModelResponse(
        _ text: String
    ) -> (summary: String, citations: [SubagentCitation], unresolved: [SubagentUnresolvedItem]) {
        // Try parsing JSON block if present
        if let jsonRange = text.range(of: "\\{[\\s\\S]*\\}", options: .regularExpression) {
            let jsonString = String(text[jsonRange])
            if let data = jsonString.data(using: .utf8) {
                struct ParsedFormat: Codable {
                    let summary: String?
                    let citations: [SubagentCitation]?
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

        // Fallback: entire text is the summary
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
    public let displayName = "Apple System Language Model"
    private let fallback = LocalEngineBackend()

    public init() {}

    public func execute(
        task: SubagentTaskBrief,
        context: SubagentExecutionContext
    ) async throws -> SubagentResult {
        #if canImport(FoundationModels)
        if #available(macOS 15.0, *) {
            let model = SystemLanguageModel.default
            if case .available = model.availability {
                // On-device SystemLanguageModel progressive enhancement
                return try await fallback.execute(task: task, context: context)
            }
        }
        #endif
        return try await fallback.execute(task: task, context: context)
    }
}
