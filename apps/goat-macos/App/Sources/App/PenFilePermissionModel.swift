import Foundation
import Hoofprint
import Observation
import Persistence

/// User-owned native file permissions. The model and tools cannot edit these records.
@MainActor @Observable
final class PenFilePermissionModel {
    enum Scope: String, CaseIterable {
        case ask, chat, pen

        var label: String {
            switch self {
            case .ask: "Ask Every Time"
            case .chat: "Allowed for This Chat"
            case .pen: "Always Allowed for This Pen"
            }
        }

        var choiceLabel: String {
            switch self {
            case .ask: "Ask for approval"
            case .chat: "Allow for this chat"
            case .pen: "Always allow for this Pen"
            }
        }

        var symbol: String {
            switch self {
            case .ask: "hand.raised"
            case .chat: "bubble.left.and.text.bubble.right"
            case .pen: "checkmark.shield"
            }
        }

        func detail(current: Scope) -> String {
            switch self {
            case .ask:
                current == .pen
                    ? "Ask before each file change in this Pen and its chats."
                    : "Ask before each file creation or edit in this chat."
            case .chat:
                current == .pen
                    ? "Allow this chat; other chats in this Pen return to asking."
                    : "Allow file creation and edits, including when you reopen this chat."
            case .pen:
                "Allow file creation and edits in all current and future chats in this Pen."
            }
        }
    }

    private var grants: Set<PenFileGrantRecord> = []
    private var database: ChatDatabase?
    private let activity: ActivityLog
    private var updateTask: Task<Bool, Never>?
    private(set) var revision: UInt64 = 0
    private(set) var error: String?
    var isUpdating: Bool { updateTask != nil }
    var canRemember: Bool { database != nil && !isUpdating && error == nil }

    init(activity: ActivityLog) { self.activity = activity }

    func load(database: ChatDatabase?) async {
        self.database = database
        _ = await update { _ in }
    }

    func scope(penID: UUID, chatID: UUID?, workspaceIdentity: String) -> Scope {
        guard !isUpdating, error == nil else { return .ask }
        if grants.contains(record(penID: penID, chatID: nil, workspaceIdentity: workspaceIdentity)) { return .pen }
        if let chatID, grants.contains(record(penID: penID, chatID: chatID, workspaceIdentity: workspaceIdentity)) {
            return .chat
        }
        return .ask
    }

    func remember(penID: UUID, chatID: UUID?, workspaceIdentity: String) async -> Bool {
        guard canRemember else { return false }
        let grant = record(penID: penID, chatID: chatID, workspaceIdentity: workspaceIdentity)
        return await update { db in try await db.setPenFileGrant(grant) }
    }

    /// Explicit owner selection from the composer. The menu describes the effect on other chats
    /// before a user changes an existing Pen-wide grant to a narrower scope.
    func select(_ choice: Scope, penID: UUID, chatID: UUID?, workspaceIdentity: String) async -> Bool {
        guard !isUpdating, choice == .ask || canRemember, choice != .chat || chatID != nil else { return false }
        let current = scope(penID: penID, chatID: chatID, workspaceIdentity: workspaceIdentity)
        let clearWholePen = chatID == nil || current == .pen || choice == .pen
        return await update { db in
            try await db.replacePenFileGrant(
                penID: penID.uuidString, chatID: choice == .pen ? "" : chatID?.uuidString ?? "",
                workspaceIdentity: workspaceIdentity, allow: choice != .ask, wholePen: clearWholePen)
        }
    }

    @discardableResult
    func reset(penID: UUID, chatID: UUID? = nil) async -> Bool {
        await update { db in
            try await db.deletePenFileGrants(penID: penID.uuidString, chatID: chatID?.uuidString)
        }
    }

    private func record(penID: UUID, chatID: UUID?, workspaceIdentity: String) -> PenFileGrantRecord {
        PenFileGrantRecord(
            penID: penID.uuidString, chatID: chatID?.uuidString ?? "", workspaceIdentity: workspaceIdentity)
    }

    /// Serialize durable mutations. Revocation immediately invalidates in-flight checks; an older
    /// save/load cannot publish over a newer reset, and reset is durably ordered after that save.
    private func update(_ operation: @escaping @Sendable (ChatDatabase) async throws -> Void) async -> Bool {
        revision &+= 1
        let intent = revision
        grants = []
        error = nil
        let previous = updateTask
        let db = database
        let task = Task { @MainActor in
            _ = await previous?.value
            guard let db else { return true }
            do {
                try await operation(db)
                let records = try await db.penFileGrants()
                guard revision == intent else { return false }
                grants = Set(records)
                return true
            } catch {
                guard revision == intent else { return false }
                self.error =
                    "File permissions could not be saved or loaded. GOAT will ask for each change. \(error.localizedDescription)"
                activity.log(.warn, self.error ?? "File permissions are unavailable.")
                return false
            }
        }
        updateTask = task
        let success = await task.value
        guard revision == intent else { return false }
        updateTask = nil
        return success
    }
}
