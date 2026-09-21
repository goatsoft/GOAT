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
