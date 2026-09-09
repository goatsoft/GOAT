import Foundation
import Pens
import Testing

@testable import GOAT
@testable import Hoofprint

@Test @MainActor func commandWhitelistIsSeparateScopedDurableAndRevocable() async throws {
    let suite = "command-grants-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try PenFileTools(workspace: root)
    let runner = PenCommandTools(workspace: root, files: files)
    let command = try await runner.prepare(argumentsJSON: #"{"command":"sh","args":["-c","echo test"]}"#)
    let pen = UUID()
    let chat = UUID()
    let permissions = PenCommandPermissionModel(defaults: defaults)
    #expect(!permissions.allows(command, penID: pen, chatID: chat, workspaceIdentity: files.workspaceIdentity))
    #expect(permissions.remember(command, penID: pen, chatID: chat, workspaceIdentity: files.workspaceIdentity))
    let restored = PenCommandPermissionModel(defaults: defaults)
    #expect(restored.allows(command, penID: pen, chatID: chat, workspaceIdentity: files.workspaceIdentity))
    #expect(!restored.allows(command, penID: pen, chatID: UUID(), workspaceIdentity: files.workspaceIdentity))
    #expect(!restored.allows(command, penID: UUID(), chatID: chat, workspaceIdentity: files.workspaceIdentity))
    #expect(!restored.allows(command, penID: pen, chatID: chat, workspaceIdentity: "replacement workspace"))
    #expect(restored.remember(command, penID: pen, chatID: nil, workspaceIdentity: files.workspaceIdentity))
    #expect(restored.allows(command, penID: pen, chatID: UUID(), workspaceIdentity: files.workspaceIdentity))
    let network = try await runner.prepare(argumentsJSON: #"{"command":"sh","args":["-c","echo test"],"network":true}"#)
    #expect(!restored.allows(network, penID: pen, chatID: chat, workspaceIdentity: files.workspaceIdentity))
    restored.reset(penID: pen)
    #expect(!restored.allows(command, penID: pen, chatID: chat, workspaceIdentity: files.workspaceIdentity))
    #expect(PenCommandPermissionModel(defaults: defaults).grants.isEmpty)
    await runner.stopAll()
}

@Test @MainActor func ownerCanReviewAddEditAndRemoveAnExecutableWithoutRunningIt() async throws {
    let suite = "owner-command-grants-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(suite)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("custom-tool")
    let marker = root.appendingPathComponent("should-not-run")
    try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let permissions = PenCommandPermissionModel(defaults: defaults)
    let checked = try await permissions.review(command: "./custom-tool", workspace: root)
    #expect(
        checked.executable.path
            == URL(fileURLWithPath: try PenFileTools(workspace: root).workspacePath)
            .appendingPathComponent("custom-tool").path)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    let pen = UUID()
    let chat = UUID()
    #expect(await permissions.saveReviewed(checked, penID: pen, chatID: nil, network: true, replacing: nil))
    let files = try PenFileTools(workspace: root)
    let runner = PenCommandTools(workspace: root, files: files)
    let offline = try await runner.prepare(
        argumentsJSON: #"{"command":"./custom-tool","args":["custom-script","--custom-option"]}"#)
    let online = try await runner.prepare(
        argumentsJSON: #"{"command":"./custom-tool","args":["install"],"network":true}"#)
    #expect(permissions.allows(offline, penID: pen, chatID: chat, workspaceIdentity: files.workspaceIdentity))
    #expect(permissions.allows(online, penID: pen, chatID: chat, workspaceIdentity: files.workspaceIdentity))
    #expect(!permissions.allows(online, penID: UUID(), chatID: chat, workspaceIdentity: files.workspaceIdentity))
    let restored = PenCommandPermissionModel(defaults: defaults)
    let grant = try #require(restored.grants.first)
    #expect(grant.executablePath == checked.executable.path)
    let edited = try await restored.review(command: script.path, workspace: root)
    #expect(await restored.saveReviewed(edited, penID: pen, chatID: chat, network: false, replacing: grant.id))
    #expect(restored.grants.count == 1 && restored.grants.first?.id == grant.id)
    #expect(restored.allows(offline, penID: pen, chatID: chat, workspaceIdentity: files.workspaceIdentity))
    #expect(!restored.allows(online, penID: pen, chatID: chat, workspaceIdentity: files.workspaceIdentity))
    #expect(!restored.allows(offline, penID: pen, chatID: UUID(), workspaceIdentity: files.workspaceIdentity))
    restored.revoke(grant.id)
    #expect(PenCommandPermissionModel(defaults: defaults).grants.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test @MainActor func manualReviewCannotRestoreRevokedAuthorityOrApproveAChangedExecutable() async throws {
    let suite = "stale-command-review-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(suite)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("tool")
    try "#!/bin/sh\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let permissions = PenCommandPermissionModel(defaults: defaults)
    let pen = UUID()
    let stale = try await permissions.review(command: script.path, workspace: root)
    permissions.reset(penID: pen)
    #expect(!(await permissions.saveReviewed(stale, penID: pen, chatID: nil, network: false, replacing: nil)))
    let changed = try await permissions.review(command: script.path, workspace: root)
    try "#!/bin/sh\necho changed\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    #expect(!(await permissions.saveReviewed(changed, penID: pen, chatID: nil, network: true, replacing: nil)))
    #expect(permissions.grants.isEmpty)
    #expect(permissions.reviewError != nil)
    #expect(permissions.error == nil)
    await #expect(throws: (any Error).self) {
        _ = try await permissions.review(command: "sh -c echo wrong", workspace: root)
    }
}

@Test @MainActor func olderCommandGrantsLoadWithoutAnExecutablePath() throws {
    let suite = "legacy-command-grant-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let id = UUID()
    let pen = UUID()
    let data = try JSONSerialization.data(withJSONObject: [
        [
            "id": id.uuidString, "penID": pen.uuidString,
            "workspaceIdentity": "workspace", "commandIdentity": "executable", "name": "npm", "network": true,
        ]
    ])
    defaults.set(data, forKey: "herder.commandGrants.v1")
    let permissions = PenCommandPermissionModel(defaults: defaults)
    #expect(permissions.error == nil)
    #expect(permissions.grants.first?.id == id)
    #expect(permissions.grants.first?.executablePath == nil)
}
