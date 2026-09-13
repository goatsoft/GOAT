import Foundation
import Testing

@testable import GOAT
@testable import Hoofprint

@MainActor
@Test func simultaneousSkillCatalogRequestsShareCompleteRegistration() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("router-skills-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("example")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "---\nname: example\ndescription: Test provider readiness.\n---\nRead the example."
        .write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    let activity = ActivityLog()
    let router = AppToolRouter(
        mcp: MCPModel(db: nil, activity: activity), memory: MemoryModel(activity: activity), activity: activity,
        builtInSkillsRoot: root, globalSkillsRoot: root.appendingPathComponent("missing"))
    let chatID = UUID()
    let requests = (0..<8).map { _ in Task { await router.skillCatalog(forChatID: chatID, projectID: nil) } }
    let first = await requests[0].value
    #expect(first.skills.map(\.name) == ["example"])
    for request in requests {
        let catalog = await request.value
        #expect(catalog.skills == first.skills)
        #expect(!catalog.issues.contains { $0.message.contains("already registered") })
    }
}

@MainActor @Test func nativeExampleUsesRuntimeRoutesAndDisablingRevokesTheTurnHandle() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("router-pronk-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let activity = ActivityLog()
    let router = AppToolRouter(
        mcp: MCPModel(db: nil, activity: activity), memory: MemoryModel(activity: activity),
        activity: activity, builtInSkillsRoot: root, globalSkillsRoot: root,
        pronkStateRoot: root.appendingPathComponent("state"))
    try await router.setPronkEnabled(true)
    let chat = UUID()
    let pen = UUID()
    let turn = UUID()
    try await router.turnWillPrepare(chatID: chat, projectID: pen, turnID: turn)
    let (specs, routes) = await router.availableToolSpecs(
        forChatID: chat, projectID: pen, includeMCP: false, excludedMCPServers: [])
    #expect(specs.contains { $0.name == "pronk_report" })
    let route = try #require(routes["pronk_report"])
    let result = try await router.authorizeAndInvoke(route: route, argumentsJSON: "{}")
    #expect(result?.content.contains("empty pasture") == true)
    let skills = await router.skillCatalog(forChatID: chat, projectID: pen)
    #expect(skills.skills.contains { $0.name == "pronk" })
    #expect(!skills.skills.contains { $0.name == "hindsight" })
    try await router.setPronkEnabled(false)
    await #expect(throws: (any Error).self) {
        _ = try await router.authorizeAndInvoke(route: route, argumentsJSON: "{}")
    }
    await router.turnDidEnd(turnID: turn, cancelled: false)
}

@MainActor @Test func penFilesUseGOATedRoutesAndRequireApprovalForEachWrite() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
        "pen-router-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let activity = ActivityLog()
    let mcp = MCPModel(db: nil, activity: activity)
    let router = AppToolRouter(
        mcp: mcp, memory: MemoryModel(activity: activity), activity: activity,
        builtInSkillsRoot: root, globalSkillsRoot: root)
    let pen = UUID()
    let chat = UUID()
    let turn = UUID()
    router.workspaceForProject = { $0 == pen ? root : nil }
    try await router.turnWillPrepare(chatID: chat, projectID: pen, turnID: turn)
    let (specs, routes) = await router.availableToolSpecs(
        forChatID: chat, projectID: pen, includeMCP: true, excludedMCPServers: [])
    #expect(specs.filter { $0.name.hasPrefix("pen_") }.count == 9)
    let route = try #require(routes["pen_write_file"])
    guard case .extensionTool(let handle) = route.origin else {
        Issue.record("Missing GOATed route")
        return
    }
    #expect(handle.registration.extensionID.rawValue == "goat.herder")
    let disabled = await router.availableToolSpecs(
        forChatID: chat, projectID: pen, includeMCP: false, excludedMCPServers: [])
    #expect(!disabled.0.contains { $0.name.hasPrefix("pen_") })
    let other = await router.availableToolSpecs(
        forChatID: UUID(), projectID: nil, includeMCP: true, excludedMCPServers: [])
    #expect(!other.0.contains { $0.name.hasPrefix("pen_") })

    for allow in [false, true] {
        let task = Task {
            try await router.authorizeAndInvoke(
                route: route, argumentsJSON: #"{"path":"check.txt","content":"GOAT_PEN_WRITE_OK\n"}"#)
        }
        for _ in 0..<200 where mcp.pendingPermission == nil { try await Task.sleep(for: .milliseconds(5)) }
        guard let request = mcp.pendingPermission else {
            task.cancel()
            Issue.record("Write did not request approval")
            return
        }
        #expect(!request.allowsAlways)
        #expect(request.arguments.contains(root.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("check.txt").path))
        mcp.resolvePermission(allow ? .allowOnce : .deny, requestID: request.id)
        if allow {
            let result = try await task.value
            #expect(result?.isError == false)
        } else {
            #expect(try await task.value == nil)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("check.txt").path))
        }
    }
    #expect(try String(contentsOf: root.appendingPathComponent("check.txt"), encoding: .utf8) == "GOAT_PEN_WRITE_OK\n")
    let read = try #require(routes["pen_read_file"])
    router.workspaceForProject = { _ in nil }
    await #expect(throws: (any Error).self) {
        _ = try await router.authorizeAndInvoke(route: read, argumentsJSON: #"{"path":"check.txt"}"#)
    }
    await router.turnDidEnd(turnID: turn, cancelled: false)
    router.workspaceForProject = { _ in root }
    await #expect(throws: (any Error).self) {
        _ = try await router.authorizeAndInvoke(route: read, argumentsJSON: #"{"path":"check.txt"}"#)
    }
}

