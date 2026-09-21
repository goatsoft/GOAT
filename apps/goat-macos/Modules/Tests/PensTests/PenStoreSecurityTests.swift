import Darwin
import Foundation
import Testing

@testable import Herd
@testable import Pens

private func temporaryDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("goat-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func missingPenRootIsEmpty() throws {
    let parent = try temporaryDirectory("missing-stores")
    defer { try? FileManager.default.removeItem(at: parent) }

    #expect(try PenStore.all(in: parent.appendingPathComponent("pens")).isEmpty)
}

@Test func symlinkedPenEntriesAreRejected() throws {
    let parent = try temporaryDirectory("store-symlinks")
    defer { try? FileManager.default.removeItem(at: parent) }
    let outside = parent.appendingPathComponent("outside", isDirectory: true)
    let pens = parent.appendingPathComponent("pens", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: pens, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: pens.appendingPathComponent("linked"), withDestinationURL: outside)

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

@Test func failedPenUpdatesLeaveVisibleStateUntouched() throws {
    let parent = try temporaryDirectory("transactional-directory-update")
    defer { try? FileManager.default.removeItem(at: parent) }
    let pens = parent.appendingPathComponent("pens", isDirectory: true)
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

}

@Test func newPenCommitsLeaveNoStagingDirectories() throws {
    let root = try temporaryDirectory("staged-pens")
    defer { try? FileManager.default.removeItem(at: root) }
    let pen = PenSpec(id: UUID().uuidString, name: "Safe Pen", emoji: "🐐", color: .fallback)
    try PenStore.save(pen, instructions: "Keep it safe.", in: root)
    #expect(try PenStore.all(in: root).map(\.id) == [pen.id])
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".goat-stage-") })
}
