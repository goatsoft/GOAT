import Bleet
import Foundation
import Hoofprint
import Pens
import Persistence
import Shepherd
import Testing
import Tools

@testable import GOAT

@MainActor
private struct FilePermissionFixture {
    let root: URL
    let db: ChatDatabase
    let mcp: MCPModel
    let router: AppToolRouter
    let pen = UUID()
    let chat = UUID()

    init() async throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("file-permissions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        db = try ChatDatabase(path: root.appendingPathComponent("permissions.sqlite").path)
        let activity = ActivityLog()
        mcp = MCPModel(db: db, activity: activity)
        router = AppToolRouter(
            mcp: mcp, memory: MemoryModel(activity: activity), activity: activity,
            builtInSkillsRoot: root.appendingPathComponent("missing"),
            globalSkillsRoot: root.appendingPathComponent("missing"))
        await router.filePermissions.load(database: db)
        router.workspaceForProject = { [root] _ in root }
        router.nameForProject = { _ in "Test Pen" }
    }

    func routes(chatID: UUID, penID: UUID, turnID: UUID) async throws -> [String: ShepherdToolRoute] {
        try await router.turnWillPrepare(chatID: chatID, projectID: penID, turnID: turnID)
        return await router.availableToolSpecs(
            forChatID: chatID, projectID: penID, includeMCP: true, excludedMCPServers: []
        ).1
    }

    func invoke(
        _ route: ShepherdToolRoute, arguments: String, choice: MCPModel.PermissionChoice? = nil
    ) async throws -> Tools.ToolResult? {
        var completed = false
        let task = Task {
            defer { completed = true }
            return try await router.authorizeAndInvoke(route: route, argumentsJSON: arguments)
        }
        for _ in 0..<400 where !completed && mcp.pendingPermission == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        if let choice {
            guard let request = mcp.pendingPermission else {
                task.cancel()
                Issue.record("Expected a native approval request")
                return try await task.value
            }
            #expect(request.penName == "Test Pen")
            #expect(request.allowsPenScopes)
            #expect(!request.allowsAlways)
            mcp.resolvePermission(choice, requestID: request.id)
        } else if let request = mcp.pendingPermission {
            Issue.record("Remembered file permission unexpectedly prompted")
            mcp.resolvePermission(.deny, requestID: request.id)
        } else if !completed {
            task.cancel()
            Issue.record("File invocation did not finish")
        }
        return try await task.value
    }
}

