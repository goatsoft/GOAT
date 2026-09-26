import CoreGraphics
import Foundation
import Testing

@testable import Bleet

@MainActor
@Test func streamRevisionAndThinkingTailStayIncremental() {
    let message = ChatMessage(role: .assistant)

    message.appendStream(text: "", thinking: "first line")
    #expect(message.renderRevision == 1)
    #expect(message.thinkingTail == "first line")

    message.appendStream(text: "hello", thinking: " continued\nnewest line")
    #expect(message.renderRevision == 2)
    #expect(message.thinkingTail == "newest line")

    message.appendStream(text: " world", thinking: String(repeating: "x", count: 120))
    #expect(message.renderRevision == 3)
    #expect(message.thinkingTail.count == 90)
    #expect(message.text == "hello world")

    let continued = ChatMessage(role: .assistant)
    continued.appendStream(text: "", thinking: "split")
    continued.appendStream(text: "", thinking: " line\n")
    #expect(continued.thinkingTail == "split line")
}

/// #60 A1: streamed appends keep a text's revision epoch; any other change starts a new one.
@MainActor
@Test func textRevisionsKeepTheirEpochOnlyWhileTheTextGrows() {
    let message = ChatMessage(role: .assistant)
    let empty = message.textRevision
    #expect(empty.utf8Count == 0)

    message.appendStream(text: "Hello", thinking: "")
    let streamed = message.textRevision
    #expect(streamed.epoch == empty.epoch && streamed.utf8Count == 5)
    #expect(streamed.extends(empty))

    // Assigning an extension of the current text is an append too.
    message.text += ", world"
    #expect(message.textRevision.epoch == empty.epoch && message.textRevision.utf8Count == 12)

    // A trim, an edit or a replacement starts a new epoch, even at the same length.
    message.text = "Hello"
    let trimmed = message.textRevision
    #expect(trimmed.epoch != empty.epoch && !trimmed.extends(streamed))
    message.text = "Jello"
    #expect(message.textRevision.epoch != trimmed.epoch)

    // Restoring content replaces both texts.
    let thinking = message.thinkingRevision
    message.restoreContent(text: "Restored", thinking: "Thought")
    #expect(message.textRevision.utf8Count == 8 && message.thinkingRevision.utf8Count == 7)
    #expect(message.thinkingRevision.epoch != thinking.epoch)

    // Epochs are unique across messages, so a recreated message never reuses one.
    let recreated = ChatMessage(role: .assistant, id: message.id)
    #expect(recreated.textRevision.epoch != message.textRevision.epoch)
    #expect(recreated.textRevision != TextRevision(epoch: empty.epoch, utf8Count: 0))
}
