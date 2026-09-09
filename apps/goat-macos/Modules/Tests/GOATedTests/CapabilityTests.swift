import Foundation
import Testing

@testable import GOATed
@testable import Pronk
@testable import Tools

private struct FixtureExtension: Extension {
    let manifest: ExtensionManifest
    let contributions: ExtensionContributions
    init(
        _ id: String, scopeVersion: Int = 1, dependencies: Set<ExtensionID> = [],
        contributions: ExtensionContributions = .init()
    ) {
        manifest = ExtensionManifest(id: id, version: "0.1.0", apiVersion: scopeVersion, dependencies: dependencies)
        self.contributions = contributions
    }
}
private actor Journal: PromptProvider, ModelToolProvider, TurnObserver {
    var events: [String] = []
    var invocations = 0
    let name: String
    init(_ name: String = "fixture_tool") { self.name = name }
    func prompt(for context: ExtensionContext) async throws -> String {
        events.append("prompt")
        return "Fixture context"
    }
    func tools(for context: ExtensionContext) async throws -> [ToolSchema] {
        events.append("tools")
        return [
            ToolSchema(
                name: name, description: "Fixture",
                inputSchemaJSON:
                    #"{"type":"object","additionalProperties":false,"properties":{"count":{"type":"integer","minimum":1,"maximum":3}},"required":["count"]}"#
            )
        ]
    }
    func invoke(_ call: ToolCallRequest, context: ExtensionContext) async throws -> ToolResult {
        invocations += 1
        return ToolResult(content: "ok")
    }
    func turnWillPrepare(_ context: ExtensionContext) async throws { events.append("prepare") }
    func turnDidPersist(_ turn: PersistedTurn) async throws -> ObserverReceipt? {
        events.append("persist")
        return ObserverReceipt(message: "saved")
    }
    func turnDidEnd(_ context: ExtensionContext, outcome: TurnOutcome) async throws {
        events.append(outcome.rawValue)
    }
}
private actor Barrier {
    private var opened = false
    private var waits: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waits.append($0) }
    }
    func open() {
        opened = true
        let all = waits
        waits = []
        all.forEach { $0.resume() }
    }
}
private struct ManualClock: ExtensionClock {
    let scheduled: Barrier
    let advance: Barrier
    func sleep(for duration: Duration) async throws {
        await scheduled.open()
        await advance.wait()
    }
}
private struct HungPrompt: PromptProvider {
    let entered: Barrier
    let release: Barrier
    func prompt(for context: ExtensionContext) async throws -> String {
        await entered.open()
        await release.wait()
        return "late secret"
    }
}
private func context(pen: UUID? = nil) -> ExtensionContext {
    ExtensionContext(view: ExtensionView(chatID: UUID(), penID: pen), turnID: UUID())
}

@Test func extensionLifecycleIsOrderedAndPersistenceIsOnce() async throws {
    let runtime = ExtensionRuntime()
    let journal = Journal()
    let context = context()
    _ = try await runtime.activate(
        FixtureExtension(
            "example.journal", contributions: .init(prompts: [journal], tools: [journal], observers: [journal])))
    let snapshot = try await runtime.prepareTurn(context)
    #expect(snapshot.promptSections[0].contains("example.journal"))
    let turn = PersistedTurn(context: context, title: "test", createdAt: .now, messages: [])
    #expect(await runtime.didPersist(turn).count == 1)
    #expect(await runtime.didPersist(turn).isEmpty)
    await runtime.endTurn(context.turnID, outcome: .completed)
    await runtime.endTurn(context.turnID, outcome: .completed)
    #expect(await journal.events == ["prepare", "prompt", "tools", "persist", "completed"])
    await #expect(throws: (any Error).self) {
        _ = try await runtime.invoke(snapshot.tools[0].handle, argumentsJSON: #"{"count":1}"#) { _, _ in true }
    }
}

@Test func extensionScopesAndToolCollisionsFailClosed() async throws {
    let runtime = ExtensionRuntime()
    let pen = UUID()
    let a = Journal()
    let b = Journal()
    _ = try await runtime.activate(FixtureExtension("example.a", contributions: .init(tools: [a])))
    _ = try await runtime.activate(FixtureExtension("example.b", contributions: .init(tools: [b])), scope: .pen(pen))
    #expect(try await runtime.prepareTurn(context()).tools.count == 1)
    #expect(try await runtime.prepareTurn(context(pen: pen)).tools.isEmpty)
    #expect(try await runtime.prepareTurn(context(), reservedToolNames: ["fixture_tool"]).tools.isEmpty)
}

@Test func invalidActivationDoesNotPublishAnyCapabilities() async throws {
    let runtime = ExtensionRuntime()
    await #expect(throws: CapabilityError.incompatibleAPI) {
        _ = try await runtime.activate(FixtureExtension("example.bad", scopeVersion: 2))
    }
    await #expect(throws: CapabilityError.missingDependency) {
        _ = try await runtime.activate(
            FixtureExtension("example.missing", dependencies: [ExtensionID(rawValue: "missing")]))
    }
    #expect(await runtime.activeExtensions().isEmpty)
}

