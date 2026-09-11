import Foundation
import GOATed
import Herd
import Hoofprint
import Inference
import JUDAS
import Memory
import Pens
import Pronk
import Shepherd
import Tools

@MainActor
final class AppToolRouter: ShepherdToolSource {
    private let mcp: MCPModel
    var workspaceForProject: (UUID) -> URL? = { _ in nil }
    var nameForProject: (UUID) -> String = { _ in "this Pen" }
    let commandPermissions: PenCommandPermissionModel
    let filePermissions: PenFilePermissionModel
    private var penFileSession:
        (
            turnID: UUID, chatID: UUID, projectID: UUID, workspace: URL, provider: HerderFileProvider,
            registration: Registration, workspaceIdentity: String
        )?
    private let memory: MemoryModel
    private let activity: ActivityLog
    private let builtInSkillsRoot: URL
    private let globalSkillsRoot: URL
    private let pronkStateRoot: URL
    let extensions: ExtensionRuntime
    private let hindsightRegistration: ExtensionRegistrationController
    private var pronkRegistration: Registration?
    private var turnSnapshot: TurnSnapshot?
    private var turnMemoryConfiguration: MemoryConfiguration?
    private var turnUsedHindsight = false
    private var turnPersisted = false
    private var skillSetupTasks: [String: Task<Registration?, Never>] = [:]
    private struct SkillToolSession {
        let view: ExtensionView
        let provider: SkillToolProvider
    }
    private var skillToolSessions: [UUID: SkillToolSession] = [:]

    init(
        mcp: MCPModel, memory: MemoryModel, activity: ActivityLog,
        builtInSkillsRoot: URL? = nil, globalSkillsRoot: URL = Home.skillsDir,
        pronkStateRoot: URL = Home.url.appendingPathComponent("extensions/pronk", isDirectory: true),
        commandPermissions: PenCommandPermissionModel? = nil
    ) {
        self.commandPermissions = commandPermissions ?? PenCommandPermissionModel()
        self.mcp = mcp
        self.memory = memory
        self.activity = activity
        let runtime = ExtensionRuntime()
        extensions = runtime
        hindsightRegistration = ExtensionRegistrationController(
            activate: { try await runtime.activate(HindsightExtension(memory: memory)) },
            deactivate: { token in
                do { try await runtime.unregister(token) } catch {
                    activity.log(.warn, "Hindsight extension removal: \(error.localizedDescription)")
                }
            },
            reportFailure: { error in
                activity.log(.warn, "Hindsight extension activation: \(error.localizedDescription)")
            })
        filePermissions = PenFilePermissionModel(activity: activity)
        self.builtInSkillsRoot =
            builtInSkillsRoot
            ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("Skills", isDirectory: true)
        self.globalSkillsRoot = globalSkillsRoot
        self.pronkStateRoot = pronkStateRoot
    }

    func availableToolSpecs(
        forChatID chatID: UUID,
        projectID: UUID?,
        includeMCP: Bool,
        excludedMCPServers: Set<String>
    ) async -> ([ToolSpec], [String: ShepherdToolRoute]) {
        var (specs, routes): ([ToolSpec], [String: ShepherdToolRoute]) =
            includeMCP
            ? await mcp.availableToolSpecs(
                forChatID: chatID,
                projectID: projectID,
                includeMCP: true,
                excludedMCPServers: excludedMCPServers)
            : ([], [:])
        if memory.isEnabled(forProjectID: projectID) {
            let context = MemoryContext(projectID: projectID)
            let memorySpecs: [ToolSpec]
            if memory.isUsingHindsight(forProjectID: projectID) {
                memorySpecs = []
            } else {
                memorySpecs =
                    Self.memoryToolSpecs
                    + (memory.usesLLMWiki(forProjectID: projectID) ? Self.llmWikiToolSpecs : [])
            }
            for spec in memorySpecs {
                specs.append(spec)
                routes[spec.name] = ShepherdToolRoute(
                    server: "Memory", tool: spec.name, origin: .memory(context))
            }
        }

        let skillTools = await skillToolProvider(forChatID: chatID, projectID: projectID)
        for schema in await skillTools.availableTools() where routes[schema.name] == nil {
            specs.append(
                ToolSpec(
                    name: schema.name,
                    description: "[GOATed] \(schema.description)",
                    parametersJSON: schema.inputSchemaJSON))
            routes[schema.name] = ShepherdToolRoute(
                server: "GOATed",
                tool: schema.name,
                origin: .goated(chatID))
        }
        if let snapshot = turnSnapshot {
            for tool in snapshot.tools where routes[tool.schema.name] == nil {
                if tool.handle.registration.extensionID.rawValue == "goat.herder" {
                    guard includeMCP, memory.builtInSettings.allowsHerderTool(tool.schema.name),
                        let session = penFileSession,
                        session.chatID == chatID, session.projectID == projectID,
                        workspaceForProject(session.projectID) == session.workspace
                    else { continue }
                }
                specs.append(
                    ToolSpec(
                        name: tool.schema.name,
                        description: "[\(tool.handle.registration.extensionID.rawValue)] \(tool.schema.description)",
                        parametersJSON: tool.schema.inputSchemaJSON))
                routes[tool.schema.name] = ShepherdToolRoute(
                    server: "GOATed", tool: tool.schema.name, origin: .extensionTool(tool.handle))
            }
        }
        return (specs, routes)
    }

