import Foundation
import Pens
import Persistence
import Testing

@testable import Bleet
@testable import GOAT
@testable import Herd
@testable import Hoofprint
@testable import Inference
@testable import MCPClient
@testable import Shepherd
@testable import Tools

// The Shepherd against fakes: turn assembly, continued tool rounds, stale-model healing,
// and the pasture-meter estimate. No network, no MCP processes, no database.

// MARK: - Fakes

/// Scripted engine: each stream() call plays the next event list.
private actor FakeEngine: InferenceEngine {
    private var script: [[GenerationEvent]]
    private(set) var requests: [GenerationRequest] = []
    private let onRequest: (@MainActor @Sendable (Int) -> Void)?
    private let failingRequest: Int?

    init(
        script: [[GenerationEvent]], failingRequest: Int? = nil,
        onRequest: (@MainActor @Sendable (Int) -> Void)? = nil
    ) {
        self.script = script
        self.failingRequest = failingRequest
        self.onRequest = onRequest
    }

    func health() async -> EngineHealth { .ok([]) }

    func stream(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
        requests.append(request)
        if let onRequest { await onRequest(requests.count) }
        if requests.count == failingRequest {
            return AsyncThrowingStream { $0.finish(throwing: EngineError.http(503)) }
        }
        let events =
            script.isEmpty
            ? [.done(GenStats(ttft: nil, tokens: 0, duration: 0.01))]
            : script.removeFirst()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// An engine whose first stream stays open until its consumer is cancelled.
/// Tests use it to inspect ownership while a turn is genuinely in flight.
private actor BlockingEngine: InferenceEngine {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuations: [AsyncThrowingStream<GenerationEvent, Error>.Continuation] = []
    private(set) var requests: [GenerationRequest] = []

    func health() async -> EngineHealth { .ok([]) }

    func stream(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
        requests.append(request)
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        let pair = AsyncThrowingStream<GenerationEvent, Error>.makeStream()
        continuations.append(pair.continuation)
        return pair.stream
    }

    func finishCurrent(_ events: [GenerationEvent]) {
        guard let continuation = continuations.last else { return }
        for event in events { continuation.yield(event) }
        continuation.finish()
    }

    func waitForRequests(_ count: Int) async {
        while requests.count < count { await Task.yield() }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

private actor AttachmentLoaderProbe {
    private(set) var ranOnMainThread: Bool?
    let payload: Data

    init(payload: Data) {
        self.payload = payload
    }

    func load(_ path: String) -> Data? {
        ranOnMainThread = Thread.isMainThread
        return payload
    }
}

@MainActor
private final class FakeToolSource: ShepherdToolSource {
    var specs: [ToolSpec] = []
    var mapping: [String: ShepherdToolRoute] = [:]
    var allow = true
    var blockPermission = false
    var blockExecution = false
    var pendingWorkNotice: String?
    func finishPendingWork() async -> String? { pendingWorkNotice }
    private var executionContinuation: CheckedContinuation<Void, Never>?
    var extensionSections: [String] = []
    var memoryEntries: [PromptMemoryEntry] = []
    var memoryFailure: (any Error)?
    var preparationFailure: (any Error)?
    private(set) var extensionEvents: [String] = []
    func turnWillPrepare(chatID: UUID, projectID: UUID?, turnID: UUID) async throws {
        extensionEvents.append("prepare")
        if let preparationFailure { throw preparationFailure }
    }
    func turnDidEnd(turnID: UUID, cancelled: Bool) async {
        extensionEvents.append(cancelled ? "cancelled" : "end")
    }
    private(set) var invocations = 0
    private(set) var cancellationRequests = 0
    private(set) var permissionRequested = false
    private(set) var lastCanLoadSkills: Bool?
    private(set) var lastRequestedSkillName: String?
    private(set) var lastExcludedMCPServers: Set<String> = []
    private(set) var persistedTurns: [ShepherdPersistedTurn] = []
    var persistedTurnReceipt = ShepherdPersistedTurnReceipt(
        message: "Handover queued in Hindsight",
        isError: false)
    private var permissionContinuation: CheckedContinuation<Bool, Never>?

    func availableToolSpecs(
        forChatID _: UUID,
        projectID _: UUID?,
        includeMCP _: Bool,
        excludedMCPServers: Set<String>
    ) async -> ([ToolSpec], [String: ShepherdToolRoute]) {
        lastExcludedMCPServers = excludedMCPServers
        return (specs, mapping)
    }
    func memoryEntries(forProjectID _: UUID?) async throws -> [PromptMemoryEntry] {
        if let memoryFailure { throw memoryFailure }
        return memoryEntries
    }
    func extensionPromptSections(
        forChatID _: UUID,
        projectID _: UUID?,
        canLoadSkills: Bool,
        requestedSkillName: String?
    ) async -> [String] {
        lastCanLoadSkills = canLoadSkills
        lastRequestedSkillName = requestedSkillName
        return canLoadSkills ? extensionSections : []
    }
    func requestName(server: String, tool: String) -> String { "\(server)__\(tool)" }
    func turnDidPersist(_ turn: ShepherdPersistedTurn) async -> ShepherdPersistedTurnReceipt? {
        extensionEvents.append("persist")
        persistedTurns.append(turn)
        return persistedTurnReceipt
    }
    func authorizeAndInvoke(
        route: ShepherdToolRoute, argumentsJSON: String
    ) async throws -> ToolResult? {
        permissionRequested = true
        let allowed =
            if blockPermission {
                await withCheckedContinuation { permissionContinuation = $0 }
            } else {
                allow
            }
        guard allowed, !Task.isCancelled else { return nil }
        invocations += 1
        if blockExecution { await withCheckedContinuation { executionContinuation = $0 } }
        return ToolResult(content: "ok", isError: false)
    }

    func finishExecution() {
        executionContinuation?.resume()
        executionContinuation = nil
    }

    func waitUntilPermissionRequested() async {
        while !permissionRequested { await Task.yield() }
    }

    func resolvePermission(_ allowed: Bool) {
        permissionContinuation?.resume(returning: allowed)
        permissionContinuation = nil
    }
    func logCall(server: String, tool: String, status: String, duration: TimeInterval) {}
    func cancelPendingPermission() {
        cancellationRequests += 1
        permissionContinuation?.resume(returning: false)
        permissionContinuation = nil
    }
}

private func fakeToolRoute(server: String = "srv", tool: String = "tool") -> ShepherdToolRoute {
    ShepherdToolRoute(
        server: server,
        tool: tool,
        origin: .mcp(
            MCPServerManager.CapabilityToken(
                permissionFingerprint: "test-fingerprint",
                connectionGeneration: UUID())))
}

@MainActor
private final class FakeEnv: ShepherdEnvironment {
    var automaticChatTitles = true
    var availableModels: [ModelRef] = [ModelRef(id: "test-model")]
    var fallbackModelID: String? = "test-model"
    var project: ShepherdProjectContext?
    var blockInitialPersistence = false
    var blockLeadPersistence = false
    var failingPersistenceAttempts: Set<Int> = []
    private(set) var persisted = 0
    private(set) var persistenceAttempts = 0
    private(set) var initialPersistenceRequested = false
    private(set) var checkpoints = 0
    private(set) var touched = 0
    private(set) var metaChanges = 0
    private(set) var activeSessionID: UUID?
    private var persistenceContinuation: CheckedContinuation<Bool, Never>?
    private var pendingPersistenceResult: Bool?

    func generationContext(for modelID: String) -> GenerationContext? {
        guard availableModels.contains(where: { $0.id == modelID }) else { return nil }
        let identity = ModelIdentity(engineProfileID: "test", modelID: modelID)
        let compatibility = ModelCompatibilityResolver.resolve(identity: identity)
        return GenerationContext(
            engineProfileID: "test", engineName: "Test", engineConfigurationRevision: 1,
            identity: identity, compatibility: compatibility)
    }

    func projectContext(forProject id: UUID) async -> ShepherdProjectContext? { project }
    func persist(_ message: ChatMessage, in session: ChatSession) async -> Bool {
        persistenceAttempts += 1
        if failingPersistenceAttempts.contains(persistenceAttempts) { return false }
        // Block only the first incomplete row: the lifecycle path saves the same row again as
        // `started` before streaming, and that second save must not wait on a resolver.
        if (blockInitialPersistence && !message.complete && !initialPersistenceRequested)
            || (blockLeadPersistence && message.role == .user)
        {
            initialPersistenceRequested = true
            if let pendingPersistenceResult {
                self.pendingPersistenceResult = nil
                return pendingPersistenceResult
            }
            let saved = await withCheckedContinuation { continuation in
                persistenceContinuation = continuation
            }
            if !saved { return false }
        }
        persisted += 1
        return true
    }

    func waitUntilInitialPersistenceRequested() async {
        for _ in 0..<5_000 {
            if initialPersistenceRequested { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func resolveInitialPersistence(_ saved: Bool) {
        if let persistenceContinuation {
            persistenceContinuation.resume(returning: saved)
            self.persistenceContinuation = nil
        } else {
            pendingPersistenceResult = saved
        }
    }
    func checkpoint(messageID: String, text: String, thinking: String) async { checkpoints += 1 }
    func sessionTouched(_ session: ChatSession) { touched += 1 }
    func sessionMetaChanged(_ session: ChatSession) { metaChanges += 1 }
    func turnOwnershipChanged(activeSessionID: UUID?) { self.activeSessionID = activeSessionID }
}

@MainActor
private func makeShepherd(
    script: [[GenerationEvent]],
    tools: FakeToolSource = FakeToolSource(),
    env: FakeEnv = FakeEnv()
) -> (ShepherdModel, FakeEngine, FakeToolSource, FakeEnv) {
    let engine = FakeEngine(script: script)
    let shepherd = ShepherdModel(engine: engine, tools: tools, activity: ActivityLog())
    shepherd.env = env
    return (shepherd, engine, tools, env)
}

@MainActor
private func makeBlockingShepherd(
    tools: FakeToolSource = FakeToolSource(),
    env: FakeEnv = FakeEnv()
) -> (ShepherdModel, BlockingEngine, FakeToolSource, FakeEnv) {
    let engine = BlockingEngine()
    let shepherd = ShepherdModel(engine: engine, tools: tools, activity: ActivityLog())
    shepherd.env = env
    return (shepherd, engine, tools, env)
}

private func toolCallRound() -> [GenerationEvent] {
    [
        .toolCalls([ToolCallEvent(id: "c1", name: "srv__tool", argumentsJSON: "{}")]),
        .done(GenStats(ttft: nil, tokens: 1, duration: 0.01)),
    ]
}

private func workerSnapshot(
    attachmentPaths: [String] = [],
    extensionSections: [String] = [],
    project: ShepherdProjectContext? = nil
) -> ShepherdPromptSnapshot {
    ShepherdPromptSnapshot(
        date: Date(timeIntervalSince1970: 0),
        project: project,
        extensionSections: extensionSections,
        messages: [
            ShepherdPromptSnapshot.Message(
                role: .user,
                text: "hello",
                thinking: "",
                complete: true,
                error: nil,
                attachmentPaths: attachmentPaths,
                toolEvents: [])
        ])
}

@Test func goatedExtensionCatalogEntersTheCanonicalSystemPrompt() async {
    let worker = ShepherdGenerationWorker(engine: FakeEngine(script: []))
    let section = "<available_skills><skill name=\"review\" /></available_skills>"
    let turns = await worker.turns(for: workerSnapshot(extensionSections: [section]))

    #expect(turns.first?.role == .system)
    #expect(turns.first?.text.contains(section) == true)
}

@Test @MainActor func slashSkillInvocationIsResolvedDuringTurnPreparation() async throws {
    let tools = FakeToolSource()
    tools.extensionSections = ["GOATED_REQUESTED_SKILL"]
    let (shepherd, engine, _, env) = makeShepherd(
        script: [[.done(GenStats(ttft: nil, tokens: 1, duration: 0.01))]],
        tools: tools)
    defer { _ = env }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.title = "Skill invocation"
    let user = ChatMessage(role: .user)
    user.text = "/review include verification"
    user.complete = true
    session.messages = [user]

    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value

    #expect(tools.lastRequestedSkillName == "review")
    let request = try #require(await engine.requests.first)
    #expect(request.turns.first?.text.contains("GOATED_REQUESTED_SKILL") == true)
    let userTurn = try #require(request.turns.last(where: { $0.role == .user }))
    #expect(
        userTurn.text
            == "Run the review skill now.\n\nAdditional request:\ninclude verification")
    #expect(!userTurn.text.contains("/review"))
    #expect(session.messages.first?.text == "/review include verification")
}

@Test @MainActor func handoffIsADirectCommandWithHostOwnedPersistence() async throws {
    let tools = FakeToolSource()
    tools.specs = [ToolSpec(name: "skill_load", description: "load", parametersJSON: "{}")]
    tools.mapping = ["skill_load": fakeToolRoute(server: "GOATed", tool: "skill_load")]
    tools.extensionSections = ["GOATED_SKILL_CATALOG"]
    let (shepherd, engine, sameTools, env) = makeShepherd(
        script: [
            [
                .token(
                    "Here is the requested handover.\n\n```markdown\n# Handover\n\nReady.\n```\n\nNo memory was written."
                ),
                .done(GenStats(ttft: nil, tokens: 8, duration: 0.01)),
            ]
        ],
        tools: tools)
    defer { _ = env }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.title = "Direct handoff"
    let user = ChatMessage(role: .user)
    user.text = "/handoff include verification"
    user.complete = true
    session.messages = [user]

    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value

    #expect(sameTools.lastRequestedSkillName == nil)
    #expect(sameTools.lastCanLoadSkills == false)
    let request = try #require(await engine.requests.first)
    #expect(request.tools.isEmpty)
    #expect(request.turns.first?.text.contains("<goat_handoff_command>") == true)
    #expect(request.turns.first?.text.contains("GOATED_SKILL_CATALOG") == false)
    let userTurn = try #require(request.turns.last(where: { $0.role == .user }))
    #expect(
        userTurn.text
            == "Prepare the GOAT session handover now.\n\nAdditional request:\ninclude verification")
    let persisted = try #require(sameTools.persistedTurns.first)
    #expect(persisted.kind == .handoff)
    #expect(persisted.commandMessageID == user.id)
    #expect(persisted.messages.last?.text.contains("# Handover") == true)
    let response = try #require(session.messages.last)
    #expect(response.text.hasPrefix("```markdown\n# Handover "))
    #expect(response.text.hasSuffix("\n```"))
    #expect(!response.text.contains("```markdown\n# Handover\n"))
    #expect(!response.text.contains("No memory was written"))
    #expect(response.toolEvents.count == 1)
    #expect(response.toolEvents.first?.server == "Memory")
    #expect(response.toolEvents.first?.tool == "memory_handoff")
    #expect(response.toolEvents.first?.result == "Handover queued in Hindsight")
    #expect(response.toolEvents.first?.isError == false)
    #expect(session.messages.first?.text == "/handoff include verification")
}

@Test @MainActor func failedFinalPersistenceDoesNotWriteLifecycleMemory() async {
    let tools = FakeToolSource()
    let env = FakeEnv()
    env.failingPersistenceAttempts = [3]
    let (shepherd, _, sameTools, sameEnv) = makeShepherd(
        script: [[.token("handover"), .done(GenStats(ttft: nil, tokens: 1, duration: 0.01))]],
        tools: tools,
        env: env)
    defer { _ = sameEnv }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.title = "Failed handoff"
    let user = ChatMessage(role: .user)
    user.text = "/handoff"
    user.complete = true
    session.messages = [user]

    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value

    #expect(sameTools.persistedTurns.isEmpty)
    #expect(session.messages.last?.error?.contains("could not be saved") == true)
}

private func workerRequest() -> GenerationRequest {
    GenerationRequest(
        model: "test-model",
        turns: [ChatTurn(role: .user, text: "hello")],
        effort: .trot)
}

// MARK: - Tests

@Test @MainActor func promptAttachmentLoadingRunsOutsideTheMainActor() async {
    let payload = Data("image".utf8)
    let probe = AttachmentLoaderProbe(payload: payload)
    let engine = FakeEngine(script: [])
    let worker = ShepherdGenerationWorker(engine: engine) { path in
        await probe.load(path)
    }

    let turns = await worker.turns(for: workerSnapshot(attachmentPaths: ["image.png"]))

    #expect(turns.last?.images == [payload])
    #expect(await probe.ranOnMainThread == false)
}

@Test @MainActor func streamWorkerCoalescesATokenBurstBeforePublishing() async throws {
    let tokenCount = 64
    let events =
        Array(repeating: GenerationEvent.token("x"), count: tokenCount)
        + [.done(GenStats(ttft: nil, tokens: tokenCount, duration: 0.01))]
    let engine = FakeEngine(script: [events])
    let worker = ShepherdGenerationWorker(engine: engine)
    var updates: [ShepherdStreamUpdate] = []

    let result = try await worker.stream(workerRequest()) { update in
        updates.append(update)
        return true
    }

    #expect(updates.map(\.text).joined() == String(repeating: "x", count: tokenCount))
    #expect(updates.count == 1)
    #expect(result.stats?.tokens == tokenCount)
}

@Test @MainActor func engineWaitsForTheInitialAssistantRowToPersist() async {
    let env = FakeEnv()
    env.blockInitialPersistence = true
    let (shepherd, engine, _, sameEnv) = makeShepherd(
        script: [[.token("ok"), .done(GenStats(ttft: nil, tokens: 1, duration: 0.01))]],
        env: env)
    defer { _ = sameEnv }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.title = "Durable"
    let user = ChatMessage(role: .user)
    user.text = "hello"
    user.complete = true
    session.messages = [user]

    #expect(shepherd.run(in: session))
    await sameEnv.waitUntilInitialPersistenceRequested()
    #expect(await engine.requests.isEmpty)

    sameEnv.resolveInitialPersistence(true)
    await shepherd.streamTask?.value
    #expect(await engine.requests.count == 1)
}

@Test @MainActor func failedInitialAssistantPersistenceStopsBeforeInference() async {
    let env = FakeEnv()
    env.blockInitialPersistence = true
    let (shepherd, engine, _, sameEnv) = makeShepherd(
        script: [[.token("must not run")]], env: env)
    defer { _ = sameEnv }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.title = "Durable failure"
    let user = ChatMessage(role: .user)
    user.text = "hello"
    user.complete = true
    session.messages = [user]

    #expect(shepherd.run(in: session))
    await sameEnv.waitUntilInitialPersistenceRequested()
    sameEnv.resolveInitialPersistence(false)
    await shepherd.streamTask?.value

    #expect(await engine.requests.isEmpty)
    #expect(session.messages.last?.complete == true)
    #expect(session.messages.last?.error?.contains("persistence") == true)
}

@Test @MainActor func toolInvocationWaitsForItsTranscriptToPersist() async {
    let tools = FakeToolSource()
    tools.mapping = ["srv__tool": fakeToolRoute()]
    let env = FakeEnv()
    env.failingPersistenceAttempts = [3]  // 1 prepared, 2 started, 3 tool-call transcript
    let (shepherd, engine, sameTools, sameEnv) = makeShepherd(
        script: [toolCallRound()], tools: tools, env: env)
    defer { _ = sameEnv }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.title = "Durable tools"
    let user = ChatMessage(role: .user)
    user.text = "run it"
    user.complete = true
    session.messages = [user]

    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value

    #expect(await engine.requests.count == 1)
    #expect(sameTools.invocations == 0)
    #expect(session.messages.last?.error?.contains("transcript") == true)
}

@Test @MainActor func failedToolResultPersistenceStopsBeforeAnotherRound() async {
    let tools = FakeToolSource()
    tools.mapping = ["srv__tool": fakeToolRoute()]
    let env = FakeEnv()
    env.failingPersistenceAttempts = [4]  // 1 prepared, 2 started, 3 transcript, 4 result
    let (shepherd, engine, sameTools, sameEnv) = makeShepherd(
        script: [toolCallRound(), toolCallRound()], tools: tools, env: env)
    defer { _ = sameEnv }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.title = "Durable result"
    let user = ChatMessage(role: .user)
    user.text = "run it"
    user.complete = true
    session.messages = [user]

    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value

    #expect(sameTools.invocations == 1)
    #expect(await engine.requests.count == 1)
    #expect(session.messages.last?.error?.contains("result") == true)
}

@Test @MainActor func streamWorkerStopsWhenTheTurnOwnerRejectsAPublication() async {
    let engine = FakeEngine(
        script: [[.token("partial"), .done(GenStats(ttft: nil, tokens: 1, duration: 0.01))]])
    let worker = ShepherdGenerationWorker(engine: engine)
    var updates: [ShepherdStreamUpdate] = []
    var wasCancelled = false

    do {
        _ = try await worker.stream(workerRequest()) { update in
            updates.append(update)
            return false
        }
    } catch is CancellationError {
        wasCancelled = true
    } catch {}

    #expect(wasCancelled)
    #expect(updates.map(\.text).joined() == "partial")
}

@Test @MainActor func systemPromptCarriesProjectInstructions() async {
    let (shepherd, _, _, env) = makeShepherd(script: [])
    env.project = ShepherdProjectContext(name: "Lab", instructions: "Answer in haiku.")
    let session = ChatSession(effort: .trot, modelID: "test-model", projectID: UUID())
    let turns = await shepherd.turns(for: session)
    #expect(turns.first?.role == .system)
    #expect(turns.first?.text.contains("Project instructions (Lab)") == true)
    #expect(turns.first?.text.contains("Answer in haiku.") == true)
}

@Test @MainActor func projectWorkspaceReachesThePromptWithoutCustomInstructions() async {
    let (shepherd, _, _, env) = makeShepherd(script: [])
    env.project = ShepherdProjectContext(
        name: "Lab", instructions: "", workspacePath: "/Users/test/My Project")
    let session = ChatSession(effort: .trot, modelID: "test-model", projectID: UUID())
    let turns = await shepherd.turns(for: session)
    #expect(turns.first?.text.contains("/Users/test/My Project") == true)
    #expect(turns.first?.text.contains("not an access grant") == true)

    let plainChat = ChatSession(effort: .trot, modelID: "test-model")
    let plainTurns = await shepherd.turns(for: plainChat)
    #expect(plainTurns.first?.text.contains("/Users/test/My Project") == false)
}

@Test(arguments: [false, true])
func executionGuidanceMatchesToolsOfferedInThePlannedRequest(hasTools: Bool) async throws {
    let worker = ShepherdGenerationWorker(engine: FakeEngine(script: []))
    let specs =
        hasTools
        ? [
            ToolSpec(
                name: "project_read", description: "Read a project file", parametersJSON: "{}")
        ] : []
    let plan = try await worker.plan(
        snapshot: workerSnapshot(), model: ModelRef(id: "test-model", contextLength: 32_768),
        effort: .trot, tools: specs)
    let system = try #require(plan.request.turns.first?.text)
    #expect(plan.request.tools == specs)
    #expect(system.contains("Invoke tools through structured tool calls") == hasTools)
    #expect(system.contains("No callable tools are available") == !hasTools)
}

@Test func penBriefAndLegacyAgentGuideRemainDistinctFromWorkspaceFiles() async throws {
    let worker = ShepherdGenerationWorker(engine: FakeEngine(script: []))
    let snapshot = workerSnapshot(
        project: ShepherdProjectContext(
            name: "Empty project", instructions: "Use TypeScript and Vue.", workspacePath: "/tmp/empty-project",
            agentInstructions: "Read README.md before working. Preserve existing files."))
    let names = ["pen_list_files", "pen_read_file", "pen_write_file", "pen_edit_file"]
    let specs = names.map { ToolSpec(name: $0, description: "Pen file tool", parametersJSON: "{}") }
    let plan = try await worker.plan(
        snapshot: snapshot, model: ModelRef(id: "test-model", contextLength: 32_768), effort: .trot, tools: specs)
    let system = try #require(plan.request.turns.first?.text)
    #expect(system.contains("Use TypeScript and Vue."))
    #expect(system.contains("Never guess old_text"))
    #expect(system.contains("An unchanged edit is not progress"))
    #expect(system.contains("do not recreate files"))
    #expect(system.contains("Read README.md before working. Preserve existing files."))
    #expect(system.contains("app-managed Pen brief"))
    #expect(system.contains("separate from workspace files"))
    #expect(system.contains("References to README.md in the app-managed guide refer to the supplied Pen brief"))
    #expect(system.contains("An empty listing is a valid new project"))
    #expect(system.contains("Herder file tools are available for this Pen now"))
    #expect(system.contains("Missing parent directories are created automatically"))
    #expect(!system.contains("standalone cd"))
    #expect(plan.request.tools == specs.sorted { $0.name < $1.name })
}

@Test(arguments: [false, true])
func missingPenFileCapabilitiesAreNeverAdvertised(readOnly: Bool) async throws {
    let worker = ShepherdGenerationWorker(engine: FakeEngine(script: []))
    let specs = readOnly ? [ToolSpec(name: "pen_read_file", description: "Read", parametersJSON: "{}")] : []
    let plan = try await worker.plan(
        snapshot: workerSnapshot(project: ShepherdProjectContext(name: "Lab", instructions: "")),
        model: ModelRef(id: "test-model", contextLength: 32_768), effort: .trot, tools: specs)
    let system = try #require(plan.request.turns.first?.text)
    #expect(!system.contains("Herder file tools are available for this Pen now"))
    #expect(system.contains("No callable tools are available") == !readOnly)
    #expect(system.contains("Pen brief is empty"))
    #expect(system.contains("No project workspace folder is configured"))
}

@Test @MainActor func printedToolCommandsNeverExecute() async {
    let tools = FakeToolSource()
    tools.specs = [ToolSpec(name: "srv__tool", description: "Write file", parametersJSON: "{}")]
    tools.mapping = ["srv__tool": fakeToolRoute(server: "srv", tool: "tool")]
    let (shepherd, engine, _, env) = makeShepherd(
        script: [
            [
                .token("```sh\nsrv__tool --command touch example.txt\n```"),
                .done(GenStats(ttft: nil, tokens: 10, duration: 0.01)),
            ]
        ], tools: tools)
    defer { _ = env }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.title = "File task"
    session.toolsEnabled = true
    let user = ChatMessage(role: .user)
    user.text = "Create example.txt"
    user.complete = true
    session.messages = [user]
    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value
    #expect(await engine.requests.first?.tools.count == 1)
    #expect(tools.invocations == 0)
    // Fenced syntax is ordinary content (ADR-0065): no tool runs and no approval is requested.
    #expect(!tools.permissionRequested)
}

@Test @MainActor func incompleteAndErroredMessagesStayOutOfThePrompt() async {
    let (shepherd, _, _, _) = makeShepherd(script: [])
    let session = ChatSession(effort: .trot, modelID: "test-model")
    let good = ChatMessage(role: .user)
    good.text = "hello"
    good.complete = true
    let streaming = ChatMessage(role: .assistant)
    streaming.text = "half a rep"
    let errored = ChatMessage(role: .assistant)
    errored.text = "boom"
    errored.complete = true
    errored.error = "engine exploded"
    session.messages = [good, streaming, errored]
    let turns = await shepherd.turns(for: session)
    #expect(turns.count == 2)  // system + the one good user turn
}

@Test @MainActor func unknownModelNeverSilentlyDropsUserImages() async throws {
    let (shepherd, _, _, env) = makeShepherd(script: [])
    defer { _ = env }
    let payload = Data("image payload".utf8)
    let attachment = try #require(AttachmentStore.save(payload, ext: "test"))
    defer { AttachmentStore.delete([attachment]) }

    let session = ChatSession(effort: .trot, modelID: "future-multimodal-model")
    let user = ChatMessage(role: .user)
    user.text = "describe this"
    user.attachmentPaths = [attachment]
    user.complete = true
    session.messages = [user]

    let turns = await shepherd.turns(for: session)
    #expect(turns.last?.images == [payload])
}

@Test @MainActor func imageOnlyUserTurnReachesTheEngine() async throws {
    let (shepherd, _, _, env) = makeShepherd(script: [])
    defer { _ = env }
    let payload = Data("image only".utf8)
    let attachment = try #require(AttachmentStore.save(payload, ext: "test"))
    defer { AttachmentStore.delete([attachment]) }

    let session = ChatSession(effort: .trot, modelID: "future-multimodal-model")
    let user = ChatMessage(role: .user)
    user.attachmentPaths = [attachment]
    user.complete = true
    session.messages = [user]

    let turns = await shepherd.turns(for: session)
    #expect(turns.last?.role == .user)
    #expect(turns.last?.text.isEmpty == true)
    #expect(turns.last?.images == [payload])
}

@Test @MainActor func toolWorkContinuesPastEightRoundsUntilTheModelFinishes() async {
    let tools = FakeToolSource()
    tools.mapping = ["srv__tool": fakeToolRoute()]
    // A longer coding workflow must reach its final response without a round cutoff.
    let (shepherd, _, sameTools, env) = makeShepherd(
        script: Array(repeating: toolCallRound(), count: 12) + [[.token("All twelve actions are complete.")]],
        tools: tools, env: FakeEnv()
    )
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.title = "Capped"  // sidestep auto-title's extra engine call
    let user = ChatMessage(role: .user)
    user.text = "go"
    user.complete = true
    session.messages = [user]

    shepherd.run(in: session)
    await shepherd.streamTask?.value

    #expect(sameTools.invocations == 12)
    #expect(
        session.messages.filter { $0.role == .assistant }.count == 13
    )
    #expect(session.messages.last?.text == "All twelve actions are complete.")
    #expect(session.isStreaming == false)
    #expect(env.touched == 1)
}

@Test @MainActor func staleModelHealsToAServedOne() async {
    let env = FakeEnv()
    env.availableModels = [ModelRef(id: "served")]
    env.fallbackModelID = "served"
    let (shepherd, _, _, sameEnv) = makeShepherd(
        script: [[.token("hi"), .done(GenStats(ttft: nil, tokens: 1, duration: 0.01))]],
        env: env
    )
    let session = ChatSession(effort: .trot, modelID: "gone-model")
    session.title = "Healed"
    let user = ChatMessage(role: .user)
    user.text = "hello"
    user.complete = true
    session.messages = [user]

    shepherd.run(in: session)
    await shepherd.streamTask?.value

    #expect(session.modelID == "served")
    #expect(sameEnv.metaChanges >= 1)
}

@Test @MainActor func generationCapturesSelectedModelCapabilities() async throws {
    let capabilities = ModelCapabilities(
        reasoning: .supported(by: .modelDetail),
        advertisedRequestParameters: ["reasoning_effort"],
        reasoningEffortValues: [.none, .low, .medium, .high])
    let env = FakeEnv()
    env.availableModels = [ModelRef(id: "coder", capabilities: capabilities)]
    env.fallbackModelID = "coder"
    let (shepherd, engine, _, sameEnv) = makeShepherd(
        script: [[.done(GenStats(ttft: nil, tokens: 1, duration: 0.01))]],
        env: env)
    defer { _ = sameEnv }
    let session = ChatSession(effort: .summit, modelID: "coder")
    session.title = "Capability snapshot"
    let user = ChatMessage(role: .user)
    user.text = "write code"
    user.complete = true
    session.messages = [user]

    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value

    let sent = try #require(await engine.requests.first)
    #expect(sent.modelCapabilities == capabilities)
}

@Test @MainActor func explicitUnsupportedToolCapabilityOmitsSchemas() async throws {
    let tools = FakeToolSource()
    tools.specs = [ToolSpec(name: "srv__tool", description: "test", parametersJSON: "{}")]
    tools.mapping = ["srv__tool": fakeToolRoute()]
    tools.extensionSections = ["GOATED_SKILL_CATALOG"]
    let env = FakeEnv()
    env.availableModels = [
        ModelRef(
            id: "text-only-coder",
            capabilities: ModelCapabilities(tools: .unsupported(by: .modelDetail)))
    ]
    env.fallbackModelID = "text-only-coder"
    let (shepherd, engine, _, sameEnv) = makeShepherd(
        script: [[.done(GenStats(ttft: nil, tokens: 1, duration: 0.01))]],
        tools: tools, env: env)
    defer { _ = sameEnv }
    let session = ChatSession(effort: .trot, modelID: "text-only-coder")
    session.title = "No tool template"
    session.toolsEnabled = true
    let user = ChatMessage(role: .user)
    user.text = "hello"
    user.complete = true
    session.messages = [user]

    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value

    let sent = try #require(await engine.requests.first)
    #expect(sent.tools.isEmpty)
    #expect(sent.turns.first?.text.contains("GOATED_SKILL_CATALOG") == false)
    #expect(tools.lastCanLoadSkills == false)
}

@Test @MainActor func generationPassesPerChatMCPServerExclusionsToTheToolLayer() async throws {
    let tools = FakeToolSource()
    let env = FakeEnv()
    let (shepherd, _, sameTools, sameEnv) = makeShepherd(
        script: [[.done(GenStats(ttft: nil, tokens: 1, duration: 0.01))]],
        tools: tools,
        env: env)
    defer { _ = sameEnv }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.disabledMCPServers = ["calendar", "drive"]
    let user = ChatMessage(role: .user)
    user.text = "hello"
    user.complete = true
    session.messages = [user]

    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value

    #expect(sameTools.lastExcludedMCPServers == ["calendar", "drive"])
}

@Test @MainActor func pastureMeterPrefersServerUsage() async {
    // Hold the fakes: the Shepherd's env reference is deliberately weak.
    let (shepherd, _, _, env) = makeShepherd(
        script: [
            [
                .token("hi"),
                .done(
                    GenStats(
                        ttft: nil, tokens: 40, duration: 0.5,
                        promptTokens: 960, tokensAreExact: true)),
            ]
        ]
    )
    defer { _ = env }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.title = "Metered"
    let user = ChatMessage(role: .user)
    user.text = "hello"
    user.complete = true
    session.messages = [user]

    shepherd.run(in: session)
    await shepherd.streamTask?.value

    #expect(session.lastContextTokens == 1000)
    #expect(session.contextIsExact == true)
    #expect(!session.contextWindowIsExact)
}

@Test @MainActor func pastureMeterFallsBackToEstimate() async {
    // Hold the fakes: the Shepherd's env reference is deliberately weak.
    let (shepherd, _, _, env) = makeShepherd(
        script: [[.token("reply"), .done(GenStats(ttft: nil, tokens: 1, duration: 0.5))]]
    )
    defer { _ = env }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.title = "Estimated"
    let user = ChatMessage(role: .user)
    user.text = String(repeating: "a", count: 4000)
    user.complete = true
    session.messages = [user]

    shepherd.run(in: session)
    await shepherd.streamTask?.value

    #expect(session.contextIsExact == false)
    #expect((session.lastContextTokens ?? 0) >= 1000)  // At least the planner's user-turn estimate.
}

@Test @MainActor func partialServerUsageRemainsAnEstimate() async {
    let (shepherd, _, _, env) = makeShepherd(
        script: [
            [
                .token("hi"),
                .done(
                    GenStats(
                        ttft: nil, tokens: 40, duration: 0.5,
                        promptTokens: 960, tokensAreExact: false)),
            ]
        ]
    )
    defer { _ = env }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.title = "Partially metered"
    let user = ChatMessage(role: .user)
    user.text = "hello"
    user.complete = true
    session.messages = [user]

    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value

    #expect(session.lastContextTokens == 1_000)
    #expect(!session.contextIsExact)
}

@Test @MainActor func untrimmedPlanClearsAStaleContextNotice() async {
    let (shepherd, _, _, env) = makeShepherd(
        script: [[.token("ok"), .done(GenStats(ttft: nil, tokens: 1, duration: 0.01))]]
    )
    defer { _ = env }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.title = "Fits"
    session.lastPromptWasTrimmed = true
    let user = ChatMessage(role: .user)
    user.text = "hello"
    user.complete = true
    user.contextNotice = "Old trim notice"
    session.messages = [user]

    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value

    #expect(user.contextNotice == nil)
    #expect(!session.lastPromptWasTrimmed)
}

@Test @MainActor func omittedMemoryDoesNotAddAnInlineContextWarning() async {
    let tools = FakeToolSource()
    tools.memoryEntries = [
        PromptMemoryEntry(
            identifier: "global:oversized",
            title: "Oversized",
            summary: String(repeating: "memory ", count: 1_000))
    ]
    let (shepherd, _, _, env) = makeShepherd(
        script: [[.token("ok"), .done(GenStats(ttft: nil, tokens: 1, duration: 0.01))]],
        tools: tools)
    defer { _ = env }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    let user = ChatMessage(role: .user)
    user.text = "hello"
    user.complete = true
    session.messages = [user]

    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value

    #expect(session.lastPromptWasTrimmed)
    #expect(user.contextNotice == nil)
}

@Test @MainActor func plannerUsesTheServedModelsContextWindowAndClampsOutput() async {
    let env = FakeEnv()
    env.availableModels = [ModelRef(id: "test-model", contextLength: 2_048)]
    let (shepherd, engine, _, sameEnv) = makeShepherd(
        script: [[.token("ok"), .done(GenStats(ttft: nil, tokens: 1, duration: 0.01))]],
        env: env
    )
    defer { _ = sameEnv }
    let session = ChatSession(effort: .climb, modelID: "test-model")
    session.title = "Budgeted"
    let user = ChatMessage(role: .user)
    user.text = "hello"
    user.complete = true
    session.messages = [user]

    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value

    let request = await engine.requests.first
    #expect(request?.maxTokens == 1_024)
    #expect(session.lastContextWindow == 2_048)
}

@Test @MainActor func impossiblePromptFailsLocallyWithoutStartingTheEngine() async {
    let env = FakeEnv()
    env.availableModels = [ModelRef(id: "test-model", contextLength: 256)]
    let (shepherd, engine, _, sameEnv) = makeShepherd(script: [], env: env)
    defer { _ = sameEnv }
    let session = ChatSession(effort: .summit, modelID: "test-model")
    session.title = "Too small"
    session.lastPromptWasTrimmed = true
    let user = ChatMessage(role: .user)
    user.text = "hello"
    user.complete = true
    session.messages = [user]

    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value

    #expect(await engine.requests.isEmpty)
    #expect(session.messages.count == 2)
    #expect(session.messages.last?.role == .assistant)
    #expect(session.messages.last?.complete == true)
    #expect(session.messages.last?.error?.contains("no input capacity") == true)
    #expect(!session.lastPromptWasTrimmed)
    #expect(!shepherd.hasActiveTurn)
}

@Test @MainActor func trimmingDropsWholeOldExchangesAndAnnotatesTheCurrentUser() async {
    let env = FakeEnv()
    env.availableModels = [ModelRef(id: "test-model", contextLength: 2_048)]
    let (shepherd, engine, _, sameEnv) = makeShepherd(
        script: [[.token("ok"), .done(GenStats(ttft: nil, tokens: 1, duration: 0.01))]],
        env: env
    )
    defer { _ = sameEnv }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.title = "Trimmed"
    let oldUser = ChatMessage(role: .user)
    oldUser.text = String(repeating: "old context ", count: 400)
    oldUser.complete = true
    let oldAssistant = ChatMessage(role: .assistant)
    oldAssistant.text = "old reply"
    oldAssistant.complete = true
    let currentUser = ChatMessage(role: .user)
    currentUser.text = "current question"
    currentUser.complete = true
    session.messages = [oldUser, oldAssistant, currentUser]

    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value

    let request = await engine.requests.first
    #expect(request?.turns.contains(where: { $0.text.contains("old context") }) == false)
    #expect(request?.turns.contains(where: { $0.text == "current question" }) == true)
    #expect(currentUser.contextNotice?.contains("1 older exchange") == true)
    #expect(session.lastPromptWasTrimmed)
}

@Test @MainActor func reservationRejectsARapidSecondSendBeforeStreamingStarts() {
    let (shepherd, _, _, env) = makeBlockingShepherd()
    defer { _ = env }
    let first = ChatSession(effort: .trot, modelID: "test-model")
    let second = ChatSession(effort: .trot, modelID: "test-model")

    #expect(shepherd.reserve(in: first) != nil)
    #expect(shepherd.reserve(in: second) == nil)
    #expect(shepherd.activeSessionID == first.id)
    #expect(first.isStreaming)
    #expect(!second.isStreaming)

    shepherd.stop(sessionID: first.id)
    #expect(!shepherd.hasActiveTurn)
    #expect(!first.isStreaming)
}

@Test @MainActor func stalePreparationTokenCannotStartOrStopANewerTurnInTheSameChat() async throws {
    let (shepherd, engine, _, env) = makeBlockingShepherd()
    defer { _ = env }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.title = "Same chat"
    let user = ChatMessage(role: .user)
    user.text = "hello"
    user.complete = true
    session.messages = [user]

    let staleTurnID = try #require(shepherd.reserve(in: session))
    shepherd.stop(sessionID: session.id, turnID: staleTurnID)
    let currentTurnID = try #require(shepherd.reserve(in: session))

    shepherd.startReserved(in: session, turnID: staleTurnID)
    shepherd.stop(sessionID: session.id, turnID: staleTurnID)
    await Task.yield()
    #expect(await engine.requests.isEmpty)
    #expect(shepherd.activeTurnID == currentTurnID)
    #expect(session.isStreaming)

    shepherd.startReserved(in: session, turnID: currentTurnID)
    await engine.waitUntilStarted()
    let currentTask = shepherd.streamTask
    shepherd.stop(sessionID: session.id, turnID: currentTurnID)
    await currentTask?.value
    #expect(!shepherd.hasActiveTurn)
}

@Test @MainActor func liveTurnRejectsAnotherChatAndOnlyItsOwnerCanStopIt() async {
    let (shepherd, engine, tools, env) = makeBlockingShepherd()
    defer { _ = env }
    let owner = ChatSession(effort: .trot, modelID: "test-model")
    owner.title = "Owner"
    let user = ChatMessage(role: .user)
    user.text = "hello"
    user.complete = true
    owner.messages = [user]
    let other = ChatSession(effort: .trot, modelID: "test-model")
    other.title = "Other"

    #expect(shepherd.run(in: owner))
    await engine.waitUntilStarted()
    let ownerTask = shepherd.streamTask

    #expect(!shepherd.run(in: other))
    #expect(await engine.requests.count == 1)
    #expect(shepherd.activeSessionID == owner.id)
    #expect(owner.isStreaming)
    #expect(!other.isStreaming)

    shepherd.stop(sessionID: other.id)
    await Task.yield()
    #expect(shepherd.activeSessionID == owner.id)
    #expect(owner.isStreaming)
    #expect(tools.invocations == 0)
    #expect(tools.cancellationRequests == 0)

    shepherd.stop(sessionID: owner.id)
    await ownerTask?.value
    #expect(tools.cancellationRequests == 1)
    #expect(!shepherd.hasActiveTurn)
    #expect(shepherd.streamTask == nil)
    #expect(!owner.isStreaming)
    #expect(!other.isStreaming)
}

@Test @MainActor func stopWhilePermissionIsPendingNeverInvokesTheTool() async {
    let tools = FakeToolSource()
    tools.specs = [ToolSpec(name: "srv__tool", description: "test", parametersJSON: "{}")]
    tools.mapping = ["srv__tool": fakeToolRoute()]
    tools.blockPermission = true
    let (shepherd, _, sameTools, env) = makeShepherd(script: [toolCallRound()], tools: tools)
    defer { _ = env }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.title = "Permission"
    session.toolsEnabled = true
    let user = ChatMessage(role: .user)
    user.text = "use it"
    user.complete = true
    session.messages = [user]

    #expect(shepherd.run(in: session))
    await sameTools.waitUntilPermissionRequested()
    let turnTask = shepherd.streamTask
    shepherd.stop(sessionID: session.id)
    sameTools.resolvePermission(true)
    await turnTask?.value

    #expect(sameTools.invocations == 0)
    #expect(sameTools.cancellationRequests == 1)
    #expect(session.messages.last?.toolEvents.first?.result?.contains("outcome is unknown") == true)
    #expect(session.messages.last?.toolEvents.first?.isError == true)
}

@Test @MainActor func composerWaitsForHistoryAndTheAppWideTurnSlot() {
    #expect(
        !ChatView.permitsSend(
            localStateReady: true, engineIsHealthy: true, messagesLoaded: false, isBusy: false))
    #expect(
        !ChatView.permitsSend(
            localStateReady: true, engineIsHealthy: true, messagesLoaded: true, isBusy: true))
    #expect(
        !ChatView.permitsSend(
            localStateReady: true, engineIsHealthy: false, messagesLoaded: true, isBusy: false))
    #expect(
        !ChatView.permitsSend(
            localStateReady: false, engineIsHealthy: true, messagesLoaded: true, isBusy: false))
    #expect(
        ChatView.permitsSend(
            localStateReady: true, engineIsHealthy: true, messagesLoaded: true, isBusy: false))
}