@Test func dependentExtensionDeactivatesWithItsDependency() async throws {
    let runtime = ExtensionRuntime()
    let token = try await runtime.activate(FixtureExtension("example.base"))
    _ = try await runtime.activate(FixtureExtension("example.child", dependencies: [token.extensionID]))
    try await runtime.unregister(token)
    #expect(await runtime.activeExtensions().isEmpty)
}

@Test func modelToolValidationAndHostAuthorizationPrecedeInvocation() async throws {
    let runtime = ExtensionRuntime()
    let journal = Journal()
    _ = try await runtime.activate(FixtureExtension("example.tools", contributions: .init(tools: [journal])))
    let snapshot = try await runtime.prepareTurn(context())
    let handle = snapshot.tools[0].handle
    for args in [#"{"count":true}"#, #"{"count":4}"#, #"{"count":1,"extra":true}"#, "{}"] {
        await #expect(throws: (any Error).self) {
            _ = try await runtime.invoke(handle, argumentsJSON: args) { _, _ in true }
        }
    }
    await #expect(throws: CapabilityError.unauthorized) {
        _ = try await runtime.invoke(handle, argumentsJSON: #"{"count":1}"#) { _, _ in false }
    }
    await #expect(throws: CapabilityError.argumentsTooLarge) {
        _ = try await runtime.invoke(handle, argumentsJSON: String(repeating: "x", count: 65_537)) { _, _ in
            Issue.record("Oversized arguments must not reach approval")
            return true
        }
    }
    #expect(await journal.invocations == 0)
    #expect(try await runtime.invoke(handle, argumentsJSON: #"{"count":1}"#) { _, _ in true }.content == "ok")
}

@Test func revokingDuringHostApprovalPreventsDispatch() async throws {
    let runtime = ExtensionRuntime()
    let journal = Journal()
    let entered = Barrier()
    let release = Barrier()
    let token = try await runtime.activate(FixtureExtension("example.tools", contributions: .init(tools: [journal])))
    let snapshot = try await runtime.prepareTurn(context())
    let call = Task {
        try await runtime.invoke(snapshot.tools[0].handle, argumentsJSON: #"{"count":1}"#) { _, _ in
            await entered.open()
            await release.wait()
            return true
        }
    }
    await entered.wait()
    try await runtime.unregister(token)
    await release.open()
    await #expect(throws: (any Error).self) { _ = try await call.value }
    #expect(await journal.invocations == 0)
}

@Test func hungProviderDeadlineReturnsWithoutWaitingForProvider() async throws {
    let scheduled = Barrier()
    let advance = Barrier()
    let entered = Barrier()
    let release = Barrier()
    let runtime = ExtensionRuntime(clock: ManualClock(scheduled: scheduled, advance: advance))
    _ = try await runtime.activate(
        FixtureExtension(
            "example.hung", contributions: .init(prompts: [HungPrompt(entered: entered, release: release)])))
    let task = Task { try await runtime.prepareTurn(context()) }
    await entered.wait()
    await scheduled.wait()
    await advance.open()
    let snapshot = try await task.value
    #expect(snapshot.promptSections.isEmpty)
    #expect(await runtime.activeExtensions().isEmpty)
    #expect(await runtime.recentDiagnostics().contains { $0.code == "deadline_exceeded" })
    await release.open()
}

@Test func cancellationDoesNotWaitForUncooperativeProvider() async throws {
    let runtime = ExtensionRuntime()
    let entered = Barrier()
    let release = Barrier()
    _ = try await runtime.activate(
        FixtureExtension(
            "example.hung", contributions: .init(prompts: [HungPrompt(entered: entered, release: release)])))
    let ctx = context()
    let task = Task { try await runtime.prepareTurn(ctx) }
    await entered.wait()
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(await runtime.turns[ctx.turnID] == nil)
    await release.open()
}

@Test func replacementCannotReuseOldModelToolHandle() async throws {
    let runtime = ExtensionRuntime()
    let journal = Journal()
    let plugin = FixtureExtension("example.tools", contributions: .init(tools: [journal]))
    let token = try await runtime.activate(plugin)
    let snapshot = try await runtime.prepareTurn(context())
    try await runtime.unregister(token)
    _ = try await runtime.activate(plugin)
    await #expect(throws: (any Error).self) {
        _ = try await runtime.invoke(snapshot.tools[0].handle, argumentsJSON: #"{"count":1}"#) { _, _ in true }
    }
    #expect(await journal.invocations == 0)
}

