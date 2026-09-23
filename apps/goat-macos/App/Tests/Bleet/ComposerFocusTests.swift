import AppKit
import Foundation
import Inference
import SwiftUI
import Testing

@testable import GOAT

extension AppTests.Bleet {
    @Suite struct ComposerFocusTests {

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
            if #available(macOS 15.0, *) {
                #expect(textView.writingToolsBehavior == .complete)
                #expect(textView.allowedWritingToolsResultOptions == [.plainText])
            }
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
    }
}

extension AppTests.Bleet {
    @Suite struct ComposerEditingTests {

        @Test func slashSelectionMovesOneItemAndWrapsAtBothEnds() {
            #expect(ComposerSlashSelection.moved(from: 0, by: 1, itemCount: 6) == 1)
            #expect(ComposerSlashSelection.moved(from: 1, by: 1, itemCount: 6) == 2)
            #expect(ComposerSlashSelection.moved(from: 5, by: 1, itemCount: 6) == 0)
            #expect(ComposerSlashSelection.moved(from: 0, by: -1, itemCount: 6) == 5)
            #expect(ComposerSlashSelection.moved(from: 0, by: 1, itemCount: 0) == nil)
        }

        @Test func markdownComposerFindsClosedAndUnclosedCodeFences() throws {
            let closed = "before\n```swift\nprint(\"hello\")\n```\nafter"
            let closedRange = try #require(MarkdownComposerSyntax.fencedRanges(in: closed).first)
            #expect((closed as NSString).substring(with: closedRange) == "```swift\nprint(\"hello\")\n```\n")

            let unclosed = "before\n~~~json\n{\"ready\":true}"
            let unclosedRange = try #require(MarkdownComposerSyntax.fencedRanges(in: unclosed).first)
            #expect((unclosed as NSString).substring(with: unclosedRange) == "~~~json\n{\"ready\":true}")
        }

        @Test func markdownComposerHeightGrowsThenCapsAtEightLines() {
            let oneLine = MarkdownComposerLayout.clampedHeight(for: 18, fontSize: 14)
            let fourLines = MarkdownComposerLayout.clampedHeight(for: 76, fontSize: 14)
            let oversized = MarkdownComposerLayout.clampedHeight(for: 1_000, fontSize: 14)
            let expectedMaximum = CGFloat(14 * 1.35 * 8 + 12)

            #expect(fourLines > oneLine)
            #expect(oversized == expectedMaximum)
        }
    }
}
