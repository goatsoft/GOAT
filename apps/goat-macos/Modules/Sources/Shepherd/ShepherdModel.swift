import Bleet
import Foundation
import GOATed
import Hoofprint
import Inference
import MCPClient
import Memory
import Observation
import Persistence
import Tools

/// Only explicitly optional remote context may degrade. Local store and invariant failures
/// retain the fail-closed preparation path.
public enum ShepherdMemoryContextError: Error {
    case optionalProviderUnavailable
}

public enum ShepherdToolOrigin: Sendable, Equatable {
    case mcp(MCPServerManager.CapabilityToken)
    case memory(MemoryContext)
    case goated(UUID)
    case extensionTool(ToolHandle)
}

public struct ShepherdToolRoute: Sendable, Equatable {
    public init(server: String, tool: String, origin: ShepherdToolOrigin) {
        self.server = server
        self.tool = tool
        self.origin = origin
    }

    public let server: String
    public let tool: String
    public let origin: ShepherdToolOrigin
}

public enum ShepherdPersistedTurnKind: Sendable, Equatable {
    case regular
    case handoff
}

public struct ShepherdPersistedTurn: Sendable, Equatable {
    public init(
        chatID: UUID, projectID: UUID?, commandMessageID: UUID?, title: String, createdAt: Date,
        kind: ShepherdPersistedTurnKind, messages: [Message]
    ) {
        self.chatID = chatID
        self.projectID = projectID
        self.commandMessageID = commandMessageID
        self.title = title
        self.createdAt = createdAt
        self.kind = kind
        self.messages = messages
    }

    public struct Message: Sendable, Equatable {
        public init(role: ChatTurn.Role, text: String) {
            self.role = role
            self.text = text
        }

        public let role: ChatTurn.Role
        public let text: String
    }

    public let chatID: UUID
    public let projectID: UUID?
    public let commandMessageID: UUID?
    public let title: String
    public let createdAt: Date
    public let kind: ShepherdPersistedTurnKind
    public let messages: [Message]
}

public struct ShepherdPersistedTurnReceipt: Sendable, Equatable {
    public init(message: String, isError: Bool) {
        self.message = message
        self.isError = isError
    }

    public let message: String
    public let isError: Bool
}

/// What the Shepherd needs from the tool layer (MCP today, builtin memory tools in M6).
@MainActor
public protocol ShepherdToolSource: AnyObject {
    func turnWillPrepare(chatID: UUID, projectID: UUID?, turnID: UUID) async throws
    func turnDidEnd(turnID: UUID, cancelled: Bool) async
    func finishPendingWork() async -> String?
    func availableToolSpecs(
        forChatID chatID: UUID,
        projectID: UUID?,
        includeMCP: Bool,
        excludedMCPServers: Set<String>
    ) async -> ([ToolSpec], [String: ShepherdToolRoute])
    func memoryEntries(forProjectID projectID: UUID?) async throws -> [PromptMemoryEntry]
    func extensionPromptSections(
        forChatID chatID: UUID,
        projectID: UUID?,
        canLoadSkills: Bool,
        requestedSkillName: String?
    ) async -> [String]
    /// Runs only after the final assistant row is durable. Implementations must contain failures
    /// so provider write-back cannot turn a completed chat response into a failed turn.
    func turnDidPersist(_ turn: ShepherdPersistedTurn) async -> ShepherdPersistedTurnReceipt?
    func requestName(server: String, tool: String) -> String
    /// Authorization and invocation are one capability-bound operation. Keeping them together
    /// prevents a reconnect from spending approval for one process on its replacement.
    func authorizeAndInvoke(
        route: ShepherdToolRoute, argumentsJSON: String
    ) async throws -> ToolResult?
    func previewToolEffect(
        route: ShepherdToolRoute, argumentsJSON: String
    ) async -> ToolExecutionDiagnostic?
    func logCall(server: String, tool: String, status: String, duration: TimeInterval)
    func cancelPendingPermission()
}

extension ShepherdToolSource {
    public func turnWillPrepare(chatID: UUID, projectID: UUID?, turnID: UUID) async throws {}
    public func turnDidEnd(turnID: UUID, cancelled: Bool) async {}
    public func finishPendingWork() async -> String? { nil }
    public func previewToolEffect(
        route: ShepherdToolRoute, argumentsJSON: String
    ) async -> ToolExecutionDiagnostic? { nil }
}

/// The selected Pen's prompt context. A workspace path describes the intended project;
/// it does not grant filesystem access or change an MCP server's working directory.
public struct ShepherdProjectContext: Sendable {
    public let name: String
    public let instructions: String
    public let agentInstructions: String
    public let workspacePath: String?

    public init(name: String, instructions: String, workspacePath: String? = nil, agentInstructions: String = "") {
        self.name = name
        self.instructions = instructions
        self.agentInstructions = agentInstructions
        self.workspacePath = workspacePath
    }
}

/// What the Shepherd needs from the app: model availability, project instructions,
/// and persistence. Kept narrow so tests can supply fakes.
@MainActor
public protocol ShepherdEnvironment: AnyObject {
    var availableModels: [ModelRef] { get }
    var fallbackModelID: String? { get }
    func generationContext(for modelID: String) -> GenerationContext?
    var automaticChatTitles: Bool { get }
    func projectContext(forProject id: UUID) async -> ShepherdProjectContext?
    @discardableResult
    func persist(_ message: ChatMessage, in session: ChatSession) async -> Bool
    func checkpoint(messageID: String, text: String, thinking: String) async
    func sessionTouched(_ session: ChatSession)
    func sessionMetaChanged(_ session: ChatSession)
    func turnOwnershipChanged(activeSessionID: UUID?)
}

