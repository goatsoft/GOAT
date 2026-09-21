import Darwin
import Foundation
import Testing

@testable import Caprine
@testable import Herd

private func temporaryDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("goat-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func userTheme(id: String = "test-theme", preview: String? = nil) -> ThemeSpec {
    var spec = storedThemeFixture()
    spec.id = id
    spec.name = "Test Theme"
    spec.preview = preview
    return spec
}

@Test func missingThemeRootIsEmpty() throws {
    let parent = try temporaryDirectory("missing-stores")
    defer { try? FileManager.default.removeItem(at: parent) }

    #expect(try ThemeStore.all(in: parent.appendingPathComponent("themes")).isEmpty)
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

@Test func symlinkedThemeEntriesAreRejected() throws {
    let parent = try temporaryDirectory("store-symlinks")
    defer { try? FileManager.default.removeItem(at: parent) }
    let outside = parent.appendingPathComponent("outside", isDirectory: true)
    let themes = parent.appendingPathComponent("themes", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: themes.appendingPathComponent("linked"), withDestinationURL: outside)

    #expect(throws: LocalStoreError.self) { _ = try ThemeStore.all(in: themes) }
    #expect(FileManager.default.fileExists(atPath: outside.path))
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

@Test func failedThemeUpdatesLeaveVisibleStateUntouched() throws {
    let parent = try temporaryDirectory("transactional-directory-update")
    defer { try? FileManager.default.removeItem(at: parent) }
    let themes = parent.appendingPathComponent("themes", isDirectory: true)
    let outside = parent.appendingPathComponent("outside.txt")
    try Data("outside".utf8).write(to: outside)

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

@Test func newThemeCommitsLeaveNoStagingDirectories() throws {
    let root = try temporaryDirectory("staged-themes")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try ThemeStore.save(userTheme(), in: root)
    #expect(try ThemeStore.all(in: root).map(\.id) == ["test-theme"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".goat-stage-") })
}
