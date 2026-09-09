import Foundation
import GOATed
import Inference
import Memory
import Shepherd
import Tools

struct HindsightExtension: Extension {
    let manifest = ExtensionManifest(id: "goat.hindsight", version: "0.1.0")
    let contributions: ExtensionContributions
    @MainActor init(memory: MemoryModel) {
        let adapter = HindsightExtensionAdapter(memory: memory)
        contributions = ExtensionContributions(
            contextProviders: [adapter], prompts: [adapter], tools: [adapter], observers: [adapter],
            skills: [
                CompanionSkillProvider(
                    providerID: "goat.hindsight.companion", name: "hindsight",
                    description:
                        "Use GOAT's configured Hindsight memory for explicit recall, reflection and durable documents.",
                    instructions:
                        "GOAT prepares bounded memory context and retains successfully persisted chat transcripts automatically. Do not duplicate automatic transcript retention. Use hindsight_search_memories for relevant facts; hindsight_reflect for deliberate synthesis; hindsight_ingest_document for explicitly requested durable documents; hindsight_capture_initiative for substantial approved work. Inspect tool receipts before claiming success. Skills never enable memory or choose an endpoint or bank. If a tool is unavailable, continue without Hindsight and explain the limitation.",
                    available: { view in await adapter.skillAvailable(view) })
            ])
    }
}

/// The adapter owns lifecycle wiring; the existing memory service remains authoritative for
/// configuration, permission, bank routing, private transport and durable write semantics.
@MainActor
private final class HindsightExtensionAdapter: ContextProvider, PromptProvider, ModelToolProvider,
    TurnObserver
{
    private let memory: MemoryModel
    private var bindings: [UUID: MemoryConfiguration] = [:]
    init(memory: MemoryModel) { self.memory = memory }
    func turnWillPrepare(_ context: ExtensionContext) async throws {
        await memory.recoverHindsightIfNeeded(forProjectID: context.view.penID)
        if memory.isUsingHindsight(forProjectID: context.view.penID) {
            bindings[context.turnID] = memory.configuration
        }
    }
    func skillAvailable(_ view: ExtensionView) -> Bool {
        memory.isEnabled(forProjectID: view.penID) && memory.isUsingHindsight(forProjectID: view.penID)
    }

    private func active(_ context: ExtensionContext) -> Bool {
        bindings[context.turnID] == memory.configuration && memory.isEnabled(forProjectID: context.view.penID)
            && memory.isUsingHindsight(forProjectID: context.view.penID)
    }
    func contextEntries(for context: ExtensionContext) async throws -> [ContextEntry] {
        guard active(context) else { return [] }
        let entries = try await memory.promptEntries(forProjectID: context.view.penID)
        guard active(context) else { throw CapabilityError.revoked }
        return entries.map { ContextEntry(identifier: $0.identifier, title: $0.title, summary: $0.summary) }
    }
    func prompt(for context: ExtensionContext) async throws -> String {
        guard active(context) else { return "" }
        return memory.hindsightLifecyclePromptSection(forProjectID: context.view.penID) ?? ""
    }
    func tools(for context: ExtensionContext) async throws -> [ToolSchema] {
        guard active(context) else { return [] }
        return AppToolRouter.hindsightToolSpecs.map {
            ToolSchema(name: $0.name, description: $0.description, inputSchemaJSON: $0.parametersJSON)
        }
    }
    func invoke(_ call: ToolCallRequest, context: ExtensionContext) async throws -> ToolResult {
        guard active(context) else { throw CapabilityError.revoked }
        let result = try await memory.invoke(
            tool: call.tool, argumentsJSON: call.argumentsJSON,
            context: MemoryContext(projectID: context.view.penID))
        guard active(context) else { throw CapabilityError.revoked }
        return ToolResult(content: result.content, isError: result.isError)
    }
    func turnDidPersist(_ turn: PersistedTurn) async throws -> ObserverReceipt? {
        guard active(turn.context) else { return nil }
        let native = ShepherdPersistedTurn(
            chatID: turn.context.view.chatID, projectID: turn.context.view.penID,
            commandMessageID: turn.commandMessageID, title: turn.title, createdAt: turn.createdAt,
            kind: turn.isHandoff ? .handoff : .regular,
            messages: turn.messages.compactMap {
                guard let role = ChatTurn.Role(rawValue: $0.role) else { return nil }
                return ShepherdPersistedTurn.Message(role: role, text: $0.text)
            })
        guard let receipt = await memory.retainPersistedTurn(native) else { return nil }
        return ObserverReceipt(message: receipt.message, isError: receipt.isError)
    }
    func turnDidEnd(_ context: ExtensionContext, outcome: TurnOutcome) async throws {
        bindings.removeValue(forKey: context.turnID)
    }
}
