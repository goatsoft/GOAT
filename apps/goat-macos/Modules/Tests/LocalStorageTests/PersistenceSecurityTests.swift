import Darwin
import Foundation
import Testing

@testable import Caprine
@testable import Herd
@testable import Pens

private func temporaryDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("goat-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func userTheme(id: String = "test-theme", preview: String? = nil) -> ThemeSpec {
    var spec = ThemeCatalog.builtins[2]
    spec.id = id
    spec.name = "Test Theme"
    spec.preview = preview
    return spec
}

@Test func missingThemeAndPenRootsAreEmpty() throws {
    let parent = try temporaryDirectory("missing-stores")
    defer { try? FileManager.default.removeItem(at: parent) }

    #expect(try ThemeStore.all(in: parent.appendingPathComponent("themes")).isEmpty)
    #expect(try PenStore.all(in: parent.appendingPathComponent("pens")).isEmpty)
}

@Test func corruptThemeMetadataThrowsInsteadOfLookingMissing() throws {
    let root = try temporaryDirectory("corrupt-theme")
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("broken", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: folder.appendingPathComponent("theme.json"))

    #expect(throws: LocalStoreError.self) {
        _ = try ThemeStore.all(in: root)
    }
}

@Test func corruptCredentialsAreNeverOverwrittenByASet() throws {
    let root = try temporaryDirectory("corrupt-credentials")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("credentials.json")
    let original = Data("{ broken".utf8)
    try original.write(to: file)

    #expect(throws: LocalStoreError.self) {
        try CredentialStore.set("secret", for: "engine.test.apiKey", in: file)
    }
    #expect(try Data(contentsOf: file) == original)
}

@Test func credentialReplacementIsOwnerOnly() throws {
    let root = try temporaryDirectory("credential-mode")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("credentials.json")

    try CredentialStore.set("secret", for: "engine.test.apiKey", in: file)

    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect((permissions.intValue & 0o777) == 0o600)
    #expect(try CredentialStore.load(from: file)["engine.test.apiKey"] == "secret")
}

@Test func loadingLegacyCredentialsTightensPermissionsBeforeReading() throws {
    let root = try temporaryDirectory("credential-load-mode")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("credentials.json")
    try Data(#"{"key":"secret"}"#.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

    #expect(try CredentialStore.load(from: file)["key"] == "secret")

    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect((permissions.intValue & 0o777) == 0o600)
}

@Test func managedAndOwnerOnlyReadsRejectOversizedFiles() throws {
    let root = try temporaryDirectory("bounded-local-files")
    defer { try? FileManager.default.removeItem(at: root) }
    let managed = root.appendingPathComponent("managed.json")
    let secret = root.appendingPathComponent("secret.json")

    FileManager.default.createFile(atPath: managed.path, contents: Data())
    let managedHandle = try FileHandle(forWritingTo: managed)
    try managedHandle.truncate(
        atOffset: UInt64(LocalFileStore.maximumManagedFileBytes + 1))
    try managedHandle.close()

    FileManager.default.createFile(atPath: secret.path, contents: Data())
    let secretHandle = try FileHandle(forWritingTo: secret)
    try secretHandle.truncate(
        atOffset: UInt64(LocalFileStore.maximumOwnerOnlyFileBytes + 1))
    try secretHandle.close()

    #expect(throws: LocalStoreError.self) {
        _ = try LocalFileStore.dataIfPresent(at: managed)
    }
    #expect(throws: LocalStoreError.self) {
        _ = try CredentialStore.load(from: secret)
    }
}

@Test func managedReadsRejectSpecialFilesWithoutBlocking() throws {
    let root = try temporaryDirectory("special-local-files")
    defer { try? FileManager.default.removeItem(at: root) }
    let fifo = root.appendingPathComponent("named-pipe")
    #expect(Darwin.mkfifo(fifo.path, mode_t(0o600)) == 0)

    #expect(throws: LocalStoreError.self) {
        _ = try LocalFileStore.dataIfPresent(at: fifo)
    }
    #expect(throws: LocalStoreError.self) {
        _ = try LocalFileStore.ownerOnlyDataIfPresent(at: fifo)
    }
}

