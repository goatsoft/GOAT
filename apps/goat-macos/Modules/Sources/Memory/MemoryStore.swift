import Foundation

/// A durable memory namespace. Project identifiers are typed UUIDs so no caller-provided path
/// component crosses the storage boundary.
public enum MemoryScope: Sendable, Hashable {
    case global
    case project(UUID)
}

/// The single durable memory namespace visible to one chat. A Pen reads and writes only its own
/// scope, while a loose chat reads and writes only global memory. Scope changes are deliberate
/// application actions and never union the two stores.
public struct MemoryContext: Sendable, Hashable {
    public let projectID: UUID?

    public init(projectID: UUID? = nil) {
        self.projectID = projectID
    }

    public var readableScopes: [MemoryScope] {
        [defaultWriteScope]
    }

    public var defaultWriteScope: MemoryScope {
        projectID.map(MemoryScope.project) ?? .global
    }
}

/// One small wiki fact. `name` is both its stable identifier and safe filename stem.
public struct MemoryNote: Sendable, Equatable {
    public let name: String
    public let description: String
    public let body: String

    public init(name: String, description: String, body: String) {
        self.name = name
        self.description = description
        self.body = body
    }
}

/// An opaque content revision used by the browser to reject stale external-edit overwrites.
public struct MemoryRevision: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct MemoryNoteSummary: Sendable, Equatable {
    public let scope: MemoryScope
    public let name: String
    public let description: String
    public let modifiedAt: Date
    public let revision: MemoryRevision

    public init(
        scope: MemoryScope,
        name: String,
        description: String,
        modifiedAt: Date,
        revision: MemoryRevision
    ) {
        self.scope = scope
        self.name = name
        self.description = description
        self.modifiedAt = modifiedAt
        self.revision = revision
    }
}

public struct StoredMemoryNote: Sendable, Equatable {
    public let note: MemoryNote
    public let scope: MemoryScope
    public let modifiedAt: Date
    public let revision: MemoryRevision

    public init(
        note: MemoryNote,
        scope: MemoryScope,
        modifiedAt: Date,
        revision: MemoryRevision
    ) {
        self.note = note
        self.scope = scope
        self.modifiedAt = modifiedAt
        self.revision = revision
    }

    public var summary: MemoryNoteSummary {
        MemoryNoteSummary(
            scope: scope,
            name: note.name,
            description: note.description,
            modifiedAt: modifiedAt,
            revision: revision)
    }
}

/// A backend-neutral scope label for prompt and browser presentation.
public enum MemoryDisplayScope: Sendable, Hashable {
    case global
    case project(UUID)
    case shared
}

/// One backend-neutral prompt index entry. Wiki notes use their safe name as `identifier`;
/// service backends may use a knowledge-page identifier. The text is still uncapped here.
public struct MemoryPromptEntry: Sendable, Equatable {
    public let identifier: String
    public let title: String
    public let summary: String
    public let scope: MemoryDisplayScope
    public let modifiedAt: Date?

    public init(
        identifier: String,
        title: String,
        summary: String,
        scope: MemoryDisplayScope,
        modifiedAt: Date? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.summary = summary
        self.scope = scope
        self.modifiedAt = modifiedAt
    }
}

/// Uncapped structured memory. PromptBudgeter owns rendering and the token cap so the same
/// estimator which plans the final wire request also decides which entries fit.
public struct MemoryPromptSnapshot: Sendable, Equatable {
    public let entries: [MemoryPromptEntry]

    public init(entries: [MemoryPromptEntry]) {
        self.entries = entries
    }
}

public enum MemoryStoreCapability: String, Sendable, Hashable, CaseIterable {
    case promptSnapshot
    case browse
    case remember
    case edit
    case delete
    case backendTools
}

/// Operations supported by a memory backend. Hindsight can expose bank tools independently
/// of the local wiki's document operations.
public struct MemoryStoreCapabilities: Sendable, Equatable {
    public let features: Set<MemoryStoreCapability>

    public init(_ features: Set<MemoryStoreCapability>) {
        self.features = features
    }

    public func contains(_ capability: MemoryStoreCapability) -> Bool {
        features.contains(capability)
    }
}

public enum MemoryWriteCondition: Sendable, Equatable {
    case upsert
    case ifAbsent
    case ifRevision(MemoryRevision)
}

public enum MemoryStoreError: LocalizedError, Sendable, Equatable {
    case invalidName(String)
    case invalidEntryID(String)
    case invalidNote(path: String, reason: String)
    case capacityExceeded(path: String, reason: String)
    case conflict(name: String, reason: String)
    case recoveryRequired(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            "Invalid memory note name \"\(name)\". Use 1 to 64 lowercase letters, numbers, or hyphens."
        case .invalidEntryID(let id):
            "Invalid memory entry identifier \"\(id)\"."
        case .invalidNote(let path, let reason):
            "Invalid memory note at \(path): \(reason)"
        case .capacityExceeded(let path, let reason):
            "Memory limit exceeded at \(path): \(reason)"
        case .conflict(let name, let reason):
            "Memory note \"\(name)\" changed before it could be saved: \(reason)"
        case .recoveryRequired(let path, let reason):
            "Memory publication needs manual recovery at \(path): \(reason)"
        }
    }
}

