import Darwin
import Dispatch
import Foundation
import Testing

@testable import Herd
@testable import Memory

private func temporaryMemoryRoot(_ label: String) throws -> (parent: URL, root: URL) {
    let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("goat-memory-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    return (parent, parent.appendingPathComponent("memory", isDirectory: true))
}

private func expectFailure<T>(
    _ message: String = "Expected operation to fail",
    _ operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        Issue.record("Operation unexpectedly succeeded: \(message)")
    } catch {}
}

private func note(
    _ name: String = "dog-name",
    description: String = "The user's dog's name.",
    body: String = "The dog's name is Peanut."
) -> MemoryNote {
    MemoryNote(name: name, description: description, body: body)
}

private func globalFolder(_ root: URL) -> URL {
    root.appendingPathComponent("global", isDirectory: true)
}

@Test func localFileStoreWritesThroughPrivateTmpWithoutLosingContainment() throws {
    let paths = try temporaryMemoryRoot("local-file-store-private-tmp")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let file = paths.root.appendingPathComponent("AGENTS.md")
    try LocalFileStore.write(Data("ok".utf8), to: file)
    #expect(try Data(contentsOf: file) == Data("ok".utf8))
}

private func waitForSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: TimeInterval = 5
) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(
                returning: semaphore.wait(timeout: .now() + timeout) == .success)
        }
    }
}

@Test func missingScopesAreEmptyAndDoNotCreateDirectories() async throws {
    let paths = try temporaryMemoryRoot("missing")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let store = WikiMemoryStore(root: paths.root)

    #expect(try await store.summaries(in: .global).isEmpty)
    #expect(try await store.read("dog-name", scope: .global) == nil)
    #expect(try await store.promptSnapshot(for: MemoryContext()).entries.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: paths.root.path))
}

@Test func roundTripUsesQuotedYAMLAndPublishesCanonicalIndex() async throws {
    let paths = try temporaryMemoryRoot("round-trip")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let store = WikiMemoryStore(root: paths.root)
    let description = "Prefers \"quotes\", backslash \\, colon: value, #hash, and café 🐐."
    let original = note(description: description, body: "Peanut's name uses café spelling 🐐.")

    let saved = try await store.write(original, scope: .global, condition: .ifAbsent)
    let loaded = try #require(try await store.read(original.name, scope: .global))
    #expect(loaded.note == original)
    #expect(loaded.revision == saved.revision)

    let folder = globalFolder(paths.root)
    let markdown = try String(
        contentsOf: folder.appendingPathComponent("dog-name.md"), encoding: .utf8)
    #expect(markdown.contains("name: \"dog-name\""))
    #expect(markdown.contains("description: \"Prefers \\\"quotes\\\", backslash \\\\"))
    #expect(markdown.contains("café 🐐"))

    let index = try String(
        contentsOf: folder.appendingPathComponent("MEMORY.md"), encoding: .utf8)
    #expect(index.hasPrefix(WikiMemoryCodec.indexHeader))
    #expect(index.contains("- [[dog-name]]: \(description)"))
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: paths.root.path)
            .allSatisfy { !$0.hasPrefix(".goat-memory-stage-") })
}

@Test func globalAndProjectScopesRemainIsolatedInPromptSnapshots() async throws {
    let paths = try temporaryMemoryRoot("scopes")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let store = WikiMemoryStore(root: paths.root)
    let projectID = UUID()
    _ = try await store.write(note("global-fact"), scope: .global, condition: .upsert)
    _ = try await store.write(
        note("project-fact", description: "Project preference."),
        scope: .project(projectID),
        condition: .upsert)

    #expect(try await store.summaries(in: .global).map(\.name) == ["global-fact"])
    #expect(
        try await store.summaries(in: .project(projectID)).map(\.name)
            == ["project-fact"])

    let globalSnapshot = try await store.promptSnapshot(for: MemoryContext())
    #expect(globalSnapshot.entries.map(\.title) == ["global-fact"])
    #expect(globalSnapshot.entries[0].scope == .global)

    let snapshot = try await store.promptSnapshot(for: MemoryContext(projectID: projectID))
    #expect(snapshot.entries.map(\.title) == ["project-fact"])
    #expect(snapshot.entries[0].scope == .project(projectID))
    #expect(store.directoryURL(for: .project(projectID)).lastPathComponent == projectID.uuidString)
    #expect(store.capabilities.contains(.promptSnapshot))
    #expect(store.capabilities.contains(.delete))
    #expect(!store.capabilities.contains(.backendTools))
}

@Test func namesAreStrictSafeSlugsAndMemoryIsReserved() async throws {
    let paths = try temporaryMemoryRoot("names")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let store = WikiMemoryStore(root: paths.root)
    let invalid = [
        "", "memory", "MEMORY", ".hidden", "trailing-", "-leading", "two--/parts",
        "../outside", "/absolute", "Uppercase", "with space", "under_score",
        String(repeating: "a", count: 65),
    ]

    for name in invalid {
        await expectFailure("Expected invalid name \(name) to fail") {
            try await store.write(note(name), scope: .global, condition: .upsert)
        }
    }
    #expect(!FileManager.default.fileExists(atPath: paths.root.path))
}

@Test func conditionalWritesAndDeletesRejectStaleBrowserRevisions() async throws {
    let paths = try temporaryMemoryRoot("revisions")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let store = WikiMemoryStore(root: paths.root)
    let first = try await store.write(note(), scope: .global, condition: .ifAbsent)

    await expectFailure {
        try await store.write(note(), scope: .global, condition: .ifAbsent)
    }
    let second = try await store.write(
        note(body: "The dog's name is Pickle."),
        scope: .global,
        condition: .ifRevision(first.revision))
    #expect(second.revision != first.revision)

    await expectFailure {
        try await store.write(
            note(body: "Stale overwrite."),
            scope: .global,
            condition: .ifRevision(first.revision))
    }
    await expectFailure {
        try await store.delete("dog-name", scope: .global, ifRevision: first.revision)
    }
    #expect(try await store.delete("dog-name", scope: .global, ifRevision: second.revision))
    #expect(try await store.read("dog-name", scope: .global) == nil)
    #expect(!(try await store.delete("dog-name", scope: .global, ifRevision: nil)))
}