@Test func pronkIsOfflinePersistentAndPenScoped() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pronk-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = ExtensionRuntime()
    let pen = UUID()
    _ = try await runtime.activate(PronkExtension(stateDirectory: root))
    #expect(try await runtime.prepareTurn(context()).tools.isEmpty)
    let ctx = context(pen: pen)
    let snapshot = try await runtime.prepareTurn(ctx)
    func handle(_ name: String) -> ToolHandle { snapshot.tools.first { $0.schema.name == name }!.handle }
    let adopted = try await runtime.invoke(handle("pronk_adopt"), argumentsJSON: #"{"name":"Pebble","breed":"pygmy"}"#)
    { _, _ in true }
    #expect(adopted.content.contains("Pebble"))
    _ = try await runtime.invoke(handle("pronk_treat"), argumentsJSON: #"{"treat":"carrot"}"#) { _, _ in true }
    let turn = PersistedTurn(context: ctx, title: "Adventure", createdAt: .now, messages: [])
    _ = await runtime.didPersist(turn)
    _ = await runtime.didPersist(turn)
    let report = try await runtime.invoke(handle("pronk_report"), argumentsJSON: "{}") { _, _ in true }
    #expect(report.content.contains("treats: 1"))
    #expect(report.content.contains("adventures: 1"))
    let other = try await runtime.prepareTurn(context(pen: UUID()))
    let otherReport = try await runtime.invoke(
        other.tools.first { $0.schema.name == "pronk_report" }!.handle, argumentsJSON: "{}"
    ) { _, _ in true }
    #expect(!otherReport.content.contains("Pebble"))
    let fresh = ExtensionRuntime()
    _ = try await fresh.activate(PronkExtension(stateDirectory: root))
    let restored = try await fresh.prepareTurn(context(pen: pen))
    #expect(restored.promptSections.joined().contains("Pebble"))
}

private struct FailedPrompt: PromptProvider {
    func prompt(for context: ExtensionContext) async throws -> String {
        throw NSError(domain: "secret credential must never reach diagnostics", code: 1)
    }
}
private struct HungTool: ModelToolProvider {
    let entered: Barrier
    let release: Barrier
    func tools(for context: ExtensionContext) async throws -> [ToolSchema] {
        [
            ToolSchema(
                name: "hung_tool", description: "fixture",
                inputSchemaJSON: #"{"type":"object","additionalProperties":false,"properties":{}}"#)
        ]
    }
    func invoke(_ call: ToolCallRequest, context: ExtensionContext) async throws -> ToolResult {
        await entered.open()
        await release.wait()
        return ToolResult(content: "late")
    }
}

@Test func endingATurnRevokesAnUncooperativeInFlightTool() async throws {
    let runtime = ExtensionRuntime()
    let entered = Barrier()
    let release = Barrier()
    _ = try await runtime.activate(
        FixtureExtension("example.hung", contributions: .init(tools: [HungTool(entered: entered, release: release)])))
    let ctx = context()
    let snapshot = try await runtime.prepareTurn(ctx)
    let call = Task { try await runtime.invoke(snapshot.tools[0].handle, argumentsJSON: "{}") { _, _ in true } }
    await entered.wait()
    await runtime.endTurn(ctx.turnID, outcome: .cancelled)
    await #expect(throws: (any Error).self) { _ = try await call.value }
    await release.open()
}

@Test func failedOptionalProviderDoesNotExposeRawErrorsOrHideHealthyProviders() async throws {
    let runtime = ExtensionRuntime()
    let journal = Journal()
    _ = try await runtime.activate(FixtureExtension("example.bad", contributions: .init(prompts: [FailedPrompt()])))
    _ = try await runtime.activate(
        FixtureExtension("example.good", contributions: .init(prompts: [journal], tools: [journal])))
    let snapshot = try await runtime.prepareTurn(context())
    #expect(snapshot.promptSections.count == 1)
    #expect(snapshot.tools.count == 1)
    #expect(await runtime.recentDiagnostics().allSatisfy { !$0.code.contains("secret") })
}

@Test func companionSkillFollowsExtensionAndConsumerScope() async throws {
    let runtime = ExtensionRuntime()
    let provider = CompanionSkillProvider(
        providerID: "example.companion", name: "companion", description: "fixture", instructions: "hello",
        available: { $0.penID != nil })
    let token = try await runtime.activate(FixtureExtension("example.skills", contributions: .init(skills: [provider])))
    #expect(await runtime.skillCatalog(for: context().view).skills.isEmpty)
    let view = context(pen: UUID()).view
    #expect(await runtime.skillCatalog(for: view).skills.count == 1)
    #expect(try await runtime.loadSkill(named: "companion", for: view).instructions == "hello")
    try await runtime.unregister(token)
    #expect(await runtime.skillCatalog(for: view).skills.isEmpty)
}

@Test func invalidSchemaDefinitionsAreRejected() {
    for schema in [
        #"{"type":"string","maxLength":"large"}"#,
        #"{"type":"integer","minimum":5,"maximum":1}"#,
        #"{"type":"object","properties":{},"additionalProperties":true}"#,
        #"{"type":"string","pattern":".*"}"#,
    ] {
        #expect(throws: (any Error).self) { try Schema.validateDefinition(schema) }
    }
}