@Test @MainActor func chatNavigationOnlyProbesWhenTheResolvedModelChanges() {
    #expect(
        !AppModel.selectionNeedsCapabilityProbe(
            previousModelID: "coder", currentModelID: "coder"))
    #expect(
        AppModel.selectionNeedsCapabilityProbe(
            previousModelID: "coder", currentModelID: "reasoner"))
    #expect(
        !AppModel.selectionNeedsCapabilityProbe(
            previousModelID: "coder", currentModelID: nil))
}

@Test @MainActor func staleChatModelResolvesToTheCurrentEngineDefault() {
    let available = [ModelRef(id: "mtplx-qwen"), ModelRef(id: "mtplx-coder")]

    #expect(
        AppModel.resolvedModelID(
            requested: "mlx-community/Qwen3-8B-4bit",
            defaultModelID: "mtplx-qwen",
            availableModels: available)
            == "mtplx-qwen")
    #expect(
        AppModel.resolvedModelID(
            requested: "gone-model",
            defaultModelID: "also-gone",
            availableModels: available)
            == "mtplx-qwen")
}

@Test @MainActor func contextStatusKeepsTheWindowCapturedWithTheRequest() throws {
    let session = ChatSession(effort: .trot, modelID: "new-model")
    session.lastContextTokens = 700
    session.lastContextWindow = 1_000
    session.lastContextPressureLimit = 800
    session.contextWindowIsExact = true
    session.lastPromptWasTrimmed = true
    let status = try #require(
        ContextStatus(
            session: session,
            models: [ModelRef(id: "new-model", contextLength: 8_000)],
            defaultModelID: nil))

    #expect(status.window == 1_000)
    #expect(status.pressureLimit == 800)
    #expect(status.ratio == 0.875)
    #expect(status.label == "~700 / 800 input")
    #expect(status.worthShowing)
}