@Test func missingAndRecognizedStaleIndexesAreRebuiltAtomically() async throws {
    let paths = try temporaryMemoryRoot("index-repair")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let store = WikiMemoryStore(root: paths.root)
    _ = try await store.write(note("alpha"), scope: .global, condition: .upsert)
    _ = try await store.write(note("beta"), scope: .global, condition: .upsert)
    let indexURL = globalFolder(paths.root).appendingPathComponent("MEMORY.md")

    try FileManager.default.removeItem(at: indexURL)
    #expect(try await store.summaries(in: .global).count == 2)
    #expect(FileManager.default.fileExists(atPath: indexURL.path))

    let stale = WikiMemoryCodec.indexHeader + "- [[old-note]]: An old generated entry.\n"
    try Data(stale.utf8).write(to: indexURL)
    #expect(try await store.summaries(in: .global).count == 2)
    let repaired = try String(contentsOf: indexURL, encoding: .utf8)
    #expect(!repaired.contains("old-note"))
    #expect(repaired.contains("[[alpha]]"))
    #expect(repaired.contains("[[beta]]"))
}

@Test func summaryAndIndexOrderUseModificationTimeThenName() async throws {
    let paths = try temporaryMemoryRoot("order")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let store = WikiMemoryStore(root: paths.root)
    _ = try await store.write(note("alpha"), scope: .global, condition: .upsert)
    _ = try await store.write(note("beta"), scope: .global, condition: .upsert)
    let folder = globalFolder(paths.root)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 100)],
        ofItemAtPath: folder.appendingPathComponent("alpha.md").path)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 200)],
        ofItemAtPath: folder.appendingPathComponent("beta.md").path)

    #expect(try await store.summaries(in: .global).map(\.name) == ["beta", "alpha"])
    let index = try String(
        contentsOf: folder.appendingPathComponent("MEMORY.md"), encoding: .utf8)
    #expect(try #require(index.range(of: "[[beta]]")).lowerBound < #require(index.range(of: "[[alpha]]")).lowerBound)
}

@Test func arbitraryOrMalformedGeneratedIndexesFailClosedUntouched() async throws {
    let malformedValues = [
        "arbitrary user text\n",
        WikiMemoryCodec.indexHeader + "- [[dog-name]]: \n",
        WikiMemoryCodec.indexHeader + "- [[dog-name]]: valid\nnot-an-entry\n",
        WikiMemoryCodec.indexHeader + "- [[dog-name]]: valid\n\n",
        WikiMemoryCodec.indexHeader + "- [[dog-name]]: missing final newline",
        WikiMemoryCodec.indexHeader + "- [[dog-name]]: valid\n- [[dog-name]]: duplicate\n",
    ]
    for (offset, value) in malformedValues.enumerated() {
        let paths = try temporaryMemoryRoot("bad-index-\(offset)")
        defer { try? FileManager.default.removeItem(at: paths.parent) }
        let store = WikiMemoryStore(root: paths.root)
        _ = try await store.write(note(), scope: .global, condition: .upsert)
        let indexURL = globalFolder(paths.root).appendingPathComponent("MEMORY.md")
        let original = Data(value.utf8)
        try original.write(to: indexURL)

        await expectFailure { try await store.summaries(in: .global) }
        #expect(try Data(contentsOf: indexURL) == original)
        await expectFailure {
            try await store.write(note(body: "Must not overwrite recovery evidence."), scope: .global)
        }
        #expect(try Data(contentsOf: indexURL) == original)
    }
}

@Test func malformedNotesBlockTheWholeScopeWithoutRecoveryWrites() async throws {
    let malformed: [(String, Data)] = [
        (
            "wrong-name.md",
            Data("---\nname: \"other\"\ndescription: \"Mismatch\"\n---\n\nBody.\n".utf8)
        ),
        (
            "duplicate.md",
            Data(
                "---\nname: \"duplicate\"\ndescription: \"One\"\ndescription: \"Two\"\n---\n\nBody.\n".utf8)
        ),
        ("invalid-utf8.md", Data([0xff, 0xfe, 0xfd])),
    ]

    for (offset, item) in malformed.enumerated() {
        let paths = try temporaryMemoryRoot("bad-note-\(offset)")
        defer { try? FileManager.default.removeItem(at: paths.parent) }
        let folder = globalFolder(paths.root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(item.0)
        try item.1.write(to: file)
        let store = WikiMemoryStore(root: paths.root)

        await expectFailure { try await store.summaries(in: .global) }
        #expect(try Data(contentsOf: file) == item.1)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("MEMORY.md").path))
    }
}

@Test func symlinksAndSpecialFilesAreRejectedWithoutTouchingTargets() async throws {
    let paths = try temporaryMemoryRoot("unsafe-files")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let folder = globalFolder(paths.root)
    let outside = paths.parent.appendingPathComponent("outside.md")
    let outsideData = Data("outside recovery evidence".utf8)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try outsideData.write(to: outside)
    try FileManager.default.createSymbolicLink(
        at: folder.appendingPathComponent("linked.md"), withDestinationURL: outside)
    let store = WikiMemoryStore(root: paths.root)

    await expectFailure { try await store.summaries(in: .global) }
    #expect(try Data(contentsOf: outside) == outsideData)

    try FileManager.default.removeItem(at: folder.appendingPathComponent("linked.md"))
    let fifo = folder.appendingPathComponent("pipe.md")
    #expect(Darwin.mkfifo(fifo.path, mode_t(0o600)) == 0)
    await expectFailure { try await store.summaries(in: .global) }
    #expect(try Data(contentsOf: outside) == outsideData)
}

@Test func symlinkedRootAndIndexFailClosed() async throws {
    let paths = try temporaryMemoryRoot("unsafe-root")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let outsideRoot = paths.parent.appendingPathComponent("outside-root", isDirectory: true)
    try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: paths.root, withDestinationURL: outsideRoot)
    let linkedStore = WikiMemoryStore(root: paths.root)
    await expectFailure { try await linkedStore.summaries(in: .global) }
    await expectFailure { try await linkedStore.write(note(), scope: .global) }

    try FileManager.default.removeItem(at: paths.root)
    let store = WikiMemoryStore(root: paths.root)
    _ = try await store.write(note(), scope: .global)
    let folder = globalFolder(paths.root)
    let index = folder.appendingPathComponent("MEMORY.md")
    let outside = paths.parent.appendingPathComponent("outside-index")
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.removeItem(at: index)
    try FileManager.default.createSymbolicLink(at: index, withDestinationURL: outside)

    await expectFailure { try await store.summaries(in: .global) }
    #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
}

