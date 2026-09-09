import Foundation
import GOATed
import Herd
import Testing

@testable import GOAT

private func examplePackage() throws -> ExtensionPackage {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../examples/vue-toolkit.goated").standardizedFileURL
    return try ExtensionPackage(archive: Data(contentsOf: path))
}

@MainActor @Test func userPackageInstallEnableDisableRestoreAndRemoveAreScoped() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("goated-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = ExtensionRuntime()
    let manager = UserExtensionManager(runtime: runtime, root: root)
    await manager.load()
    let package = try examplePackage()
    let pen = UUID()
    let view = ExtensionView(chatID: UUID(), penID: pen)
    try await manager.install(package, penID: pen, enabled: false)
    #expect(manager.items.count == 1)
    #expect(await runtime.skillCatalog(for: view).skills.isEmpty)
    try await manager.setEnabled(package.manifest.id, true)
    #expect(await runtime.skillCatalog(for: view).skills.map(\.name) == ["vue"])
    #expect(await runtime.skillCatalog(for: ExtensionView(chatID: UUID(), penID: nil)).skills.isEmpty)
    let restoredRuntime = ExtensionRuntime()
    let restored = UserExtensionManager(runtime: restoredRuntime, root: root)
    await restored.load()
    #expect(restored.items.first?.enabled == true)
    #expect(await restoredRuntime.skillCatalog(for: view).skills.map(\.name) == ["vue"])
    try await restored.setEnabled(package.manifest.id, false)
    #expect(await restoredRuntime.skillCatalog(for: view).skills.isEmpty)
    let disabled = UserExtensionManager(runtime: ExtensionRuntime(), root: root)
    await disabled.load()
    #expect(disabled.items.first?.enabled == false)
    try await restored.remove(package.manifest.id)
    #expect(restored.items.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(package.manifest.id + ".json").path))
}

@MainActor @Test func userPackageReviewPinsBytesAndExportsWithoutEnabling() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("goated-review-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let original = try examplePackage()
    let source = root.appendingPathComponent("input.goated")
    try original.archive.write(to: source)
    let manager = UserExtensionManager(runtime: ExtensionRuntime(), root: root.appendingPathComponent("installed"))
    let reviewed = try await manager.store.inspect(source)
    try Data("changed after review".utf8).write(to: source)
    try await manager.install(reviewed, penID: nil, enabled: false)
    #expect(manager.items.first?.package.archive == original.archive)
    let exported = root.appendingPathComponent("export.goated")
    try await manager.store.export(reviewed, to: exported)
    #expect(try Data(contentsOf: exported) == original.archive)
    #expect(manager.items.first?.enabled == false)
    await #expect(throws: (any Error).self) { try await manager.install(reviewed, penID: nil, enabled: true) }
    #expect(manager.items.count == 1)
    #expect(manager.items.first?.enabled == false)
}

@MainActor @Test func corruptUserPackageCannotActivateAndManagedWritesRejectLinks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("goated-corrupt-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let package = try examplePackage()
    let record = root.appendingPathComponent(package.manifest.id + ".json")
    try Data("invalid record".utf8).write(to: record)
    let runtime = ExtensionRuntime()
    let manager = UserExtensionManager(runtime: runtime, root: root)
    await manager.load()
    #expect(manager.items.isEmpty)
    #expect(manager.issues.count == 1)
    #expect(await runtime.activeExtensions().isEmpty)
    await #expect(throws: (any Error).self) { try await manager.install(package, penID: nil, enabled: true) }
    try FileManager.default.removeItem(at: record)
    let outside = root.appendingPathComponent("untouched")
    try Data("unchanged".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: record, withDestinationURL: outside)
    await #expect(throws: (any Error).self) { try await manager.install(package, penID: nil, enabled: true) }
    #expect(try String(contentsOf: outside, encoding: .utf8) == "unchanged")
    #expect(await runtime.activeExtensions().isEmpty)
}