    func memoryEntries(forProjectID projectID: UUID?) async throws -> [PromptMemoryEntry] {
        if turnUsedHindsight {
            return turnSnapshot?.contextEntries.map {
                PromptMemoryEntry(identifier: $0.identifier, title: $0.title, summary: $0.summary)
            } ?? []
        }
        return try await memory.promptEntries(forProjectID: projectID)
    }

    func extensionPromptSections(
        forChatID chatID: UUID,
        projectID: UUID?,
        canLoadSkills: Bool,
        requestedSkillName: String?
    ) async -> [String] {
        var sections = turnSnapshot?.promptSections ?? []
        guard canLoadSkills else { return sections }
        await ensureSkillProviders(forProjectID: projectID)
        let catalog = await extensions.skillCatalog(
            for: ExtensionView(chatID: chatID, penID: projectID))
        sections.append(contentsOf: [catalog.promptCatalog(), catalog.requestedSkillPrompt(named: requestedSkillName)])
        return sections.filter { !$0.isEmpty }
    }

    func turnDidPersist(_ turn: ShepherdPersistedTurn) async -> ShepherdPersistedTurnReceipt? {
        turnPersisted = true
        guard let snapshot = turnSnapshot else { return nil }
        let event = PersistedTurn(
            context: snapshot.context, title: turn.title, createdAt: turn.createdAt,
            commandMessageID: turn.commandMessageID, isHandoff: turn.kind == .handoff,
            messages: turn.messages.suffix(64).map {
                PersistedTurn.Message(role: $0.role.rawValue, text: String($0.text.suffix(4096)))
            })
        let receipts = await extensions.didPersist(event)
        if turnUsedHindsight {
            return receipts.first.map { ShepherdPersistedTurnReceipt(message: $0.message, isError: $0.isError) }
        }
        guard turnMemoryConfiguration == memory.configuration else { return nil }
        return await memory.retainPersistedTurn(turn)
    }

    func setPronkEnabled(_ enabled: Bool) async throws {
        if enabled, pronkRegistration == nil {
            pronkRegistration = try await extensions.activate(
                PronkExtension(
                    stateDirectory: pronkStateRoot))
        } else if !enabled, let registration = pronkRegistration {
            try? await extensions.unregister(registration)
            pronkRegistration = nil
        }
    }

    func refreshHindsightExtension() async {
        await hindsightRegistration.setEnabled(memory.builtInSettings.hindsightEnabled)
    }