@Test @MainActor func contextStatusSeparatesExactUsageFromFallbackWindow() throws {
    let session = ChatSession(effort: .trot, modelID: "model-without-metadata")
    session.lastContextTokens = 1_000
    session.contextIsExact = true
    session.lastContextWindow = 8_192
    session.contextWindowIsExact = false
    session.lastContextPressureLimit = 8_192
    let status = try #require(
        ContextStatus(
            session: session,
            models: [ModelRef(id: "model-without-metadata")],
            defaultModelID: nil))

    #expect(status.exact)
    #expect(!status.windowExact)
    #expect(status.label == "1.0k / ~8.2k")
}

@Test func slashSelectionMovesOneItemAndWrapsAtBothEnds() {
    #expect(ComposerSlashSelection.moved(from: 0, by: 1, itemCount: 6) == 1)
    #expect(ComposerSlashSelection.moved(from: 1, by: 1, itemCount: 6) == 2)
    #expect(ComposerSlashSelection.moved(from: 5, by: 1, itemCount: 6) == 0)
    #expect(ComposerSlashSelection.moved(from: 0, by: -1, itemCount: 6) == 5)
    #expect(ComposerSlashSelection.moved(from: 0, by: 1, itemCount: 0) == nil)
}

@Test func markdownComposerFindsClosedAndUnclosedCodeFences() throws {
    let closed = "before\n```swift\nprint(\"hello\")\n```\nafter"
    let closedRange = try #require(MarkdownComposerSyntax.fencedRanges(in: closed).first)
    #expect((closed as NSString).substring(with: closedRange) == "```swift\nprint(\"hello\")\n```\n")

    let unclosed = "before\n~~~json\n{\"ready\":true}"
    let unclosedRange = try #require(MarkdownComposerSyntax.fencedRanges(in: unclosed).first)
    #expect((unclosed as NSString).substring(with: unclosedRange) == "~~~json\n{\"ready\":true}")
}