/// Common backend seam. Prompt material remains structured and uncapped here.
public protocol MemoryStore: Sendable {
    var capabilities: MemoryStoreCapabilities { get }
    func promptSnapshot(for context: MemoryContext) async throws -> MemoryPromptSnapshot
}

/// An opaque backend identifier. Callers must not interpret this as a path or knowledge-page ID.
public struct MemoryEntryID: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct MemoryBrowserEntry: Sendable, Equatable {
    /// A title needs to stay scannable in the compact Pages and Map views. The underlying
    /// document and summary remain intact; this only bounds the browser-facing label.
    public static let maximumDisplayTitleCharacters = 80

    public let id: MemoryEntryID
    public let title: String
    public let summary: String
    public let scope: MemoryDisplayScope
    public let modifiedAt: Date?
    public let revision: MemoryRevision?
    public let canEdit: Bool
    public let canDelete: Bool

    public init(
        id: MemoryEntryID,
        title: String,
        summary: String,
        scope: MemoryDisplayScope,
        modifiedAt: Date? = nil,
        revision: MemoryRevision? = nil,
        canEdit: Bool,
        canDelete: Bool
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.scope = scope
        self.modifiedAt = modifiedAt
        self.revision = revision
        self.canEdit = canEdit
        self.canDelete = canDelete
    }

    public static func displayTitle(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumDisplayTitleCharacters else { return trimmed }
        return String(trimmed.prefix(maximumDisplayTitleCharacters - 1)) + "…"
    }

    public var displayTitle: String {
        Self.displayTitle(for: title)
    }
}

public struct MemoryBrowserDocument: Sendable, Equatable {
    public let entry: MemoryBrowserEntry
    public let content: String

    public init(entry: MemoryBrowserEntry, content: String) {
        self.entry = entry
        self.content = content
    }
}

/// Browser access is capability-gated independently from mutation support.
public protocol BrowsableMemoryStore: MemoryStore {
    func browserEntries(for context: MemoryContext) async throws -> [MemoryBrowserEntry]
    func browserDocument(_ id: MemoryEntryID, context: MemoryContext) async throws
        -> MemoryBrowserDocument
}

public enum MemoryRememberKind: String, Sendable, Hashable, Codable {
    case explicit
    case feedback
    case reflection
    case session
}

public struct MemoryRememberRequest: Sendable, Equatable {
    public let idempotencyKey: UUID
    public let title: String
    public let summary: String
    public let content: String
    public let context: MemoryContext
    public let suggestedName: String?
    public let kind: MemoryRememberKind
    public let sourceIdentifier: String?

    public init(
        idempotencyKey: UUID,
        title: String,
        summary: String,
        content: String,
        context: MemoryContext,
        suggestedName: String? = nil,
        kind: MemoryRememberKind = .explicit,
        sourceIdentifier: String? = nil
    ) {
        self.idempotencyKey = idempotencyKey
        self.title = title
        self.summary = summary
        self.content = content
        self.context = context
        self.suggestedName = suggestedName
        self.kind = kind
        self.sourceIdentifier = sourceIdentifier
    }
}

public enum MemoryRememberStatus: String, Sendable, Hashable, Codable {
    case stored
    case queued
}

public struct MemoryUndoToken: Sendable, Equatable {
    public let entryID: MemoryEntryID
    public let revision: MemoryRevision

    public init(entryID: MemoryEntryID, revision: MemoryRevision) {
        self.entryID = entryID
        self.revision = revision
    }
}

public struct MemoryRememberReceipt: Sendable, Equatable {
    public let status: MemoryRememberStatus
    public let entryID: MemoryEntryID?
    public let revision: MemoryRevision?
    public let undoToken: MemoryUndoToken?

    public init(
        status: MemoryRememberStatus,
        entryID: MemoryEntryID? = nil,
        revision: MemoryRevision? = nil,
        undoToken: MemoryUndoToken? = nil
    ) {
        self.status = status
        self.entryID = entryID
        self.revision = revision
        self.undoToken = undoToken
    }
}

/// Append-only service backends can remember without claiming browser edit or delete parity.
public protocol RememberingMemoryStore: MemoryStore {
    func remember(_ request: MemoryRememberRequest) async throws -> MemoryRememberReceipt
}

/// Human-editable stores add CRUD without forcing service backends into false parity.
public protocol EditableMemoryStore: BrowsableMemoryStore, RememberingMemoryStore {
    func summaries(in scope: MemoryScope) async throws -> [MemoryNoteSummary]
    func read(_ name: String, scope: MemoryScope) async throws -> StoredMemoryNote?
    func write(
        _ note: MemoryNote,
        scope: MemoryScope,
        condition: MemoryWriteCondition
    ) async throws -> StoredMemoryNote
    @discardableResult
    func delete(
        _ name: String,
        scope: MemoryScope,
        ifRevision revision: MemoryRevision?
    ) async throws -> Bool
}