    func turnWillPrepare(chatID: UUID, projectID: UUID?, turnID: UUID) async throws {
        if let session = penFileSession {
            await session.provider.stopCommands()
            try? await extensions.unregister(session.registration)
        }
        penFileSession = nil
        if memory.builtInSettings.herderEnabled, let projectID, let workspace = workspaceForProject(projectID) {
            do {
                let files = try await Task.detached { try PenFileTools(workspace: workspace) }.value
                let provider = HerderFileProvider(
                    files: files, turnID: turnID,
                    commands: memory.builtInSettings.herderCommandsEnabled
                        ? PenCommandTools(
                            workspace: workspace, files: files,
                            defaultTimeout: memory.builtInSettings.commandTimeout) : nil,
                    writesEnabled: memory.builtInSettings.herderWritesEnabled)
                if workspaceForProject(projectID) == workspace {
                    let registration = try await extensions.activate(
                        HerderExtension(provider: provider), scope: .pen(projectID))
                    penFileSession = (
                        turnID, chatID, projectID, workspace, provider, registration, files.workspaceIdentity
                    )
                }
            } catch {
                activity.log(.warn, "Pen file tools unavailable: \(error.localizedDescription)")
            }
        }
        await refreshHindsightExtension()
        await ensureSkillProviders(forProjectID: projectID)
        skillToolSessions.removeValue(forKey: chatID)
        turnMemoryConfiguration = memory.configuration
        turnUsedHindsight = memory.isUsingHindsight(forProjectID: projectID)
        turnPersisted = false
        turnSnapshot = try await extensions.prepareTurn(
            ExtensionContext(view: ExtensionView(chatID: chatID, penID: projectID), turnID: turnID),
            reservedToolNames: Set(
                ["skill_load", "skill_read_resource", "handoff"]
                    + Self.memoryToolSpecs.map(\.name)
                    + Self.llmWikiToolSpecs.map(\.name)))
    }

    func stopCommands(penID: UUID, chatID: UUID? = nil) async {
        guard let session = penFileSession, session.projectID == penID,
            chatID == nil || session.chatID == chatID
        else { return }
        await session.provider.stopCommands()
    }

    func finishPendingWork() async -> String? {
        guard let commands = penFileSession?.provider.commands else { return nil }
        let count = await commands.runningCount()
        await commands.stopAll()
        return count == 0
            ? nil
            : "The agent ended with \(count) command job(s) still running. GOAT stopped those jobs. Their file changes were not rolled back; inspect the project before retrying."
    }

    func turnDidEnd(turnID: UUID, cancelled: Bool) async {
        if let session = penFileSession, session.turnID == turnID {
            penFileSession = nil
            await session.provider.stopCommands()
            try? await extensions.unregister(session.registration)
        }
        let outcome: TurnOutcome = cancelled ? .cancelled : (turnPersisted ? .completed : .failed)
        let runtime = extensions
        // Cleanup has its own bounded lifetime and must run even when the generation task was cancelled.
        await Task.detached { await runtime.endTurn(turnID, outcome: outcome) }.value
        if let snapshot = turnSnapshot { skillToolSessions.removeValue(forKey: snapshot.context.view.chatID) }
        turnSnapshot = nil
        turnMemoryConfiguration = nil
    }

    func skillCatalog(forChatID chatID: UUID, projectID: UUID?) async -> SkillCatalog {
        await refreshHindsightExtension()
        await ensureSkillProviders(forProjectID: projectID)
        return await extensions.skillCatalog(
            for: ExtensionView(chatID: chatID, penID: projectID))
    }

    func requestName(server: String, tool: String) -> String {
        server == "Memory" || server == "GOATed" || server == "Herder"
            ? tool : mcp.requestName(server: server, tool: tool)
    }

    private struct OwnerDeniedTool: Error {}

    func authorizeAndInvoke(
        route: ShepherdToolRoute,
        argumentsJSON: String
    ) async throws -> ToolResult? {
        switch route.origin {
        case .extensionTool(let handle):
            do {
                let result = try await extensions.invoke(handle, argumentsJSON: argumentsJSON) {
                    [weak self] handle, arguments in
                    let allowed: Bool
                    do {
                        allowed = try await self?.authorizeExtension(handle, arguments: arguments) ?? false
                    } catch is OwnerDeniedTool {
                        Judas.shared.recordTool(
                            .denied, server: handle.registration.extensionID.rawValue, tool: handle.name,
                            isExtension: true)
                        throw OwnerDeniedTool()
                    }
                    Judas.shared.recordTool(
                        allowed ? .allowed : .denied,
                        server: handle.registration.extensionID.rawValue, tool: handle.name, isExtension: true)
                    return allowed
                }
                return ToolResult(
                    content: result.content, isError: result.isError, diagnostic: result.diagnostic)
            } catch is OwnerDeniedTool { return nil }
            catch let error as PenFileTools.Failure {
                return ToolResult(content: error.localizedDescription, isError: true, diagnostic: error.diagnostic)
            }
        case .mcp:
            return try await mcp.authorizeAndInvoke(route: route, argumentsJSON: argumentsJSON)
        case .memory(let context):
            return try await memory.invoke(tool: route.tool, argumentsJSON: argumentsJSON, context: context)
        case .goated(let chatID):
            guard let provider = skillToolSessions[chatID]?.provider else {
                throw SkillError.providerUnavailable("GOATed skill tools")
            }
            let result = try await provider.invoke(
                ToolCallRequest(tool: route.tool, argumentsJSON: argumentsJSON))
            return ToolResult(
                content: result.content, isError: result.isError, diagnostic: result.diagnostic)
        }
    }

