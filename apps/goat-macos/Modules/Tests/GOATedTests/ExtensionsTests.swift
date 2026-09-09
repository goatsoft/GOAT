import Foundation
import Testing

@testable import GOATed
@testable import Tools

private struct FixedSkillProvider: SkillProvider {
    let providerID: String
    let skills: [String: (String, SkillSource)]

    func listSkills() async throws -> [SkillCandidate] {
        skills.map { name, value in
            SkillCandidate(
                name: name,
                description: value.0,
                source: value.1,
                providerID: providerID)
        }
    }

    func loadSkill(named name: String) async throws -> SkillDefinition {
        guard let value = skills[name] else { throw SkillError.notFound(name) }
        return SkillDefinition(
            summary: SkillSummary(
                identity: SkillIdentity(
                    extensionID: ExtensionID(rawValue: "unregistered"),
                    scope: .application,
                    providerID: providerID,
                    name: name),
                name: name,
                description: value.0,
                source: value.1),
            instructions: "Instructions for \(name).")
    }

    func readResource(skill name: String, path: String) async throws -> String {
        "\(name):\(path)"
    }
}

private func temporaryDirectory(_ label: String) throws -> URL {
    let value = FileManager.default.temporaryDirectory
        .appendingPathComponent("goated-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
    return value
}

private func writeSkill(
    root: URL,
    name: String,
    description: String = "Use for test work.",
    metadata: String = "",
    instructions: String = "Follow the test procedure.",
    resource: (String, String)? = nil
) throws {
    let folder = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let document = """
        ---
        name: \(name)
        description: \(description)
        \(metadata)
        ---
        \(instructions)
        """
    try Data(document.utf8).write(to: folder.appendingPathComponent("SKILL.md"))
    if let resource {
        let target = folder.appendingPathComponent(resource.0)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(resource.1.utf8).write(to: target)
    }
}

@Test func goatedScopesComposeAndUnregisterReversibly() async throws {
    let runtime = ExtensionRuntime()
    let chatID = UUID()
    let penID = UUID()
    let otherPenID = UUID()
    _ = try await runtime.registerSkillProvider(
        FixedSkillProvider(
            providerID: "global", skills: ["global-skill": ("Global.", .global)]),
        extensionID: ExtensionID(rawValue: "skills.global"),
        scope: .application)
    let penRegistration = try await runtime.registerSkillProvider(
        FixedSkillProvider(
            providerID: "pen", skills: ["pen-skill": ("Pen.", .pen(penID))]),
        extensionID: ExtensionID(rawValue: "skills.pen"),
        scope: .pen(penID))

    let penCatalog = await runtime.skillCatalog(
        for: ExtensionView(chatID: chatID, penID: penID))
    #expect(penCatalog.skills.map(\.name) == ["global-skill", "pen-skill"])
    let otherCatalog = await runtime.skillCatalog(
        for: ExtensionView(chatID: chatID, penID: otherPenID))
    #expect(otherCatalog.skills.map(\.name) == ["global-skill"])

    try await runtime.unregister(penRegistration)
    let removedCatalog = await runtime.skillCatalog(
        for: ExtensionView(chatID: chatID, penID: penID))
    #expect(removedCatalog.skills.map(\.name) == ["global-skill"])
}

@Test func fileSkillsUseProgressiveMetadataBodyAndResourceReads() async throws {
    let root = try temporaryDirectory("file")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSkill(
        root: root,
        name: "test-skill",
        description: "Use when testing GOATed.",
        metadata: "disable-model-invocation: false\nuser-invocable: true",
        instructions: "Read references/checks.md only when needed.",
        resource: ("references/checks.md", "One bounded resource."))
    let provider = FileSkillProvider(providerID: "files", root: root, source: .global)

    let listed = try await provider.listSkills()
    #expect(listed.map(\.name) == ["test-skill"])
    #expect(listed[0].description == "Use when testing GOATed.")
    let loaded = try await provider.loadSkill(named: "test-skill")
    #expect(loaded.instructions == "Read references/checks.md only when needed.")
    #expect(
        try await provider.readResource(skill: "test-skill", path: "references/checks.md")
            == "One bounded resource.")
}