@Test func themeIDsAndPreviewNamesCannotEscapeTheThemeRoot() throws {
    let root = try temporaryDirectory("theme-paths")
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(throws: LocalStoreError.self) {
        _ = try ThemeStore.save(userTheme(id: "../../escaped"), in: root)
    }
    #expect(throws: LocalStoreError.self) {
        _ = try ThemeStore.save(
            userTheme(id: "safe-theme", preview: "../outside.png"), in: root)
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("safe-theme").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func symlinkedThemeAndPenEntriesAreRejected() throws {
    let parent = try temporaryDirectory("store-symlinks")
    defer { try? FileManager.default.removeItem(at: parent) }
    let outside = parent.appendingPathComponent("outside", isDirectory: true)
    let themes = parent.appendingPathComponent("themes", isDirectory: true)
    let pens = parent.appendingPathComponent("pens", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: pens, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: themes.appendingPathComponent("linked"), withDestinationURL: outside)
    try FileManager.default.createSymbolicLink(
        at: pens.appendingPathComponent("linked"), withDestinationURL: outside)

    #expect(throws: LocalStoreError.self) { _ = try ThemeStore.all(in: themes) }
    #expect(throws: LocalStoreError.self) { _ = try PenStore.all(in: pens) }
    #expect(FileManager.default.fileExists(atPath: outside.path))
}

@Test func invalidPenUUIDIsRejectedWithoutCreatingAFolder() throws {
    let root = try temporaryDirectory("invalid-pen-id")
    defer { try? FileManager.default.removeItem(at: root) }
    let spec = PenSpec(
        id: "not-a-uuid", name: "Unsafe", emoji: "🐐", color: .fallback)

    #expect(throws: LocalStoreError.self) {
        try PenStore.save(spec, instructions: "test", in: root)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func penIDsMustBeCanonicalAndUnique() throws {
    let root = try temporaryDirectory("canonical-pen-id")
    defer { try? FileManager.default.removeItem(at: root) }
    let canonicalID = UUID().uuidString
    let lowercase = PenSpec(
        id: canonicalID.lowercased(), name: "Lowercase", emoji: "🐐", color: .fallback)

    #expect(throws: LocalStoreError.self) {
        try PenStore.save(lowercase, instructions: "test", in: root)
    }

    let valid = PenSpec(
        id: canonicalID, name: "Original", emoji: "🐐", color: .fallback)
    try PenStore.save(valid, instructions: "test", in: root)
    let original = try #require(try PenStore.folder(for: canonicalID, in: root))
    try FileManager.default.copyItem(
        at: original, to: root.appendingPathComponent("duplicate", isDirectory: true))
    #expect(throws: LocalStoreError.self) { _ = try PenStore.all(in: root) }
}

@Test func penWorkspaceRoundTripsWithoutMovingTheUserFolder() throws {
    let root = try temporaryDirectory("pen-workspace")
    defer { try? FileManager.default.removeItem(at: root) }
    let workspacePath = "/tmp/goat-user-workspace-\(UUID().uuidString)"
    let workspace = PenWorkspace(
        path: workspacePath, bookmark: Data([0x01]), wasCreatedByGOAT: false)
    let pen = PenSpec(
        id: UUID().uuidString, name: "River", emoji: "🐐", color: .fallback, workspace: workspace)

    try PenStore.save(pen, instructions: "A Pen with a user workspace.", in: root)

    let restored = try #require(try PenStore.all(in: root).first)
    #expect(restored.workspace == workspace)
    #expect(!FileManager.default.fileExists(atPath: workspacePath))
}

@Test func themeIDsSchemasAndTokensFailClosed() throws {
    let root = try temporaryDirectory("theme-validation")
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try ThemeStore.save(userTheme(id: "foo"), in: root)
    #expect(throws: LocalStoreError.self) {
        _ = try ThemeStore.save(userTheme(id: "Foo"), in: root)
    }
    #expect(throws: LocalStoreError.self) {
        _ = try ThemeStore.save(userTheme(id: "foo.bar"), in: root)
    }
    var future = userTheme(id: "future")
    future.schema = ThemeSpec.schemaVersion + 1
    #expect(throws: LocalStoreError.self) { _ = try ThemeStore.save(future, in: root) }
    var malformed = userTheme(id: "malformed")
    malformed.accent = "red"
    malformed.intensity = 3
    #expect(throws: LocalStoreError.self) { _ = try ThemeStore.save(malformed, in: root) }
    #expect(try ThemeStore.all(in: root).map(\.id) == ["foo"])
}

