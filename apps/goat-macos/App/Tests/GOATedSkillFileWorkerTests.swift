import Foundation
import Testing

@testable import GOAT
@testable import Herd

@Test func skillManagerImportsListsAndRemovesAValidatedSkill() async throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("goat-skill-manager-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let sourceParent = temporary.appendingPathComponent("source", isDirectory: true)
    let source = sourceParent.appendingPathComponent("review-code", isDirectory: true)
    let destination = temporary.appendingPathComponent("destination", isDirectory: true)
    try LocalFileStore.ensureDirectory(at: source)
    try LocalFileStore.write(
        Data(
            """
            ---
            name: review-code
            description: Review code for correctness and maintainability.
            ---
            # Review code

            Inspect the relevant diff before reporting findings.
            """.utf8),
        to: source.appendingPathComponent("SKILL.md"))
    try LocalFileStore.write(
        Data("Checklist".utf8),
        to: source.appendingPathComponent("checklist.md"))

    let root = SkillManagementRoot(
        id: "global", label: "Global", root: destination, source: .global, isLocked: false)
    let worker = GOATedSkillFileWorker()

    try await worker.install(from: source, into: root)
    let installed = await worker.snapshot(roots: [root])
    #expect(installed.issues.isEmpty)
    #expect(installed.skills.map(\.name) == ["review-code"])

    try await worker.remove(named: "review-code", from: root)
    let removed = await worker.snapshot(roots: [root])
    #expect(removed.skills.isEmpty)
}

@Test func skillManagerRejectsSymlinkedResourcesDuringImport() async throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("goat-skill-manager-link-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let sourceParent = temporary.appendingPathComponent("source", isDirectory: true)
    let source = sourceParent.appendingPathComponent("unsafe-skill", isDirectory: true)
    let destination = temporary.appendingPathComponent("destination", isDirectory: true)
    let external = temporary.appendingPathComponent("outside.txt")
    try LocalFileStore.ensureDirectory(at: source)
    try LocalFileStore.write(
        Data(
            """
            ---
            name: unsafe-skill
            description: A skill with an unsafe resource link.
            ---
            # Unsafe
            """.utf8),
        to: source.appendingPathComponent("SKILL.md"))
    try LocalFileStore.write(Data("outside".utf8), to: external)
    try FileManager.default.createSymbolicLink(
        at: source.appendingPathComponent("linked.txt"),
        withDestinationURL: external)

    let root = SkillManagementRoot(
        id: "global", label: "Global", root: destination, source: .global, isLocked: false)
    let worker = GOATedSkillFileWorker()

    await #expect(throws: (any Error).self) {
        try await worker.install(from: source, into: root)
    }
    #expect(!(try LocalFileStore.directoryExists(at: destination.appendingPathComponent("unsafe-skill"))))
}