@Test func createdMemoryAuthorityUsesOwnerOnlyPermissions() async throws {
    let paths = try temporaryMemoryRoot("permissions")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let store = WikiMemoryStore(root: paths.root)
    let projectID = UUID()
    _ = try await store.write(note("global-note"), scope: .global)
    _ = try await store.write(note("project-note"), scope: .project(projectID))

    let expectedDirectories = [
        paths.root,
        globalFolder(paths.root),
        paths.root.appendingPathComponent("projects", isDirectory: true),
        store.directoryURL(for: .project(projectID)),
    ]
    for directory in expectedDirectories {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
    let expectedFiles = [
        paths.root.appendingPathComponent(".goat-memory.lock"),
        globalFolder(paths.root).appendingPathComponent("global-note.md"),
        globalFolder(paths.root).appendingPathComponent("MEMORY.md"),
        store.directoryURL(for: .project(projectID)).appendingPathComponent("project-note.md"),
        store.directoryURL(for: .project(projectID)).appendingPathComponent("MEMORY.md"),
    ]
    for file in expectedFiles {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}

@Test func writableMemoryAuthoritiesAndLockSymlinksFailClosed() async throws {
    let paths = try temporaryMemoryRoot("authority-modes")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let store = WikiMemoryStore(root: paths.root)
    _ = try await store.write(note(), scope: .global)

    try FileManager.default.setAttributes(
        [.posixPermissions: 0o770],
        ofItemAtPath: paths.root.path)
    do {
        _ = try await store.summaries(in: .global)
        Issue.record("A group-writable memory root unexpectedly opened")
    } catch let error as LocalStoreError {
        guard case .unsafePath = error else {
            Issue.record("Expected unsafePath, got \(error)")
            return
        }
    }
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: paths.root.path)

    let folder = globalFolder(paths.root)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o707],
        ofItemAtPath: folder.path)
    await expectFailure("A world-writable scope unexpectedly opened") {
        try await store.summaries(in: .global)
    }
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: folder.path)

    let noteURL = folder.appendingPathComponent("dog-name.md")
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o660],
        ofItemAtPath: noteURL.path)
    await expectFailure("A group-writable note unexpectedly opened") {
        try await store.summaries(in: .global)
    }

    let lockPaths = try temporaryMemoryRoot("lock-link")
    defer { try? FileManager.default.removeItem(at: lockPaths.parent) }
    try FileManager.default.createDirectory(at: lockPaths.root, withIntermediateDirectories: true)
    let outside = lockPaths.parent.appendingPathComponent("outside-lock")
    let outsideData = Data("must remain untouched".utf8)
    try outsideData.write(to: outside)
    try FileManager.default.createSymbolicLink(
        at: lockPaths.root.appendingPathComponent(".goat-memory.lock"),
        withDestinationURL: outside)
    let linkedLockStore = WikiMemoryStore(root: lockPaths.root)
    await expectFailure("A symlinked writer lock unexpectedly opened") {
        try await linkedLockStore.write(note(), scope: .global)
    }
    #expect(try Data(contentsOf: outside) == outsideData)
    #expect(!FileManager.default.fileExists(atPath: globalFolder(lockPaths.root).path))

    let fifoPaths = try temporaryMemoryRoot("lock-fifo")
    defer { try? FileManager.default.removeItem(at: fifoPaths.parent) }
    try FileManager.default.createDirectory(at: fifoPaths.root, withIntermediateDirectories: true)
    #expect(
        Darwin.mkfifo(
            fifoPaths.root.appendingPathComponent(".goat-memory.lock").path,
            mode_t(0o600)) == 0)
    await expectFailure("A FIFO writer lock unexpectedly opened") {
        try await WikiMemoryStore(root: fifoPaths.root).write(note(), scope: .global)
    }
    #expect(!FileManager.default.fileExists(atPath: globalFolder(fifoPaths.root).path))
}

@Test func oversizedNotesAndIndexesAreRejectedWithoutAllocationOrReplacement() async throws {
    let paths = try temporaryMemoryRoot("oversized")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let folder = globalFolder(paths.root)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let oversizedNote = folder.appendingPathComponent("large.md")
    FileManager.default.createFile(atPath: oversizedNote.path, contents: Data())
    let noteHandle = try FileHandle(forWritingTo: oversizedNote)
    try noteHandle.truncate(atOffset: UInt64(WikiMemoryStore.maximumNoteBytes + 1))
    try noteHandle.close()
    let store = WikiMemoryStore(root: paths.root)
    await expectFailure { try await store.summaries(in: .global) }

    try FileManager.default.removeItem(at: oversizedNote)
    let oversizedIndex = folder.appendingPathComponent("MEMORY.md")
    FileManager.default.createFile(atPath: oversizedIndex.path, contents: Data())
    let indexHandle = try FileHandle(forWritingTo: oversizedIndex)
    try indexHandle.truncate(atOffset: UInt64(WikiMemoryStore.maximumIndexBytes + 1))
    try indexHandle.close()
    await expectFailure { try await store.summaries(in: .global) }
    let attributes = try FileManager.default.attributesOfItem(atPath: oversizedIndex.path)
    #expect((attributes[.size] as? NSNumber)?.intValue == WikiMemoryStore.maximumIndexBytes + 1)
}

@Test func unexpectedFilesBlockMutationAndLeaveVisibleStateUntouched() async throws {
    let paths = try temporaryMemoryRoot("unexpected")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let store = WikiMemoryStore(root: paths.root)
    _ = try await store.write(note(), scope: .global)
    let folder = globalFolder(paths.root)
    let noteURL = folder.appendingPathComponent("dog-name.md")
    let indexURL = folder.appendingPathComponent("MEMORY.md")
    let oldNote = try Data(contentsOf: noteURL)
    let oldIndex = try Data(contentsOf: indexURL)
    try Data("unexpected".utf8).write(to: folder.appendingPathComponent("notes.txt"))

    await expectFailure {
        try await store.write(note(body: "Replacement must not land."), scope: .global)
    }
    #expect(try Data(contentsOf: noteURL) == oldNote)
    #expect(try Data(contentsOf: indexURL) == oldIndex)
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: paths.root.path)
            .allSatisfy { !$0.hasPrefix(".goat-memory-stage-") })
}

