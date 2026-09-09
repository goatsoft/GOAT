import Foundation
import Testing

@testable import GOAT
@testable import Herd

@Test func herdSlugNormalizesNamesWithoutLosingMeaning() {
    #expect(HerdWorkspace.slug(for: "GOAT hardening!") == "goat-hardening")
    #expect(HerdWorkspace.slug(for: "Café con leche") == "cafe-con-leche")
    #expect(HerdWorkspace.slug(for: "!!!") == "pen")
}

@Test func herdFolderAddsNumericSuffixInsteadOfAdoptingExistingFolder() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("goat-herd-workspace-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("goat-hardening", isDirectory: true),
        withIntermediateDirectories: false)

    let candidate = HerdWorkspace.nextAvailableFolder(for: "GOAT hardening", in: root)

    #expect(candidate.lastPathComponent == "goat-hardening-1")
}

@Test func herdBindingPersistsTheResolvedWorkspaceInsteadOfASymlinkAlias() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("goat-herd-workspace-link-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("target", isDirectory: true)
    let alias = root.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

    let workspace = HerdWorkspace.binding(for: alias, wasCreatedByGOAT: false)

    #expect(workspace.path == target.resolvingSymlinksInPath().path)
}

@Test func porcelainParserSeparatesStagedModifiedUntrackedAndRemoteCounts() {
    let status = GitPorcelainParser.parse(
        """
        # branch.oid 1234567890
        # branch.head codex/goat-hardening
        # branch.upstream origin/codex/goat-hardening
        # branch.ab +2 -1
        1 M. N... 100644 100644 100644 abc def staged.swift
        1 .M N... 100644 100644 100644 abc def modified.swift
        ? new.swift
        u UU N... 100644 100644 100644 100644 abc def ghi conflict.swift
        """,
        rootPath: "/tmp/project")

    #expect(status.branch == "codex/goat-hardening")
    #expect(!status.isDetached)
    #expect(status.stagedCount == 1)
    #expect(status.modifiedCount == 1)
    #expect(status.untrackedCount == 1)
    #expect(status.conflictedCount == 1)
    #expect(status.aheadCount == 2)
    #expect(status.behindCount == 1)
    #expect(!status.isClean)
}

@Test func explicitlyInitializingANewWorkspaceCreatesAnEmptyGitRepository() async throws {
    let installation = await GitWorkspaceWorker.shared.installation()
    guard installation.isAvailable else { return }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("goat-git-workspace-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let workspace = try await HerdWorkspaceFileWorker.shared.createWorkspace(
        name: "Git project", rootPath: root.path)
    let initialization = await GitWorkspaceWorker.shared.initializeRepository(at: workspace)

    #expect(initialization == .initialized)
    if case .repository(let status) = await GitWorkspaceWorker.shared.status(at: workspace) {
        #expect(status.isClean)
    } else {
        Issue.record("The initialized project folder should report a Git repository.")
    }
}

@Test func gitInitializationDoesNotMutateABoundExistingFolder() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("goat-bound-workspace-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let workspace = await HerdWorkspaceFileWorker.shared.bindWorkspace(at: root)
    let initialization = await GitWorkspaceWorker.shared.initializeRepository(at: workspace)

    #expect(initialization == .failed("GOAT only initializes project folders it just created."))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path))
}

@Test func gitStatusNeverExecutesARepositoryConfiguredFsmonitorHook() async throws {
    let installation = await GitWorkspaceWorker.shared.installation()
    guard installation.isAvailable else { return }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("goat-git-fsmonitor-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try runSystemGit(["init", "--quiet"], directory: root)

    let sentinel = root.appendingPathComponent("fsmonitor-ran", isDirectory: false)
    let hook = root.appendingPathComponent("fsmonitor-hook", isDirectory: false)
    let script = "#!/bin/sh\nprintf hook > \"\(sentinel.path)\"\n"
    try script.write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    try runSystemGit(["config", "core.fsmonitor", hook.path], directory: root)

    _ = await GitWorkspaceWorker.shared.status(
        at: HerdWorkspace.binding(for: root, wasCreatedByGOAT: false))

    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
}

private func runSystemGit(_ arguments: [String], directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "HerdWorkspaceTests", code: Int(process.terminationStatus))
    }
}