@Test func fileSkillsRejectTraversalSymlinksAndMismatchedNames() async throws {
    let root = try temporaryDirectory("unsafe")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSkill(root: root, name: "safe-skill")
    let provider = FileSkillProvider(providerID: "files", root: root, source: .global)

    do {
        _ = try await provider.readResource(skill: "safe-skill", path: "../outside")
        Issue.record("Traversal should be rejected")
    } catch let error as SkillError {
        #expect(error == .invalidResourcePath("../outside"))
    }

    let outside = try temporaryDirectory("outside")
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("linked-skill"),
        withDestinationURL: outside)
    do {
        _ = try await provider.listSkills()
        Issue.record("A symbolic-link skill should fail closed")
    } catch {
        #expect(error is SkillError)
    }

    try FileManager.default.removeItem(at: root.appendingPathComponent("linked-skill"))
    let mismatch = root.appendingPathComponent("wrong-name", isDirectory: true)
    try FileManager.default.createDirectory(at: mismatch, withIntermediateDirectories: true)
    try Data("---\nname: another-name\ndescription: Wrong.\n---\nBody".utf8)
        .write(to: mismatch.appendingPathComponent("SKILL.md"))
    do {
        _ = try await provider.listSkills()
        Issue.record("Folder and declared names must match")
    } catch let error as SkillError {
        #expect(error == .invalidName("another-name"))
    }
}

@Test func builtInSkillNamesCannotBeImpersonated() async throws {
    let runtime = ExtensionRuntime()
    let view = ExtensionView(chatID: UUID(), penID: nil)
    _ = try await runtime.registerSkillProvider(
        FixedSkillProvider(
            providerID: "builtin", skills: ["hindsight": ("Trusted.", .builtIn)]),
        extensionID: ExtensionID(rawValue: "builtin.hindsight"),
        scope: .application)
    _ = try await runtime.registerSkillProvider(
        FixedSkillProvider(
            providerID: "user", skills: ["hindsight": ("Imposter.", .global)]),
        extensionID: ExtensionID(rawValue: "skills.global"),
        scope: .application)

    let catalog = await runtime.skillCatalog(for: view)
    #expect(catalog.skills.map(\.description) == ["Trusted."])
    #expect(catalog.issues.contains { $0.message.contains("reserved") })
}

@Test func firstClassCommandNamesCannotBeRegisteredAsSkills() async throws {
    let runtime = ExtensionRuntime()
    let view = ExtensionView(chatID: UUID(), penID: nil)
    _ = try await runtime.registerSkillProvider(
        FixedSkillProvider(providerID: "personal", skills: ["handoff": ("Imposter.", .global)]),
        extensionID: ExtensionID(rawValue: "skills.personal"),
        scope: .application)

    let catalog = await runtime.skillCatalog(for: view)

    #expect(catalog.skills.allSatisfy { $0.name != "handoff" })
    #expect(catalog.issues.contains { $0.message.contains("first-class GOAT command") })
}

@Test func duplicateUserSkillsFailClosedInsteadOfShadowing() async throws {
    let runtime = ExtensionRuntime()
    let view = ExtensionView(chatID: UUID(), penID: UUID())
    _ = try await runtime.registerSkillProvider(
        FixedSkillProvider(providerID: "one", skills: ["review": ("One.", .global)]),
        extensionID: ExtensionID(rawValue: "skills.one"),
        scope: .application)
    _ = try await runtime.registerSkillProvider(
        FixedSkillProvider(providerID: "two", skills: ["review": ("Two.", .runtime("test"))]),
        extensionID: ExtensionID(rawValue: "skills.two"),
        scope: .chat(view.chatID))

    let catalog = await runtime.skillCatalog(for: view)
    #expect(catalog.skills.isEmpty)
    #expect(catalog.issues.contains { $0.message.contains("ambiguous") })
}