@Test func markdownComposerHeightGrowsThenCapsAtEightLines() {
    let oneLine = MarkdownComposerLayout.clampedHeight(for: 18, fontSize: 14)
    let fourLines = MarkdownComposerLayout.clampedHeight(for: 76, fontSize: 14)
    let oversized = MarkdownComposerLayout.clampedHeight(for: 1_000, fontSize: 14)
    let expectedMaximum = CGFloat(14 * 1.35 * 8 + 12)

    #expect(fourLines > oneLine)
    #expect(oversized == expectedMaximum)
}

@Test @MainActor func chatMCPSelectionPreservesLegacyOffAndSupportsIndividualServers() {
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.toolsEnabled = false

    #expect(!session.isMCPServerEnabled("drive"))
    session.setMCPServer("drive", enabled: true, activeServerNames: ["drive", "calendar"])
    #expect(session.isMCPServerEnabled("drive"))
    #expect(!session.isMCPServerEnabled("calendar"))

    session.setMCPServer("drive", enabled: false, activeServerNames: ["drive", "calendar"])
    #expect(!session.isMCPServerEnabled("drive"))
    session.setMCPServer("calendar", enabled: true, activeServerNames: ["drive", "calendar"])
    #expect(session.isMCPServerEnabled("calendar"))
}