@Test func actorSerializesConcurrentWritesWithoutLosingIndexEntries() async throws {
    let paths = try temporaryMemoryRoot("concurrent")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let store = WikiMemoryStore(root: paths.root)

    async let first = store.write(note("alpha"), scope: .global, condition: .upsert)
    async let second = store.write(note("beta"), scope: .global, condition: .upsert)
    _ = try await (first, second)

    #expect(Set(try await store.summaries(in: .global).map(\.name)) == ["alpha", "beta"])
    let index = try String(
        contentsOf: globalFolder(paths.root).appendingPathComponent("MEMORY.md"),
        encoding: .utf8)
    #expect(index.contains("[[alpha]]"))
    #expect(index.contains("[[beta]]"))
}

@Test func ancestorSymlinksFailWithTypedUnsafePathErrors() async throws {
    let paths = try temporaryMemoryRoot("ancestor-link")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let outside = paths.parent.appendingPathComponent("outside", isDirectory: true)
    let linked = paths.parent.appendingPathComponent("linked", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
    let store = WikiMemoryStore(
        root: linked.appendingPathComponent("memory", isDirectory: true))

    do {
        _ = try await store.summaries(in: .global)
        Issue.record("A symlinked ancestor unexpectedly opened")
    } catch let error as LocalStoreError {
        guard case .unsafePath = error else {
            Issue.record("Expected unsafePath, got \(error)")
            return
        }
    }
    do {
        _ = try await store.write(note(), scope: .global)
        Issue.record("A write through a symlinked ancestor unexpectedly succeeded")
    } catch let error as LocalStoreError {
        guard case .unsafePath = error else {
            Issue.record("Expected unsafePath, got \(error)")
            return
        }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
}

@Test func entryEnumerationStopsAtTheHardCapWithTypedCapacityError() async throws {
    let paths = try temporaryMemoryRoot("entry-cap")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let folder = globalFolder(paths.root)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for index in 0...(WikiMemoryStore.maximumNotesPerScope + 2) {
        _ = FileManager.default.createFile(
            atPath: folder.appendingPathComponent("entry-\(index)").path,
            contents: Data())
    }
    let store = WikiMemoryStore(root: paths.root)

    do {
        _ = try await store.summaries(in: .global)
        Issue.record("An over-cap directory unexpectedly scanned")
    } catch let error as MemoryStoreError {
        guard case .capacityExceeded = error else {
            Issue.record("Expected capacityExceeded, got \(error)")
            return
        }
    }
}

@Test func invalidUTF8DirectoryEntryBytesFailClosed() throws {
    do {
        _ = try SecureWikiFileSystem.decodeDirectoryEntryName(
            [102, 0xff, 0],
            path: "/memory/global")
        Issue.record("Invalid UTF-8 directory entry bytes unexpectedly decoded")
    } catch let error as LocalStoreError {
        guard case .unsafePath = error else {
            Issue.record("Expected unsafePath, got \(error)")
            return
        }
    }
    #expect(
        try SecureWikiFileSystem.decodeDirectoryEntryName(
            [102, 105, 108, 101, 0, 120],
            path: "/memory/global") == "file")
}

@Test func noncooperatingExternalEditWinsBeforeExchangeWithoutDataLoss() async throws {
    let paths = try temporaryMemoryRoot("external-race")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let initialStore = WikiMemoryStore(root: paths.root)
    _ = try await initialStore.write(note(body: "Initial body."), scope: .global)

    let reached = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    let racingStore = WikiMemoryStore(
        root: paths.root,
        testingHooks: WikiMemoryStoreTestingHooks(beforePublish: {
            reached.signal()
            proceed.wait()
        }))
    let racingWrite = Task {
        try await racingStore.write(note(body: "Racing body."), scope: .global)
    }
    guard await waitForSemaphore(reached) else {
        proceed.signal()
        Issue.record("Racing store did not reach publication")
        _ = try? await racingWrite.value
        return
    }
    var released = false
    defer {
        if !released { proceed.signal() }
    }

    let noteURL = globalFolder(paths.root).appendingPathComponent("dog-name.md")
    let external = try WikiMemoryCodec.encode(
        note(body: "Winning external body."),
        path: noteURL.path)
    try external.write(to: noteURL, options: .atomic)
    proceed.signal()
    released = true
    do {
        _ = try await racingWrite.value
        Issue.record("The stale racing write unexpectedly committed")
    } catch let error as MemoryStoreError {
        guard case .conflict = error else {
            Issue.record("Expected conflict, got \(error)")
            return
        }
    }

    let visible = try #require(try await initialStore.read("dog-name", scope: .global))
    #expect(visible.note.body == "Winning external body.")
    let recovery = try FileManager.default.contentsOfDirectory(atPath: paths.root.path)
        .filter { $0.hasPrefix(".goat-memory-stage-") }
    #expect(recovery.isEmpty)
}

@Test func mtimeOnlyExternalEditIsPartOfTheExchangeFingerprint() async throws {
    let paths = try temporaryMemoryRoot("mtime-race")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let initialStore = WikiMemoryStore(root: paths.root)
    _ = try await initialStore.write(note(body: "Initial body."), scope: .global)

    let reached = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    let racingStore = WikiMemoryStore(
        root: paths.root,
        testingHooks: WikiMemoryStoreTestingHooks(beforePublish: {
            reached.signal()
            proceed.wait()
        }))
    let racingWrite = Task {
        try await racingStore.write(note(body: "Replacement body."), scope: .global)
    }
    guard await waitForSemaphore(reached) else {
        proceed.signal()
        Issue.record("Racing store did not reach publication")
        _ = try? await racingWrite.value
        return
    }
    let externalDate = Date(timeIntervalSince1970: 1_700_000_000)
    let noteURL = globalFolder(paths.root).appendingPathComponent("dog-name.md")
    try FileManager.default.setAttributes(
        [.modificationDate: externalDate],
        ofItemAtPath: noteURL.path)
    proceed.signal()

    do {
        _ = try await racingWrite.value
        Issue.record("An mtime-stale write unexpectedly committed")
    } catch let error as MemoryStoreError {
        guard case .conflict = error else {
            Issue.record("Expected conflict, got \(error)")
            return
        }
    }
    let visible = try #require(try await initialStore.read("dog-name", scope: .global))
    #expect(visible.note.body == "Initial body.")
    #expect(abs(visible.modifiedAt.timeIntervalSince(externalDate)) < 0.001)
}

@Test func conditionalIndexRepairLosesNoConcurrentWrite() async throws {
    let paths = try temporaryMemoryRoot("repair-race")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let initialStore = WikiMemoryStore(root: paths.root)
    _ = try await initialStore.write(note("alpha"), scope: .global)
    let indexURL = globalFolder(paths.root).appendingPathComponent("MEMORY.md")
    try FileManager.default.removeItem(at: indexURL)

    let reached = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    let repairStore = WikiMemoryStore(
        root: paths.root,
        testingHooks: WikiMemoryStoreTestingHooks(beforePublish: {
            reached.signal()
            proceed.wait()
        }))
    let repair = Task {
        try await repairStore.summaries(in: .global)
    }
    guard await waitForSemaphore(reached) else {
        proceed.signal()
        Issue.record("Repair did not reach publication")
        _ = try? await repair.value
        return
    }
    let betaURL = globalFolder(paths.root).appendingPathComponent("beta.md")
    let betaData = try WikiMemoryCodec.encode(note("beta"), path: betaURL.path)
    try betaData.write(to: betaURL, options: .withoutOverwriting)
    proceed.signal()

    do {
        _ = try await repair.value
        Issue.record("A stale repair unexpectedly replaced a newer scope")
    } catch let error as MemoryStoreError {
        guard case .conflict = error else {
            Issue.record("Expected conflict, got \(error)")
            return
        }
    }
    #expect(Set(try await initialStore.summaries(in: .global).map(\.name)) == ["alpha", "beta"])
    let index = try String(contentsOf: indexURL, encoding: .utf8)
    #expect(index.contains("[[alpha]]"))
    #expect(index.contains("[[beta]]"))
}

@Test func projectParentSwapCannotPublishIntoDetachedProjectsDirectory() async throws {
    let paths = try temporaryMemoryRoot("project-parent-race")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let projectID = UUID()
    let initialStore = WikiMemoryStore(root: paths.root)
    _ = try await initialStore.write(
        note(body: "Original project body."),
        scope: .project(projectID))

    let reached = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    let racingStore = WikiMemoryStore(
        root: paths.root,
        testingHooks: WikiMemoryStoreTestingHooks(beforePublish: {
            reached.signal()
            proceed.wait()
        }))
    let racingWrite = Task {
        try await racingStore.write(
            note(body: "Must not land in a detached directory."),
            scope: .project(projectID))
    }
    guard await waitForSemaphore(reached) else {
        proceed.signal()
        Issue.record("Project write did not reach publication")
        _ = try? await racingWrite.value
        return
    }

    let projects = paths.root.appendingPathComponent("projects", isDirectory: true)
    let movedProjects = paths.root.appendingPathComponent("projects-moved", isDirectory: true)
    try FileManager.default.moveItem(at: projects, to: movedProjects)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: false)
    proceed.signal()

    do {
        _ = try await racingWrite.value
        Issue.record("A detached project-parent write unexpectedly succeeded")
    } catch let error as MemoryStoreError {
        guard case .conflict = error else {
            Issue.record("Expected conflict, got \(error)")
            return
        }
    }
    let movedNote = movedProjects.appendingPathComponent(projectID.uuidString, isDirectory: true)
        .appendingPathComponent("dog-name.md")
    let source = try String(contentsOf: movedNote, encoding: .utf8)
    #expect(source.contains("Original project body."))
    #expect(!source.contains("Must not land"))
}