@MainActor @Test func penFileApprovalCancellationAndWorkspaceChangeNeverWrite() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
        "pen-revoke-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let activity = ActivityLog()
    let mcp = MCPModel(db: nil, activity: activity)
    let router = AppToolRouter(
        mcp: mcp, memory: MemoryModel(activity: activity), activity: activity,
        builtInSkillsRoot: root, globalSkillsRoot: root)
    let pen = UUID()
    let chat = UUID()
    let turn = UUID()
    router.workspaceForProject = { _ in root }
    try await router.turnWillPrepare(chatID: chat, projectID: pen, turnID: turn)
    let (_, routes) = await router.availableToolSpecs(
        forChatID: chat, projectID: pen, includeMCP: true, excludedMCPServers: [])
    let route = try #require(routes["pen_write_file"])
    for cancel in [true, false] {
        router.workspaceForProject = { _ in root }
        let task = Task {
            try await router.authorizeAndInvoke(route: route, argumentsJSON: #"{"path":"check.txt","content":"no"}"#)
        }
        for _ in 0..<200 where mcp.pendingPermission == nil { try await Task.sleep(for: .milliseconds(5)) }
        guard let request = mcp.pendingPermission else {
            task.cancel()
            Issue.record("Missing approval")
            return
        }
        if cancel {
            task.cancel()
        } else {
            router.workspaceForProject = { _ in nil }
            mcp.resolvePermission(.allowOnce, requestID: request.id)
        }
        do {
            _ = try await task.value
            Issue.record("Revoked write should fail")
        } catch {}
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("check.txt").path))
        #expect(mcp.pendingPermission == nil)
    }
    await router.turnDidEnd(turnID: turn, cancelled: true)
}

@Test func shellPolicyAdministrationIsOwnerOnly() {
    for name in [
        "add_to_whitelist", "remove_from_whitelist", "update_security_level", "approve_command", "deny_command",
    ] {
        #expect(MCPModel.isOwnerAdministrationTool(name))
    }
    #expect(!MCPModel.isOwnerAdministrationTool("execute_command"))
    #expect(!MCPModel.isOwnerAdministrationTool("get_whitelist"))
}

@MainActor @Test func nativeCommandsAskBeforeExecutionAndCanBePolledThroughGOATed() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("command-route-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "command-route-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let activity = ActivityLog()
    let mcp = MCPModel(db: nil, activity: activity)
    let router = AppToolRouter(
        mcp: mcp, memory: MemoryModel(activity: activity), activity: activity,
        builtInSkillsRoot: root, globalSkillsRoot: root,
        commandPermissions: PenCommandPermissionModel(defaults: defaults))
    let pen = UUID()
    let chat = UUID()
    let turn = UUID()
    router.workspaceForProject = { $0 == pen ? root : nil }
    try await router.turnWillPrepare(chatID: chat, projectID: pen, turnID: turn)
    let (_, routes) = await router.availableToolSpecs(
        forChatID: chat, projectID: pen, includeMCP: true, excludedMCPServers: [])
    let run = try #require(routes["pen_run_command"])
    let status = try #require(routes["pen_command_status"])
    let args = #"{"command":"sh","args":["-c","echo command_ok > command.txt"],"background":true}"#
    for allow in [false, true] {
        let task = Task { try await router.authorizeAndInvoke(route: run, argumentsJSON: args) }
        for _ in 0..<200 where mcp.pendingPermission == nil { try await Task.sleep(for: .milliseconds(5)) }
        let request = try #require(mcp.pendingPermission)
        #expect(request.allowsPenScopes)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("command.txt").path))
        mcp.resolvePermission(allow ? .allowPen : .deny, requestID: request.id)
        if allow {
            let result = try #require(await task.value)
            let object = try #require(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
            let id = try #require(object["job_id"] as? String)
            let final = try await router.authorizeAndInvoke(
                route: status, argumentsJSON: "{\"job_id\":\"\(id)\",\"wait_seconds\":1}")
            #expect(final?.isError == false)
            #expect(
                try String(contentsOf: root.appendingPathComponent("command.txt"), encoding: .utf8) == "command_ok\n")
        } else {
            #expect(try await task.value == nil)
        }
    }
    #expect(router.commandPermissions.grants.count == 1)
    let search = try #require(routes["pen_search"])
    let result = try await router.authorizeAndInvoke(
        route: search, argumentsJSON: #"{"path":".","query":"command_ok"}"#)
    #expect(result?.content.contains("command.txt") == true)
    #expect(mcp.pendingPermission == nil)
    await router.turnDidEnd(turnID: turn, cancelled: false)
    await #expect(throws: (any Error).self) { _ = try await router.authorizeAndInvoke(route: run, argumentsJSON: args) }
}