@MainActor
@Test(arguments: [true, false])
func automaticTitlesRespectPreference(enabled: Bool) async {
    let env = FakeEnv()
    defer { _ = env }
    env.automaticChatTitles = enabled
    let engine = FakeEngine(script: [
        [.token("Use a daily backup schedule."), .done(GenStats(ttft: nil, tokens: 6, duration: 0.1))],
        [.token("Planning Reliable Daily Backups"), .done(GenStats(ttft: nil, tokens: 4, duration: 0.1))],
    ])
    let shepherd = ShepherdModel(engine: engine, tools: FakeToolSource(), activity: ActivityLog())
    shepherd.env = env
    let session = ChatSession(effort: .graze, modelID: "test-model")
    let user = ChatMessage(role: .user)
    user.text = "Help me plan daily backups"
    user.complete = true
    session.messages = [user]
    #expect(session.title == "New chat")
    shepherd.run(in: session)
    await shepherd.streamTask?.value
    #expect(session.title == (enabled ? "Planning Reliable Daily Backups" : "New chat"))
    #expect(await engine.requests.count == (enabled ? 2 : 1))
}

@MainActor
@Test(arguments: ["custom", "default", "disabled"])
func pendingAutomaticTitleRespectsManualRenameAndPreference(change: String) async {
    let env = FakeEnv()
    defer { _ = env }
    let session = ChatSession(effort: .graze, modelID: "test-model")
    let user = ChatMessage(role: .user)
    user.text = "Help me plan backups"
    user.complete = true
    session.messages = [user]
    let engine = FakeEngine(
        script: [
            [.token("Keep three copies."), .done(GenStats(ttft: nil, tokens: 3, duration: 0.1))],
            [.token("Generated Backup Plan"), .done(GenStats(ttft: nil, tokens: 3, duration: 0.1))],
        ],
        onRequest: { request in
            if request == 2 {
                switch change {
                case "custom": session.title = "My backup notes"
                case "default": session.title = "New chat"
                default: env.automaticChatTitles = false
                }
            }
        })
    let shepherd = ShepherdModel(engine: engine, tools: FakeToolSource(), activity: ActivityLog())
    shepherd.env = env
    shepherd.run(in: session)
    await shepherd.streamTask?.value
    #expect(session.title == (change == "custom" ? "My backup notes" : "New chat"))
}

@MainActor
@Test(arguments: ["thinking", "failure", "multiline", "too long", "default"])
func automaticTitlesFallBackWhenTheNamingRequestCannotSupplyATitle(result: String) async {
    let env = FakeEnv()
    defer { _ = env }
    let invalidTitle: String
    switch result {
    case "multiline": invalidTitle = "Title one\nTitle two"
    case "too long": invalidTitle = String(repeating: "word ", count: 20)
    case "default": invalidTitle = "New chat"
    default: invalidTitle = ""
    }
    let engine = FakeEngine(
        script: [
            [.token("Use a daily backup schedule.")],
            [.thinking("Thinking about a title"), .token(invalidTitle)],
        ], failingRequest: result == "failure" ? 2 : nil)
    let shepherd = ShepherdModel(engine: engine, tools: FakeToolSource(), activity: ActivityLog())
    shepherd.env = env
    let session = ChatSession(effort: .graze, modelID: "test-model")
    let user = ChatMessage(role: .user)
    user.text = "Help me plan\n daily backups for all my computers"
    user.complete = true
    session.messages = [user]
    shepherd.run(in: session)
    await shepherd.streamTask?.value
    #expect(session.title == "Help me plan daily backups for")
    #expect(env.metaChanges == 1)
    let requests = await engine.requests
    #expect(requests.last?.maxTokens == 1024)
}

@MainActor
@Test func automaticTitlesRecoverAfterAnEmptyFirstReply() async {
    let env = FakeEnv()
    defer { _ = env }
    let engine = FakeEngine(script: [
        [.thinking("No answer this time")],
        [.token("Keep three copies of your files.")],
        [.token("Planning Reliable Daily Backups")],
    ])
    let shepherd = ShepherdModel(engine: engine, tools: FakeToolSource(), activity: ActivityLog())
    shepherd.env = env
    let session = ChatSession(effort: .graze, modelID: "test-model")
    let user = ChatMessage(role: .user)
    user.text = "Help me plan backups"
    user.complete = true
    session.messages = [user]
    shepherd.run(in: session)
    await shepherd.streamTask?.value
    #expect(session.hasDefaultTitle)
    let retry = ChatMessage(role: .user)
    retry.text = "Please try again"
    retry.complete = true
    session.messages.append(retry)
    shepherd.run(in: session)
    await shepherd.streamTask?.value
    #expect(session.title == "Planning Reliable Daily Backups")
    let request = await engine.requests.last
    #expect(request?.turns.first?.text.contains("Assistant: Keep three copies") == true)
}

@MainActor
@Test(arguments: [true, false])
func automaticTitlesNameToolWorkflowsWithAnEmptyFinalMessage(narrated: Bool) async {
    let tools = FakeToolSource()
    tools.mapping = ["srv__tool": fakeToolRoute()]
    let firstRound: [GenerationEvent] =
        (narrated ? [.token("Let me create the Vite configuration file.")] : []) + toolCallRound()
    // The title request follows the whole turn (ADR-0085), so it is the last scripted response.
    let (shepherd, engine, _, env) = makeShepherd(
        script: [
            firstRound,
            [.done(GenStats(ttft: nil, tokens: 0, duration: 0.01))],
            [.token("Vue TypeScript Project Setup")],
        ], tools: tools)
    defer { _ = env }
    let session = ChatSession(effort: .graze, modelID: "test-model")
    let user = ChatMessage(role: .user)
    user.text = "Create a Vue TypeScript project skeleton"
    user.complete = true
    session.messages = [user]
    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value
    #expect(tools.invocations == 1)
    #expect(session.messages.last?.text.isEmpty == true)
    #expect(session.title == "Vue TypeScript Project Setup")
    #expect(env.metaChanges == 1)
    #expect(await engine.requests.count == 3)
}

@MainActor
@Test func newChatNavigationUsesVisiblePenContext() {
    let pen = UUID()
    let other = UUID()
    let known = Set([pen, other])
    #expect(AppModel.newChatPenID(selectedPenID: nil, chatProjectID: pen, showingPensHome: false, penIDs: known) == pen)
    #expect(
        AppModel.newChatPenID(selectedPenID: other, chatProjectID: pen, showingPensHome: false, penIDs: known) == other)
    #expect(AppModel.newChatPenID(selectedPenID: nil, chatProjectID: nil, showingPensHome: false, penIDs: known) == nil)
    #expect(AppModel.newChatPenID(selectedPenID: nil, chatProjectID: pen, showingPensHome: true, penIDs: known) == nil)
    #expect(
        AppModel.newChatPenID(selectedPenID: nil, chatProjectID: UUID(), showingPensHome: false, penIDs: known) == nil)
}

@Test @MainActor func optionalHindsightFailureDoesNotPreventAChatResponse() async {
    let tools = FakeToolSource()
    tools.memoryFailure = ShepherdMemoryContextError.optionalProviderUnavailable
    let (shepherd, _, _, env) = makeShepherd(
        script: [[.token("Still working"), .done(GenStats(ttft: nil, tokens: 2, duration: 0.01))]], tools: tools)
    defer { _ = env }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    let user = ChatMessage(role: .user)
    user.text = "hello"
    user.complete = true
    session.messages = [user]
    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value
    #expect(session.messages.last?.text == "Still working")
    #expect(session.messages.last?.complete == true)
    #expect(!session.isStreaming)
}

@Test @MainActor func requiredMemoryFailureStillStopsChatPreparation() async {
    let tools = FakeToolSource()
    tools.memoryFailure = NSError(domain: "LocalStore", code: 1)
    let (shepherd, _, _, env) = makeShepherd(
        script: [[.token("Must not run"), .done(GenStats(ttft: nil, tokens: 1, duration: 0.01))]], tools: tools)
    defer { _ = env }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    let user = ChatMessage(role: .user)
    user.text = "hello"
    user.complete = true
    session.messages = [user]
    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value
    #expect(!session.messages.contains { $0.text == "Must not run" })
    #expect(!session.isStreaming)
}

@Test @MainActor func extensionLifecycleEndsAfterDurableCompletion() async {
    let (shepherd, _, tools, env) = makeShepherd(script: [
        [.token("Done"), .done(GenStats(ttft: nil, tokens: 1, duration: 0.01))]
    ])
    defer { _ = env }
    env.automaticChatTitles = false
    let session = ChatSession(effort: .trot, modelID: "test-model")
    let message = ChatMessage(role: .user)
    message.text = "hello"
    message.complete = true
    session.messages = [message]
    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value
    #expect(tools.extensionEvents == ["prepare", "persist", "end"])
    #expect(!shepherd.hasActiveTurn)
}

@Test @MainActor func failedExtensionPreparationStillEndsAndReleasesOwnership() async {
    let (shepherd, engine, tools, env) = makeShepherd(script: [])
    defer { _ = env }
    tools.preparationFailure = NSError(domain: "test", code: 1)
    let session = ChatSession(effort: .trot, modelID: "test-model")
    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value
    #expect(tools.extensionEvents == ["prepare", "end"])
    #expect(await engine.requests.isEmpty)
    #expect(!shepherd.hasActiveTurn)
}

@Test @MainActor func failedPersistenceDoesNotPublishAnExtensionCommit() async {
    let env = FakeEnv()
    env.failingPersistenceAttempts = [2]
    env.automaticChatTitles = false
    let (shepherd, _, tools, _) = makeShepherd(
        script: [[.token("Done"), .done(GenStats(ttft: nil, tokens: 1, duration: 0.01))]], env: env)
    let session = ChatSession(effort: .trot, modelID: "test-model")
    let message = ChatMessage(role: .user)
    message.text = "hello"
    message.complete = true
    session.messages = [message]
    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value
    #expect(tools.extensionEvents == ["prepare", "end"])
}

@Test @MainActor func cancelledGenerationEndsExtensionLifecycleWithoutCommit() async {
    let (shepherd, engine, tools, env) = makeBlockingShepherd()
    defer { _ = env }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    let user = ChatMessage(role: .user)
    user.text = "hello"
    user.complete = true
    session.messages = [user]
    #expect(shepherd.run(in: session))
    await engine.waitUntilStarted()
    let task = shepherd.streamTask
    shepherd.stop()
    await task?.value
    #expect(tools.extensionEvents == ["prepare", "cancelled"])
    #expect(!shepherd.hasActiveTurn)
}

@Test @MainActor func textualToolMarkupSurfacesAnExecutionFailureWithoutRunningIt() async {
    let tools = FakeToolSource()
    tools.specs = [ToolSpec(name: "pen_write_file", description: "Write file", parametersJSON: "{}")]
    tools.mapping = ["pen_write_file": fakeToolRoute(server: "srv", tool: "tool")]
    let (shepherd, engine, _, env) = makeShepherd(
        script: Array(
            repeating: [
                .token(
                    "<tool_call>\n<function=pen_write_file>\n<parameter=path>test.txt</parameter>\n</function>\n</tool_call>"
                ),
                .done(GenStats(ttft: nil, tokens: 20, duration: 0.01)),
            ], count: 2), tools: tools)
    defer { _ = env }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.title = "File task"
    let user = ChatMessage(role: .user)
    user.text = "Create test.txt"
    user.complete = true
    session.messages = [user]
    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value
    #expect(tools.invocations == 0)
    #expect(!tools.permissionRequested)
    #expect(session.messages.last?.error?.contains("No tool was executed") == true)
    #expect(await engine.requests.count == 2)
}