@Test func firstScopePublicationIsExclusiveAgainstAnExternalCreator() async throws {
    let paths = try temporaryMemoryRoot("exclusive-new")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let reached = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    let store = WikiMemoryStore(
        root: paths.root,
        testingHooks: WikiMemoryStoreTestingHooks(beforePublish: {
            reached.signal()
            proceed.wait()
        }))
    let write = Task { try await store.write(note("alpha"), scope: .global) }
    guard await waitForSemaphore(reached) else {
        proceed.signal()
        Issue.record("The first writer did not reach exclusive publication")
        _ = try? await write.value
        return
    }

    let folder = globalFolder(paths.root)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let externalNote = note("external", description: "External note.", body: "External body.")
    let externalURL = folder.appendingPathComponent("external.md")
    try WikiMemoryCodec.encode(externalNote, path: externalURL.path).write(to: externalURL)
    let index = WikiMemoryCodec.indexHeader + "- [[external]]: External note.\n"
    try Data(index.utf8).write(to: folder.appendingPathComponent("MEMORY.md"))
    proceed.signal()

    do {
        _ = try await write.value
        Issue.record("Exclusive publication overwrote an externally created scope")
    } catch let error as MemoryStoreError {
        guard case .conflict = error else {
            Issue.record("Expected conflict, got \(error)")
            return
        }
    }
    let visible = try #require(
        try await WikiMemoryStore(root: paths.root).read("external", scope: .global))
    #expect(visible.note == externalNote)
}

@Test func writerLockSerializesStoresAcrossTheAfterExchangeWindow() async throws {
    let paths = try temporaryMemoryRoot("after-exchange-lock")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let initialStore = WikiMemoryStore(root: paths.root)
    _ = try await initialStore.write(note(body: "Initial body."), scope: .global)

    let exchanged = DispatchSemaphore(value: 0)
    let finishFirst = DispatchSemaphore(value: 0)
    let secondReachedPublish = DispatchSemaphore(value: 0)
    let firstStore = WikiMemoryStore(
        root: paths.root,
        testingHooks: WikiMemoryStoreTestingHooks(afterExchange: {
            exchanged.signal()
            finishFirst.wait()
        }))
    let secondStore = WikiMemoryStore(
        root: paths.root,
        testingHooks: WikiMemoryStoreTestingHooks(beforePublish: {
            secondReachedPublish.signal()
        }))
    let first = Task {
        try await firstStore.write(note(body: "First committed body."), scope: .global)
    }
    guard await waitForSemaphore(exchanged) else {
        finishFirst.signal()
        Issue.record("The first store did not reach its post-exchange window")
        _ = try? await first.value
        return
    }
    let second = Task {
        try await secondStore.write(note(body: "Second committed body."), scope: .global)
    }
    #expect(!(await waitForSemaphore(secondReachedPublish, timeout: 0.2)))
    finishFirst.signal()
    _ = try await first.value
    #expect(await waitForSemaphore(secondReachedPublish))
    _ = try await second.value

    let visible = try #require(try await initialStore.read("dog-name", scope: .global))
    #expect(visible.note.body == "Second committed body.")
}