    func previewToolEffect(
        route: ShepherdToolRoute, argumentsJSON: String
    ) async -> ToolExecutionDiagnostic? {
        guard case .extensionTool(let handle) = route.origin,
            handle.registration.extensionID.rawValue == "goat.herder",
            handle.name == "pen_run_command",
            let session = penFileSession,
            session.turnID == handle.turnID
        else { return nil }
        return await session.provider.previewToolEffect(
            ToolCallRequest(tool: route.tool, argumentsJSON: argumentsJSON))
    }

    private func authorizeExtension(_ handle: ToolHandle, arguments: String) async throws -> Bool {
        guard extensionAuthorized(handle) else { return false }
        if handle.registration.extensionID.rawValue == "goat.herder", let session = penFileSession {
            if handle.name == "pen_run_command" {
                let revision = commandPermissions.revision
                let command = try await session.provider.prepareCommand(argumentsJSON: arguments)
                guard extensionAuthorized(handle), !Task.isCancelled, commandPermissions.revision == revision else {
                    return false
                }
                if commandPermissions.allows(
                    command, penID: session.projectID, chatID: session.chatID,
                    workspaceIdentity: session.workspaceIdentity)
                {
                    return true
                }
                let choice = await mcp.approvePenWrite(
                    tool: handle.name, preview: command.previewJSON,
                    penName: nameForProject(session.projectID), allowsScopes: true)
                guard extensionAuthorized(handle), !Task.isCancelled, commandPermissions.revision == revision else {
                    return false
                }
                switch choice {
                case .allowOnce: return true
                case .allowChat, .allowPen:
                    return commandPermissions.remember(
                        command, penID: session.projectID,
                        chatID: choice == .allowChat ? session.chatID : nil,
                        workspaceIdentity: session.workspaceIdentity)
                case .deny: throw OwnerDeniedTool()
                case .alwaysAllow: return false
                }
            }
            let revision = filePermissions.revision
            let preview = try await session.provider.prepare(
                ToolCallRequest(tool: handle.name, argumentsJSON: arguments))
            if let preview {
                guard extensionAuthorized(handle), !Task.isCancelled, filePermissions.revision == revision else {
                    return false
                }
                if filePermissions.scope(
                    penID: session.projectID, chatID: session.chatID, workspaceIdentity: session.workspaceIdentity
                ) != .ask {
                    return true
                }
                let choice = await mcp.approvePenWrite(
                    tool: handle.name, preview: preview, penName: nameForProject(session.projectID),
                    allowsScopes: filePermissions.canRemember)
                guard extensionAuthorized(handle), !Task.isCancelled, filePermissions.revision == revision else {
                    return false
                }
                switch choice {
                case .allowOnce: break
                case .allowChat, .allowPen:
                    let scopeChatID = choice == .allowChat ? session.chatID : nil
                    guard
                        await filePermissions.remember(
                            penID: session.projectID, chatID: scopeChatID, workspaceIdentity: session.workspaceIdentity)
                    else { return false }
                    guard extensionAuthorized(handle), !Task.isCancelled,
                        filePermissions.scope(
                            penID: session.projectID, chatID: session.chatID,
                            workspaceIdentity: session.workspaceIdentity) != .ask
                    else {
                        await filePermissions.reset(penID: session.projectID, chatID: scopeChatID)
                        return false
                    }
                case .deny: throw OwnerDeniedTool()
                case .alwaysAllow: return false
                }
            }
            return extensionAuthorized(handle) && !Task.isCancelled
        }
        return true
    }

    private func extensionAuthorized(_ handle: ToolHandle) -> Bool {
        guard turnSnapshot?.context.turnID == handle.turnID else { return false }
        switch handle.registration.extensionID.rawValue {
        case "goat.herder":
            guard memory.builtInSettings.allowsHerderTool(handle.name), let session = penFileSession else {
                return false
            }
            return session.turnID == handle.turnID && session.registration == handle.registration
                && workspaceForProject(session.projectID) == session.workspace
        case "goat.pronk": return pronkRegistration != nil
        case "goat.hindsight":
            return memory.builtInSettings.hindsightEnabled && turnMemoryConfiguration == memory.configuration
        default: return false
        }
    }