@Test @MainActor func malformedToolResponseRetriesThroughTheNormalPermissionGate() async throws {
    let tools = FakeToolSource()
    tools.specs = [ToolSpec(name: "srv__tool", description: "Write file", parametersJSON: "{}")]
    tools.mapping = ["srv__tool": fakeToolRoute()]
    tools.allow = false
    let broken = "<function=srv__tool>\n<parameter=path>. </parameter>\n</function>\n</tool_call>"
    let (shepherd, engine, _, env) = makeShepherd(
        script: [[.token(broken)], toolCallRound(), [.token("The requested action was denied.")]], tools: tools)
    defer { _ = env }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.title = "File task"
    let user = ChatMessage(role: .user)
    user.text = "Create a file"
    user.complete = true
    session.messages = [user]
    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value
    #expect(tools.invocations == 0)
    #expect(tools.permissionRequested)
    #expect(session.messages[1].toolEvents.isEmpty)
    #expect(session.messages[2].toolEvents.first?.denied == true)
    let requests = await engine.requests
    #expect(requests.count == 3)
    #expect(requests[1].turns.first?.text.contains("No tool from that response was executed") == true)
    #expect(!requests[1].turns.contains { $0.text == broken })
    #expect(requests[2].turns.contains { $0.role == .tool && $0.text.contains("denied") })
}

@Test @MainActor func mixedPrintedMarkupExecutesOnlyStructuredToolAndContinues() async {
    let tools = FakeToolSource()
    tools.specs = [ToolSpec(name: "srv__tool", description: "Fixture tool", parametersJSON: "{}")]
    tools.mapping = ["srv__tool": fakeToolRoute()]
    let (shepherd, engine, _, env) = makeShepherd(
        script: [
            [
                .token("Narrative before the printed <tool_call> markup."),
                .toolCalls([
                    ToolCallEvent(id: "structured-1", name: "srv__tool", argumentsJSON: "{}")
                ]),
                .token("Narrative after the printed markup."),
                .done(GenStats(ttft: nil, tokens: 12, duration: 0.01)),
            ],
            [
                .token("The structured tool result was received."),
                .done(GenStats(ttft: nil, tokens: 8, duration: 0.01)),
            ],
        ], tools: tools)
    defer { _ = env }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.title = "Tool fixture"
    let user = ChatMessage(role: .user)
    user.text = "Run the fixture tool"
    user.complete = true
    session.messages = [user]

    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value
    #expect(tools.invocations == 1)
    #expect(tools.permissionRequested)
    #expect(await engine.requests.count == 2)
    #expect(session.messages.contains { $0.text.contains("structured tool result") })
}

@Test @MainActor func toolMarkupDetectionRequiresStandaloneKnownEnvelopes() {
    let body = "<tool_call>\n<function=pen_list_files>\n<parameter=path>. </parameter>\n</function>\n</tool_call>"
    let names: Set<String> = ["pen_list_files"]
    #expect(ShepherdModel.hasUnexecutedToolMarkup(body, toolNames: names))
    #expect(!ShepherdModel.hasUnexecutedToolMarkup("Example: " + body, toolNames: names))
    #expect(!ShepherdModel.hasUnexecutedToolMarkup("Example:\n```xml\n" + body + "\n```", toolNames: names))
    #expect(!ShepherdModel.hasUnexecutedToolMarkup("Example:\n~~~xml\n" + body + "\n~~~", toolNames: names))
    #expect(!ShepherdModel.hasUnexecutedToolMarkup(body, toolNames: []))
    #expect(!ShepherdModel.hasUnexecutedToolMarkup("</tool_call>", toolNames: names))
    #expect(
        !ShepherdModel.hasUnexecutedToolMarkup(
            "<tool_call>\nunknown\n<arg_key>x</arg_key><arg_value>y</arg_value>\n</tool_call>", toolNames: names))
    let glm = "<tool_call>\npen_list_files\n<arg_key>path</arg_key><arg_value>.</arg_value>\n</tool_call>"
    #expect(UnexecutedToolMarkupDetector.detect(glm, toolNames: names)?.style == .glm)
    #expect(UnexecutedToolMarkupDetector.detect("</tool_call>", toolNames: names)?.confidence == .low)
    #expect(!ShepherdModel.hasUnexecutedToolMarkup("vec4<f32>(1.0) < T", toolNames: names))
}

@Test func fileRepairTrackerBlocksDeleteAfterCreateConflictAndStopsCycles() {
    var tracker = FileRepairProgressTracker()
    let key = FileRepairProgressTracker.Key(workspaceIdentity: "workspace", relativePath: "src/main.swift")
    let conflict = ToolExecutionDiagnostic(fileObservations: [
        FileOperationObservation(
            workspaceIdentity: key.workspaceIdentity, relativePath: key.relativePath,
            kind: .create, outcome: .alreadyExists)
    ])
    #expect(tracker.observe(conflict) == nil)
    let removal = ToolExecutionDiagnostic(fileObservations: [
        FileOperationObservation(
            workspaceIdentity: key.workspaceIdentity, relativePath: key.relativePath,
            kind: .remove, outcome: .succeeded)
    ])
    #expect(tracker.preflight(removal) == FileRepairProgressTracker.blockedRemovalMessage)

    var cycleTracker = FileRepairProgressTracker()
    var stop: String?
    for digest in ["B", "A", "B", "A", "B"] {
        stop = cycleTracker.observe(
            ToolExecutionDiagnostic(fileObservations: [
                FileOperationObservation(
                    workspaceIdentity: key.workspaceIdentity, relativePath: key.relativePath,
                    kind: .edit, outcome: .succeeded, beforeDigest: "previous", afterDigest: digest)
            ]))
    }
    #expect(stop?.contains("content cycle") == true)
}

@Test @MainActor func toolFormatRecoveryStopsIfItsFailedResponseCannotBeSaved() async {
    let tools = FakeToolSource()
    tools.specs = [ToolSpec(name: "srv__tool", description: "Tool", parametersJSON: "{}")]
    let env = FakeEnv()
    env.failingPersistenceAttempts = [3]  // 1 prepared, 2 started, 3 failed row
    let (shepherd, engine, _, _) = makeShepherd(
        script: [[.token("<function=srv__tool></function></tool_call>")], toolCallRound()],
        tools: tools, env: env)
    defer { _ = env }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.title = "Recovery persistence"
    let user = ChatMessage(role: .user)
    user.text = "Use the tool"
    user.complete = true
    session.messages = [user]
    shepherd.run(in: session)
    await shepherd.streamTask?.value
    #expect(await engine.requests.count == 1)
    #expect(!tools.permissionRequested)
    #expect(session.messages.last?.error?.contains("could not be saved") == true)
}

@Test @MainActor func formatRecoveryRetainsCompletedToolResultsWithoutReplayingTheCall() async {
    let tools = FakeToolSource()
    tools.specs = [ToolSpec(name: "srv__tool", description: "Tool", parametersJSON: "{}")]
    tools.mapping = ["srv__tool": fakeToolRoute()]
    let (shepherd, engine, _, env) = makeShepherd(
        script: [toolCallRound(), [.token("<function=srv__tool></function></tool_call>")], [.token("Done.")]],
        tools: tools)
    defer { _ = env }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.title = "Recovery history"
    let user = ChatMessage(role: .user)
    user.text = "Use the tool"
    user.complete = true
    session.messages = [user]
    shepherd.run(in: session)
    await shepherd.streamTask?.value
    #expect(tools.invocations == 1)
    let requests = await engine.requests
    #expect(requests.count == 3)
    #expect(requests[2].turns.contains { $0.role == .tool && $0.text == "ok" })
    #expect(requests[2].turns.filter { !$0.toolCalls.isEmpty }.count == 1)
}

private actor LiveRecoveryProbeEngine: InferenceEngine {
    let engine: OpenAICompatEngine
    var injectMalformedResponse: Bool
    init(engine: OpenAICompatEngine, injectMalformedResponse: Bool) {
        self.engine = engine
        self.injectMalformedResponse = injectMalformedResponse
    }
    func health() async -> EngineHealth { await engine.health() }
    func stream(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
        if injectMalformedResponse {
            injectMalformedResponse = false
            return AsyncThrowingStream {
                $0.yield(.token("<function=pen_list_files>\n<parameter=path>. </parameter>\n</function>\n</tool_call>"))
                $0.finish()
            }
        }
        return await engine.stream(request)
    }
}

extension Tag {
    @Tag static var integration: Self
}

@Test(
    .tags(.integration), .enabled(if: ProcessInfo.processInfo.environment["GOAT_LIVE_TOOLS"] == "1"),
    arguments: [false, true])
@MainActor func liveNativeCodingUsesStructuredCallsAndVerifiesBytes(recoverMalformedResponse: Bool) async throws {
    let config = try #require(try EngineStore.load(from: Home.enginesFile))
    let profile = try #require(config.engines.first { $0.id == config.active })
    let endpoint = try #require(URL(string: profile.url))
    let engine = OpenAICompatEngine(
        config: EngineConfig(
            baseURL: endpoint, apiKey: try CredentialStore.get("engine.\(profile.id).apiKey"),
            name: profile.name, requestStyle: profile.requestStyle))
    let health = await engine.health()
    #expect(health.isOK, "Configured engine health: \(health)")
    let model = try #require(health.models.first { $0.id == "Qwen3-Coder-30B-A3B-Instruct-MLX-4bit" })
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("goat-live-coding-\(UUID())")
    let workspace = root.appendingPathComponent("workspace")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try Persistence.ChatDatabase(path: root.appendingPathComponent("test.sqlite").path)
    let activity = ActivityLog()
    let mcp = MCPModel(db: db, activity: activity)
    let router = AppToolRouter(
        mcp: mcp, memory: MemoryModel(activity: activity), activity: activity,
        builtInSkillsRoot: root.appendingPathComponent("missing"),
        globalSkillsRoot: root.appendingPathComponent("missing"))
    await router.filePermissions.load(database: db)
    router.workspaceForProject = { _ in workspace }
    router.nameForProject = { _ in "Disposable acceptance Pen" }
    let session = ChatSession(effort: .trot, modelID: model.id)
    session.projectID = UUID()
    let env = FakeEnv()
    env.availableModels = [model]
    env.fallbackModelID = model.id
    env.project = ShepherdProjectContext(
        name: "Disposable acceptance Pen", instructions: "", workspacePath: workspace.path)
    let probeEngine = LiveRecoveryProbeEngine(engine: engine, injectMalformedResponse: recoverMalformedResponse)
    let shepherd = ShepherdModel(engine: probeEngine, tools: router, activity: activity)
    shepherd.env = env
    let user = ChatMessage(role: .user)
    user.text = """
        In this disposable Pen, list the workspace, create src/check.ts with exactly export const value = 'one'; followed by one newline, read it back, then edit 'one' to 'two' and read it back again. Do not create any other files. Use the Pen tools to do the work, then report the verified result.
        """
    if !recoverMalformedResponse {
        user.text +=
            " After editing, use pen_search to locate the literal text 'two'. Then use pen_run_command to run node with args ['-e', \"const fs=require('fs'); if(!fs.readFileSync('src/check.ts','utf8').includes('two')) process.exit(1); console.log('GOAT_COMMAND_VERIFIED')\"], and poll pen_command_status until it finishes with exit code 0. Do not install packages or request network access."
    }
    user.complete = true
    session.messages = [user]
    #expect(shepherd.run(in: session))
    let deadline = ContinuousClock.now.advanced(by: .seconds(240))
    var approvals = 0
    while shepherd.hasActiveTurn && ContinuousClock.now < deadline {
        if let request = mcp.pendingPermission {
            // This grant belongs only to the random chat in the disposable test database.
            #expect(request.allowsPenScopes)
            mcp.resolvePermission(request.tool == "pen_run_command" ? .allowOnce : .allowChat, requestID: request.id)
            approvals += 1
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    if shepherd.hasActiveTurn { shepherd.stop() }
    await shepherd.streamTask?.value
    let events = session.messages.flatMap(\.toolEvents)
    print(
        "LIVE_NATIVE_TOOLS", events.map { "\($0.tool):\($0.isError ? "error" : "ok")" }, "approvals", approvals,
        "title", session.title)
    for message in session.messages where message.error != nil { print("LIVE_NATIVE_ERROR", message.error ?? "") }
    #expect(approvals == (recoverMalformedResponse ? 1 : 2))
    if !recoverMalformedResponse {
        #expect(events.contains { $0.tool == "pen_search" && !$0.isError })
        #expect(
            events.contains {
                $0.tool == "pen_command_status" && $0.result?.contains("GOAT_COMMAND_VERIFIED") == true && !$0.isError
            })
    }
    #expect(events.contains { $0.tool == "pen_list_files" && !$0.isError })
    #expect(events.contains { $0.tool == "pen_write_file" && !$0.isError })
    #expect(events.contains { $0.tool == "pen_edit_file" && !$0.isError })
    #expect(events.filter { $0.tool == "pen_read_file" && !$0.isError }.count >= 2)
    #expect(
        try String(contentsOf: workspace.appendingPathComponent("src/check.ts"), encoding: .utf8)
            == "export const value = 'two';\n")
    #expect(!session.hasDefaultTitle)
}

