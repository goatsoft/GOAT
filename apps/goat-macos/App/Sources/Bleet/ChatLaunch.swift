import Bleet
import Foundation

/// Accept a first turn before navigation can start capability work or retire its composer.
/// Persistence can suspend, so admission must be checked again when it returns.
@MainActor
enum ChatLaunch {
    /// The composer UUID already owns any chat-scoped approvals. Promote that same session.
    static func sessionForSubmission(
        _ draft: ChatSession, penID: UUID, existingChatIDs: Set<UUID>
    ) -> ChatSession? {
        guard draft.projectID == penID, !existingChatIDs.contains(draft.id),
            draft.messages.isEmpty, !draft.isStreaming
        else { return nil }
        draft.messagesLoaded = true
        return draft
    }

    /// Another opening message is a different chat and must not inherit a chat-only grant.
    static func nextDraft(after session: ChatSession) -> ChatSession {
        let draft = ChatSession(effort: session.effort, modelID: session.modelID, projectID: session.projectID)
        draft.toolsEnabled = session.toolsEnabled
        draft.disabledMCPServers = session.disabledMCPServers
        return draft
    }

    static func submit(
        text: String, attachments: [Data], hasDocuments: Bool = false,
        persist: () async -> Bool,
        accept: (String, [Data]) -> Bool,
        navigate: () -> Void,
        discard: () async -> Void
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty || hasDocuments else { return false }
        guard await persist() else { return false }
        guard accept(trimmed, attachments) else {
            await discard()
            return false
        }
        navigate()
        return true
    }
}