/// The Shepherd: orchestrates one turn - streams a round, executes tool calls behind
/// the permission gate, feeds results back, and continues until completion, failure, or cancellation
/// (ADR-0006). The only place inference, tools, and the transcript meet.
@MainActor
@Observable
public final class ShepherdModel {

    private struct HandoffCommand {
        let messageID: UUID
        let additionalRequest: String

        static let promptSection = """
            <goat_handoff_command>
            The user invoked GOAT's first-class /handoff command. This is a direct application command, not a skill or tool.
            Review the completed conversation and produce a compact handover for the next chat as one fenced Markdown block.
            Include current state, durable decisions, exact next steps, verification already completed, and blockers. Omit empty sections.
            Do not call skill_load, a handoff tool, or any memory tool. GOAT owns durable memory write-back after this response is saved.
            Do not claim whether memory succeeded or failed. Report only the handover content.
            </goat_handoff_command>
            """

        func modelRequest() -> String {
            let base = "Prepare the GOAT session handover now."
            guard !additionalRequest.isEmpty else { return base }
            return "\(base)\n\nAdditional request:\n\(additionalRequest)"
        }

        private static func fencedPayload(in value: String) -> String? {
            let lines = value.components(separatedBy: .newlines)
            var leadingFencePayload: String?

            for openingIndex in lines.indices {
                let openingLine = lines[openingIndex].trimmingCharacters(in: .whitespaces)
                guard let fenceCharacter = openingLine.first,
                    fenceCharacter == "`" || fenceCharacter == "~"
                else { continue }
                let fenceLength = openingLine.prefix { $0 == fenceCharacter }.count
                guard fenceLength >= 3 else { continue }
                let infoStart = openingLine.index(openingLine.startIndex, offsetBy: fenceLength)
                let info = openingLine[infoStart...]
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()

                for closingIndex in lines.indices where closingIndex > openingIndex {
                    let closingLine = lines[closingIndex].trimmingCharacters(in: .whitespaces)
                    let closingLength = closingLine.prefix { $0 == fenceCharacter }.count
                    guard closingLength >= fenceLength else { continue }
                    let closingRemainderStart = closingLine.index(
                        closingLine.startIndex, offsetBy: closingLength)
                    guard
                        closingLine[closingRemainderStart...]
                            .trimmingCharacters(in: .whitespaces).isEmpty
                    else { continue }

                    let payload = lines[(openingIndex + 1)..<closingIndex]
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if info == "markdown" || info == "md" {
                        return payload
                    }
                    if openingIndex == lines.startIndex, leadingFencePayload == nil {
                        leadingFencePayload = payload
                    }
                    break
                }
            }
            return leadingFencePayload
        }