@Test @MainActor func leadDuringGenerationIsDurableAndJoinsTheNextResponse() async {
    let env = FakeEnv()
    env.automaticChatTitles = false
    let engine = BlockingEngine()
    let shepherd = ShepherdModel(engine: engine, tools: FakeToolSource(), activity: ActivityLog())
    shepherd.env = env
    let session = ChatSession(effort: .graze, modelID: "test-model")
    let user = ChatMessage(role: .user)
    user.text = "Create a project"
    user.complete = true
    session.messages = [user]
    shepherd.run(in: session)
    await engine.waitUntilStarted()
    #expect(await shepherd.lead("Use Vue instead", in: session))
    #expect(shepherd.pendingLeadCount == 1)
    #expect(session.messages.last?.complete == true)
    #expect(!(await shepherd.lead("Wrong chat", in: ChatSession(effort: .graze, modelID: "test-model"))))
    await engine.finishCurrent([.token("I was planning React.")])
    await engine.waitForRequests(2)
    let requests = await engine.requests
    #expect(requests.last?.turns.last?.text == "Use Vue instead")
    #expect(shepherd.pendingLeadCount == 0)
    await engine.finishCurrent([.token("I will use Vue.")])
    await shepherd.streamTask?.value
    #expect(session.messages.last?.text == "I will use Vue.")
    #expect(!session.isStreaming)
    #expect(!(await shepherd.lead("Too late", in: session)))
}

@Test(arguments: [true, false]) @MainActor
func leadWaitsForTheCurrentApprovalAndPreservesItsOutcome(approved: Bool) async {
    let tools = FakeToolSource()
    tools.mapping = ["srv__tool": fakeToolRoute()]
    tools.blockPermission = true
    // The title request follows the whole turn (ADR-0085), so it is the last scripted response.
    let (shepherd, engine, _, env) = makeShepherd(
        script: [
            [.token("I will create the files.")] + toolCallRound(),
            [.token("I will explain the next step.")],
            [.token("Create Vue Project")],
        ], tools: tools)
    defer { _ = env }
    let session = ChatSession(effort: .graze, modelID: "test-model")
    let user = ChatMessage(role: .user)
    user.text = "Create a Vue project"
    user.complete = true
    session.messages = [user]
    shepherd.run(in: session)
    await tools.waitUntilPermissionRequested()
    #expect(session.hasDefaultTitle)
    #expect(session.isStreaming)
    #expect(await shepherd.lead("Explain the next step after this action", in: session))
    #expect(tools.cancellationRequests == 0)
    #expect(shepherd.pendingLeadCount == 1)
    #expect(session.messages.flatMap(\.toolEvents).first?.result == nil)
    #expect(await engine.requests.count == 1)
    tools.resolvePermission(approved)
    await shepherd.streamTask?.value
    #expect(tools.invocations == (approved ? 1 : 0))
    let call = session.messages.flatMap(\.toolEvents).first
    #expect(call?.denied == !approved)
    #expect(call?.result == (approved ? "ok" : "User denied this tool call."))
    let requests = await engine.requests
    #expect(requests.count == 3)
    #expect(requests[1].turns.last?.text == "Explain the next step after this action")
    #expect(requests.last?.turns.first?.text.contains("Write a 3-5 word title") == true)
    #expect(session.messages.last?.text == "I will explain the next step.")
    #expect(session.title == "Create Vue Project")
}

@Test @MainActor func failedLeadSaveKeepsItOutOfTheConversationAndStopDoesNotRestart() async {
    let env = FakeEnv()
    env.automaticChatTitles = false
    let engine = BlockingEngine()
    let shepherd = ShepherdModel(engine: engine, tools: FakeToolSource(), activity: ActivityLog())
    shepherd.env = env
    let session = ChatSession(effort: .graze, modelID: "test-model")
    let user = ChatMessage(role: .user)
    user.text = "Please do the task"
    user.complete = true
    session.messages = [user]
    shepherd.run(in: session)
    await engine.waitUntilStarted()
    env.failingPersistenceAttempts = [env.persistenceAttempts + 1]
    #expect(!(await shepherd.lead("Unsaved", in: session)))
    #expect(!session.messages.contains { $0.text == "Unsaved" })
    env.failingPersistenceAttempts = []
    #expect(await shepherd.lead("Saved follow-up", in: session))
    shepherd.stop()
    await shepherd.streamTask?.value
    #expect(await engine.requests.count == 1)
    #expect(session.messages.last?.error?.contains("before applying your Lead") == true)
    #expect(!session.isStreaming)
}

@Test @MainActor func outputLimitExplainsTheStopAndDoesNotExecutePartialToolCalls() async {
    let tools = FakeToolSource()
    tools.mapping = ["srv__tool": fakeToolRoute()]
    let env = FakeEnv()
    env.automaticChatTitles = false
    let (shepherd, _, _, _) = makeShepherd(
        script: [
            toolCallRound() + [
                .done(GenStats(ttft: nil, tokens: 100, duration: 1, finishReason: "length"))
            ]
        ], tools: tools, env: env)
    let session = ChatSession(effort: .graze, modelID: "test-model")
    let user = ChatMessage(role: .user)
    user.text = "Please do the task"
    user.complete = true
    session.messages = [user]
    shepherd.run(in: session)
    await shepherd.streamTask?.value
    #expect(tools.invocations == 0)
    #expect(session.messages.last?.error?.contains("output limit") == true)
}

@Test @MainActor func emptyResponseExplainsWhyTheAgentStopped() async {
    let (shepherd, _, _, env) = makeShepherd(script: [[.thinking("Thinking only")]])
    defer { _ = env }
    let session = ChatSession(effort: .graze, modelID: "test-model")
    let user = ChatMessage(role: .user)
    user.text = "Please do the task"
    user.complete = true
    session.messages = [user]
    shepherd.run(in: session)
    await shepherd.streamTask?.value
    #expect(session.messages.last?.error?.contains("without a final reply") == true)
    #expect(!session.isStreaming)
}

@Test @MainActor func leadFinishesAnActiveOperationAndSkipsTheRemainingOldCalls() async {
    let tools = FakeToolSource()
    tools.mapping = ["srv__tool": fakeToolRoute()]
    tools.blockExecution = true
    let env = FakeEnv()
    env.automaticChatTitles = false
    let (shepherd, engine, _, _) = makeShepherd(
        script: [
            [
                .toolCalls([
                    ToolCallEvent(id: "one", name: "srv__tool", argumentsJSON: "{}"),
                    ToolCallEvent(id: "two", name: "srv__tool", argumentsJSON: "{}"),
                ])
            ],
            [.token("The first action finished. I will follow your new direction.")],
        ], tools: tools, env: env)
    let session = ChatSession(effort: .graze, modelID: "test-model")
    let user = ChatMessage(role: .user)
    user.text = "Please do the task"
    user.complete = true
    session.messages = [user]
    shepherd.run(in: session)
    while tools.invocations == 0 { await Task.yield() }
    #expect(await shepherd.lead("Do something different next", in: session))
    #expect(await engine.requests.count == 1)
    #expect(session.messages.first(where: { $0.role == .assistant })?.toolEvents.first?.result == nil)
    tools.finishExecution()
    await shepherd.streamTask?.value
    #expect(tools.invocations == 1)
    let events = session.messages.flatMap(\.toolEvents)
    #expect(events.first?.result == "ok")
    #expect(events.last?.result?.contains("Lead instruction") == true)
    #expect(await engine.requests.count == 2)
}

@Test @MainActor func leadSaveFinishingAfterTheResponseStillReachesTheNextRequest() async {
    let env = FakeEnv()
    env.automaticChatTitles = false
    let engine = BlockingEngine()
    let shepherd = ShepherdModel(engine: engine, tools: FakeToolSource(), activity: ActivityLog())
    shepherd.env = env
    let session = ChatSession(effort: .graze, modelID: "test-model")
    let user = ChatMessage(role: .user)
    user.text = "Please do the task"
    user.complete = true
    session.messages = [user]
    shepherd.run(in: session)
    await engine.waitUntilStarted()
    env.blockLeadPersistence = true
    let saving = Task { await shepherd.lead("Use the saved direction", in: session) }
    await env.waitUntilInitialPersistenceRequested()
    #expect(session.messages.last?.complete == false)
    #expect(!(await shepherd.lead("Duplicate send", in: session)))
    await engine.finishCurrent([.token("The original answer.")])
    env.resolveInitialPersistence(true)
    #expect(await saving.value)
    await engine.waitForRequests(2)
    #expect(await engine.requests.last?.turns.last?.text == "Use the saved direction")
    await engine.finishCurrent([.token("Applied the direction.")])
    await shepherd.streamTask?.value
    #expect(session.messages.last?.text == "Applied the direction.")
    #expect(!session.isStreaming)
}

@Test @MainActor func leadDuringAToolResponseLetsItsCurrentActionFinish() async {
    let env = FakeEnv()
    env.automaticChatTitles = false
    let tools = FakeToolSource()
    tools.mapping = ["srv__tool": fakeToolRoute()]
    let engine = BlockingEngine()
    let shepherd = ShepherdModel(engine: engine, tools: tools, activity: ActivityLog())
    shepherd.env = env
    let session = ChatSession(effort: .graze, modelID: "test-model")
    let user = ChatMessage(role: .user)
    user.text = "Create a file"
    user.complete = true
    session.messages = [user]
    shepherd.run(in: session)
    await engine.waitUntilStarted()
    #expect(await shepherd.lead("Explain the next step afterwards", in: session))
    await engine.finishCurrent(toolCallRound())
    await engine.waitForRequests(2)
    #expect(tools.invocations == 1)
    #expect(session.messages.flatMap(\.toolEvents).first?.result == "ok")
    #expect(await engine.requests.last?.turns.last?.text == "Explain the next step afterwards")
    await engine.finishCurrent([.token("Here is the next step.")])
    await shepherd.streamTask?.value
}

@Test @MainActor func stopStillCancelsApprovalWithLeadQueued() async {
    let env = FakeEnv()
    env.automaticChatTitles = false
    let tools = FakeToolSource()
    tools.mapping = ["srv__tool": fakeToolRoute()]
    tools.blockPermission = true
    let (shepherd, engine, _, _) = makeShepherd(script: [toolCallRound()], tools: tools, env: env)
    let session = ChatSession(effort: .graze, modelID: "test-model")
    let user = ChatMessage(role: .user)
    user.text = "Create a file"
    user.complete = true
    session.messages = [user]
    shepherd.run(in: session)
    await tools.waitUntilPermissionRequested()
    #expect(await shepherd.lead("Explain afterwards", in: session))
    shepherd.stop()
    await shepherd.streamTask?.value
    #expect(tools.invocations == 0)
    #expect(tools.cancellationRequests == 1)
    #expect(await engine.requests.count == 1)
    #expect(session.messages.last?.error?.contains("before applying your Lead") == true)
    #expect(!session.isStreaming)
}