@Test func changedCapturedBackupIsRetainedAfterTheDurableCommit() async throws {
    let paths = try temporaryMemoryRoot("cleanup-race")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let initialStore = WikiMemoryStore(root: paths.root)
    _ = try await initialStore.write(note(body: "Old durable body."), scope: .global)
    let store = WikiMemoryStore(
        root: paths.root,
        testingHooks: WikiMemoryStoreTestingHooks(beforeBackupCleanup: {
            guard
                let recoveryName = try? FileManager.default
                    .contentsOfDirectory(atPath: paths.root.path)
                    .first(where: { $0.hasPrefix(".goat-memory-stage-") })
            else { return }
            let noteURL = paths.root.appendingPathComponent(recoveryName, isDirectory: true)
                .appendingPathComponent("dog-name.md")
            try? Data("Externally changed recovery evidence.".utf8).write(
                to: noteURL,
                options: .atomic)
        }))

    _ = try await store.write(note(body: "New durable body."), scope: .global)

    let visible = try #require(try await initialStore.read("dog-name", scope: .global))
    #expect(visible.note.body == "New durable body.")
    let recoveries = try FileManager.default.contentsOfDirectory(
        at: paths.root,
        includingPropertiesForKeys: nil
    )
    .filter { $0.lastPathComponent.hasPrefix(".goat-memory-stage-") }
    let recovery = try #require(recoveries.first)
    #expect(
        try String(
            contentsOf: recovery.appendingPathComponent("dog-name.md"),
            encoding: .utf8) == "Externally changed recovery evidence.")
}

@Test func externallyChangedPrepublicationStageIsRetainedUntouched() async throws {
    let paths = try temporaryMemoryRoot("staging-injection")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let initialStore = WikiMemoryStore(root: paths.root)
    _ = try await initialStore.write(note(body: "Original visible body."), scope: .global)
    let injected = Data("Externally injected recovery evidence.".utf8)
    let store = WikiMemoryStore(
        root: paths.root,
        testingHooks: WikiMemoryStoreTestingHooks(beforePublish: {
            guard
                let stagingName = try? FileManager.default
                    .contentsOfDirectory(atPath: paths.root.path)
                    .first(where: { $0.hasPrefix(".goat-memory-stage-") })
            else { return }
            let injectedURL = paths.root.appendingPathComponent(stagingName, isDirectory: true)
                .appendingPathComponent("external.txt")
            try? injected.write(to: injectedURL, options: .withoutOverwriting)
        }))

    await expectFailure("A changed staging tree unexpectedly published") {
        try await store.write(note(body: "Must not become visible."), scope: .global)
    }

    let visible = try #require(try await initialStore.read("dog-name", scope: .global))
    #expect(visible.note.body == "Original visible body.")
    let recoveries = try FileManager.default.contentsOfDirectory(
        at: paths.root,
        includingPropertiesForKeys: nil
    )
    .filter { $0.lastPathComponent.hasPrefix(".goat-memory-stage-") }
    let recovery = try #require(recoveries.first)
    #expect(try Data(contentsOf: recovery.appendingPathComponent("external.txt")) == injected)
}

@Test func simulatedExchangeInterruptionRetainsCapturedBackup() async throws {
    let paths = try temporaryMemoryRoot("exchange-interruption")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let initialStore = WikiMemoryStore(root: paths.root)
    _ = try await initialStore.write(note(body: "Old durable body."), scope: .global)
    let interrupted = WikiMemoryStore(
        root: paths.root,
        testingHooks: WikiMemoryStoreTestingHooks(interruptAfterExchange: true))

    do {
        _ = try await interrupted.write(note(body: "New exchanged body."), scope: .global)
        Issue.record("The simulated interruption unexpectedly returned success")
    } catch WikiMemoryStoreTestingInterruption.afterExchange {
    } catch {
        Issue.record("Expected the testing interruption, got \(error)")
    }

    let visible = try #require(try await initialStore.read("dog-name", scope: .global))
    #expect(visible.note.body == "New exchanged body.")
    let backups = try FileManager.default.contentsOfDirectory(
        at: paths.root,
        includingPropertiesForKeys: nil
    )
    .filter { $0.lastPathComponent.hasPrefix(".goat-memory-stage-") }
    let backup = try #require(backups.first)
    let oldSource = try String(
        contentsOf: backup.appendingPathComponent("dog-name.md"),
        encoding: .utf8)
    #expect(oldSource.contains("Old durable body."))
}

@Test func copiedNotesPreserveBytesModeAndNanosecondMtime() async throws {
    let paths = try temporaryMemoryRoot("copy-metadata")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let store = WikiMemoryStore(root: paths.root)
    _ = try await store.write(note("alpha", body: "Unchanged bytes."), scope: .global)
    _ = try await store.write(note("beta"), scope: .global)
    let alpha = globalFolder(paths.root).appendingPathComponent("alpha.md")
    let fixedDate = Date(timeIntervalSince1970: 1_700_000_000.123_456)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600, .modificationDate: fixedDate],
        ofItemAtPath: alpha.path)
    let before = try Data(contentsOf: alpha)

    _ = try await store.write(note("beta", body: "Changed beta."), scope: .global)

    #expect(try Data(contentsOf: alpha) == before)
    let attributes = try FileManager.default.attributesOfItem(atPath: alpha.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let afterDate = try #require(attributes[.modificationDate] as? Date)
    #expect(abs(afterDate.timeIntervalSince(fixedDate)) < 0.000_001)
}