@Test func skillToolRequiresProgressiveLoadBeforeResourceRead() async throws {
    let runtime = ExtensionRuntime()
    let view = ExtensionView(chatID: UUID(), penID: nil)
    _ = try await runtime.registerSkillProvider(
        FixedSkillProvider(providerID: "runtime", skills: ["review": ("Review.", .global)]),
        extensionID: ExtensionID(rawValue: "skills.runtime"),
        scope: .application)
    let tools = SkillToolProvider(runtime: runtime, view: view)
    #expect(await tools.availableTools().map(\.name) == ["skill_load", "skill_read_resource"])

    do {
        _ = try await tools.invoke(
            ToolCallRequest(
                tool: "skill_read_resource",
                argumentsJSON: #"{"name":"review","path":"references/a.md"}"#))
        Issue.record("Resource reads must follow a skill load")
    } catch let error as SkillError {
        #expect(error == .resourceNotLoaded("review"))
    }

    let loaded = try await tools.invoke(
        ToolCallRequest(tool: "skill_load", argumentsJSON: #"{"name":"review"}"#))
    #expect(loaded.content.contains("Instructions for review."))
    let resource = try await tools.invoke(
        ToolCallRequest(
            tool: "skill_read_resource",
            argumentsJSON: #"{"name":"review","path":"references/a.md"}"#))
    #expect(resource.content.contains("review:references/a.md"))
}

@Test func loadedSkillResourcesStayBoundToTheResolvedProviderIdentity() async throws {
    let runtime = ExtensionRuntime()
    let view = ExtensionView(chatID: UUID(), penID: nil)
    let registration = try await runtime.registerSkillProvider(
        FixedSkillProvider(providerID: "first", skills: ["review": ("First.", .global)]),
        extensionID: ExtensionID(rawValue: "skills.first"),
        scope: .application)
    let tools = SkillToolProvider(runtime: runtime, view: view)
    _ = try await tools.invoke(
        ToolCallRequest(tool: "skill_load", argumentsJSON: #"{"name":"review"}"#))

    try await runtime.unregister(registration)
    _ = try await runtime.registerSkillProvider(
        FixedSkillProvider(providerID: "second", skills: ["review": ("Second.", .global)]),
        extensionID: ExtensionID(rawValue: "skills.second"),
        scope: .application)

    do {
        _ = try await tools.invoke(
            ToolCallRequest(
                tool: "skill_read_resource",
                argumentsJSON: #"{"name":"review","path":"references/a.md"}"#))
        Issue.record("A resource must not switch providers after its skill was loaded")
    } catch let error as SkillError {
        #expect(error == .notFound("review"))
    }
}

@Test func slashSkillCommandsSeparateMenuFilteringFromSentInvocations() {
    #expect(SkillCommand.menuQuery(in: "/") == "")
    #expect(SkillCommand.menuQuery(in: "/Hand") == "hand")
    #expect(SkillCommand.menuQuery(in: "/handoff add docs") == nil)
    #expect(SkillCommand.menuQuery(in: "ask /handoff") == nil)

    #expect(SkillCommand.invocationName(in: " /handoff add docs ") == "handoff")
    #expect(SkillCommand.invocationName(in: "/") == nil)
    #expect(SkillCommand.invocationName(in: "handoff") == nil)

    #expect(
        SkillCommand.modelRequest(
            in: " /handoff include verification ",
            invokedSkill: "handoff")
            == "Run the handoff skill now.\n\nAdditional request:\ninclude verification")
    #expect(
        SkillCommand.modelRequest(in: "/handoff", invokedSkill: "handoff")
            == "Run the handoff skill now.")
    #expect(
        SkillCommand.modelRequest(in: "/review", invokedSkill: "handoff")
            == "/review")
}

@Test func requestedSkillPromptRequiresAnEffectiveUserInvocableSkill() async throws {
    let runtime = ExtensionRuntime()
    let view = ExtensionView(chatID: UUID(), penID: nil)
    _ = try await runtime.registerSkillProvider(
        FixedSkillProvider(providerID: "builtin", skills: ["review": ("Review.", .builtIn)]),
        extensionID: ExtensionID(rawValue: "skills.builtin"),
        scope: .application)
    let catalog = await runtime.skillCatalog(for: view)

    #expect(catalog.requestedSkillPrompt(named: "missing").isEmpty)
    #expect(catalog.requestedSkillPrompt(named: "review").contains("skill_load"))
    #expect(catalog.requestedSkillPrompt(named: "review").contains("skills.builtin"))
    #expect(catalog.requestedSkillPrompt(named: "review").contains("not a callable tool"))
    #expect(catalog.requestedSkillPrompt(named: "review").contains("Never call a tool named review"))
}

private actor SuspendedSkillProvider: SkillProvider {
    nonisolated let providerID = "suspended"
    enum Phase { case list, load, resource }
    let phase: Phase
    init(phase: Phase = .list) { self.phase = phase }
    private var pending: CheckedContinuation<Void, Never>?
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resume() {
        pending?.resume()
        pending = nil
    }

    private func suspend() async {
        await withCheckedContinuation { continuation in
            pending = continuation
            started = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    func listSkills() async throws -> [SkillCandidate] {
        if phase == .list { await suspend() }
        return [SkillCandidate(name: "late", description: "Late result", source: .global, providerID: providerID)]
    }

    func loadSkill(named name: String) async throws -> SkillDefinition {
        if phase == .load { await suspend() }
        return try await FixedSkillProvider(providerID: providerID, skills: ["late": ("Late result", .global)])
            .loadSkill(named: name)
    }
    func readResource(skill name: String, path: String) async throws -> String {
        if phase == .resource { await suspend() }
        return "resource"
    }

}

@Test func unregisteredProviderCannotPublishLateCatalogResults() async throws {
    let runtime = ExtensionRuntime()
    let provider = SuspendedSkillProvider()
    let token = try await runtime.registerSkillProvider(
        provider, extensionID: ExtensionID(rawValue: "test"), scope: .application)
    let task = Task { await runtime.skillCatalog(for: ExtensionView(chatID: UUID(), penID: nil)) }
    await provider.waitUntilStarted()
    try await runtime.unregister(token)
    await provider.resume()
    #expect(await task.value.skills.isEmpty)
}

@Test func cancelledCatalogDoesNotPublishProviderResults() async throws {
    let runtime = ExtensionRuntime()
    let provider = SuspendedSkillProvider()
    _ = try await runtime.registerSkillProvider(
        provider, extensionID: ExtensionID(rawValue: "test"), scope: .application)
    let task = Task { await runtime.skillCatalog(for: ExtensionView(chatID: UUID(), penID: nil)) }
    await provider.waitUntilStarted()
    task.cancel()
    await provider.resume()
    #expect(await task.value.skills.isEmpty)
}

@Test func reRegisteringProviderInvalidatesLoadedResourceIdentity() async throws {
    let runtime = ExtensionRuntime()
    let provider = FixedSkillProvider(providerID: "fixed", skills: ["example": ("Example", .global)])
    let extensionID = ExtensionID(rawValue: "test")
    let view = ExtensionView(chatID: UUID(), penID: nil)
    let token = try await runtime.registerSkillProvider(provider, extensionID: extensionID, scope: .application)
    let original = try await runtime.loadSkill(named: "example", for: view)
    try await runtime.unregister(token)
    _ = try await runtime.registerSkillProvider(provider, extensionID: extensionID, scope: .application)
    let replacement = try await runtime.loadSkill(named: "example", for: view)
    #expect(original.summary.identity != replacement.summary.identity)
    #expect(original.summary.identity.selectionKey == replacement.summary.identity.selectionKey)
    await #expect(throws: SkillError.self) {
        try await runtime.readSkillResource(
            skill: "example", path: "notes.md", expectedIdentity: original.summary.identity, for: view)
    }
}

@Test func revokedLoadAndResourceCallsCannotReturnLateData() async throws {
    for phase in [SuspendedSkillProvider.Phase.load, .resource] {
        let runtime = ExtensionRuntime()
        let provider = SuspendedSkillProvider(phase: phase)
        let view = ExtensionView(chatID: UUID(), penID: nil)
        let token = try await runtime.registerSkillProvider(
            provider, extensionID: ExtensionID(rawValue: "test"), scope: .application)
        let catalog = await runtime.skillCatalog(for: view)
        let identity = try #require(catalog.skills.first?.identity)
        let task = Task {
            if phase == .load {
                _ = try await runtime.loadSkill(named: "late", for: view)
            } else {
                _ = try await runtime.readSkillResource(
                    skill: "late", path: "data", expectedIdentity: identity, for: view)
            }
        }
        await provider.waitUntilStarted()
        try await runtime.unregister(token)
        await provider.resume()
        await #expect(throws: ExtensionRuntimeError.registrationNotFound) { try await task.value }
    }
}