@Test func legacyThemeMigrationResumesAndDoesNotResurrectAfterDeleteAll() throws {
    let parent = try temporaryDirectory("theme-migration")
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("themes", isDirectory: true)
    let legacy = parent.appendingPathComponent("themes.json")
    let marker = parent.appendingPathComponent(".themes-v1-migrated")
    let first = userTheme(id: "legacy-one")
    let second = userTheme(id: "legacy-two")
    try JSONEncoder().encode([first, second]).write(to: legacy)

    // Simulate interruption after the first folder committed but before the marker was written.
    _ = try ThemeStore.save(first, in: root)
    try ThemeStore.migrateLegacyFileIfNeeded(legacy: legacy, marker: marker, root: root)
    #expect(Set(try ThemeStore.all(in: root).map(\.id)) == ["legacy-one", "legacy-two"])
    #expect(FileManager.default.fileExists(atPath: marker.path))

    try ThemeStore.delete(id: "legacy-one", in: root)
    try ThemeStore.delete(id: "legacy-two", in: root)
    try ThemeStore.migrateLegacyFileIfNeeded(legacy: legacy, marker: marker, root: root)
    #expect(try ThemeStore.all(in: root).isEmpty)
}

@Test func failedExistingDirectoryUpdatesLeaveVisibleStateUntouched() throws {
    let parent = try temporaryDirectory("transactional-directory-update")
    defer { try? FileManager.default.removeItem(at: parent) }
    let pens = parent.appendingPathComponent("pens", isDirectory: true)
    let themes = parent.appendingPathComponent("themes", isDirectory: true)
    let outside = parent.appendingPathComponent("outside.txt")
    try Data("outside".utf8).write(to: outside)

    let pen = PenSpec(
        id: UUID().uuidString, name: "Stable", emoji: "🐐", color: .fallback)
    try PenStore.save(pen, instructions: "old", in: pens)
    let penFolder = try #require(try PenStore.folder(for: pen.id, in: pens))
    let agents = penFolder.appendingPathComponent("AGENTS.md")
    try FileManager.default.removeItem(at: agents)
    try FileManager.default.createSymbolicLink(at: agents, withDestinationURL: outside)
    #expect(throws: LocalStoreError.self) {
        try PenStore.save(pen, instructions: "new", in: pens)
    }
    #expect(try String(contentsOf: penFolder.appendingPathComponent("README.md"), encoding: .utf8) == "old")

    let theme = userTheme(id: "stable-theme")
    _ = try ThemeStore.save(theme, previewData: Data("old-preview".utf8), in: themes)
    let themeFolder = try ThemeStore.folder(for: theme.id, in: themes)
    let metadata = themeFolder.appendingPathComponent("theme.json")
    try FileManager.default.removeItem(at: metadata)
    try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: outside)
    #expect(throws: LocalStoreError.self) {
        _ = try ThemeStore.save(theme, previewData: Data("new-preview".utf8), in: themes)
    }
    #expect(
        try Data(contentsOf: themeFolder.appendingPathComponent("preview.png"))
            == Data("old-preview".utf8))
}

@Test func newPenAndThemeCommitsLeaveNoStagingDirectories() throws {
    let parent = try temporaryDirectory("staged-stores")
    defer { try? FileManager.default.removeItem(at: parent) }
    let themes = parent.appendingPathComponent("themes", isDirectory: true)
    let pens = parent.appendingPathComponent("pens", isDirectory: true)
    let pen = PenSpec(
        id: UUID().uuidString, name: "Safe Pen", emoji: "🐐", color: .fallback)

    _ = try ThemeStore.save(userTheme(), in: themes)
    try PenStore.save(pen, instructions: "Keep it safe.", in: pens)

    #expect(try ThemeStore.all(in: themes).map(\.id) == ["test-theme"])
    #expect(try PenStore.all(in: pens).map(\.id) == [pen.id])
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: themes.path)
            .allSatisfy { !$0.hasPrefix(".goat-stage-") })
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: pens.path)
            .allSatisfy { !$0.hasPrefix(".goat-stage-") })
}
