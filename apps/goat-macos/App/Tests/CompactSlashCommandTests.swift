import Inference
import Testing

@testable import GOAT

// ADR-0087 Stage 2c: /compact is discoverable in the composer slash-command menu, and the draft it
// produces parses as a bare compaction command (execution already lives in the Shepherd backend).

@Test func compactCommandIsRegisteredInTheSlashMenu() {
    #expect(ComposerCommand.compact.slashName == "compact")
    #expect(!ComposerCommand.compact.title.isEmpty)
    #expect(!ComposerCommand.compact.description.isEmpty)
    #expect(!ComposerCommand.compact.symbol.isEmpty)
}

@Test func compactSlashItemMatchesTypedQueries() {
    let item = ComposerSlashItem.command(.compact)
    #expect(item.matches("compact"))
    #expect(item.matches("comp"))
    #expect(item.matches(""))
    #expect(!item.matches("zzz"))
}

@Test func compactMenuDraftParsesAsBareCompaction() {
    // Selecting /compact fills the composer with \"/compact \"; sending it must parse as a bare compaction.
    let bare = ConversationCompaction.command(from: "/compact ")
    #expect(bare != nil)
    #expect(bare?.focus == "")
    // A typed focus after the command is carried through to the backend.
    let focused = ConversationCompaction.command(from: "/compact keep the migration constraints")
    #expect(focused != nil)
    #expect(focused?.focus.contains("migration constraints") == true)
}
