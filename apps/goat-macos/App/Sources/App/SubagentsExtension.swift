import Foundation
import GOATed
import Inference
import Pens
import Persistence
import Tools

public struct SubagentsExtension: Extension {
    public let manifest = ExtensionManifest(id: "goat.subagents", version: "0.1.0")
    public let contributions: ExtensionContributions

    public init(provider: SubagentsProvider) {
        contributions = ExtensionContributions(tools: [provider], observers: [provider])
    }
}

public actor SubagentsProvider: ModelToolProvider, TurnObserver {
    public static let toolName = "subagent_delegate"
    public static let toolDescription =
        "Delegates a read-only code search and investigation task to a subagent assistant within the Pen workspace."
    public static let toolInputSchemaJSON = """
        {
          "type": "object",
          "required": ["objective"],
          "additionalProperties": false,
          "properties": {
            "objective": {
              "type": "string",
              "description": "Clear and specific objective for the subagent to investigate."
            },
            "scope_hint": {
              "type": "array",
              "items": { "type": "string" },
              "description": "Optional advisory paths to focus on. This is not an access restriction; read-only tools may inspect other files within the Pen."
            },
            "max_rounds": {
              "type": "integer",
              "minimum": 1,
              "maximum": 10,
              "description": "Optional round limit for the subagent tool loop (1 to 10)."
            },
            "return_schema": {
              "type": "string",
              "description": "Optional presentation guidance for the summary string only. The host receipt and citation structure cannot be replaced."
            }
          }
        }
        """

    public static let toolSchema = ToolSchema(
        name: toolName,
        description: toolDescription,
        inputSchemaJSON: toolInputSchemaJSON
    )

    private let turnID: UUID
    private let fileTools: PenFileTools
    private let workspace: URL
    private let authority: (any SubagentHostAuthority)?
    private let engine: (any InferenceEngine)?
    private let modelID: String?
    private let configuration: SubagentConfiguration
    private let database: ChatDatabase?
    private let accounting: SubagentTurnTokenAccounting
    nonisolated public let quarantine: SubagentTransportQuarantine

    private var activeWorker: SubagentWorker?
    private var activeLease: SubagentCapabilityLease?

    public init(
        turnID: UUID,
        fileTools: PenFileTools,
        workspace: URL,
        authority: (any SubagentHostAuthority)? = nil,
        engine: (any InferenceEngine)? = nil,
        modelID: String? = nil,
        configuration: SubagentConfiguration = SubagentConfiguration(),
        database: ChatDatabase? = nil,
        accounting: SubagentTurnTokenAccounting = SubagentTurnTokenAccounting(),
        quarantine: SubagentTransportQuarantine = SubagentTransportQuarantine()
    ) {
        self.turnID = turnID
        self.fileTools = fileTools
        self.workspace = workspace
        self.authority = authority
        self.engine = engine
        self.modelID = modelID
        self.configuration = configuration
        self.database = database
        self.accounting = accounting
        self.quarantine = quarantine
    }

    public func tools(for context: ExtensionContext) async throws -> [ToolSchema] {
        guard context.turnID == turnID else { return [] }
        guard configuration.enabled else { return [] }
        guard configuration.preferredBackend.isSupportedInStage1 else { return [] }
        guard SubagentAvailability.unavailableReason(hasLocalEngine: engine != nil, modelID: modelID) == nil else {
            return []
        }
        guard !quarantine.isQuarantined else { return [] }
        guard !quarantine.isTransportActive else { return [] }
        guard accounting.canDelegate else { return [] }
        return [Self.toolSchema]
    }

    public func invoke(_ call: ToolCallRequest, context: ExtensionContext) async throws -> ToolResult {
        guard context.turnID == turnID else { throw CapabilityError.revoked }
        guard call.tool == Self.toolName else { throw CapabilityError.unauthorized }
        guard configuration.enabled else {
            return ToolResult(content: "Subagents are disabled in settings.", isError: true)
        }
        guard !quarantine.isQuarantined else {
            return ToolResult(content: "Subagent engine reservation is quarantined.", isError: true)
        }
        guard !quarantine.isTransportActive else {
            return ToolResult(
                content: "Subagent engine reservation denied: subagent engine transport is currently busy.",
                isError: true)
        }
        guard accounting.delegationsCount < SubagentLimits.maxDelegationsPerTurn else {
            return ToolResult(
                content: "Subagent delegation limit of \(SubagentLimits.maxDelegationsPerTurn) reached for this turn.",
                isError: true
            )
        }
        guard accounting.canDelegate else {
            return ToolResult(
                content: "Parent turn token budget exceeded for subagent delegations.",
                isError: true
            )
        }
        guard activeWorker == nil else {
            return ToolResult(
                content: "A subagent is already running for this turn. Concurrent delegation is not permitted.",
                isError: true
            )
        }

        guard let data = call.argumentsJSON.data(using: .utf8),
            let taskBrief = try? JSONDecoder().decode(SubagentTaskBrief.self, from: data)
        else {
            return ToolResult(
                content: "Invalid subagent_delegate arguments: expected JSON with 'objective'.", isError: true)
        }

        guard !taskBrief.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolResult(content: "An investigation needs a nonempty objective.", isError: true)
        }
        if let rounds = taskBrief.maxRounds, !(1...SubagentLimits.ceilingMaxRounds).contains(rounds) {
            return ToolResult(content: "max_rounds must be between 1 and 10.", isError: true)
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["path_filter"] != nil {
            return ToolResult(
                content:
                    "Use scope_hint for advisory paths. path_filter is not an enforced restriction and is no longer accepted.",
                isError: true)
        }
        if let reason = SubagentAvailability.unavailableReason(hasLocalEngine: engine != nil, modelID: modelID) {
            return ToolResult(content: reason, isError: true)
        }

        let lease = SubagentCapabilityLease()
        self.activeLease = lease

        let effectiveMaxRounds = min(
            taskBrief.maxRounds ?? configuration.maxRounds,
            configuration.maxRounds,
            SubagentLimits.ceilingMaxRounds
        )

        let executionContext = SubagentExecutionContext(
            chatID: context.view.chatID,
            turnID: context.turnID,
            projectID: context.view.penID,
            workspace: workspace,
            fileTools: fileTools,
            authority: authority,
            engine: engine,
            modelID: modelID,
            effort: .graze,
            maxRounds: effectiveMaxRounds,
            timeoutSeconds: configuration.timeoutSeconds,
            database: database,
            turnTokenAccounting: accounting,
            lease: lease,
            quarantine: quarantine
        )

        let worker = SubagentWorker(task: taskBrief, context: executionContext)
        self.activeWorker = worker
        defer {
            self.activeWorker = nil
            self.activeLease = nil
        }

        let backend: any SubagentBackend
        switch configuration.preferredBackend {
        case .localEngine:
            backend = LocalEngineBackend(worker: worker)
        case .systemLanguageModel:
            backend = SystemLanguageModelBackend()
        }

        do {
            let result = try await backend.execute(task: taskBrief, context: executionContext)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let bounded = result.receipt.boundedReceipt()
            var receiptData = (try? encoder.encode(bounded)) ?? Data()

            var receiptString = String(data: receiptData, encoding: .utf8) ?? "{}"
            if receiptString.utf8.count > SubagentLimits.maxReceiptBytes {
                let minimal = SubagentReceipt(
                    runId: bounded.runId,
                    status: bounded.status,
                    summary: UTF8BoundaryTruncator.truncate(bounded.summary, maxBytes: 128),
                    citations: [],
                    unresolved: [],
                    roundsExecuted: bounded.roundsExecuted,
                    totalTokens: bounded.totalTokens
                )
                receiptData = (try? encoder.encode(minimal)) ?? Data()
                receiptString = String(data: receiptData, encoding: .utf8) ?? "{}"
            }

            return ToolResult(content: receiptString, isError: result.receipt.status != .completed)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ToolResult(content: "Subagent error: \(error.localizedDescription)", isError: true)
        }
    }

    public func turnDidEnd(_ context: ExtensionContext, outcome: TurnOutcome) async throws {
        guard context.turnID == turnID else { return }
        activeLease?.revoke()
        if let worker = activeWorker {
            await worker.cancel()
            activeWorker = nil
        }
        _ = await quarantine.awaitClosure(timeoutSeconds: SubagentLimits.cancellationGracePeriodSeconds)
        activeLease = nil
    }
}
