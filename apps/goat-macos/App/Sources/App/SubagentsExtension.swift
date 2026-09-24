import Foundation
import GOATed
import Inference
import Pens
import Persistence
import Tools

struct SubagentsExtension: Extension {
    public let manifest = ExtensionManifest(id: "goat.subagents", version: "0.1.0")
    public let contributions: ExtensionContributions

    init(provider: SubagentsProvider) {
        contributions = ExtensionContributions(
            tools: [provider],
            observers: [provider]
        )
    }
}

actor SubagentsProvider: ModelToolProvider, TurnObserver {
    static let toolName = "subagent_delegate"

    static let toolSchema = ToolSchema(
        name: toolName,
        description: "Delegate a focused read-only repository search or code investigation to an isolated subagent. The subagent inspects files within the Pen workspace and returns a concise, evidence-backed receipt with citations.",
        inputSchemaJSON: """
        {
          "type": "object",
          "additionalProperties": false,
          "required": ["objective"],
          "properties": {
            "objective": {
              "type": "string",
              "description": "The specific read-only investigation objective or question to research."
            },
            "path_filter": {
              "type": "array",
              "items": { "type": "string" },
              "description": "Optional list of directory or file paths to constrain the search scope."
            },
            "max_rounds": {
              "type": "integer",
              "minimum": 1,
              "maximum": 10,
              "description": "Optional maximum number of tool execution rounds for the subagent (capped by host configuration)."
            },
            "return_schema": {
              "type": "string",
              "description": "Optional description of the expected format or structure of the summary."
            }
          }
        }
        """
    )

    private let turnID: UUID
    private let fileTools: PenFileTools
    private let workspace: URL
    private let engine: (any InferenceEngine)?
    private let modelID: String?
    private let configuration: SubagentConfiguration
    private let database: ChatDatabase?
    private let accounting: SubagentTurnTokenAccounting

    private var activeWorker: SubagentWorker?
    private var activeLease: SubagentCapabilityLease?
    private var isQuarantined = false

    init(
        turnID: UUID,
        fileTools: PenFileTools,
        workspace: URL,
        engine: (any InferenceEngine)? = nil,
        modelID: String? = nil,
        configuration: SubagentConfiguration,
        database: ChatDatabase? = nil,
        accounting: SubagentTurnTokenAccounting = SubagentTurnTokenAccounting()
    ) {
        self.turnID = turnID
        self.fileTools = fileTools
        self.workspace = workspace
        self.engine = engine
        self.modelID = modelID
        self.configuration = configuration
        self.database = database
        self.accounting = accounting
    }

    public func tools(for context: ExtensionContext) async throws -> [ToolSchema] {
        guard context.turnID == turnID else { return [] }
        guard configuration.enabled else { return [] }
        guard !isQuarantined else { return [] }
        guard accounting.canDelegate else { return [] }
        return [Self.toolSchema]
    }

    public func invoke(_ call: ToolCallRequest, context: ExtensionContext) async throws -> ToolResult {
        guard context.turnID == turnID else { throw CapabilityError.revoked }
        guard call.tool == Self.toolName else { throw CapabilityError.unauthorized }
        guard configuration.enabled else {
            return ToolResult(content: "Subagents are disabled in settings.", isError: true)
        }
        guard !isQuarantined else {
            return ToolResult(content: "Subagent engine reservation is quarantined.", isError: true)
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
              let taskBrief = try? JSONDecoder().decode(SubagentTaskBrief.self, from: data) else {
            return ToolResult(content: "Invalid subagent_delegate arguments: expected JSON with 'objective'.", isError: true)
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
            engine: engine,
            modelID: modelID,
            effort: .trot,
            maxRounds: effectiveMaxRounds,
            timeoutSeconds: configuration.timeoutSeconds,
            database: database,
            turnTokenAccounting: accounting,
            lease: lease
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
            backend = LocalEngineBackend()
        case .systemLanguageModel:
            backend = SystemLanguageModelBackend()
        }

        do {
            let result = try await backend.execute(task: taskBrief, context: executionContext)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let receiptData = try encoder.encode(result.receipt)
            let receiptString = String(data: receiptData, encoding: .utf8) ?? "{}"
            return ToolResult(content: receiptString, isError: result.receipt.status != .completed)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ToolResult(content: "Subagent error: \(error.localizedDescription)", isError: true)
        }
    }

    public func turnDidEnd(_ context: ExtensionContext, outcome: TurnOutcome) async throws {
        guard context.turnID == turnID else { return }

        if let lease = activeLease {
            lease.revoke()
        }

        if activeWorker != nil {
            // 5-second shutdown grace period
            let shutdownTask = Task {
                try? await Task.sleep(for: .seconds(SubagentLimits.cancellationGracePeriodSeconds))
            }
            activeWorker = nil
            activeLease = nil
            shutdownTask.cancel()
        }
    }
}