        static func fencedMarkdown(_ value: String, date: Date) -> String {
            var body = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let payload = fencedPayload(in: body) {
                body = payload
            }
            var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if let first = lines.first?.trimmingCharacters(in: .whitespaces),
                first.hasPrefix("# "), first.lowercased().contains("handover")
            {
                lines.removeFirst()
                while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                    lines.removeFirst()
                }
            }
            body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let heading = "# Handover \(date.formatted(date: .abbreviated, time: .shortened))"
            let document = body.isEmpty ? heading : "\(heading)\n\n\(body)"
            var longestRun = 0
            var currentRun = 0
            for character in document {
                if character == "`" {
                    currentRun += 1
                    longestRun = max(longestRun, currentRun)
                } else {
                    currentRun = 0
                }
            }
            let fence = String(repeating: "`", count: max(3, longestRun + 1))
            return "\(fence)markdown\n\(document)\n\(fence)"
        }
    }

    private let tools: ShepherdToolSource
    private let activity: ActivityLog
    private let worker: ShepherdGenerationWorker
    public weak var env: ShepherdEnvironment?
    public private(set) var streamTask: Task<Void, Never>?
    public private(set) var activeTurnID: UUID?
    public private(set) var activeSessionID: UUID?
    private weak var activeSession: ChatSession?
    public private(set) var acceptsLead = false
    public private(set) var pendingLeadCount = 0
    private var leadSave: Task<Bool, Never>?
    private var leadSaveID: UUID?
    private var leadRevision = 0
    private var appliedLeadRevision = 0

    /// Persist follow-up text before making it available to the active turn.
    public func lead(_ text: String, in session: ChatSession) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard acceptsLead, activeSessionID == session.id, let env,
            leadSave == nil, !text.isEmpty, text.utf8.count <= 32_768,
            pendingLeadCount < 8, streamTask?.isCancelled == false
        else { return false }
        let message = ChatMessage(role: .user)
        message.text = text
        session.messages.append(message)
        // Save a complete row while keeping the visible message out of prompt snapshots
        // until the durability barrier finishes. Identity and transcript position are shared.
        let durable = ChatMessage(role: .user, id: message.id, createdAt: message.createdAt)
        durable.text = text
        durable.complete = true
        let save = Task { @MainActor in
            guard await env.persist(durable, in: session) else {
                session.messages.removeAll { $0.id == message.id }
                return false
            }
            message.complete = true
            self.leadRevision += 1
            self.pendingLeadCount += 1
            env.sessionTouched(session)
            return true
        }
        let saveID = UUID()
        leadSaveID = saveID
        leadSave = save
        let saved = await save.value
        if leadSaveID == saveID {
            leadSave = nil
            leadSaveID = nil
        }
        return saved
    }

    private func drainLeadSave() async {
        while let save = leadSave {
            let saveID = leadSaveID
            _ = await save.value
            if leadSaveID == saveID {
                leadSave = nil
                leadSaveID = nil
            }
        }
    }

    public init(engine: any InferenceEngine, tools: ShepherdToolSource, activity: ActivityLog) {
        self.tools = tools
        self.activity = activity
        worker = ShepherdGenerationWorker(engine: engine)
    }

    public var hasActiveTurn: Bool { activeSessionID != nil }

    /// Claim the single app-wide generation slot before any asynchronous preparation begins.
    /// This closes the double-send and cross-chat races described by ADR-0023.
    @discardableResult
    public func reserve(in session: ChatSession) -> UUID? {
        guard activeSessionID == nil, streamTask == nil else { return nil }
        let turnID = UUID()
        activeTurnID = turnID
        activeSessionID = session.id
        activeSession = session
        session.isStreaming = true
        env?.turnOwnershipChanged(activeSessionID: session.id)
        return turnID
    }

    /// Cancel only the turn owned by `sessionID`. Passing nil targets the current owner and is
    /// reserved for the app-wide Stop command.
    public func stop(sessionID: UUID? = nil, turnID expectedTurnID: UUID? = nil) {
        guard let activeSessionID, let activeTurnID,
            sessionID == nil || sessionID == activeSessionID,
            expectedTurnID == nil || expectedTurnID == activeTurnID
        else { return }
        acceptsLead = false
        tools.cancelPendingPermission()
        if let streamTask {
            streamTask.cancel()
        } else {
            releaseReservation(turnID: activeTurnID, sessionID: activeSessionID)
        }
    }

    @discardableResult
    public func run(in session: ChatSession) -> Bool {
        guard let turnID = reserve(in: session) else { return false }
        startReserved(in: session, turnID: turnID)
        return true
    }

    /// Start a turn whose slot was claimed by `reserve(in:)`. AppModel uses this after attachment
    /// persistence so the slot is owned throughout preparation as well as generation.
    public func startReserved(in session: ChatSession, turnID: UUID) {
        guard owns(turnID: turnID, sessionID: session.id), streamTask == nil else { return }
        guard let env, let requestedModelID = session.modelID ?? env.fallbackModelID else {
            releaseReservation(turnID: turnID, sessionID: session.id)
            return
        }
        guard let model = env.availableModels.first(where: { $0.id == requestedModelID }),
            let context = env.generationContext(for: requestedModelID)
        else {
            activity.log(.warn, "Model \(requestedModelID) is unavailable or needs compatibility review")
            releaseReservation(turnID: turnID, sessionID: session.id)
            return
        }
        activity.log(.engine, "→ \(model.displayName) · \(session.effort.label)")

        acceptsLead = true
        streamTask = Task {
            await executeTurn(in: session, turnID: turnID, model: model, context: context, env: env)
            acceptsLead = false
            await drainLeadSave()
            if leadRevision != appliedLeadRevision {
                let notice = ChatMessage(role: .assistant)
                notice.error =
                    "The agent stopped before applying your Lead instruction. It is saved in this chat; send a message to continue."
                notice.complete = true
                session.messages.append(notice)
                await env.persist(notice, in: session)
            }
            await tools.turnDidEnd(turnID: turnID, cancelled: Task.isCancelled)
            releaseReservation(turnID: turnID, sessionID: session.id)
        }
    }

    private func executeTurn(
        in session: ChatSession, turnID: UUID, model: ModelRef,
        context: GenerationContext, env: ShepherdEnvironment
    ) async {
        do {
            try await tools.turnWillPrepare(chatID: session.id, projectID: session.projectID, turnID: turnID)
        } catch is CancellationError { return } catch {
            await recordPromptFailure(error, in: session, env: env)
            return
        }
        let memory: [PromptMemoryEntry]
        do {
            memory = try await tools.memoryEntries(forProjectID: session.projectID)
        } catch is CancellationError {
            return
        } catch ShepherdMemoryContextError.optionalProviderUnavailable {
            memory = []
            activity.log(.warn, "Hindsight context unavailable. Continuing this chat without memory.")
        } catch {
            guard owns(turnID: turnID, sessionID: session.id), !Task.isCancelled else { return }
            await recordPromptFailure(error, in: session, env: env)
            return
        }
        guard owns(turnID: turnID, sessionID: session.id), !Task.isCancelled else { return }
        let handoffCommand = Self.handoffCommand(in: session)
        let requestedSkillName = handoffCommand == nil ? Self.requestedSkillName(in: session) : nil
        let extensionSections =
            await tools.extensionPromptSections(
                forChatID: session.id,
                projectID: session.projectID,
                canLoadSkills: handoffCommand == nil && model.capabilities.tools.support != .unsupported,
                requestedSkillName: requestedSkillName)
            + (handoffCommand == nil ? [] : [HandoffCommand.promptSection])
        var repairedToolFormat = false
        var repairNextRound = false
        var repairProgress = FileRepairProgressTracker()
        shepherd: while true {
            guard owns(turnID: turnID, sessionID: session.id), !Task.isCancelled else { break }
            await drainLeadSave()
            let plannedLeadRevision = leadRevision
            let (specs, mapping) =
                handoffCommand == nil && model.capabilities.tools.support != .unsupported
                ? await tools.availableToolSpecs(
                    forChatID: session.id,
                    projectID: session.projectID,
                    includeMCP: session.toolsEnabled,
                    excludedMCPServers: session.disabledMCPServers)
                : ([], [:])
            guard owns(turnID: turnID, sessionID: session.id), !Task.isCancelled else { break }
            let snapshot = await promptSnapshot(
                for: session,
                extensionSections: extensionSections + (repairNextRound ? [Self.toolFormatRecoveryPrompt] : []),
                requestedSkillName: requestedSkillName,
                handoffCommand: handoffCommand)
            guard owns(turnID: turnID, sessionID: session.id), !Task.isCancelled else { break }
            let plan: PromptPlan
            do {
                plan = try await worker.plan(
                    snapshot: snapshot,
                    model: model,
                    effort: session.effort,
                    tools: specs,
                    memory: memory,
                    compatibility: context.compatibility)
            } catch {
                guard owns(turnID: turnID, sessionID: session.id), !Task.isCancelled else {
                    break shepherd
                }
                await recordPromptFailure(error, in: session, env: env)
                break shepherd
            }
            guard owns(turnID: turnID, sessionID: session.id), !Task.isCancelled else { break }
            await drainLeadSave()
            guard !Task.isCancelled else { break }
            if plannedLeadRevision != leadRevision { continue }
            repairNextRound = false
            appliedLeadRevision = plannedLeadRevision
            pendingLeadCount = 0
            applyPreflight(plan.report, to: session)
            if !plan.request.tools.isEmpty {
                activity.log(
                    .info,
                    "tools: \(plan.request.tools.count) schemas (~\(plan.report.breakdownAfter.toolSchemas) tok)"
                )
            }
            let assistant = ChatMessage(role: .assistant)
            assistant.generationContext = context
            assistant.generationParameters = EffectiveGenerationParameters(request: plan.request)
            assistant.generationSelectedEffort = session.effort.rawValue
            assistant.generationLifecycle = GenerationProvenanceRecord.Lifecycle.prepared.rawValue
            session.messages.append(assistant)
            // The first incomplete row is a durability barrier. A checkpoint can only run
            // after this insert succeeds, so a fast stream never checkpoints a missing row.
            guard await env.persist(assistant, in: session) else {
                assistant.error = "The response could not start because persistence is unavailable."
                assistant.complete = true
                assistant.markRenderChanged()
                activity.log(.warn, "persistence: initial assistant row was not saved")
                break shepherd
            }
            await drainLeadSave()
            if !Task.isCancelled, leadRevision != appliedLeadRevision {
                assistant.complete = true
                assistant.error = "This response was superseded by Lead before generation started."
                assistant.markRenderChanged()
                guard await env.persist(assistant, in: session) else { break shepherd }
                continue shepherd
            }
            let request = plan.request
            assistant.generationLifecycle = GenerationProvenanceRecord.Lifecycle.started.rawValue
            guard await env.persist(assistant, in: session) else {
                assistant.generationLifecycle = GenerationProvenanceRecord.Lifecycle.failed.rawValue
                assistant.error = "The response could not start because persistence is unavailable."
                assistant.complete = true
                assistant.markRenderChanged()
                break shepherd
            }

            @MainActor func finishPendingToolsAsStopped(unknownIndex: Int? = nil) async {
                for index in assistant.toolEvents.indices
                where assistant.toolEvents[index].result == nil {
                    assistant.toolEvents[index].result =
                        index == unknownIndex
                        ? "Stopped while this tool was pending. Its outcome is unknown. Inspect the file or process state before retrying; it may already have completed."
                        : "Not executed because the turn was stopped."
                    assistant.toolEvents[index].isError = true
                }
                assistant.markRenderChanged()
                if !(await env.persist(assistant, in: session)) {
                    assistant.error = "The stopped response could not be saved."
                    assistant.markRenderChanged()
                    activity.log(.warn, "persistence: stopped tool state was not saved")
                }
            }

            let streamResult: ShepherdStreamResult
            do {
                streamResult = try await worker.stream(request) { update in
                    guard self.owns(turnID: turnID, sessionID: session.id) else {
                        return false
                    }
                    self.apply(update, to: assistant)
                    if update.shouldCheckpoint, !Task.isCancelled {
                        await env.checkpoint(
                            messageID: assistant.id.uuidString,
                            text: assistant.text,
                            thinking: assistant.thinking)
                    }
                    return self.owns(turnID: turnID, sessionID: session.id)
                        && !Task.isCancelled
                }
            } catch {
                if Task.isCancelled || !owns(turnID: turnID, sessionID: session.id) {
                    assistant.generationLifecycle = GenerationProvenanceRecord.Lifecycle.cancelled.rawValue
                    assistant.generationFailureCategory = GenerationProvenanceRecord.FailureCategory.cancelled.rawValue
                    assistant.error = "Stopped by you before the response finished."
                    assistant.complete = true
                    assistant.markRenderChanged()
                    await env.persist(assistant, in: session)
                    break shepherd
                }
                assistant.generationLifecycle = GenerationProvenanceRecord.Lifecycle.failed.rawValue
                assistant.generationFailureCategory = Self.failureCategory(for: error).rawValue
                assistant.error = (error as? EngineError)?.userFacingFailureDescription ?? error.localizedDescription
                assistant.complete = true
                assistant.markRenderChanged()
                await env.persist(assistant, in: session)
                activity.log(.warn, "engine: \(error.localizedDescription)")
                break shepherd
            }

            let toolCalls = streamResult.toolCalls
            assistant.stats = streamResult.stats
            assistant.generationLifecycle = GenerationProvenanceRecord.Lifecycle.completed.rawValue
            assistant.text = assistant.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if handoffCommand != nil {
                assistant.text = HandoffCommand.fencedMarkdown(assistant.text, date: .now)
            }
            if assistant.thinkingStartedAt != nil, assistant.thinkingEndedAt == nil {
                assistant.thinkingEndedAt = .now
            }
            assistant.complete = true
            assistant.markRenderChanged()
            if let s = assistant.stats {
                let tokenApprox = s.tokensAreExact ? "" : "~"
                let speedApprox = s.speedIsServerReported ? "" : "~"
                activity.log(
                    .engine,
                    "\(tokenApprox)\(s.tokens) tok · \(speedApprox)\(Int(s.toksPerSec)) tok/s\(s.ttft.map { String(format: " · %.1fs ttft", $0) } ?? "")"
                )
            }
            updateContextGauge(
                session, report: plan.report, stats: assistant.stats,
                reply: assistant.text + assistant.thinking)

            if assistant.stats?.finishReason == "length" {
                assistant.error =
                    "The model reached its output limit. This response may be incomplete; no tool calls from this response were run. Send a message to continue."
                assistant.markRenderChanged()
                await env.persist(assistant, in: session)
                break shepherd
            }

            if toolCalls.isEmpty,
                Self.hasUnexecutedToolMarkup(assistant.text, toolNames: Set(specs.map(\.name)))
            {
                assistant.generationFailureCategory = GenerationProvenanceRecord.FailureCategory.toolFormatRecovery.rawValue
                let canRetry = !repairedToolFormat && !Task.isCancelled
                assistant.error =
                    canRetry
                    ? "The model printed a tool call without executing it. Retrying the tool-call format once."
                    : "The engine returned tool-call markup as ordinary text. No tool was executed from this response. Check the engine's tool-call parser and the model's chat template."
                assistant.markRenderChanged()
                guard await env.persist(assistant, in: session) else {
                    assistant.error = "Tool-format recovery stopped because the response could not be saved."
                    assistant.markRenderChanged()
                    break shepherd
                }
                guard canRetry else { break shepherd }
                // The failed row is excluded from prompt history. Only a fresh structured
                // call can reach the existing authorization and filesystem checks.
                repairedToolFormat = true
                repairNextRound = true
                activity.log(.warn, "tools: retrying unexecuted tool-call format once")
                continue shepherd
            }

            if toolCalls.isEmpty || Task.isCancelled {
                await drainLeadSave()
                if !Task.isCancelled, leadRevision != appliedLeadRevision {
                    guard await env.persist(assistant, in: session) else { break shepherd }
                    continue shepherd
                }
                acceptsLead = false
                if Task.isCancelled {
                    assistant.generationLifecycle = GenerationProvenanceRecord.Lifecycle.cancelled.rawValue
                    assistant.generationFailureCategory = GenerationProvenanceRecord.FailureCategory.cancelled.rawValue
                    assistant.error = "Stopped by you before the turn finished."
                } else if assistant.text.isEmpty {
                    assistant.error =
                        "The model ended without a final reply. Any completed tool actions are shown above. Send a message to continue."
                }
                assistant.markRenderChanged()
                let finalPersisted = await env.persist(assistant, in: session)
                if !finalPersisted {
                    assistant.error = "The completed response could not be saved."
                    assistant.markRenderChanged()
                    activity.log(.warn, "persistence: completed assistant row was not saved")
                } else if !Task.isCancelled, assistant.error == nil,
                    let persistedTurn = Self.persistedTurn(
                        from: session,
                        handoffCommand: handoffCommand)
                {
                    let receipt = await tools.turnDidPersist(persistedTurn)
                    if handoffCommand != nil, let receipt {
                        assistant.toolEvents.append(
                            ToolEventSnapshot(
                                id: "goat-handoff-memory-\(assistant.id.uuidString.lowercased())",
                                server: "Memory",
                                tool: "memory_handoff",
                                arguments: "{}",
                                result: receipt.message,
                                isError: receipt.isError))
                        assistant.markRenderChanged()
                        if !(await env.persist(assistant, in: session)) {
                            activity.log(.warn, "persistence: handoff memory receipt was not saved")
                        }
                    }
                }
                break shepherd
            }

            // Execute the round's tools, permission-gated, sequentially.
            assistant.toolEvents = toolCalls.map { call in
                let target = mapping[call.name]
                return ToolEventSnapshot(
                    id: call.id,
                    server: target?.server ?? "?",
                    tool: target?.tool ?? call.name,
                    arguments: call.argumentsJSON
                )
            }
            assistant.markRenderChanged()
            guard await env.persist(assistant, in: session) else {
                assistant.error = "Tool calls were not run because their transcript could not be saved."
                assistant.markRenderChanged()
                activity.log(.warn, "persistence: tool-call transcript was not saved")
                break shepherd
            }

            if !Task.isCancelled { await autoTitle(session, model: model, context: context) }
            for (index, call) in toolCalls.enumerated() {
                await drainLeadSave()
                // Finish the current response's first tool step, including its approval.
                // Lead takes effect between actions; Stop owns cancellation.
                if index > 0, !Task.isCancelled, leadRevision != appliedLeadRevision {
                    for pending in assistant.toolEvents.indices where assistant.toolEvents[pending].result == nil {
                        assistant.toolEvents[pending].result =
                            "Not executed because a Lead instruction changed the request."
                        assistant.toolEvents[pending].isError = true
                    }
                    assistant.markRenderChanged()
                    guard await env.persist(assistant, in: session) else { break shepherd }
                    continue shepherd
                }
                guard owns(turnID: turnID, sessionID: session.id), !Task.isCancelled else {
                    await finishPendingToolsAsStopped()
                    break shepherd
                }
                guard let target = mapping[call.name] else {
                    assistant.toolEvents[index].result = "Unknown tool: \(call.name)"
                    assistant.toolEvents[index].isError = true
                    assistant.markRenderChanged()
                    guard await env.persist(assistant, in: session) else {
                        assistant.error = "Tool processing stopped because its transcript could not be saved."
                        assistant.markRenderChanged()
                        activity.log(.warn, "persistence: unknown-tool result was not saved")
                        break shepherd
                    }
                    continue
                }
                if let preview = await tools.previewToolEffect(
                    route: target, argumentsJSON: call.argumentsJSON),
                    let blocked = repairProgress.preflight(preview)
                {
                    assistant.toolEvents[index].result = blocked
                    assistant.toolEvents[index].isError = true
                    assistant.error = blocked
                    assistant.markRenderChanged()
                    guard await env.persist(assistant, in: session) else { break shepherd }
                    break shepherd
                }
                let started = Date()
                var repairStop: String?
                do {
                    let result = try await tools.authorizeAndInvoke(
                        route: target, argumentsJSON: call.argumentsJSON)
                    // A provider may finish a write as Stop arrives. Preserve its known result
                    // before sealing unstarted calls; cancellation does not undo a committed action.
                    if let result {
                        assistant.toolEvents[index].result = result.content
                        assistant.toolEvents[index].isError = result.isError
                        if let diagnostic = result.diagnostic {
                            repairStop = repairProgress.observe(diagnostic)
                        }
                        assistant.markRenderChanged()
                        tools.logCall(
                            server: target.server, tool: target.tool,
                            status: result.isError ? "error" : "ok",
                            duration: Date().timeIntervalSince(started))
                    } else if Task.isCancelled || !owns(turnID: turnID, sessionID: session.id) {
                        await finishPendingToolsAsStopped(unknownIndex: index)
                        break shepherd
                    } else {
                        assistant.toolEvents[index].denied = true
                        assistant.toolEvents[index].isError = true
                        assistant.toolEvents[index].result = "User denied this tool call."
                        assistant.markRenderChanged()
                        tools.logCall(
                            server: target.server, tool: target.tool, status: "denied", duration: 0)
                    }
                } catch {
                    guard owns(turnID: turnID, sessionID: session.id), !Task.isCancelled else {
                        await finishPendingToolsAsStopped(unknownIndex: index)
                        break shepherd
                    }
                    assistant.toolEvents[index].result = error.localizedDescription
                    assistant.toolEvents[index].isError = true
                    assistant.markRenderChanged()
                    tools.logCall(
                        server: target.server, tool: target.tool, status: "error",
                        duration: Date().timeIntervalSince(started))
                }
                guard await env.persist(assistant, in: session) else {
                    assistant.error = "Tool processing stopped because its result could not be saved."
                    assistant.markRenderChanged()
                    activity.log(.warn, "persistence: tool result was not saved")
                    break shepherd
                }
                if let repairStop {
                    assistant.error = repairStop
                    assistant.markRenderChanged()
                    _ = await env.persist(assistant, in: session)
                    break shepherd
                }
                if Task.isCancelled || !owns(turnID: turnID, sessionID: session.id) {
                    await finishPendingToolsAsStopped()
                    break shepherd
                }
            }
            if !Task.isCancelled { await autoTitle(session, model: model, context: context) }
            // Loop: next round streams a fresh assistant message with the results in context.
        }
        acceptsLead = false
        if let warning = await tools.finishPendingWork() {
            let notice = ChatMessage(role: .assistant)
            notice.error = warning
            notice.complete = true
            session.messages.append(notice)
            await env.persist(notice, in: session)
        }
        env.sessionTouched(session)
        if owns(turnID: turnID, sessionID: session.id), !Task.isCancelled,
            env.automaticChatTitles, session.hasDefaultTitle
        {
            // Tool workflows may finish with an empty assistant message. autoTitle selects
            // the first usable reply from the exchange instead of requiring final-round text.
            await autoTitle(session, model: model, context: context)
        }
    }

    private func owns(turnID: UUID, sessionID: UUID) -> Bool {
        activeTurnID == turnID && activeSessionID == sessionID
    }

    private static let toolFormatRecoveryPrompt = """
        The last response printed a tool invocation as text. Use the supplied structured tool interface with its exact function names and JSON schemas. Do not print tool envelopes. Do not repeat actions with completed results.
        If the user only asked for an explanation, answer normally and put illustrative syntax inside a fenced code block. Do not claim that an action happened without a successful tool result.
        """

    static func hasUnexecutedToolMarkup(_ text: String, toolNames: Set<String>) -> Bool {
        UnexecutedToolMarkupDetector.detect(text, toolNames: toolNames)?.confidence == .high
    }

    private static func failureCategory(for error: Error) -> GenerationProvenanceRecord.FailureCategory {
        guard let engineError = error as? EngineError else { return .unknown }
        switch engineError.classification {
        case .modelUnavailable, .unsupportedModelArchitecture: return .unavailableModel
        case .authentication, .connection, .malformedResponse, .unknown, .none: return .engine
        }
    }

    private func releaseReservation(turnID: UUID, sessionID: UUID) {
        guard activeTurnID == turnID, activeSessionID == sessionID else { return }
        acceptsLead = false
        pendingLeadCount = 0
        leadRevision = 0
        appliedLeadRevision = 0
        activeSession?.isStreaming = false
        activeSession = nil
        activeTurnID = nil
        activeSessionID = nil
        streamTask = nil
        env?.turnOwnershipChanged(activeSessionID: nil)
    }

    private func apply(_ update: ShepherdStreamUpdate, to assistant: ChatMessage) {
        if !update.thinking.isEmpty, assistant.thinkingStartedAt == nil {
            assistant.thinkingStartedAt = .now
        }
        if !update.text.isEmpty {
            if assistant.thinkingStartedAt != nil, assistant.thinkingEndedAt == nil {
                assistant.thinkingEndedAt = .now  // first visible token ends the rumination
            }
        }
        RenderSignposts.measure("StreamPublication") {
            assistant.appendStream(text: update.text, thinking: update.thinking, toolInputBytes: update.toolInputBytes)
        }
    }

    private func applyPreflight(_ report: PromptBudgetReport, to session: ChatSession) {
        session.lastContextTokens = report.estimatedInputTokensAfter
        session.contextIsExact = false
        session.lastContextWindow = report.windowTokens
        session.contextWindowIsExact = report.windowSource == .reported
        session.lastContextPressureLimit = report.inputBudget
        session.lastPromptWasTrimmed = report.didTrim
        let currentUser = session.messages.last(where: { $0.role == .user })
        currentUser?.contextNotice = nil
        guard report.didTrim else { return }

        var changes: [String] = []
        if report.droppedExchangeCount > 0 {
            changes.append(
                "\(report.droppedExchangeCount) older exchange\(report.droppedExchangeCount == 1 ? "" : "s")")
        }
        if !report.textTruncations.isEmpty {
            changes.append("\(report.textTruncations.count) long field\(report.textTruncations.count == 1 ? "" : "s")")
        }
        if !report.omittedImages.isEmpty {
            changes.append("\(report.omittedImages.count) image\(report.omittedImages.count == 1 ? "" : "s")")
        }
        if !changes.isEmpty {
            currentUser?.contextNotice =
                "Context trimmed to fit: " + changes.joined(separator: ", ") + "."
        }
        activity.log(
            .info,
            "context: ~\(report.estimatedInputTokensBefore) → ~\(report.estimatedInputTokensAfter) input tok, \(report.droppedExchangeCount) exchanges dropped, \(report.textTruncations.count) fields truncated, \(report.omittedImages.count) images omitted, \(report.omittedMemoryEntries.count) memory summaries omitted"
        )
    }

    private func recordPromptFailure(
        _ error: Error, in session: ChatSession, env: ShepherdEnvironment
    ) async {
        let assistant = ChatMessage(role: .assistant)
        assistant.error = error.localizedDescription
        assistant.complete = true
        assistant.markRenderChanged()
        session.messages.append(assistant)
        await env.persist(assistant, in: session)
        session.lastPromptWasTrimmed = false
        if let failure = error as? PromptBudgetFailure {
            session.lastContextWindow = failure.report.windowTokens
            session.contextWindowIsExact = failure.report.windowSource == .reported
            session.lastContextPressureLimit = max(1, failure.report.inputBudget)
            session.lastContextTokens = failure.report.estimatedInputTokensAfter
            session.contextIsExact = false
            session.messages.last(where: { $0.role == .user })?.contextNotice =
                "This prompt could not fit the model's context window."
            activity.log(
                .warn,
                "prompt budget: \(failure.component.rawValue), ~\(failure.report.estimatedInputTokensAfter)/\(failure.report.inputBudget) input tok"
            )
        } else {
            activity.log(.warn, "prompt budget: \(error.localizedDescription)")
        }
    }

    /// Feed the pasture meter: prefer complete server usage; otherwise retain the
    /// planner's full-request estimate and estimate only the reply.
    private func updateContextGauge(
        _ session: ChatSession, report: PromptBudgetReport,
        stats: GenStats?, reply: String
    ) {
        if let stats, let prompt = stats.promptTokens, stats.tokensAreExact {
            let sum = prompt.addingReportingOverflow(stats.tokens)
            session.lastContextTokens = sum.overflow ? Int.max : sum.partialValue
            session.contextIsExact = true
        } else {
            let prompt = stats?.promptTokens ?? report.estimatedInputTokensAfter
            let completion = stats?.tokens ?? ((reply.utf8.count + 2) / 3)
            let sum = prompt.addingReportingOverflow(completion)
            session.lastContextTokens = sum.overflow ? Int.max : sum.partialValue
            session.contextIsExact = false
        }
        session.lastContextWindow = report.windowTokens
        session.contextWindowIsExact = report.windowSource == .reported
        session.lastContextPressureLimit = report.windowTokens
        session.lastPromptWasTrimmed = report.didTrim
    }

    // MARK: Prompt assembly

    private static func requestedSkillName(in session: ChatSession) -> String? {
        guard let text = session.messages.last(where: { $0.role == .user })?.text else { return nil }
        return SkillCommand.invocationName(in: text)
    }

    private static func handoffCommand(in session: ChatSession) -> HandoffCommand? {
        guard let message = session.messages.last(where: { $0.role == .user }) else { return nil }
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "/handoff" || trimmed.hasPrefix("/handoff ") else { return nil }
        let additionalRequest = String(trimmed.dropFirst("/handoff".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return HandoffCommand(messageID: message.id, additionalRequest: additionalRequest)
    }

    private static func persistedTurn(
        from session: ChatSession,
        handoffCommand: HandoffCommand?
    ) -> ShepherdPersistedTurn? {
        let messages = session.messages.compactMap { message -> ShepherdPersistedTurn.Message? in
            guard message.complete, message.error == nil,
                message.role == .user || message.role == .assistant
            else { return nil }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ShepherdPersistedTurn.Message(role: message.role, text: text)
        }
        guard messages.last?.role == .assistant else { return nil }
        return ShepherdPersistedTurn(
            chatID: session.id,
            projectID: session.projectID,
            commandMessageID: handoffCommand?.messageID,
            title: session.title,
            createdAt: .now,
            kind: handoffCommand == nil ? .regular : .handoff,
            messages: messages)
    }

    private func promptSnapshot(
        for session: ChatSession,
        extensionSections: [String] = [],
        requestedSkillName: String? = nil,
        handoffCommand: HandoffCommand? = nil
    ) async -> ShepherdPromptSnapshot {
        var project: ShepherdProjectContext?
        if let projectID = session.projectID {
            project = await env?.projectContext(forProject: projectID)
        }

        let latestUserIndex = session.messages.lastIndex(where: { $0.role == .user })
        let messages = session.messages.enumerated().map { index, message in
            let text =
                if let handoffCommand, message.id == handoffCommand.messageID {
                    handoffCommand.modelRequest()
                } else if index == latestUserIndex, let requestedSkillName {
                    SkillCommand.modelRequest(
                        in: message.text,
                        invokedSkill: requestedSkillName)
                } else {
                    message.text
                }
            return ShepherdPromptSnapshot.Message(
                role: message.role,
                text: text,
                thinking: message.thinking,
                complete: message.complete,
                error: message.error,
                attachmentPaths: message.attachmentPaths,
                toolEvents: message.toolEvents.map { event in
                    ShepherdPromptSnapshot.ToolEvent(
                        id: event.id,
                        requestName: tools.requestName(
                            server: event.server,
                            tool: event.tool),
                        arguments: event.arguments,
                        result: event.result, isError: event.isError, denied: event.denied)
                })
        }
        return ShepherdPromptSnapshot(
            date: .now,
            project: project,
            extensionSections: extensionSections,
            messages: messages)
    }

    public func turns(for session: ChatSession) async -> [ChatTurn] {
        let handoffCommand = Self.handoffCommand(in: session)
        let snapshot = await promptSnapshot(
            for: session,
            extensionSections: handoffCommand == nil ? [] : [HandoffCommand.promptSection],
            requestedSkillName: handoffCommand == nil ? Self.requestedSkillName(in: session) : nil,
            handoffCommand: handoffCommand)
        return await worker.turns(for: snapshot)
    }

    private func autoTitle(
        _ session: ChatSession, model: ModelRef, context: GenerationContext
    ) async {
        guard env?.automaticChatTitles == true, session.hasDefaultTitle,
            let firstUser = session.messages.first(where: { $0.role == .user })?.text
        else { return }
        let replies = session.messages.filter { $0.role == .assistant && $0.error == nil }
        let firstReply = replies.first(where: {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.text
        let hasCompletedTool = replies.contains { reply in
            reply.toolEvents.contains { $0.result != nil && !$0.isError && !$0.denied }
        }
        guard firstReply != nil || hasCompletedTool else { return }
        let titleRevision = session.titleRevision
        let prompt =
            "Write a 3-5 word title for this conversation. Reply with ONLY the title - no quotes, no punctuation at the end.\n\nUser: \(firstUser.prefix(300))\nAssistant: \((firstReply ?? "Completed tool actions for the user's request.").prefix(300))"
        let request = GenerationRequest(
            model: model.id,
            turns: [ChatTurn(role: .user, text: prompt)],
            effort: .graze,
            // Some configured models spend their output budget on reasoning before the title.
            maxTokens: 1024,
            modelCapabilities: model.capabilities,
            compatibility: context.compatibility
        )
        var generated = ""
        do {
            let plan = try await worker.plan(request, model: model)
            generated = try await worker.completeText(for: plan.request)
        } catch {
            guard !Task.isCancelled else { return }
            activity.log(.warn, "chat naming: title request failed; using the opening message")
        }
        guard !Task.isCancelled, session.hasDefaultTitle,
            session.titleRevision == titleRevision, env?.automaticChatTitles == true
        else { return }
        let title = generated.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”."))
        let usable =
            !title.isEmpty && title.count <= 60 && !title.contains(where: \.isNewline)
            && title.lowercased() != "new chat"
        let fallback = String(
            firstUser.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ").prefix(60))
        guard usable || !fallback.isEmpty else { return }
        session.title = usable ? title : fallback
        env?.sessionMetaChanged(session)
    }
}