    func logCall(server: String, tool: String, status: String, duration: TimeInterval) {
        if server == "Memory" {
            memory.logCall(tool: tool, status: status, duration: duration)
        } else if server == "GOATed" {
            mcp.logCall(server: server, tool: tool, status: status, duration: duration)
        } else {
            mcp.logCall(server: server, tool: tool, status: status, duration: duration)
        }
    }

    func cancelPendingPermission() { mcp.cancelPendingPermission() }

    private func skillToolProvider(forChatID chatID: UUID, projectID: UUID?) async -> SkillToolProvider {
        await ensureSkillProviders(forProjectID: projectID)
        let view = ExtensionView(chatID: chatID, penID: projectID)
        if let current = skillToolSessions[chatID], current.view == view {
            return current.provider
        }
        let provider = SkillToolProvider(runtime: extensions, view: view)
        skillToolSessions[chatID] = SkillToolSession(view: view, provider: provider)
        return provider
    }

    private func ensureSkillProviders(forProjectID projectID: UUID?) async {
        await registerSkillProvider(
            FileSkillProvider(providerID: "goat.skills.builtin", root: builtInSkillsRoot, source: .builtIn),
            extensionID: "goat.skills.builtin", scope: .application)
        await registerSkillProvider(
            FileSkillProvider(providerID: "goat.skills.global", root: globalSkillsRoot, source: .global),
            extensionID: "goat.skills.global", scope: .application)
        guard let projectID else { return }
        do {
            guard let root = try PenStore.skillsDir(forProjectID: projectID) else { return }
            await registerSkillProvider(
                FileSkillProvider(
                    providerID: "goat.skills.pen.\(projectID.uuidString.lowercased())", root: root,
                    source: .pen(projectID)),
                extensionID: "goat.skills.pen", scope: .pen(projectID))
        } catch {
            activity.log(.warn, "Extension skills: \(error.localizedDescription)")
        }
    }

    /// All callers join one registration operation per provider. A failed attempt can be retried;
    /// no caller sees a partially initialized provider as ready just because another caller began.
    private func registerSkillProvider(
        _ provider: FileSkillProvider, extensionID: String, scope: ExtensionScope
    ) async {
        let key = provider.providerID
        if let task = skillSetupTasks[key] {
            _ = await task.value
            return
        }
        let task = Task { @MainActor [extensions, activity] () -> Registration? in
            do {
                return try await extensions.registerSkillProvider(
                    provider, extensionID: ExtensionID(rawValue: extensionID), scope: scope)
            } catch {
                activity.log(.warn, "Extension skills: \(error.localizedDescription)")
                return nil
            }
        }
        skillSetupTasks[key] = task
        if await task.value == nil { skillSetupTasks[key] = nil }
    }