@Test func replacedNotesAndRegeneratedIndexesPreserveSafeExistingModes() async throws {
    let paths = try temporaryMemoryRoot("replacement-modes")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let store = WikiMemoryStore(root: paths.root)
    _ = try await store.write(note("alpha"), scope: .global)
    _ = try await store.write(note("beta"), scope: .global)
    let folder = globalFolder(paths.root)
    let alpha = folder.appendingPathComponent("alpha.md")
    let index = folder.appendingPathComponent("MEMORY.md")
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o640],
        ofItemAtPath: alpha.path)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o640],
        ofItemAtPath: index.path)

    _ = try await store.write(note("alpha", body: "Replacement body."), scope: .global)
    _ = try await store.write(note("new-note"), scope: .global)

    let alphaMode =
        try FileManager.default.attributesOfItem(atPath: alpha.path)[.posixPermissions]
        as? NSNumber
    let indexMode =
        try FileManager.default.attributesOfItem(atPath: index.path)[.posixPermissions]
        as? NSNumber
    let newMode =
        try FileManager.default.attributesOfItem(
            atPath: folder.appendingPathComponent("new-note.md").path)[.posixPermissions] as? NSNumber
    #expect(alphaMode?.intValue == 0o640)
    #expect(indexMode?.intValue == 0o640)
    #expect(newMode?.intValue == 0o600)
}

@Test func carriageReturnsAreRejectedWithoutRecoveryWrites() async throws {
    let paths = try temporaryMemoryRoot("carriage-return")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let store = WikiMemoryStore(root: paths.root)

    do {
        _ = try await store.write(
            note(body: "First line.\r\nSecond line."),
            scope: .global)
        Issue.record("A CRLF body unexpectedly encoded")
    } catch let error as MemoryStoreError {
        guard case .invalidNote = error else {
            Issue.record("Expected invalidNote, got \(error)")
            return
        }
    }
    #expect(!FileManager.default.fileExists(atPath: paths.root.path))

    let folder = globalFolder(paths.root)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let noteURL = folder.appendingPathComponent("manual.md")
    let raw = Data(
        "---\r\nname: \"manual\"\r\ndescription: \"Manual\"\r\n---\r\n\r\nBody.\r\n".utf8)
    try raw.write(to: noteURL)
    do {
        _ = try await store.summaries(in: .global)
        Issue.record("A manual CRLF note unexpectedly decoded")
    } catch let error as MemoryStoreError {
        guard case .invalidNote = error else {
            Issue.record("Expected invalidNote, got \(error)")
            return
        }
    }
    #expect(try Data(contentsOf: noteURL) == raw)
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("MEMORY.md").path))
}

@Test func rememberIsIdempotentAndBrowserIDsRemainOpaque() async throws {
    let paths = try temporaryMemoryRoot("remember-browser")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let store = WikiMemoryStore(root: paths.root)
    let request = MemoryRememberRequest(
        idempotencyKey: UUID(),
        title: "Dog name",
        summary: "The user's dog's name.",
        content: "The dog's name is Peanut.\n\n",
        context: MemoryContext(),
        suggestedName: "dog-name")

    let first = try await store.remember(request)
    let retry = try await store.remember(request)
    #expect(first.status == .stored)
    #expect(first.undoToken != nil)
    #expect(retry.entryID == first.entryID)
    #expect(retry.revision == first.revision)
    #expect(retry.undoToken == nil)
    let id = try #require(first.entryID)
    let document = try await store.browserDocument(id, context: MemoryContext())
    #expect(document.entry.scope == .global)
    #expect(document.entry.canEdit)
    #expect(document.entry.canDelete)
    #expect(document.content == "The dog's name is Peanut.")

    let manual = note(
        "manual-equal",
        description: "An existing manual note.",
        body: "This content was written manually.")
    _ = try await store.write(manual, scope: .global, condition: .ifAbsent)
    let indistinguishable = try await store.remember(
        MemoryRememberRequest(
            idempotencyKey: UUID(),
            title: "Manual note",
            summary: manual.description,
            content: manual.body,
            context: MemoryContext(),
            suggestedName: manual.name))
    #expect(indistinguishable.undoToken == nil)
    #expect(try await store.read(manual.name, scope: .global)?.note == manual)

    let conflicting = MemoryRememberRequest(
        idempotencyKey: UUID(),
        title: "Different",
        summary: "Different summary.",
        content: "Different content.",
        context: MemoryContext(),
        suggestedName: "dog-name")
    do {
        _ = try await store.remember(conflicting)
        Issue.record("Remember unexpectedly overwrote a same-name manual note")
    } catch let error as MemoryStoreError {
        guard case .conflict = error else {
            Issue.record("Expected conflict, got \(error)")
            return
        }
    }
    #expect(store.capabilities.contains(.remember))
    #expect(store.capabilities.contains(.edit))
    #expect(!store.capabilities.contains(.backendTools))
}