@Test @MainActor func stopPreservesACompletedToolResultAndNeverStartsTheRemainingCalls() async throws {
    let tools = FakeToolSource()
    tools.mapping = ["srv__tool": fakeToolRoute()]
    tools.blockExecution = true
    let env = FakeEnv()
    env.automaticChatTitles = false
    let (shepherd, engine, _, _) = makeShepherd(
        script: [
            [
                .toolCalls([
                    ToolCallEvent(id: "completed", name: "srv__tool", argumentsJSON: "{}"),
                    ToolCallEvent(id: "unstarted", name: "srv__tool", argumentsJSON: "{}"),
                ])
            ]
        ], tools: tools, env: env)
    let session = ChatSession(effort: .graze, modelID: "test-model")
    let user = ChatMessage(role: .user)
    user.text = "Create two files"
    user.complete = true
    session.messages = [user]
    shepherd.run(in: session)
    while tools.invocations == 0 { await Task.yield() }
    let task = shepherd.streamTask
    shepherd.stop(sessionID: session.id)
    tools.finishExecution()
    await task?.value
    let events = session.messages.flatMap(\.toolEvents)
    #expect(events.count == 2)
    #expect(events[0].result == "ok")
    #expect(!events[0].isError)
    #expect(events[1].result == "Not executed because the turn was stopped.")
    #expect(events[1].isError)
    #expect(tools.invocations == 1)
    #expect(await engine.requests.count == 1)
    #expect(!session.isStreaming)
}

@Test @MainActor func endingWithRunningCommandsAddsAVisibleNoticeWithoutErasingTheReply() async {
    let tools = FakeToolSource()
    tools.pendingWorkNotice = "The agent ended with 1 command job still running. GOAT stopped it."
    let env = FakeEnv()
    env.automaticChatTitles = false
    let (shepherd, _, _, _) = makeShepherd(script: [[.token("I started the build.")]], tools: tools, env: env)
    let session = ChatSession(effort: .graze, modelID: "test-model")
    let user = ChatMessage(role: .user)
    user.text = "Build the project"
    user.complete = true
    session.messages = [user]
    shepherd.run(in: session)
    await shepherd.streamTask?.value
    #expect(session.messages.contains { $0.text == "I started the build." && $0.error == nil })
    #expect(session.messages.last?.error == tools.pendingWorkNotice)
    #expect(session.messages.last?.complete == true)
}

@Test @MainActor func toolOnlyStreamPublishesCoalescedMetricsWithoutTranscriptText() async throws {
    let worker = ShepherdGenerationWorker(
        engine: FakeEngine(script: [
            Array(repeating: .toolInput(bytes: 3), count: 100)
                + [.done(GenStats(ttft: 40, tokens: 100, duration: 43))]
        ]))
    let message = ChatMessage(role: .assistant)
    var publications = 0
    _ = try await worker.stream(workerRequest()) { update in
        publications += 1
        message.appendStream(text: update.text, thinking: update.thinking, toolInputBytes: update.toolInputBytes)
        return true
    }
    #expect(publications == 1)
    #expect(message.liveMetrics.estimatedTokens == 100)
    #expect(message.liveMetrics.startedAt != nil)
    #expect(message.text.isEmpty && message.thinking.isEmpty && message.toolEvents.isEmpty)
}

@Test @MainActor func failedNativeCallsGetActionSpecificCorrectionWithoutRepeatingUntrustedOutput() async throws {
    let events = ["pen_write_file", "pen_edit_file", "pen_stop_command"].map {
        ShepherdPromptSnapshot.ToolEvent(
            id: UUID().uuidString, requestName: $0,
            arguments: "{}", result: "UNTRUSTED_TOOL_INSTRUCTION", isError: true)
    }
    let snapshot = ShepherdPromptSnapshot(
        date: .now, project: nil, extensionSections: [],
        messages: [
            .init(
                role: .assistant, text: "", thinking: "", complete: true, error: nil,
                attachmentPaths: [], toolEvents: events)
        ])
    let names: Set<String> = ["pen_write_file", "pen_edit_file", "pen_stop_command", "pen_run_command"]
    let hint = ShepherdGenerationWorker.recoveryGuidance(snapshot: snapshot, toolNames: names)
    #expect(hint.contains("Do not retry the same creation"))
    #expect(hint.contains("new_text differs"))
    #expect(hint.contains("exact job_id"))
    #expect(!hint.contains("UNTRUSTED_TOOL_INSTRUCTION"))
    let redirected = ShepherdPromptSnapshot(
        date: .now, project: nil, extensionSections: [],
        messages:
            snapshot.messages + [
                .init(
                    role: .user, text: "Stop editing and explain the design", thinking: "",
                    complete: true, error: nil, attachmentPaths: [], toolEvents: [])
            ])
    #expect(ShepherdGenerationWorker.recoveryGuidance(snapshot: redirected, toolNames: names).isEmpty)
    #expect(ShepherdGenerationWorker.recoveryGuidance(snapshot: snapshot, toolNames: []).isEmpty)
    let denied = ShepherdPromptSnapshot(
        date: .now, project: nil, extensionSections: [],
        messages: [
            .init(
                role: .assistant, text: "", thinking: "", complete: true, error: nil, attachmentPaths: [],
                toolEvents: [
                    .init(
                        id: "denied", requestName: "pen_write_file", arguments: "{}", result: "Denied", isError: true,
                        denied: true)
                ])
        ])
    #expect(ShepherdGenerationWorker.recoveryGuidance(snapshot: denied, toolNames: names).isEmpty)
}

@Test func textDocumentsEnterThePromptAsTextAndNeverAsImages() async throws {
    let document = try #require(TextAttachment(name: "goats.swift", text: "let goats = 7"))
    let encoded = try #require(document.encoded)
    let image = Data("image".utf8)
    let worker = ShepherdGenerationWorker(engine: FakeEngine(script: [])) { path in
        path.hasSuffix(".goatdoc") ? encoded : image
    }
    let turns = await worker.turns(for: workerSnapshot(attachmentPaths: ["file.goatdoc", "image.png"]))
    #expect(turns.last?.text.contains("goats.swift") == true)
    #expect(turns.last?.text.contains("let goats = 7") == true)
    #expect(turns.last?.images == [image])
}

// MARK: - Prefix stability (ADR-0085)

private func failedEditSnapshot(hostNotes: [String] = [], trailingUser: Bool = false) -> ShepherdPromptSnapshot {
    var messages = [
        ShepherdPromptSnapshot.Message(
            role: .user, text: "Fix the import.", thinking: "", complete: true, error: nil,
            attachmentPaths: [], toolEvents: []),
        ShepherdPromptSnapshot.Message(
            role: .assistant, text: "", thinking: "", complete: true, error: nil,
            attachmentPaths: [],
            toolEvents: [
                ShepherdPromptSnapshot.ToolEvent(
                    id: "edit-1", requestName: "pen_edit_file",
                    arguments: #"{"path":"a.ts","old_text":"x","new_text":"y"}"#,
                    result: "old_text was not found.", isError: true)
            ]),
    ]
    if trailingUser {
        messages.append(
            ShepherdPromptSnapshot.Message(
                role: .user, text: "Try again.", thinking: "", complete: true, error: nil,
                attachmentPaths: [], toolEvents: []))
    }
    var snapshot = ShepherdPromptSnapshot(
        date: Date(timeIntervalSince1970: 0), project: nil, extensionSections: [], messages: messages)
    snapshot.hostNotes = hostNotes
    return snapshot
}

@Test func recoveryHintsRideOnTheNewestToolResultAndLeaveTheSystemTurnUnchanged() async {
    let worker = ShepherdGenerationWorker(engine: FakeEngine(script: []))
    let toolNames: Set<String> = ["pen_edit_file", "pen_read_file"]
    let withFailure = await worker.turns(for: failedEditSnapshot(), toolsAvailable: true, toolNames: toolNames)
    let clean = await worker.turns(
        for: ShepherdPromptSnapshot(
            date: Date(timeIntervalSince1970: 0), project: nil, extensionSections: [],
            messages: [failedEditSnapshot().messages[0]]),
        toolsAvailable: true, toolNames: toolNames)

    // Byte-identical system turn whether or not the last round failed.
    #expect(withFailure.first?.role == .system)
    #expect(withFailure.first?.text == clean.first?.text)
    #expect(withFailure.first?.text.contains("Next-action correction") == false)

    let last = withFailure.last
    #expect(last?.role == .tool)
    #expect(last?.toolCallID == "edit-1")
    #expect(last?.text.hasPrefix("old_text was not found.") == true)
    #expect(last?.text.contains("[GOAT note]") == true)
    #expect(last?.text.contains("Next-action correction") == true)
    #expect(last?.text.contains("pen_edit_file failed") == true)
}

@Test func hostNotesAttachToTheNewestUserTurnWhenNoToolResultEndsTheExchange() async {
    let worker = ShepherdGenerationWorker(engine: FakeEngine(script: []))
    let turns = await worker.turns(
        for: failedEditSnapshot(hostNotes: ["Use the structured tool interface."], trailingUser: true),
        toolsAvailable: true, toolNames: ["pen_edit_file"])

    #expect(turns.last?.role == .user)
    #expect(turns.last?.text.hasPrefix("Try again.") == true)
    #expect(turns.last?.text.contains("[GOAT note]\nUse the structured tool interface.") == true)
    #expect(turns.filter { $0.role == .user }.count == 2)
    #expect(turns.first?.text.contains("structured tool interface") == false)
}

@Test @MainActor func automaticTitleWaitsUntilTheToolTurnEnds() async throws {
    let tools = FakeToolSource()
    tools.specs = [ToolSpec(name: "srv__tool", description: "Fixture tool", parametersJSON: "{}")]
    tools.mapping = ["srv__tool": fakeToolRoute()]
    let (shepherd, engine, _, env) = makeShepherd(
        script: [
            toolCallRound(),
            [.token("Done."), .done(GenStats(ttft: nil, tokens: 1, duration: 0.01))],
            [.token("Fixture Tool Run"), .done(GenStats(ttft: nil, tokens: 3, duration: 0.01))],
        ], tools: tools)
    defer { _ = env }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    let user = ChatMessage(role: .user)
    user.text = "Run the fixture tool"
    user.complete = true
    session.messages = [user]

    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value

    let requests = await engine.requests
    #expect(requests.count == 3)
    // Rounds one and two share the prefix; only the final request is the title prompt.
    #expect(requests[0].turns.first?.text == requests[1].turns.first?.text)
    #expect(requests[1].turns.contains { $0.role == .tool })
    #expect(requests[2].turns.first?.role == .user)
    #expect(requests[2].turns.first?.text.contains("Write a 3-5 word title") == true)
    #expect(session.title == "Fixture Tool Run")
    #expect(tools.invocations == 1)
}

@Test @MainActor func exactUsageCalibratesTheNextPlanForTheChat() async throws {
    let env = FakeEnv()
    env.availableModels = [ModelRef(id: "test-model", contextLength: 32_000)]
    let (shepherd, engine, _, sameEnv) = makeShepherd(
        script: [
            [
                .token("First."),
                .done(GenStats(ttft: nil, tokens: 1, duration: 0.01, promptTokens: 40, tokensAreExact: true)),
            ],
            [
                .token("Second."),
                .done(GenStats(ttft: nil, tokens: 1, duration: 0.01, promptTokens: 60, tokensAreExact: true)),
            ],
        ], env: env)
    defer { _ = sameEnv }
    let session = ChatSession(effort: .trot, modelID: "test-model")
    session.title = "Calibrated"
    let user = ChatMessage(role: .user)
    user.text = "hello"
    user.complete = true
    session.messages = [user]

    #expect(session.contextCalibrationRatio == 1.0)
    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value
    let first = session.contextCalibrationRatio
    #expect(first != 1.0)
    #expect(first >= PromptBudgeter.minimumCalibration && first <= PromptBudgeter.maximumCalibration)
    #expect(session.contextCalibrationSamples == 1)
    #expect(session.lastContextTokens == 41)
    #expect(session.contextIsExact)

    let follow = ChatMessage(role: .user)
    follow.text = "again"
    follow.complete = true
    session.messages.append(follow)
    #expect(shepherd.run(in: session))
    await shepherd.streamTask?.value
    #expect(session.contextCalibrationSamples == 2)
    #expect(await engine.requests.count == 2)
}
