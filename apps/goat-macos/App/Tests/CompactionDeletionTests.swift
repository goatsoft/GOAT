import Testing

@testable import Bleet
@testable import GOAT

@Test @MainActor func onlyNewestCompactionCanRestorePromptHistory() {
    let sourceUser = ChatMessage(role: .user)
    let sourceAssistant = ChatMessage(role: .assistant)
    let older = ChatMessage(role: .user)
    older.kind = .compaction
    let laterUser = ChatMessage(role: .user)
    let newest = ChatMessage(role: .user)
    newest.kind = .compaction
    let messages = [sourceUser, sourceAssistant, older, laterUser, newest]

    #expect(!CompactionDeletion.canRestore(older, in: messages))
    #expect(CompactionDeletion.canRestore(newest, in: messages))
    #expect(CompactionDeletion.removing(older, from: messages).count == messages.count)

    let restored = CompactionDeletion.removing(newest, from: messages)
    #expect(restored.map(\.id) == [sourceUser, sourceAssistant, older, laterUser].map(\.id))
}