    private static let memoryToolSpecs = [
        ToolSpec(
            name: "memory_list",
            description: "List available memory notes for this chat's memory scope.",
            parametersJSON: #"{"type":"object","additionalProperties":false,"properties":{}}"#),
        ToolSpec(
            name: "memory_read",
            description: "Read one memory note by its opaque id returned by memory_list.",
            parametersJSON: """
                {"type":"object","additionalProperties":false,
                "required":["id"],
                "properties":{"id":{"type":"string","maxLength":512}}}
                """),
        ToolSpec(
            name: "memory_write",
            description:
                "Write a concise durable memory note for this chat's current scope. Never claim a memory was saved unless this tool succeeds.",
            parametersJSON: """
                {"type":"object","additionalProperties":false,
                "required":["name","description","body"],
                "properties":{"name":{"type":"string","maxLength":64},
                "description":{"type":"string","maxLength":512},
                "body":{"type":"string","maxLength":24576}}}
                """),
        ToolSpec(
            name: "memory_capture_session",
            description:
                "When the user asks to end a session or save its key takeaways, capture a concise durable summary. There is no endSession function: call this tool before confirming the session was saved.",
            parametersJSON: """
                {"type":"object","additionalProperties":false,
                "required":["summary","content"],
                "properties":{"summary":{"type":"string","maxLength":512},
                "content":{"type":"string","maxLength":24576}}}
                """),
        ToolSpec(
            name: "memory_delete",
            description: "Delete a memory note from this chat's current write scope by safe name.",
            parametersJSON: """
                {"type":"object","additionalProperties":false,
                "required":["name"],
                "properties":{"name":{"type":"string","maxLength":64}}}
                """),
    ]

    private static let llmWikiToolSpecs = [
        ToolSpec(
            name: "wiki_ingest_source",
            description:
                "Capture one immutable LLM Wiki source. Then read it and update curated wiki pages with citations.",
            parametersJSON:
                #"{"type":"object","additionalProperties":false,"required":["title","content"],"properties":{"title":{"type":"string","maxLength":512},"content":{"type":"string","maxLength":24576}}}"#
        ),
        ToolSpec(
            name: "wiki_list_sources",
            description: "List immutable raw sources for the active LLM Wiki.",
            parametersJSON: #"{"type":"object","additionalProperties":false,"properties":{}}"#),
        ToolSpec(
            name: "wiki_read_source",
            description: "Read one immutable raw source by the opaque id returned by wiki_list_sources.",
            parametersJSON:
                #"{"type":"object","additionalProperties":false,"required":["id"],"properties":{"id":{"type":"string","maxLength":512}}}"#
        ),
        ToolSpec(
            name: "wiki_query",
            description: "Search the active LLM Wiki's curated page index and return at most 20 matching page records.",
            parametersJSON:
                #"{"type":"object","additionalProperties":false,"required":["query"],"properties":{"query":{"type":"string","minLength":1,"maxLength":256}}}"#
        ),
        ToolSpec(
            name: "wiki_lint",
            description:
                "Check the active LLM Wiki schema, index freshness, source citations, links, orphans, and log. This never edits curated pages.",
            parametersJSON: #"{"type":"object","additionalProperties":false,"properties":{}}"#),
    ]

    static let hindsightToolSpecs = [
        ToolSpec(
            name: "hindsight_sync_status",
            description: "Report whether the managed Hindsight bank is ready.",
            parametersJSON: #"{"type":"object","additionalProperties":false,"properties":{}}"#),
        ToolSpec(
            name: "hindsight_diagnose",
            description: "Report safe diagnostics for GOAT's managed Hindsight bank binding.",
            parametersJSON: #"{"type":"object","additionalProperties":false,"properties":{}}"#),
        ToolSpec(
            name: "hindsight_search_memories",
            description: "Recall relevant facts from the managed Hindsight bank before deep reflection.",
            parametersJSON:
                #"{"type":"object","additionalProperties":false,"required":["query"],"properties":{"query":{"type":"string","minLength":1,"maxLength":4096}}}"#
        ),
        ToolSpec(
            name: "hindsight_list_memories",
            description: "List up to 100 managed Hindsight memory facts without loading more metadata.",
            parametersJSON: #"{"type":"object","additionalProperties":false,"properties":{}}"#),
        ToolSpec(
            name: "hindsight_read_memory",
            description: "Read one managed Hindsight memory fact by its opaque memory id.",
            parametersJSON:
                #"{"type":"object","additionalProperties":false,"required":["memory_id"],"properties":{"memory_id":{"type":"string","minLength":1,"maxLength":512}}}"#
        ),
        ToolSpec(
            name: "hindsight_reflect",
            description: "Perform deliberate deep reasoning over the managed Hindsight bank.",
            parametersJSON:
                #"{"type":"object","additionalProperties":false,"required":["query"],"properties":{"query":{"type":"string","minLength":1,"maxLength":4096}}}"#
        ),
        ToolSpec(
            name: "hindsight_capture_initiative",
            description: "Capture a substantial approved initiative in the managed Hindsight bank.",
            parametersJSON: """
                {"type":"object","additionalProperties":false,"required":["title","summary"],
                "properties":{"title":{"type":"string","minLength":1,"maxLength":512},
                "summary":{"type":"string","minLength":1,"maxLength":4096}}}
                """),
        ToolSpec(
            name: "hindsight_ingest_document",
            description: "Ingest an explicit durable document into the managed Hindsight bank.",
            parametersJSON: """
                {"type":"object","additionalProperties":false,"required":["title","content"],
                "properties":{"title":{"type":"string","minLength":1,"maxLength":512},
                "content":{"type":"string","minLength":1,"maxLength":24576}}}
                """),
    ]
}
