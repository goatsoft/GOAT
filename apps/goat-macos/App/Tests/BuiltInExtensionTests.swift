import Foundation
import Testing

@testable import GOAT
@testable import Hoofprint
@testable import Memory
@testable import Pens

@MainActor @Test func builtInPreferencesDefaultOnAndPersistWithoutGrantingPermissions() throws {
    let name = "goat-builtin-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = BuiltInExtensionSettings(defaults: defaults)
    #expect(settings.herderEnabled && settings.herderWritesEnabled && settings.herderCommandsEnabled)
    #expect(settings.hindsightEnabled && settings.commandTimeout == 120)
    settings.herderEnabled = false
    settings.herderWritesEnabled = false
    settings.herderCommandsEnabled = false
    settings.setHindsightEnabled(false)
    settings.setCommandTimeout(900)
    let loaded = BuiltInExtensionSettings(defaults: defaults)
    #expect(!loaded.herderEnabled && !loaded.herderWritesEnabled && !loaded.herderCommandsEnabled)
    #expect(!loaded.hindsightEnabled && loaded.commandTimeout == 600)
    loaded.herderEnabled = true
    #expect(loaded.allowsHerderTool("pen_read_file"))
    #expect(!loaded.allowsHerderTool("pen_write_file"))
    #expect(!loaded.allowsHerderTool("pen_run_command"))
    loaded.setCommandTimeout(0)
    #expect(loaded.commandTimeout == 1)
}

@MainActor @Test func herderCanBeReadOnlyOrDisabledAndOldRoutesCannotBypassIt() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("herder-settings-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "hello".write(to: root.appendingPathComponent("example.txt"), atomically: true, encoding: .utf8)
    let name = "goat-builtin-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = BuiltInExtensionSettings(defaults: defaults)
    settings.herderWritesEnabled = false
    settings.herderCommandsEnabled = false
    let activity = ActivityLog()
    let memory = MemoryModel(activity: activity, builtInSettings: settings)
    let router = AppToolRouter(
        mcp: MCPModel(db: nil, activity: activity), memory: memory,
        activity: activity, builtInSkillsRoot: root, globalSkillsRoot: root)
    let pen = UUID()
    let chat = UUID()
    let turn = UUID()
    router.workspaceForProject = { _ in root }
    try await router.turnWillPrepare(chatID: chat, projectID: pen, turnID: turn)
    let (specs, routes) = await router.availableToolSpecs(
        forChatID: chat, projectID: pen,
        includeMCP: true, excludedMCPServers: [])
    #expect(
        Set(specs.filter { $0.name.hasPrefix("pen_") }.map(\.name))
            == Set(["pen_list_files", "pen_read_file", "pen_search", "pen_glob"]))
    let read = try #require(routes["pen_read_file"])
    let result = try await router.authorizeAndInvoke(route: read, argumentsJSON: #"{"path":"example.txt"}"#)
    #expect(result?.content.contains("hello") == true)
    settings.herderEnabled = false
    await #expect(throws: (any Error).self) {
        _ = try await router.authorizeAndInvoke(route: read, argumentsJSON: #"{"path":"example.txt"}"#)
    }
    await router.turnDidEnd(turnID: turn, cancelled: false)
    try await router.turnWillPrepare(chatID: chat, projectID: pen, turnID: UUID())
    let (disabled, _) = await router.availableToolSpecs(
        forChatID: chat, projectID: pen,
        includeMCP: true, excludedMCPServers: [])
    #expect(!disabled.contains { $0.name.hasPrefix("pen_") })
    #expect(try String(contentsOf: root.appendingPathComponent("example.txt"), encoding: .utf8) == "hello")
}

@MainActor @Test func disablingHindsightHidesChoicesAndPreservesItsSavedSelection() async throws {
    let name = "goat-builtin-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = BuiltInExtensionSettings(defaults: defaults)
    let activity = ActivityLog()
    let memory = MemoryModel(activity: activity, builtInSettings: settings)
    let id = MemoryProviderID(rawValue: "test-hindsight")
    memory.configuration.providers.append(
        MemoryProviderRecord(
            id: id, displayName: "Hindsight", kind: .hindsight,
            hindsight: HindsightProviderConfiguration(
                connection: HindsightBankConnection(apiURL: "http://127.0.0.1:1", bankID: "goat"))))
    memory.configuration.global.providerID = id
    let original = memory.configuration
    let router = AppToolRouter(mcp: MCPModel(db: nil, activity: activity), memory: memory, activity: activity)
    await router.refreshHindsightExtension()
    #expect(await router.extensions.activeExtensions().contains { $0.id.rawValue == "goat.hindsight" })
    await memory.setHindsightExtensionEnabled(false)
    await router.refreshHindsightExtension()
    #expect(memory.configuration == original)
    #expect(!memory.providers.contains { $0.kind == .hindsight })
    #expect(memory.configuredHindsightProvider == nil)
    #expect(memory.hindsightConnection(forProjectID: nil) == nil)
    #expect(!memory.isProviderAvailable(id))
    #expect(memory.unavailableProviderReason(id)?.contains("disabled in Extensions") == true)
    #expect(await memory.testHindsight(id)?.state != .ready)
    #expect(!memory.isUsingHindsight(forProjectID: nil))
    #expect(!(await router.extensions.activeExtensions()).contains { $0.id.rawValue == "goat.hindsight" })
    // Restore availability without choosing a different provider or touching saved configuration.
    settings.setHindsightEnabled(true)
    await router.refreshHindsightExtension()
    #expect(memory.configuration == original)
    #expect(memory.providers.contains { $0.id == id })
    #expect(await router.extensions.activeExtensions().contains { $0.id.rawValue == "goat.hindsight" })
}

@Test func herderCommandTimeoutUsesConfigurationUnlessExplicitlyOverridden() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("herder-timeout-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try PenFileTools(workspace: root)
    let runner = PenCommandTools(workspace: root, files: files, defaultTimeout: 30)
    let command = try await runner.prepare(argumentsJSON: #"{"command":"/bin/pwd","args":[]}"#)
    let explicit = try await runner.prepare(argumentsJSON: #"{"command":"/bin/pwd","args":[],"timeout_seconds":45}"#)
    let first = try #require(JSONSerialization.jsonObject(with: Data(command.previewJSON.utf8)) as? [String: Any])
    let second = try #require(JSONSerialization.jsonObject(with: Data(explicit.previewJSON.utf8)) as? [String: Any])
    #expect(first["timeout_seconds"] as? Int == 30)
    #expect(second["timeout_seconds"] as? Int == 45)
}