@MainActor @Test(arguments: [false, true])
func nativeFileGrantsCoverCreateAndEditAtOnlyTheSelectedScope(wholePen: Bool) async throws {
    let fixture = try await FilePermissionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let firstTurn = UUID()
    let first = try await fixture.routes(chatID: fixture.chat, penID: fixture.pen, turnID: firstTurn)
    let create = try #require(first["pen_write_file"])
    let result = try await fixture.invoke(
        create, arguments: #"{"path":"hello.txt","content":"first\n"}"#,
        choice: wholePen ? .allowPen : .allowChat)
    #expect(result?.isError == false)
    await fixture.router.turnDidEnd(turnID: firstTurn, cancelled: false)

    // Restore from SQLite, just as reopening the app restores the same chat permission.
    let reopened = try ChatDatabase(path: fixture.root.appendingPathComponent("permissions.sqlite").path)
    await fixture.router.filePermissions.load(database: reopened)
    let nextTurn = UUID()
    let next = try await fixture.routes(chatID: fixture.chat, penID: fixture.pen, turnID: nextTurn)
    let edit = try #require(next["pen_edit_file"])
    let edited = try await fixture.invoke(
        edit, arguments: #"{"path":"hello.txt","old_text":"first","new_text":"second"}"#)
    #expect(edited?.isError == false)
    #expect(try String(contentsOf: fixture.root.appendingPathComponent("hello.txt"), encoding: .utf8) == "second\n")
    await fixture.router.turnDidEnd(turnID: nextTurn, cancelled: false)

    let otherTurn = UUID()
    let other = try await fixture.routes(chatID: UUID(), penID: fixture.pen, turnID: otherTurn)
    _ = try await fixture.invoke(
        try #require(other["pen_write_file"]), arguments: #"{"path":"other.txt","content":"ok"}"#,
        choice: wholePen ? nil : .allowOnce)
    await fixture.router.turnDidEnd(turnID: otherTurn, cancelled: false)

    // Another Pen never inherits a grant, even when both Pens bind the same physical folder.
    let foreignTurn = UUID()
    let foreign = try await fixture.routes(chatID: fixture.chat, penID: UUID(), turnID: foreignTurn)
    _ = try await fixture.invoke(
        try #require(foreign["pen_write_file"]), arguments: #"{"path":"foreign.txt","content":"ok"}"#,
        choice: .allowOnce)
    await fixture.router.turnDidEnd(turnID: foreignTurn, cancelled: false)

    await fixture.router.filePermissions.reset(penID: fixture.pen, chatID: wholePen ? nil : fixture.chat)
    let resetTurn = UUID()
    let reset = try await fixture.routes(chatID: fixture.chat, penID: fixture.pen, turnID: resetTurn)
    _ = try await fixture.invoke(
        try #require(reset["pen_write_file"]), arguments: #"{"path":"reset.txt","content":"ok"}"#,
        choice: .allowOnce)
    #expect(try await reopened.penFileGrants().isEmpty)
    await fixture.router.turnDidEnd(turnID: resetTurn, cancelled: false)
}

@MainActor @Test
func rememberedWritesStillRejectEscapesAndChangedWorkspaceIdentity() async throws {
    let fixture = try await FilePermissionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let identity = try PenFileTools(workspace: fixture.root).workspaceIdentity
    #expect(await fixture.router.filePermissions.remember(penID: fixture.pen, chatID: nil, workspaceIdentity: identity))
    let turn = UUID()
    let routes = try await fixture.routes(chatID: fixture.chat, penID: fixture.pen, turnID: turn)
    for path in ["../escape.txt", "/tmp/escape.txt", ".git/config"] {
        await #expect(throws: (any Error).self) {
            _ = try await fixture.router.authorizeAndInvoke(
                route: try #require(routes["pen_write_file"]),
                argumentsJSON: "{\"path\":\"\(path)\",\"content\":\"blocked\"}")
        }
        #expect(fixture.mcp.pendingPermission == nil)
    }
    await fixture.router.turnDidEnd(turnID: turn, cancelled: false)

    let changed = fixture.root.appendingPathComponent("new-workspace")
    try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: true)
    fixture.router.workspaceForProject = { _ in changed }
    let newTurn = UUID()
    let newRoutes = try await fixture.routes(chatID: fixture.chat, penID: fixture.pen, turnID: newTurn)
    _ = try await fixture.invoke(
        try #require(newRoutes["pen_write_file"]), arguments: #"{"path":"new.txt","content":"ok"}"#, choice: .allowOnce)
    await fixture.router.turnDidEnd(turnID: newTurn, cancelled: false)

    // Replacing a directory at the same path also changes the grant identity.
    let before = try PenFileTools(workspace: changed).workspaceIdentity
    try FileManager.default.moveItem(at: changed, to: fixture.root.appendingPathComponent("old-workspace"))
    try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: true)
    #expect(try PenFileTools(workspace: changed).workspaceIdentity != before)
}

