import AppKit
import SwiftUI
import Testing

@testable import GOAT

/// Exercises window attachment and native responder changes without activating the app.
@MainActor
@Test func composerFocusRequestSurvivesAttachmentAndRespectsLeaving() async throws {
    var focused = true
    let editor = MarkdownComposerEditor(
        text: .constant(""), height: .constant(40),
        focused: Binding(get: { focused }, set: { focused = $0 }),
        isEditable: true, fontSize: 14, tint: .purple,
        onSubmit: {}, onMoveSelection: { _ in false }, onCancel: { false })
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer {
        window.contentView = nil
        window.close()
    }
    let host = NSHostingView(rootView: editor.frame(width: 400, height: 120))
    let content = NSView(frame: window.contentLayoutRect)
    host.frame = content.bounds
    host.autoresizingMask = [.width, .height]
    content.addSubview(host)
    window.contentView = content
    host.layoutSubtreeIfNeeded()
    for _ in 0..<20 {
        if window.firstResponder is MarkdownComposerEditor.ComposerTextView { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let textView = try #require(window.firstResponder as? MarkdownComposerEditor.ComposerTextView)
    let coordinator = try #require(textView.delegate as? MarkdownComposerEditor.Coordinator)
    #expect(focused)
    let other = NSTextField(string: "Search")
    content.addSubview(other)
    window.makeFirstResponder(other)
    #expect(!focused)
    coordinator.requestFocus()
    await Task.yield()
    #expect(window.firstResponder !== textView)
    focused = true
    coordinator.requestFocus()
    for _ in 0..<20 {
        if window.firstResponder === textView { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(window.firstResponder === textView)
}
