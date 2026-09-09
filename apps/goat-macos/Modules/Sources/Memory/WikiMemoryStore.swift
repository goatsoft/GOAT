import Foundation
import Herd

struct WikiMemoryStoreTestingHooks: Sendable {
    var beforePublish: (@Sendable () -> Void)?
    var afterExchange: (@Sendable () -> Void)?
    var beforeBackupCleanup: (@Sendable () -> Void)?
    var interruptAfterExchange: Bool

    init(
        beforePublish: (@Sendable () -> Void)? = nil,
        afterExchange: (@Sendable () -> Void)? = nil,
        beforeBackupCleanup: (@Sendable () -> Void)? = nil,
        interruptAfterExchange: Bool = false
    ) {
        self.beforePublish = beforePublish
        self.afterExchange = afterExchange
        self.beforeBackupCleanup = beforeBackupCleanup
        self.interruptAfterExchange = interruptAfterExchange
    }
}

enum WikiMemoryStoreTestingInterruption: Error {
    case afterExchange
}

/// Plain Markdown memory with descriptor-anchored validation and atomic scope publication.
///
/// Every mutation is prepared in a bounded sibling directory and synchronized before one atomic
/// publication. Replacements capture the exact displaced tree, validate it after the exchange,
/// and preserve recovery evidence if another writer won the race. Reads repair only a missing or
/// canonical stale index while holding the same conditional writer lock as ordinary mutations.
public actor WikiMemoryStore: EditableMemoryStore {
    public static let maximumDescriptionBytes = 512
    public static let maximumNoteBytes = 24 * 1_024
    public static let maximumIndexBytes = 1 * 1_024 * 1_024
    public static let maximumNotesPerScope = 1_024

    public nonisolated let capabilities = MemoryStoreCapabilities([
        .promptSnapshot, .browse, .remember, .edit, .delete,
    ])

    private let root: URL
    private let globalDirectoryName: String
    private let fileSystem: SecureWikiFileSystem
    private let testingHooks: WikiMemoryStoreTestingHooks

    public init(root: URL = Home.memoryDir, globalDirectoryName: String = "global") {
        self.root = root
        self.globalDirectoryName = globalDirectoryName
        self.fileSystem = SecureWikiFileSystem(root: root, globalDirectoryName: globalDirectoryName)
        self.testingHooks = WikiMemoryStoreTestingHooks()
    }

    init(root: URL, testingHooks: WikiMemoryStoreTestingHooks) {
        self.root = root
        globalDirectoryName = "global"
        self.fileSystem = SecureWikiFileSystem(root: root)
        self.testingHooks = testingHooks
    }

    public nonisolated func directoryURL(for scope: MemoryScope) -> URL {
        switch scope {
        case .global:
            root.appendingPathComponent(globalDirectoryName, isDirectory: true)
        case .project(let id):
            root.appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(id.uuidString, isDirectory: true)
        }
    }

    public func promptSnapshot(for context: MemoryContext) throws -> MemoryPromptSnapshot {
        var entries: [MemoryPromptEntry] = []
        for scope in context.readableScopes {
            for summary in try summaries(in: scope) {
                entries.append(
                    MemoryPromptEntry(
                        identifier: entryID(for: summary).rawValue,
                        title: summary.name,
                        summary: summary.description,
                        scope: displayScope(for: summary.scope),
                        modifiedAt: summary.modifiedAt))
            }
        }
        return MemoryPromptSnapshot(entries: entries)
    }

    public func browserEntries(for context: MemoryContext) throws -> [MemoryBrowserEntry] {
        try context.readableScopes.flatMap { scope in
            try summaries(in: scope).map { browserEntry($0) }
        }
    }

    public func browserDocument(
        _ id: MemoryEntryID,
        context: MemoryContext
    ) throws -> MemoryBrowserDocument {
        let (scope, name) = try parseEntryID(id)
        guard context.readableScopes.contains(scope) else {
            throw MemoryStoreError.invalidEntryID(id.rawValue)
        }
        guard let stored = try read(name, scope: scope) else {
            throw MemoryStoreError.invalidEntryID(id.rawValue)
        }
        return MemoryBrowserDocument(
            entry: browserEntry(stored.summary),
            content: stored.note.body)
    }

    public func remember(_ request: MemoryRememberRequest) throws -> MemoryRememberReceipt {
        let name =
            request.suggestedName
            ?? "memory-\(request.idempotencyKey.uuidString.lowercased())"
        var content = request.content
        while content.unicodeScalars.last?.value == 10 {
            content.unicodeScalars.removeLast()
        }
        let note = MemoryNote(name: name, description: request.summary, body: content)
        let scope = request.context.defaultWriteScope
        let stored: StoredMemoryNote
        let created: Bool
        do {
            stored = try write(note, scope: scope, condition: .ifAbsent)
            created = true
        } catch let error as MemoryStoreError {
            if case .conflict = error, let existing = try read(name, scope: scope),
                existing.note == note
            {
                stored = existing
                created = false
            } else {
                throw error
            }
        }
        let id = entryID(for: stored.summary)
        return MemoryRememberReceipt(
            status: .stored,
            entryID: id,
            revision: stored.revision,
            undoToken: created
                ? MemoryUndoToken(entryID: id, revision: stored.revision)
                : nil)
    }

    public func summaries(in scope: MemoryScope) throws -> [MemoryNoteSummary] {
        try Task.checkCancellation()
        guard let location = try fileSystem.locate(scope, createParents: false),
            let descriptor = location.scope
        else { return [] }
        return try stateWithCurrentIndex(
            location: location,
            descriptor: descriptor,
            scope: scope
        ).summaries
    }

    public func read(_ name: String, scope: MemoryScope) throws -> StoredMemoryNote? {
        try WikiMemoryCodec.validateName(name)
        try Task.checkCancellation()
        guard let location = try fileSystem.locate(scope, createParents: false),
            let descriptor = location.scope
        else { return nil }
        return try stateWithCurrentIndex(
            location: location,
            descriptor: descriptor,
            scope: scope
        ).notes[name]
    }

    public func write(
        _ note: MemoryNote,
        scope: MemoryScope,
        condition: MemoryWriteCondition = .upsert
    ) throws -> StoredMemoryNote {
        let notePath = directoryURL(for: scope).appendingPathComponent("\(note.name).md").path
        let data = try WikiMemoryCodec.encode(note, path: notePath)
        try Task.checkCancellation()
        guard let initialLocation = try fileSystem.locate(scope, createParents: true) else {
            throw LocalStoreError.operationFailed(
                path: directoryURL(for: scope).path,
                operation: "locate memory scope",
                reason: "memory root could not be opened")
        }
        let writerLock = try fileSystem.acquireWriterLock(
            rootDescriptor: initialLocation.root.rawValue,
            rootIdentity: initialLocation.rootIdentity,
            rootPath: root.path)
        defer { withExtendedLifetime(writerLock) {} }
        guard let location = try fileSystem.locate(scope, createParents: true),
            location.rootIdentity == initialLocation.rootIdentity
        else {
            throw MemoryStoreError.conflict(
                name: note.name,
                reason: "the memory root changed while waiting for the writer lock")
        }
        let original: ScopeState?
        if let descriptor = location.scope {
            original = try scanExistingScope(
                descriptor: descriptor.rawValue,
                path: location.scopePath,
                scope: scope)
        } else {
            original = nil
        }
        try validate(condition, current: original?.notes[note.name], name: note.name)

        let committed = try publish(
            location: location,
            original: original,
            scope: scope,
            mutation: .replace(name: note.name, data: data))
        guard let saved = committed.notes[note.name] else {
            throw LocalStoreError.operationFailed(
                path: notePath,
                operation: "read committed memory note",
                reason: "note was not present after publication")
        }
        return saved
    }

    @discardableResult
    public func delete(
        _ name: String,
        scope: MemoryScope,
        ifRevision revision: MemoryRevision? = nil
    ) throws -> Bool {
        try WikiMemoryCodec.validateName(name)
        try Task.checkCancellation()
        guard let initialLocation = try fileSystem.locate(scope, createParents: false),
            initialLocation.scope != nil
        else { return false }
        let writerLock = try fileSystem.acquireWriterLock(
            rootDescriptor: initialLocation.root.rawValue,
            rootIdentity: initialLocation.rootIdentity,
            rootPath: root.path)
        defer { withExtendedLifetime(writerLock) {} }
        guard let location = try fileSystem.locate(scope, createParents: false),
            location.rootIdentity == initialLocation.rootIdentity,
            let descriptor = location.scope
        else {
            throw MemoryStoreError.conflict(
                name: name,
                reason: "the memory scope changed while waiting for the writer lock")
        }
        let original = try scanExistingScope(
            descriptor: descriptor.rawValue,
            path: location.scopePath,
            scope: scope)
        guard let current = original.notes[name] else { return false }
        if let revision, current.revision != revision {
            throw MemoryStoreError.conflict(name: name, reason: "the expected revision is stale")
        }

        _ = try publish(
            location: location,
            original: original,
            scope: scope,
            mutation: .delete(name: name))
        return true
    }

    // MARK: Scope scanning

    private struct ScopeFingerprint: Equatable {
        let directoryIdentity: WikiDirectoryIdentity
        let directoryMode: mode_t
        let entries: [String: WikiFileFingerprint]
    }

    private struct ScopeState {
        let notes: [String: StoredMemoryNote]
        let summaries: [MemoryNoteSummary]
        let files: [String: WikiFileRecord]
        let indexData: Data?
        let directoryMode: mode_t
        let fingerprint: ScopeFingerprint
    }

    private enum ScopeMutation {
        case replace(name: String, data: Data)
        case delete(name: String)
        case rebuildIndex

        var targetName: String {
            switch self {
            case .replace(let name, _), .delete(let name):
                name
            case .rebuildIndex:
                "MEMORY.md"
            }
        }

        func shouldCopy(_ filename: String) -> Bool {
            if filename == "MEMORY.md" { return false }
            switch self {
            case .replace(let name, _), .delete(let name):
                return filename != "\(name).md"
            case .rebuildIndex:
                return true
            }
        }
    }

    private func stateWithCurrentIndex(
        location: WikiScopeLocation,
        descriptor: WikiOwnedFileDescriptor,
        scope: MemoryScope
    ) throws -> ScopeState {
        let state = try scanExistingScope(
            descriptor: descriptor.rawValue,
            path: location.scopePath,
            scope: scope)
        let expected = try WikiMemoryCodec.indexData(
            for: state.summaries,
            path: URL(fileURLWithPath: location.scopePath)
                .appendingPathComponent("MEMORY.md").path)
        guard state.indexData != expected else { return state }
        let writerLock = try fileSystem.acquireWriterLock(
            rootDescriptor: location.root.rawValue,
            rootIdentity: location.rootIdentity,
            rootPath: root.path)
        defer { withExtendedLifetime(writerLock) {} }
        guard let lockedLocation = try fileSystem.locate(scope, createParents: false),
            lockedLocation.rootIdentity == location.rootIdentity,
            let lockedDescriptor = lockedLocation.scope
        else {
            throw MemoryStoreError.conflict(
                name: "MEMORY.md",
                reason: "the memory scope changed while waiting to rebuild its index")
        }
        let authoritative = try scanExistingScope(
            descriptor: lockedDescriptor.rawValue,
            path: lockedLocation.scopePath,
            scope: scope)
        let authoritativeIndex = try WikiMemoryCodec.indexData(
            for: authoritative.summaries,
            path: URL(fileURLWithPath: lockedLocation.scopePath)
                .appendingPathComponent("MEMORY.md").path)
        guard authoritative.indexData != authoritativeIndex else { return authoritative }
        return try publish(
            location: lockedLocation,
            original: authoritative,
            scope: scope,
            mutation: .rebuildIndex)
    }

    private func scanExistingScope(
        descriptor: Int32,
        path: String,
        scope: MemoryScope
    ) throws -> ScopeState {
        try Task.checkCancellation()
        let directoryBefore = try fileSystem.directoryMetadata(descriptor: descriptor, path: path)
        let names = try fileSystem.entryNames(
            descriptor: descriptor,
            path: path,
            maximumEntries: Self.maximumNotesPerScope + 2)

        var notes: [String: StoredMemoryNote] = [:]
        var files: [String: WikiFileRecord] = [:]
        var indexData: Data?
        for filename in names {
            try Task.checkCancellation()
            let maximumBytes =
                filename == "MEMORY.md" || filename == ".DS_Store"
                ? Self.maximumIndexBytes : Self.maximumNoteBytes
            let record = try fileSystem.readFile(
                directory: descriptor,
                name: filename,
                directoryPath: path,
                maximumBytes: maximumBytes)
            files[filename] = record

            if filename == ".DS_Store" { continue }
            if filename == "MEMORY.md" {
                try WikiMemoryCodec.validateRepairableIndex(
                    record.data,
                    path: URL(fileURLWithPath: path).appendingPathComponent(filename).path)
                indexData = record.data
                continue
            }
            guard filename.hasSuffix(".md") else {
                throw LocalStoreError.unsafePath(
                    path: URL(fileURLWithPath: path).appendingPathComponent(filename).path,
                    reason: "memory scopes may contain only notes and MEMORY.md")
            }
            let name = String(filename.dropLast(3))
            try WikiMemoryCodec.validateName(name)
            let notePath = URL(fileURLWithPath: path).appendingPathComponent(filename).path
            let note = try WikiMemoryCodec.decode(
                record.data,
                expectedName: name,
                path: notePath)
            let stored = StoredMemoryNote(
                note: note,
                scope: scope,
                modifiedAt: record.fingerprint.modificationTime.date,
                revision: MemoryRevision(rawValue: record.fingerprint.contentHash))
            guard notes.updateValue(stored, forKey: name) == nil else {
                throw MemoryStoreError.invalidNote(path: notePath, reason: "duplicate note name")
            }
        }

        guard notes.count <= Self.maximumNotesPerScope else {
            throw MemoryStoreError.capacityExceeded(
                path: path,
                reason: "scope contains more than \(Self.maximumNotesPerScope) notes")
        }
        let directoryAfter = try fileSystem.directoryMetadata(descriptor: descriptor, path: path)
        guard directoryBefore == directoryAfter else {
            throw MemoryStoreError.conflict(
                name: "MEMORY.md",
                reason: "the scope changed while it was being scanned")
        }
        let summaries = notes.values.map(\.summary).sorted(by: Self.summaryOrder)
        return ScopeState(
            notes: notes,
            summaries: summaries,
            files: files,
            indexData: indexData,
            directoryMode: directoryAfter.mode,
            fingerprint: ScopeFingerprint(
                directoryIdentity: directoryAfter.identity,
                directoryMode: directoryAfter.mode,
                entries: files.mapValues(\.fingerprint)))
    }

    // MARK: Mutation publication

    private func publish(
        location: WikiScopeLocation,
        original: ScopeState?,
        scope: MemoryScope,
        mutation: ScopeMutation
    ) throws -> ScopeState {
        let targetName = mutation.targetName
        let staging = try fileSystem.createStagingDirectory(
            parent: location.parentDescriptor,
            parentPath: location.parentPath)
        var removeStagingOnFailure = true
        var stagedEntries: [String: WikiFileFingerprint] = [:]
        defer {
            if removeStagingOnFailure {
                try? fileSystem.removeFlatDirectory(
                    parent: location.parentDescriptor,
                    parentPath: location.parentPath,
                    name: staging.name,
                    maximumEntries: Self.maximumNotesPerScope + 2,
                    expectedIdentity: try fileSystem.directoryMetadata(
                        descriptor: staging.descriptor.rawValue,
                        path: staging.path
                    ).identity,
                    expectedEntries: stagedEntries)
                try? fileSystem.syncDirectory(
                    location.parentDescriptor,
                    path: location.parentPath)
            }
        }

        for (filename, record) in (original?.files ?? [:]).sorted(by: { $0.key < $1.key }) {
            if !mutation.shouldCopy(filename) { continue }
            let copied = try fileSystem.createFile(
                directory: staging.descriptor.rawValue,
                name: filename,
                directoryPath: staging.path,
                data: record.data,
                mode: record.mode,
                preservingModificationTime: record.fingerprint.modificationTime)
            stagedEntries[filename] = copied.fingerprint
        }
        if case .replace(let name, let replacementData) = mutation {
            let filename = "\(name).md"
            let replacement = try fileSystem.createFile(
                directory: staging.descriptor.rawValue,
                name: filename,
                directoryPath: staging.path,
                data: replacementData,
                mode: original?.files[filename]?.mode ?? 0o600)
            stagedEntries[filename] = replacement.fingerprint
        }

        var staged = try scanExistingScope(
            descriptor: staging.descriptor.rawValue,
            path: staging.path,
            scope: scope)
        let index = try WikiMemoryCodec.indexData(
            for: staged.summaries,
            path: URL(fileURLWithPath: staging.path).appendingPathComponent("MEMORY.md").path)
        let stagedIndex = try fileSystem.createFile(
            directory: staging.descriptor.rawValue,
            name: "MEMORY.md",
            directoryPath: staging.path,
            data: index,
            mode: original?.files["MEMORY.md"]?.mode ?? 0o600)
        stagedEntries["MEMORY.md"] = stagedIndex.fingerprint
        try fileSystem.setDirectoryMode(
            staging.descriptor.rawValue,
            mode: original?.directoryMode ?? 0o700,
            path: staging.path)
        try fileSystem.syncDirectory(staging.descriptor.rawValue, path: staging.path)
        staged = try scanExistingScope(
            descriptor: staging.descriptor.rawValue,
            path: staging.path,
            scope: scope)
        try validateStagedCopy(staged, original: original, mutation: mutation, index: index)

        testingHooks.beforePublish?()
        guard try fileSystem.locationIsCurrent(location) else {
            throw MemoryStoreError.conflict(
                name: targetName,
                reason: "the memory root changed before publication")
        }
        let observedStaging = try scanExistingScope(
            descriptor: staging.descriptor.rawValue,
            path: staging.path,
            scope: scope)
        guard observedStaging.fingerprint == staged.fingerprint,
            (try? fileSystem.siblingDirectoryIdentity(
                parent: location.parentDescriptor,
                parentPath: location.parentPath,
                name: staging.name)) == staged.fingerprint.directoryIdentity
        else {
            throw MemoryStoreError.recoveryRequired(
                path: staging.path,
                reason: "the staged scope changed before publication")
        }

        if let original {
            let observedDescriptor = try fileSystem.openSiblingDirectory(
                parent: location.parentDescriptor,
                parentPath: location.parentPath,
                name: location.destinationName)
            let observed = try scanExistingScope(
                descriptor: observedDescriptor.rawValue,
                path: location.scopePath,
                scope: scope)
            guard observed.fingerprint == original.fingerprint else {
                throw MemoryStoreError.conflict(
                    name: targetName,
                    reason: "another writer changed the scope before the atomic exchange")
            }
            try fileSystem.exchange(
                parent: location.parentDescriptor,
                parentPath: location.parentPath,
                first: staging.name,
                second: location.destinationName)
            removeStagingOnFailure = false

            testingHooks.afterExchange?()
            if testingHooks.interruptAfterExchange {
                throw WikiMemoryStoreTestingInterruption.afterExchange
            }

            let captured: ScopeState
            do {
                let capturedDescriptor = try fileSystem.openSiblingDirectory(
                    parent: location.parentDescriptor,
                    parentPath: location.parentPath,
                    name: staging.name)
                captured = try scanExistingScope(
                    descriptor: capturedDescriptor.rawValue,
                    path: staging.path,
                    scope: scope)
            } catch {
                throw MemoryStoreError.recoveryRequired(
                    path: staging.path,
                    reason:
                        "the displaced scope could not be validated after exchange; both namespace entries were preserved: \(error.localizedDescription)"
                )
            }

            let publishedMatches: Bool
            do {
                let publishedDescriptor = try fileSystem.openSiblingDirectory(
                    parent: location.parentDescriptor,
                    parentPath: location.parentPath,
                    name: location.destinationName)
                let published = try scanExistingScope(
                    descriptor: publishedDescriptor.rawValue,
                    path: location.scopePath,
                    scope: scope)
                publishedMatches = published.fingerprint == staged.fingerprint
            } catch {
                publishedMatches = false
            }
            let locationIsCurrent = (try? fileSystem.locationIsCurrent(location)) == true
            let destinationIsStaged =
                try? fileSystem.siblingDirectoryIdentity(
                    parent: location.parentDescriptor,
                    parentPath: location.parentPath,
                    name: location.destinationName) == staged.fingerprint.directoryIdentity
            let capturedIsNamed =
                try? fileSystem.siblingDirectoryIdentity(
                    parent: location.parentDescriptor,
                    parentPath: location.parentPath,
                    name: staging.name) == captured.fingerprint.directoryIdentity
            guard captured.fingerprint == original.fingerprint, publishedMatches,
                locationIsCurrent, destinationIsStaged == true, capturedIsNamed == true
            else {
                throw MemoryStoreError.recoveryRequired(
                    path: staging.path,
                    reason:
                        "namespace ownership changed after exchange; GOAT did not swap or delete either entry")
            }

            do {
                try fileSystem.syncDirectory(
                    location.parentDescriptor,
                    path: location.parentPath)
            } catch {
                throw MemoryStoreError.recoveryRequired(
                    path: staging.path,
                    reason:
                        "the exchanged scope could not be synchronized; the captured backup was preserved")
            }
            testingHooks.beforeBackupCleanup?()
            do {
                try fileSystem.removeFlatDirectory(
                    parent: location.parentDescriptor,
                    parentPath: location.parentPath,
                    name: staging.name,
                    maximumEntries: Self.maximumNotesPerScope + 2,
                    expectedIdentity: captured.fingerprint.directoryIdentity,
                    expectedEntries: captured.fingerprint.entries)
                try fileSystem.syncDirectory(
                    location.parentDescriptor,
                    path: location.parentPath)
            } catch {
                // Publication is already durable. A hidden backup is safer than a false retry.
            }
        } else {
            try fileSystem.publishNew(
                parent: location.parentDescriptor,
                parentPath: location.parentPath,
                stagingName: staging.name,
                destinationName: location.destinationName)
            removeStagingOnFailure = false
            let publishedMatches: Bool
            do {
                let publishedDescriptor = try fileSystem.openSiblingDirectory(
                    parent: location.parentDescriptor,
                    parentPath: location.parentPath,
                    name: location.destinationName)
                let published = try scanExistingScope(
                    descriptor: publishedDescriptor.rawValue,
                    path: location.scopePath,
                    scope: scope)
                publishedMatches = published.fingerprint == staged.fingerprint
            } catch {
                publishedMatches = false
            }
            let locationIsCurrent = (try? fileSystem.locationIsCurrent(location)) == true
            let destinationIsStaged =
                try? fileSystem.siblingDirectoryIdentity(
                    parent: location.parentDescriptor,
                    parentPath: location.parentPath,
                    name: location.destinationName) == staged.fingerprint.directoryIdentity
            guard locationIsCurrent, destinationIsStaged == true, publishedMatches else {
                throw MemoryStoreError.recoveryRequired(
                    path: location.scopePath,
                    reason:
                        "the new scope changed namespace ownership before synchronization; GOAT left it untouched")
            }
            do {
                try fileSystem.syncDirectory(
                    location.parentDescriptor,
                    path: location.parentPath)
            } catch {
                throw MemoryStoreError.recoveryRequired(
                    path: location.scopePath,
                    reason:
                        "the new scope could not be synchronized; GOAT left the published entry untouched")
            }
        }

        return staged
    }

    private func validateStagedCopy(
        _ staged: ScopeState,
        original: ScopeState?,
        mutation: ScopeMutation,
        index: Data
    ) throws {
        guard staged.indexData == index else {
            throw LocalStoreError.operationFailed(
                path: mutation.targetName,
                operation: "validate staged memory",
                reason:
                    "generated index did not round-trip (expected \(index.count) bytes, read \(staged.indexData?.count ?? -1))"
            )
        }
        guard staged.directoryMode == (original?.directoryMode ?? 0o700),
            staged.files["MEMORY.md"]?.mode == (original?.files["MEMORY.md"]?.mode ?? 0o600)
        else {
            throw LocalStoreError.operationFailed(
                path: mutation.targetName,
                operation: "validate staged memory",
                reason: "staged directory or index permissions changed")
        }
        if case .replace(let name, _) = mutation {
            let filename = "\(name).md"
            guard staged.files[filename]?.mode == (original?.files[filename]?.mode ?? 0o600) else {
                throw LocalStoreError.operationFailed(
                    path: filename,
                    operation: "validate staged memory",
                    reason: "staged note permissions changed")
            }
        }
        for (filename, originalRecord) in original?.files ?? [:] {
            if !mutation.shouldCopy(filename) { continue }
            guard let stagedRecord = staged.files[filename],
                stagedRecord.mode == originalRecord.mode,
                stagedRecord.fingerprint.hasSameStagedContent(as: originalRecord.fingerprint)
            else {
                throw LocalStoreError.operationFailed(
                    path: filename,
                    operation: "validate staged memory",
                    reason: "an unchanged file did not copy exactly")
            }
        }
    }

    private func validate(
        _ condition: MemoryWriteCondition,
        current: StoredMemoryNote?,
        name: String
    ) throws {
        switch condition {
        case .upsert:
            return
        case .ifAbsent:
            guard current == nil else {
                throw MemoryStoreError.conflict(name: name, reason: "a note with this name already exists")
            }
        case .ifRevision(let revision):
            guard let current, current.revision == revision else {
                throw MemoryStoreError.conflict(name: name, reason: "the expected revision is stale")
            }
        }
    }

    private nonisolated static func summaryOrder(
        _ lhs: MemoryNoteSummary,
        _ rhs: MemoryNoteSummary
    ) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        return lhs.name < rhs.name
    }

    private nonisolated func displayScope(for scope: MemoryScope) -> MemoryDisplayScope {
        switch scope {
        case .global: .global
        case .project(let id): .project(id)
        }
    }

    private nonisolated func entryID(for summary: MemoryNoteSummary) -> MemoryEntryID {
        switch summary.scope {
        case .global:
            MemoryEntryID(rawValue: "wiki:global:\(summary.name)")
        case .project(let id):
            MemoryEntryID(rawValue: "wiki:project:\(id.uuidString):\(summary.name)")
        }
    }

    private nonisolated func browserEntry(_ summary: MemoryNoteSummary) -> MemoryBrowserEntry {
        let title: String
        if summary.name.hasPrefix("memory-") {
            let lines = summary.description.split(whereSeparator: { $0.isNewline })
            let candidate = lines.first.map(String.init) ?? "Memory note"
            title = MemoryBrowserEntry.displayTitle(for: candidate)
        } else {
            title = MemoryBrowserEntry.displayTitle(for: summary.name)
        }
        return MemoryBrowserEntry(
            id: entryID(for: summary),
            title: title,
            summary: summary.description,
            scope: displayScope(for: summary.scope),
            modifiedAt: summary.modifiedAt,
            revision: summary.revision,
            canEdit: true,
            canDelete: true)
    }

    private nonisolated func parseEntryID(_ id: MemoryEntryID) throws -> (MemoryScope, String) {
        let fields = id.rawValue.split(separator: ":", omittingEmptySubsequences: false)
        if fields.count == 3, fields[0] == "wiki", fields[1] == "global" {
            let name = String(fields[2])
            try WikiMemoryCodec.validateName(name)
            return (.global, name)
        }
        if fields.count == 4, fields[0] == "wiki", fields[1] == "project",
            let projectID = UUID(uuidString: String(fields[2]))
        {
            let name = String(fields[3])
            try WikiMemoryCodec.validateName(name)
            return (.project(projectID), name)
        }
        throw MemoryStoreError.invalidEntryID(id.rawValue)
    }
}