@Test func llmWikiSeparatesImmutableRawSourcesFromCuratedPromptPages() async throws {
    let paths = try temporaryMemoryRoot("llm-wiki")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let store = LLMWikiMemoryStore(root: paths.root)
    let source = try await store.ingest(
        title: "Dog interview",
        content: "The user's dog is named Peanut.",
        context: MemoryContext(),
        sourceID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    #expect(source.rawValue == "raw:source-11111111-1111-1111-1111-111111111111")
    #expect(try await store.promptSnapshot(for: MemoryContext()).entries.isEmpty)

    _ = try await store.write(
        MemoryNote(
            name: "peanut",
            description: "The user's dog is Peanut.",
            body: "Peanut is the user's dog. [[dog-interview]]"),
        scope: .global,
        condition: .ifAbsent)
    #expect(try await store.promptSnapshot(for: MemoryContext()).entries.map(\.title) == ["peanut"])
    let rawSource = paths.root.appendingPathComponent(
        "raw/source-11111111-1111-1111-1111-111111111111.md")
    #expect(FileManager.default.fileExists(atPath: rawSource.path))
    #expect(FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("wiki/peanut.md").path))
}

@Test func llmWikiExposesRawSourcesWithoutInjectingThemAndLintsCuratedLinks() async throws {
    let paths = try temporaryMemoryRoot("llm-wiki-lint")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let store = LLMWikiMemoryStore(root: paths.root)
    let context = MemoryContext()
    let sourceID = try await store.ingest(
        title: "Dog interview",
        content: "The user's dog is named Peanut.",
        context: context,
        sourceID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)

    let sources = try await store.sourceEntries(for: context)
    #expect(sources.map(\.id) == [sourceID])
    #expect(try await store.sourceDocument(sourceID, context: context).content.contains("Peanut"))
    #expect(try await store.browserEntries(for: context).isEmpty)

    _ = try await store.write(
        MemoryNote(name: "dog", description: "Dog facts.", body: "See [[peanut]]."),
        scope: .global,
        condition: .ifAbsent)
    _ = try await store.write(
        MemoryNote(name: "peanut", description: "Peanut facts.", body: "Peanut is a dog."),
        scope: .global,
        condition: .ifAbsent)
    _ = try await store.write(
        MemoryNote(name: "orphan", description: "Unlinked.", body: "No incoming link."),
        scope: .global,
        condition: .ifAbsent)

    #expect(try await store.query("peanut", context: context).map(\.title) == ["peanut"])
    await expectFailure("empty LLM Wiki query") {
        try await store.query(" ", context: context)
    }

    let lint = try await store.lint(for: context)
    #expect(lint.pageCount == 3)
    #expect(lint.sourceCount == 1)
    #expect(lint.orphanPages == ["dog", "orphan"])
}

@Test func llmWikiGraphMaterialKeepsRawNamesPrivateAndReturnsCuratedBodies() async throws {
    let paths = try temporaryMemoryRoot("llm-wiki-graph-material")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let store = LLMWikiMemoryStore(root: paths.root)
    let context = MemoryContext()
    let sourceID = try #require(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
    _ = try await store.ingest(
        title: "Dog interview",
        content: "The user's dog is Peanut.",
        context: context,
        sourceID: sourceID)
    _ = try await store.write(
        MemoryNote(
            name: "peanut",
            description: "The user's dog is Peanut.",
            body: "Peanut is the user's dog. [[source-33333333-3333-3333-3333-333333333333]]"),
        scope: .global,
        condition: .ifAbsent)

    let material = try await store.graphMaterial(for: context)

    #expect(material.pages.map(\.name) == ["peanut"])
    #expect(material.pages.first?.content.contains("Peanut") == true)
    #expect(material.sources.map(\.name) == ["source-33333333-3333-3333-3333-333333333333"])
    #expect(material.sources.map { $0.entry.title } == ["Dog interview"])
}

@Test func llmWikiGraphMaterialBoundsPageBodiesAndDisclosesTruncation() async throws {
    let paths = try temporaryMemoryRoot("llm-wiki-graph-bounds")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let store = LLMWikiMemoryStore(root: paths.root)
    let context = MemoryContext()
    for index in 0...LLMWikiMemoryStore.maximumGraphPages {
        _ = try await store.write(
            MemoryNote(
                name: "page-\(index)",
                description: "Bounded graph page \(index).",
                body: String(repeating: "x", count: 128)),
            scope: .global,
            condition: .ifAbsent)
    }

    let material = try await store.graphMaterial(for: context)

    #expect(material.pages.count == LLMWikiMemoryStore.maximumGraphPages)
    #expect(material.isTruncated)
    #expect(material.pages.allSatisfy { $0.content.utf8.count <= LLMWikiMemoryStore.maximumGraphPageContentBytes })
}

@Test func llmWikiMaterializesAndVerifiesItsRootLifecycleAuthorities() async throws {
    let paths = try temporaryMemoryRoot("llm-wiki-lifecycle")
    defer { try? FileManager.default.removeItem(at: paths.parent) }
    let store = LLMWikiMemoryStore(root: paths.root)
    let context = MemoryContext()
    let sourceID = try #require(UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
    let rawID = try await store.ingest(
        title: "Dog interview",
        content: "The user's dog is named Peanut.",
        context: context,
        sourceID: sourceID)
    _ = try await store.write(
        MemoryNote(
            name: "dog",
            description: "Dog facts.",
            body: "Peanut is a dog. [[peanut]] [[source-44444444-4444-4444-4444-444444444444]]"),
        scope: .global,
        condition: .ifAbsent)
    _ = try await store.write(
        MemoryNote(
            name: "peanut",
            description: "Peanut facts.",
            body: "Peanut is the user's dog. [[dog]] [[source-44444444-4444-4444-4444-444444444444]]"),
        scope: .global,
        condition: .ifAbsent)

    let authorities = ["raw", "wiki", "AGENTS.md", "index.md", "log.md"]
    for authority in authorities {
        #expect(FileManager.default.fileExists(atPath: paths.root.appendingPathComponent(authority).path))
    }
    #expect(try await store.sourceDocument(rawID, context: context).entry.title == "Dog interview")
    #expect(try await store.query("dog", context: context).map(\.title) == ["dog"])

    let healthy = try await store.lint(for: context)
    #expect(healthy.schemaIsValid)
    #expect(healthy.indexIsFresh)
    #expect(healthy.pagesMissingSourceCitations.isEmpty)
    #expect(healthy.uncitedSources.isEmpty)
    #expect(healthy.invalidWikiLinks.isEmpty)
    #expect(healthy.orphanPages.isEmpty)
    let log = try #require(
        String(
            data: Data(contentsOf: paths.root.appendingPathComponent("log.md")), encoding: .utf8))
    #expect(log.contains(" | ingest | raw:source-44444444-4444-4444-4444-444444444444"))
    #expect(log.contains(" | query | pages:1"))
    #expect(log.contains(" | lint | healthy"))

    let indexURL = paths.root.appendingPathComponent("index.md")
    try Data("tampered\n".utf8).write(to: indexURL, options: .atomic)
    let stale = try await store.lint(for: context)
    #expect(!stale.indexIsFresh)
    await expectFailure("stale LLM Wiki index unexpectedly entered prompt memory") {
        try await store.promptSnapshot(for: context)
    }
}

@Test func memoryBrowserEntryDisplayTitleAddsAnEllipsisAtTheSharedLimit() {
    let title = String(repeating: "x", count: MemoryBrowserEntry.maximumDisplayTitleCharacters + 4)

    let display = MemoryBrowserEntry.displayTitle(for: title)

    #expect(display.count == MemoryBrowserEntry.maximumDisplayTitleCharacters)
    #expect(display.hasSuffix("…"))
}