@MainActor @Test
func resettingWhileApprovalIsOpenCannotCreateANewGrantOrFile() async throws {
    let fixture = try await FilePermissionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let turn = UUID()
    let routes = try await fixture.routes(chatID: fixture.chat, penID: fixture.pen, turnID: turn)
    let route = try #require(routes["pen_write_file"])
    let task = Task {
        try await fixture.router.authorizeAndInvoke(
            route: route, argumentsJSON: #"{"path":"stale.txt","content":"no"}"#)
    }
    defer { task.cancel() }
    for _ in 0..<200 where fixture.mcp.pendingPermission == nil { try await Task.sleep(for: .milliseconds(5)) }
    let request = try #require(fixture.mcp.pendingPermission)
    await fixture.router.filePermissions.reset(penID: fixture.pen)
    fixture.mcp.resolvePermission(.allowPen, requestID: request.id)
    await #expect(throws: (any Error).self) { _ = try await task.value }
    #expect(try await fixture.db.penFileGrants().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("stale.txt").path))
    await fixture.router.turnDidEnd(turnID: turn, cancelled: false)
}

@MainActor @Test
func fileGrantResetWinsOverAnInFlightSaveAndUnavailableDatabaseFailsClosed() async throws {
    let fixture = try await FilePermissionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let permissions = fixture.router.filePermissions
    var started = false
    let remember = Task {
        started = true
        _ = await permissions.remember(penID: fixture.pen, chatID: fixture.chat, workspaceIdentity: "root")
    }
    while !started { await Task.yield() }
    await permissions.reset(penID: fixture.pen)
    _ = await remember.value
    #expect(try await fixture.db.penFileGrants().isEmpty)
    #expect(permissions.scope(penID: fixture.pen, chatID: fixture.chat, workspaceIdentity: "root") == .ask)
    await permissions.load(database: nil)
    #expect(!permissions.canRemember)
    #expect(!(await permissions.remember(penID: fixture.pen, chatID: nil, workspaceIdentity: "root")))
}

@MainActor @Test
func chatMoveDeletionAndPenRemovalClearDurableFileGrants() async throws {
    let fixture = try await FilePermissionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var chat = ChatRecord(
        id: fixture.chat.uuidString, projectId: fixture.pen.uuidString, title: "Test", pinned: false,
        modelId: nil, effort: "trot", createdAt: .now, updatedAt: .now)
    try await fixture.db.save(chat)
    let grant = PenFileGrantRecord(
        penID: fixture.pen.uuidString, chatID: fixture.chat.uuidString, workspaceIdentity: "folder")
    try await fixture.db.setPenFileGrant(grant)
    chat.projectId = UUID().uuidString
    try await fixture.db.save(chat)
    #expect(try await fixture.db.penFileGrants().isEmpty)
    try await fixture.db.setPenFileGrant(grant)
    try await fixture.db.deleteChat(id: chat.id)
    #expect(try await fixture.db.penFileGrants().isEmpty)
    try await fixture.db.setPenFileGrant(grant)
    try await fixture.db.setPenFileGrant(
        PenFileGrantRecord(penID: fixture.pen.uuidString, chatID: "", workspaceIdentity: "folder"))
    try await fixture.db.clearPenLinks(id: fixture.pen.uuidString)
    #expect(try await fixture.db.penFileGrants().isEmpty)
}

@MainActor @Test
func composerCanChoosePermissionsBeforeTheFirstFileCall() async throws {
    let fixture = try await FilePermissionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let permissions = fixture.router.filePermissions
    let identity = try PenFileTools(workspace: fixture.root).workspaceIdentity
    #expect(await permissions.select(.chat, penID: fixture.pen, chatID: fixture.chat, workspaceIdentity: identity))
    let turn = UUID()
    let routes = try await fixture.routes(chatID: fixture.chat, penID: fixture.pen, turnID: turn)
    _ = try await fixture.invoke(
        try #require(routes["pen_write_file"]), arguments: #"{"path":"preapproved.txt","content":"ok"}"#)
    #expect(fixture.mcp.pendingPermission == nil)
    await fixture.router.turnDidEnd(turnID: turn, cancelled: false)
    await permissions.load(database: fixture.db)
    #expect(permissions.scope(penID: fixture.pen, chatID: fixture.chat, workspaceIdentity: identity) == .chat)
}

@MainActor @Test
func composerAndPenChoicesReplaceExactlyTheDescribedScope() async throws {
    let fixture = try await FilePermissionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let permissions = fixture.router.filePermissions
    let otherChat = UUID()
    let identity = "workspace"
    #expect(await permissions.select(.chat, penID: fixture.pen, chatID: otherChat, workspaceIdentity: identity))
    #expect(await permissions.select(.chat, penID: fixture.pen, chatID: fixture.chat, workspaceIdentity: identity))
    #expect(await permissions.select(.ask, penID: fixture.pen, chatID: fixture.chat, workspaceIdentity: identity))
    #expect(permissions.scope(penID: fixture.pen, chatID: otherChat, workspaceIdentity: identity) == .chat)
    #expect(permissions.scope(penID: fixture.pen, chatID: fixture.chat, workspaceIdentity: identity) == .ask)
    #expect(await permissions.select(.pen, penID: fixture.pen, chatID: fixture.chat, workspaceIdentity: identity))
    #expect(permissions.scope(penID: fixture.pen, chatID: otherChat, workspaceIdentity: identity) == .pen)
    #expect(await permissions.select(.chat, penID: fixture.pen, chatID: fixture.chat, workspaceIdentity: identity))
    #expect(permissions.scope(penID: fixture.pen, chatID: otherChat, workspaceIdentity: identity) == .ask)
    #expect(permissions.scope(penID: fixture.pen, chatID: fixture.chat, workspaceIdentity: identity) == .chat)
    #expect(await permissions.select(.pen, penID: fixture.pen, chatID: nil, workspaceIdentity: identity))
    #expect(permissions.scope(penID: fixture.pen, chatID: UUID(), workspaceIdentity: identity) == .pen)
    #expect(await permissions.select(.ask, penID: fixture.pen, chatID: nil, workspaceIdentity: identity))
    #expect(try await fixture.db.penFileGrants().isEmpty)
    #expect(!(await permissions.select(.chat, penID: fixture.pen, chatID: nil, workspaceIdentity: identity)))
}

@MainActor @Test(arguments: [false, true])
func penComposerLaunchCarriesItsGrantIntoTheFirstWriteAndScopesTheNextDraft(wholePen: Bool) async throws {
    let fixture = try await FilePermissionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let draft = ChatSession(effort: .trot, modelID: "coder", projectID: fixture.pen)
    let identity = try PenFileTools(workspace: fixture.root).workspaceIdentity
    let permissions = fixture.router.filePermissions
    #expect(
        await permissions.select(
            wholePen ? .pen : .chat, penID: fixture.pen,
            chatID: draft.id, workspaceIdentity: identity))
    let chat = try #require(ChatLaunch.sessionForSubmission(draft, penID: fixture.pen, existingChatIDs: []))
    #expect(chat.id == draft.id)
    // First-turn admission and navigation must use the same ID that the draft menu approved.
    var acceptedID: UUID?
    #expect(
        await ChatLaunch.submit(
            text: "Create the file", attachments: [], persist: { true },
            accept: { _, _ in
                acceptedID = chat.id
                return true
            }, navigate: {},
            discard: { Issue.record("The accepted draft should become a chat") }))
    #expect(acceptedID == draft.id)
    await permissions.load(database: fixture.db)
    let turn = UUID()
    let routes = try await fixture.routes(chatID: chat.id, penID: fixture.pen, turnID: turn)
    let result = try await fixture.invoke(
        try #require(routes["pen_write_file"]),
        arguments: #"{"path":"from-pen.txt","content":"approved in draft"}"#)
    #expect(result?.isError == false)
    #expect(
        try String(contentsOf: fixture.root.appendingPathComponent("from-pen.txt"), encoding: .utf8)
            == "approved in draft")
    await fixture.router.turnDidEnd(turnID: turn, cancelled: false)
    let next = ChatLaunch.nextDraft(after: chat)
    #expect(next.id != chat.id)
    #expect(
        permissions.scope(penID: fixture.pen, chatID: next.id, workspaceIdentity: identity)
            == (wholePen ? .pen : .ask))
}
