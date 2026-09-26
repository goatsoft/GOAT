import AppKit
import Bleet
import Inference
import Persistence
import SwiftUI
import Testing

@testable import GOAT

@MainActor private func transcript(_ session: ChatSession) -> some View {
    ChatTranscriptView(session: session).id(session.id)
        .environment(AppModel.shared).frame(width: 700, height: 450)
}

@MainActor private func click(at pointInHost: NSPoint, in host: NSView, window: NSWindow) {
    let pointInWindow = host.convert(pointInHost, to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let event = NSEvent.mouseEvent(
            with: type, location: pointInWindow, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        {
            window.sendEvent(event)
        }
    }
}

@MainActor private func findTranscriptScroll(_ view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    return view.subviews.lazy.compactMap(findTranscriptScroll).first
}
extension AppTests.Bleet {
    @Suite struct TranscriptLayoutTests {

        @Test @MainActor func switchingLongAndShortChatsCreatesFreshPopulatedScrollViewports() async throws {
            let long = ChatSession(effort: .trot, modelID: nil)
            let short = ChatSession(effort: .trot, modelID: nil)
            for (session, count) in [(long, 60), (short, 2)] {
                session.messagesLoaded = true
                session.messages = (0..<count).map { index in
                    let message = ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant)
                    message.text = "Message \(index)\n\n" + String(repeating: "- A transcript line.\n", count: 6)
                    message.complete = true
                    return message
                }
            }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: transcript(long))
            window.contentView = host
            defer {
                window.contentView = nil
                window.close()
            }
            for session in [long, short, long] {
                host.rootView = transcript(session)
                var settled: NSScrollView?
                for _ in 0..<100 {
                    host.layoutSubtreeIfNeeded()
                    if let scroll = findTranscriptScroll(host), let document = scroll.documentView,
                        document.bounds.height > 0,
                        document.visibleRect.height > 0,
                        document.bounds.maxY - document.visibleRect.maxY < 80,
                        session === long ? document.bounds.height > 3_000 : document.bounds.height < 2_000
                    {
                        settled = scroll
                        break
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                _ = try #require(
                    settled,
                    "The selected chat must lay out at its latest messages without manual scrolling; document=\(String(describing: findTranscriptScroll(host)?.documentView?.bounds)), visible=\(String(describing: findTranscriptScroll(host)?.documentView?.visibleRect))"
                )
            }
        }
        @Test @MainActor func scrollToBottomSnapsToBottomInSingleShotWhenScrolledUp() async throws {
            let session = ChatSession(effort: .trot, modelID: nil)
            session.messagesLoaded = true
            session.messages = (0..<70).map { index in
                let message = ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant)
                message.text = "Message \(index)\n\n" + String(repeating: "- A transcript line.\n", count: 6)
                message.complete = true
                return message
            }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let viewport = TranscriptViewport()
            let host = NSHostingView(
                rootView: ChatTranscriptView(session: session, viewport: viewport)
                    .environment(AppModel.shared).frame(width: 700, height: 450))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer {
                window.contentView = nil
                window.close()
            }

            // Wait for initial layout at the bottom
            var settled: NSScrollView?
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                if let scroll = findTranscriptScroll(host), let document = scroll.documentView,
                    document.bounds.height > 3_000,
                    document.bounds.maxY - document.visibleRect.maxY < 80
                {
                    settled = scroll
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let scroll = try #require(settled)

            let document = try #require(scroll.documentView)
            // Scroll up to earlier messages
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            host.layoutSubtreeIfNeeded()

            // Paging and the visibility observer publish asynchronously. Click only
            // after the real button is available, without bypassing its action.
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                if !viewport.isScrolledToBottom { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!viewport.isScrolledToBottom, "Scroll-to-bottom button must be visible")
            #expect(
                document.bounds.maxY - document.visibleRect.maxY > 500,
                "Should be scrolled away from bottom; \(viewport.diagnostics.suffix(16))")
            let clickPoint = NSPoint(x: host.bounds.midX, y: host.isFlipped ? (host.bounds.height - 28) : 28)
            click(at: clickPoint, in: host, window: window)

            #expect(viewport.autoFollow, "One click must invoke the bottom action")
            #expect(viewport.heldRange == nil, "One click must restore the latest page")

            // Wait for scroll to settle at the bottom
            var reachedBottom = false
            for _ in 0..<50 {
                host.layoutSubtreeIfNeeded()
                let distFromBottom = document.bounds.maxY - document.visibleRect.maxY
                if abs(distFromBottom) <= 1 {
                    reachedBottom = true
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }

            let trace = viewport.diagnostics.suffix(16)
            #expect(
                reachedBottom,
                "A single click on the scroll-to-bottom button must bring the viewport to the end; \(trace)")
        }

        @Test @MainActor func repeatedPagingBoundsMessageCountAndBudgetWhilePreservingReaderPosition() async throws {
            let session = ChatSession(effort: .trot, modelID: nil)
            session.messagesLoaded = true
            session.messages = (0..<120).map { index in
                let message = ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant)
                message.text = "Message \(index)\n\n" + String(repeating: "- A transcript line.\n", count: 6)
                message.complete = true
                return message
            }

            let viewport = TranscriptViewport()
            let view = ChatTranscriptView(session: session, viewport: viewport)
            let cost: (Int) -> Int = { TranscriptWindow.displayCost(session.messages[$0]) }

            // Initial window is at the bottom
            var current = viewport.messageRange(count: session.messages.count, cost: cost)
            #expect(current.upperBound == 120)
            #expect(current.count <= TranscriptWindow.capacity)
            #expect(view.visibleMessageRange == current)

            // Page earlier all the way to index 0
            while current.lowerBound > 0 {
                let previous = current
                let result = try #require(viewport.pageEarlier(count: session.messages.count, cost: cost))
                current = result.range
                #expect(current.lowerBound < previous.lowerBound, "Earlier page moves lower bound towards 0")
                #expect(current.upperBound < previous.upperBound, "Earlier page evicts opposite edge (upper bound)")
                #expect(current.count <= TranscriptWindow.capacity, "Message count is strictly bounded")
                #expect(current.contains(result.anchor), "Visible anchor preserved across paging")
                #expect(viewport.readerOwnsViewport == true, "Paging claims viewport ownership for reader")
                #expect(viewport.autoFollow == false, "Auto-follow is disabled when reader pages")
            }
            #expect(current.lowerBound == 0, "Reached the earliest message in the transcript")

            // Now page later all the way to the end
            while current.upperBound < session.messages.count {
                let previous = current
                let result = try #require(viewport.pageLater(count: session.messages.count, cost: cost))
                current = result.range
                #expect(current.upperBound > previous.upperBound, "Later page moves upper bound towards end")
                #expect(current.lowerBound > previous.lowerBound, "Later page evicts opposite edge (lower bound)")
                #expect(current.count <= TranscriptWindow.capacity, "Message count is strictly bounded")
                #expect(current.contains(result.anchor), "Visible anchor preserved across paging")
                #expect(viewport.readerOwnsViewport == true, "Viewport still owned by reader upon reaching final page")
                #expect(
                    viewport.autoFollow == false,
                    "Loading final page does NOT re-enable auto-follow or snap to bottom")
            }
            #expect(current.upperBound == session.messages.count, "Reached the latest message")
        }

        @Test @MainActor func sourceBudgetIsAppliedEvenBelowMessageCountLimit() async throws {
            let session = ChatSession(effort: .trot, modelID: nil)
            session.messagesLoaded = true
            session.messages = (0..<20).map { index in
                let msg = ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant)
                msg.text = String(repeating: "a", count: 5_000)
                msg.complete = true
                return msg
            }

            let viewport = TranscriptViewport()
            let cost: (Int) -> Int = { TranscriptWindow.displayCost(session.messages[$0]) }

            let range = viewport.messageRange(count: session.messages.count, cost: cost)
            #expect(range.count < 20, "Short chats with heavy messages must still be bounded by source budget")
            let totalCost = range.reduce(0) { $0 + cost($1) }
            #expect(totalCost <= TranscriptWindow.sourceBudget, "Total display cost must not exceed source budget")

            let view = ChatTranscriptView(session: session, initiallyFollowing: false)
            #expect(view.visibleMessageRange.count < 20)
            let restoredCost = view.visibleMessageRange.reduce(0) { $0 + cost($1) }
            #expect(restoredCost <= TranscriptWindow.sourceBudget)
        }

        @Test @MainActor func pagingAcrossNonOverlappingOversizedMessagesPreservesValidAnchor() async throws {
            let count = 100
            // 20,000 bytes per message exceeds sourceBudget (16,384), yielding 1-message non-overlapping pages
            let cost: (Int) -> Int = { _ in 20_000 }
            let viewport = TranscriptViewport()

            let initial = viewport.messageRange(count: count, cost: cost)
            #expect(initial == 99..<100)

            // Paging earlier must produce 98..<99 and anchor 98 inside that new page
            let earlier = try #require(viewport.pageEarlier(count: count, cost: cost))
            #expect(earlier.range == 98..<99)
            #expect(earlier.anchor == 98)
            #expect(earlier.range.contains(earlier.anchor))
            let restoredEarlier = viewport.messageRange(count: count, anchor: earlier.anchor, cost: cost)
            #expect(restoredEarlier == 98..<99, "Restoring with anchor must not revert to previous page")

            // Paging earlier again
            let earlier2 = try #require(viewport.pageEarlier(count: count, cost: cost))
            #expect(earlier2.range == 97..<98)
            #expect(earlier2.anchor == 97)
            #expect(earlier2.range.contains(earlier2.anchor))

            // Paging later must produce 98..<99 and anchor 98 inside that new page
            let later = try #require(viewport.pageLater(count: count, cost: cost))
            #expect(later.range == 98..<99)
            #expect(later.anchor == 98)
            #expect(later.range.contains(later.anchor))
            let restoredLater = viewport.messageRange(count: count, anchor: later.anchor, cost: cost)
            #expect(restoredLater == 98..<99, "Restoring with anchor must not revert to previous page")
        }

        /// Regression for PR 66: a parts view must re-split when its source keeps growing past 8 KiB.
        @Test @MainActor func textPartsViewUpdatesWhenSourceGrowsAfterSplitting() async throws {
            let line = String(repeating: "x", count: 99) + "\n"  // 100 bytes
            func source(_ kib: Int) -> String { String(repeating: line, count: kib * 1_024 / 100) }
            func parts(_ source: String) -> some View {
                TranscriptTextPartsView(source: source, fontSize: 13)
                    .frame(width: 500)
                    .environment(AppModel.shared)
            }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: parts(source(10)))
            window.contentView = host
            defer {
                window.contentView = nil
                window.close()
            }
            func settledHeight() async throws -> CGFloat {
                try await Task.sleep(for: .milliseconds(300))
                host.layoutSubtreeIfNeeded()
                return host.fittingSize.height
            }
            // 10 KiB splits into 8 KiB + 2 KiB; the last (short) part is shown.
            let short = try await settledHeight()
            // 16 KiB splits into 8 KiB + 8 KiB; the shown last part must grow to 8 KiB.
            host.rootView = parts(source(16))
            let full = try await settledHeight()
            #expect(full > short * 2, "The visible part must re-split as the source grows (\(short) -> \(full))")
        }

        /// Issue #60 C0: a reply whose answer and reasoning both pass 8 KiB completes while streaming.
        /// The answer's latest segments and the reasoning's latest part must show, and the transcript
        /// must stay scrollable to its bottom without reselecting the chat.
        @Test @MainActor func oversizedAnswerAndReasoningCompleteIntoAReachableBottom() async throws {
            let session = ChatSession(effort: .trot, modelID: nil)
            session.messagesLoaded = true
            let user = ChatMessage(role: .user)
            user.text = "Write a long report."
            user.complete = true
            let assistant = ChatMessage(role: .assistant)
            session.messages = [user, assistant]
            session.isStreaming = true

            let reasoningLine = String(repeating: "r", count: 79) + "\n"
            let answerLine = String(repeating: "a", count: 79) + "\n"
            assistant.appendStream(text: "", thinking: String(repeating: reasoningLine, count: 40))

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: transcript(session).environment(\.reasoningStartsExpanded, true))
            window.contentView = host
            defer {
                window.contentView = nil
                window.close()
            }
            host.layoutSubtreeIfNeeded()

            // Stream both sources well past one 8 KiB part, the way the worker publishes batches.
            for _ in 0..<6 {
                assistant.appendStream(
                    text: String(repeating: answerLine, count: 40),
                    thinking: String(repeating: reasoningLine, count: 30))
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
            }
            assistant.appendStream(text: "ANSWER-END", thinking: "REASONING-END")
            #expect(assistant.text.utf8.count > 16 * 1_024)
            #expect(assistant.thinking.utf8.count > 16 * 1_024)

            assistant.complete = true
            session.isStreaming = false

            // The answer renders its latest segments as rich Markdown (#60 A1 step 3); the reasoning's
            // parts view publishes exactly what it prepared under its owner key.
            let reasoning = TranscriptText.removingBoundaryBlankLines(assistant.thinking)
            func shownAnswer() -> String? {
                let cache = PreparedMarkdownDocumentCache.shared
                guard let document = cache.document(for: assistant.id, revision: assistant.textRevision),
                    document.isComplete, let last = document.shownSegments.last,
                    last == document.segments.count - 1, document.segments[last].isParsed
                else { return nil }
                return document.segments[last].text
            }
            func shownReasoning() -> String? {
                TranscriptPartsCache.shared.parts(for: "\(assistant.id.uuidString):thinking", source: reasoning)?.last
            }
            var settled = false
            for _ in 0..<150 {
                host.layoutSubtreeIfNeeded()
                if let scroll = findTranscriptScroll(host), let document = scroll.documentView,
                    document.bounds.height > scroll.contentView.bounds.height,
                    document.bounds.maxY - document.visibleRect.maxY < 100,
                    shownAnswer()?.hasSuffix("ANSWER-END") == true,
                    shownReasoning()?.hasSuffix("REASONING-END") == true
                {
                    settled = true
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(
                settled,
                "Latest text renders and the bottom is reachable; answer \(shownAnswer()?.suffix(12) ?? "none"), reasoning \(shownReasoning()?.suffix(12) ?? "none")"
            )
        }

        @Test @MainActor func oversizedCompletedReplyRendersScrollableDocumentAndReachesBottomSentinel() async throws {
            let session = ChatSession(effort: .trot, modelID: nil)
            session.messagesLoaded = true
            let user = ChatMessage(role: .user)
            user.text = "Write a comprehensive report on transcript performance."
            user.complete = true

            let user2 = ChatMessage(role: .user)
            user2.text = "Can you elaborate further?"
            user2.complete = true

            let assistant = ChatMessage(role: .assistant)
            // Sized so that Part 2 is substantial (> 6 KiB)
            assistant.text = String(
                repeating:
                    "Here is a detailed paragraph explaining architectural metrics and layout passes in Swift.\n\n",
                count: 160)
            assistant.thinking = String(
                repeating: "Reasoning step evaluating trade-offs and performance implications.\n\n", count: 40)
            assistant.complete = true
            session.messages = [user, user2, assistant]

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let viewport = TranscriptViewport()
            let host = NSHostingView(
                rootView: ChatTranscriptView(session: session, viewport: viewport).id(session.id)
                    .environment(AppModel.shared).frame(width: 700, height: 450))
            window.contentView = host
            defer {
                window.contentView = nil
                window.close()
            }

            var settled: NSScrollView?
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                if let scroll = findTranscriptScroll(host), let document = scroll.documentView,
                    document.bounds.height > 600,
                    document.visibleRect.height > 0,
                    document.bounds.height > scroll.contentView.bounds.height,
                    document.bounds.maxY - document.visibleRect.maxY < 100
                {
                    settled = scroll
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let scroll = findTranscriptScroll(host)
            let geometry = scroll.flatMap { scroll in
                scroll.documentView.map { ($0.bounds.height, $0.bounds.maxY - $0.visibleRect.maxY) }
            }
            let prepared = PreparedMarkdownDocumentCache.shared.document(
                for: assistant.id, revision: assistant.textRevision)
            let shown = prepared.map { "\($0.window.map { "\($0)" } ?? "all") of \($0.segments.count)" }
            let detail =
                "height and distance \(String(describing: geometry)), reply \(shown ?? "unprepared"), "
                + "follows \(viewport.autoFollow); \(viewport.diagnostics.suffix(16))"
            #expect(
                settled != nil,
                "An oversized completed reply must render a tall scrollable document at the bottom; \(detail)")
        }

        enum CompletionCase: String, CaseIterable, Sendable {
            case plain, agentic, truncated
        }

        /// #60 measurement 2 (A2): completing a reply with unchanged text must not change the row's height,
        /// including when the worker publishes final stats and when a length stop offers Continue.
        @Test(arguments: CompletionCase.allCases) @MainActor func completionKeepsTheAssistantRowHeight(
            _ completion: CompletionCase
        ) async throws {
            let message = ChatMessage(role: .assistant)
            message.text = "Here is an explanation of the layout.\n\n```swift\nlet value = 1\n```\n\nDone."
            if completion == .agentic {
                message.toolEvents = [
                    ToolEventSnapshot(
                        id: "t1", server: "Pens", tool: "pen_read_file", arguments: #"{"path":"a.swift"}"#, result: "ok"
                    )
                ]
            }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(
                rootView: MessageView(message: message, isLast: true, projectID: nil)
                    .frame(width: 600).environment(AppModel.shared))
            window.contentView = host
            defer {
                window.contentView = nil
                window.close()
            }
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let before = host.fittingSize.height

            var stats = GenStats(ttft: 0.2, tokens: 2_048, duration: 12)
            stats.finishReason = completion == .truncated ? "length" : "stop"
            message.stats = stats
            message.complete = true
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let after = host.fittingSize.height
            #expect(after == before, "Completion must not reflow a \(completion) reply (\(before) -> \(after) pt)")
        }
    }
}

/// A chat whose every line names its message and line, so a shifted view never matches pixels.
@MainActor private func distinctSession(count: Int) -> ChatSession {
    let session = ChatSession(effort: .trot, modelID: nil)
    session.messagesLoaded = true
    session.messages = (0..<count).map { index in
        let message = ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant)
        message.text =
            "Message \(index)\n\n" + (0..<6).map { "- Line \($0) of message \(index)." }.joined(separator: "\n")
        message.complete = true
        return message
    }
    return session
}

@MainActor private func snapshot(_ view: NSView) throws -> NSBitmapImageRep {
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap
}

@MainActor private func hostedWindow(
    _ session: ChatSession, viewport: TranscriptViewport
) -> (NSWindow, NSHostingView<some View>) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 700, height: 450), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(
        rootView: ChatTranscriptView(session: session, viewport: viewport)
            .environment(AppModel.shared).frame(width: 700, height: 450))
    window.contentView = host
    window.orderFront(nil)
    return (window, host)
}

@MainActor private func settle(_ viewport: TranscriptViewport, host: NSView) async throws {
    for _ in 0..<100 {
        host.layoutSubtreeIfNeeded()
        if viewport.request == nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()
}

extension AppTests.Bleet {
    /// #54 section 2: one navigation owner with explicit transitions, at most one pending request
    /// and one scroll executor.
    @Suite(.serialized) struct TranscriptNavigationTests {
        private typealias Anchor = TranscriptViewport.Anchor

        @Test @MainActor func readerInputCancelsPendingScrollsAndOnlyAGestureAtTheBottomFollows() throws {
            let viewport = TranscriptViewport()
            viewport.contentChanged()
            let bottom = try #require(viewport.request)
            #expect(bottom.target == .bottom)
            viewport.contentChanged()
            #expect(viewport.request == bottom, "Equal requests coalesce")

            let anchor = Anchor(messageID: UUID(), offset: 12)
            viewport.readerMoved(currentRange: 0..<10, anchor: anchor)
            #expect(viewport.request == nil, "Reader input cancels a pending scroll")
            #expect(viewport.readerOwnsViewport && viewport.heldRange == 0..<10)
            viewport.fulfilled(bottom)
            #expect(viewport.request == nil, "A stale completion changes nothing")

            viewport.contentChanged()
            #expect(viewport.request?.target == .anchor(anchor), "Content changes restore the reader's anchor")
            viewport.readerSettled(atTrueBottom: false, anchor: nil)
            #expect(viewport.readerOwnsViewport)
            viewport.readerSettled(atTrueBottom: true, anchor: nil)
            #expect(viewport.autoFollow && viewport.heldRange == nil && viewport.anchor == nil)
        }

        @Test @MainActor func aReplacedRequestIgnoresItsCompletion() throws {
            let viewport = TranscriptViewport(
                initiallyFollowing: false, initialHeldRange: 0..<5,
                initialAnchor: Anchor(messageID: UUID(), offset: 0))
            let restoring = try #require(viewport.request)
            viewport.jumpToLatest()
            let bottom = try #require(viewport.request)
            #expect(bottom.generation > restoring.generation)
            viewport.fulfilled(restoring)
            #expect(viewport.request == bottom)
            viewport.fulfilled(bottom)
            #expect(viewport.request == nil && viewport.autoFollow && viewport.isScrolledToBottom)

            viewport.contentChanged()
            let again = try #require(viewport.request)
            viewport.abandon(again)
            #expect(viewport.request == nil && viewport.abandonedRequests == 1)
        }

        @Test @MainActor func finalPageKeepsOwnershipAndRemovalKeepsAnAnchor() throws {
            var ids = (0..<100).map { _ in UUID() }
            let cost: (Int) -> Int = { _ in 1_000 }
            let viewport = TranscriptViewport()
            while viewport.pageEarlier(count: ids.count, cost: cost) != nil {}
            while viewport.pageLater(count: ids.count, cost: cost) != nil {}
            #expect(viewport.readerOwnsViewport, "Loading the final page must not enable following")

            viewport.restore(Anchor(messageID: ids[95], offset: 30))
            // Compaction removes the anchor's message: the reader continues at a surviving message.
            ids.removeSubrange(90..<97)
            viewport.messagesRemoved(count: ids.count, anchorIndex: nil, messageID: { ids[$0] }, cost: cost)
            let range = try #require(viewport.heldRange)
            #expect(range.upperBound <= ids.count && !range.isEmpty)
            let anchor = try #require(viewport.anchor)
            #expect(anchor == Anchor(messageID: ids[range.lowerBound], offset: 0))
            #expect(viewport.request?.target == .anchor(anchor))

            // A surviving anchor is kept as it was.
            let kept = Anchor(messageID: ids[range.lowerBound], offset: 7)
            viewport.restore(kept)
            ids.removeLast()
            viewport.messagesRemoved(
                count: ids.count, anchorIndex: range.lowerBound, messageID: { ids[$0] }, cost: cost)
            #expect(viewport.anchor == kept)
        }

        /// #60 A1 step 3: a long reply's segment window belongs to the navigation owner. Paging it makes
        /// the reader the owner and restores a segment anchor; only a window short of the reply's current
        /// end keeps the transcript's bottom from being its end, and following clears every held window.
        @Test @MainActor func segmentPagingIsAnOwnerTransition() throws {
            let reply = UUID()
            let viewport = TranscriptViewport()
            #expect(viewport.segmentWindow(for: reply) == nil)
            let kept = Anchor(messageID: reply, offset: 14, segment: 40)
            viewport.pageSegments(of: reply, to: 30..<41, segmentCount: 52, currentRange: 0..<3, keeping: kept)
            #expect(viewport.readerOwnsViewport && viewport.heldRange == 0..<3)
            #expect(viewport.segmentWindow(for: reply) == 30..<41 && viewport.holdsEarlierSegments(of: reply))
            #expect(viewport.anchor == kept && viewport.request?.target == .anchor(kept))
            viewport.readerMoved(currentRange: 0..<3)
            #expect(viewport.request == nil, "Reader input cancels the segment restore like any other")

            viewport.pageSegments(
                of: reply, to: 40..<52, segmentCount: 52, currentRange: 0..<3,
                keeping: Anchor(messageID: reply, offset: 0, segment: 40))
            #expect(viewport.segmentWindow(for: reply) == 40..<52 && !viewport.holdsEarlierSegments(of: reply))
            #expect(viewport.readerOwnsViewport)
            // The reply streams on: the held window no longer reaches its end, so the transcript's
            // bottom is not the reply's end and settling there must not resume following.
            viewport.recordSegmentCount(55, of: reply)
            #expect(
                viewport.holdsEarlierSegments(of: reply), "A window that reached the end goes stale as the reply grows")
            viewport.recordSegmentCount(3, of: UUID())
            #expect(viewport.segmentWindows.count == 1, "Only held replies record a count")

            // A reply the reader kept by scrolling, not paging, is held the same way.
            let kept2 = UUID()
            viewport.holdSegments(of: kept2, at: 20..<30, segmentCount: 30)
            #expect(viewport.segmentWindow(for: kept2) == 20..<30 && !viewport.holdsEarlierSegments(of: kept2))
            viewport.recordSegmentCount(33, of: kept2)
            #expect(viewport.holdsEarlierSegments(of: kept2), "A kept window goes stale as the reply grows")
            viewport.holdSegments(of: kept2, at: 0..<5, segmentCount: 33)
            #expect(viewport.segmentWindow(for: kept2) == 20..<30, "A held window is not replaced by a kept one")
            viewport.readerSettled(atTrueBottom: true, anchor: nil)
            #expect(viewport.autoFollow && viewport.segmentWindows.isEmpty, "Following shows latest segments again")

            for index in 0...TranscriptViewport.maximumSegmentWindows {
                viewport.pageSegments(of: UUID(), to: 0..<1, segmentCount: 2, currentRange: 0..<3, keeping: kept)
                #expect(viewport.segmentWindows.count <= TranscriptViewport.maximumSegmentWindows, "\(index)")
            }
            viewport.jumpToLatest()
            #expect(viewport.segmentWindows.isEmpty && viewport.autoFollow)
            viewport.holdSegments(of: UUID(), at: 0..<1, segmentCount: 1)
            #expect(viewport.segmentWindows.isEmpty, "While following, no reply is kept")
        }

        /// #78: a reader who scrolls up without paging keeps a streaming reply's shown segments, and
        /// the owner holds them, so newer output below does not let the transcript's bottom count as
        /// the reply's end.
        @Test @MainActor func scrollingUpHoldsAStreamingReplysSegmentsWithTheOwner() async throws {
            let session = ChatSession(effort: .trot, modelID: nil)
            session.messagesLoaded = true
            let reply = ChatMessage(role: .assistant)
            reply.text = (0..<900).map { "Paragraph \($0) of a long reply, with words enough to wrap once or twice." }
                .joined(separator: "\n\n")
            reply.complete = false
            session.messages = [reply]
            let viewport = TranscriptViewport()
            let (window, host) = hostedWindow(session, viewport: viewport)
            defer {
                window.contentView = nil
                window.close()
            }
            func prepared() -> PreparedMarkdownDocument? {
                PreparedMarkdownDocumentCache.shared.document(for: reply.id, revision: reply.textRevision)
            }
            for _ in 0..<150 where prepared()?.window == nil {
                try await Task.sleep(for: .milliseconds(20))
                host.layoutSubtreeIfNeeded()
            }
            try await settle(viewport, host: host)
            let document = try #require(prepared())
            try #require(document.window?.upperBound == document.segments.count, "The latest segments are shown")
            let scroll = try #require(findTranscriptScroll(host))

            // The reader moves up a little, short of the earlier loader.
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - 200))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(viewport, host: host)
            let trace = { viewport.diagnostics.suffix(16) }
            #expect(viewport.readerOwnsViewport, "\(trace())")
            #expect(
                viewport.segmentWindow(for: reply.id) == document.window,
                "The owner holds the kept segments; \(trace())")
            #expect(!viewport.holdsEarlierSegments(of: reply.id), "They reach the reply's end so far")

            // More output arrives below the kept segments.
            reply.text += (900..<1_000).map { "\n\nParagraph \($0), streamed after the reader moved up." }.joined()
            for _ in 0..<150 where !viewport.holdsEarlierSegments(of: reply.id) {
                try await Task.sleep(for: .milliseconds(20))
                host.layoutSubtreeIfNeeded()
            }
            #expect(viewport.holdsEarlierSegments(of: reply.id), "Newer segments are hidden below; \(trace())")
            #expect(viewport.readerOwnsViewport && viewport.segmentWindow(for: reply.id) == document.window)
        }

        /// Paging earlier keeps the reader's view in place: the message at the top of the old window
        /// stays at the same position on screen (within 1 pt), so every pixel below it is unchanged.
        @Test @MainActor func pagingEarlierKeepsTheReadersViewInPlace() async throws {
            let session = distinctSession(count: 120)
            let viewport = TranscriptViewport()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 450), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(
                rootView: ChatTranscriptView(session: session, viewport: viewport)
                    .environment(AppModel.shared).environment(\.colorScheme, .light)
                    .frame(width: 700, height: 450))
            host.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            window.orderFront(nil)
            defer {
                window.contentView = nil
                window.close()
            }
            try await settle(viewport, host: host)
            let scroll = try #require(findTranscriptScroll(host))

            // Reveal the earlier loader. Paging starts from its visibility callback, after this frame.
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            let before = try snapshot(host)
            let windowBefore = viewport.heldRange

            for _ in 0..<100 where viewport.heldRange == windowBefore || viewport.request != nil {
                try await Task.sleep(for: .milliseconds(20))
                host.layoutSubtreeIfNeeded()
            }
            try await settle(viewport, host: host)
            #expect(viewport.heldRange != windowBefore, "The earlier page loaded; \(viewport.diagnostics.suffix(16))")
            #expect(viewport.abandonedRequests == 0)
            let after = try snapshot(host)

            // Below the loader and above the jump button, the view must be identical.
            let scale = CGFloat(before.pixelsHigh) / before.size.height
            let top = Int(90 * scale)
            let bottom = before.pixelsHigh - Int(70 * scale)
            var changed = 0
            for y in stride(from: top, to: bottom, by: 2) {
                for x in stride(from: 0, to: min(before.pixelsWide, after.pixelsWide), by: 2)
                where before.colorAt(x: x, y: y) != after.colorAt(x: x, y: y) {
                    changed += 1
                }
            }
            #expect(
                changed == 0,
                "The reader's view moved while paging earlier: \(changed) pixels; \(viewport.diagnostics.suffix(16))")
        }

        /// #60 A1 step 3: a long reply renders rich as a bounded window of its latest segments, never as
        /// text parts. Paging earlier inside it keeps the reader's segment where it was on screen (every
        /// pixel below it unchanged), and paging later reaches the reply's end again.
        @Test @MainActor func pagingInsideALongReplyKeepsTheReadersViewInPlace() async throws {
            let session = ChatSession(effort: .trot, modelID: nil)
            session.messagesLoaded = true
            let reply = ChatMessage(role: .assistant)
            reply.text = (0..<900).map { "Paragraph \($0) of a long reply, with words enough to wrap once or twice." }
                .joined(separator: "\n\n")
            reply.complete = true
            session.messages = [reply]
            let viewport = TranscriptViewport()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 450), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(
                rootView: ChatTranscriptView(session: session, viewport: viewport)
                    .environment(AppModel.shared).environment(\.colorScheme, .light)
                    .frame(width: 700, height: 450))
            host.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            window.orderFront(nil)
            defer {
                window.contentView = nil
                window.close()
            }
            func prepared() -> PreparedMarkdownDocument? {
                PreparedMarkdownDocumentCache.shared.document(for: reply.id, revision: reply.textRevision)
            }
            for _ in 0..<150 where prepared()?.window == nil {
                try await Task.sleep(for: .milliseconds(20))
                host.layoutSubtreeIfNeeded()
            }
            try await settle(viewport, host: host)
            let document = try #require(prepared())
            let shown = try #require(document.window, "A long reply lays out a window of its segments")
            #expect(shown.upperBound == document.segments.count && shown.lowerBound > 0)
            #expect(document.shownBytes <= ReplyWindow.budget)
            #expect(TranscriptPartsCache.shared.parts(for: "\(reply.id.uuidString):text", source: reply.text) == nil)
            let scroll = try #require(findTranscriptScroll(host))

            // Reveal the reply's earlier loader. Paging starts from its visibility callback.
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            let before = try snapshot(host)
            let commands = viewport.scrollCommands
            // Paging is done when the owner holds an earlier window, the reply has prepared and laid it
            // out, and the owner's restore of the kept segment has ended. Moving up alone already makes
            // the owner hold the shown window, so holding a window is not enough.
            func pagedAndPlaced() -> Bool {
                guard let held = viewport.segmentWindow(for: reply.id), held.lowerBound < shown.lowerBound else {
                    return false
                }
                return prepared()?.window == held && viewport.request == nil
            }
            for _ in 0..<150 where !pagedAndPlaced() {
                try await Task.sleep(for: .milliseconds(20))
                host.layoutSubtreeIfNeeded()
            }
            try await settle(viewport, host: host)
            try #require(
                pagedAndPlaced(), "The earlier segments loaded and were placed; \(viewport.diagnostics.suffix(16))")
            let paged = try #require(viewport.segmentWindow(for: reply.id))
            #expect(paged.lowerBound < shown.lowerBound && paged.contains(shown.lowerBound))
            #expect(viewport.abandonedRequests == 0, "\(viewport.diagnostics.suffix(16))")
            let after = try snapshot(host)

            // Below the loader and message header, and above the jump button, the view is identical.
            let scale = CGFloat(before.pixelsHigh) / before.size.height
            let top = Int(150 * scale)
            let bottom = before.pixelsHigh - Int(70 * scale)
            var changed = 0
            for y in stride(from: top, to: bottom, by: 2) {
                for x in stride(from: 0, to: min(before.pixelsWide, after.pixelsWide), by: 2)
                where before.colorAt(x: x, y: y) != after.colorAt(x: x, y: y) {
                    changed += 1
                }
            }
            let commandsWhilePaging = viewport.scrollCommands - commands
            #expect(
                changed == 0,
                "The reader's view moved while paging the reply: \(changed) pixels, \(commandsWhilePaging) commands; \(viewport.diagnostics.suffix(16))"
            )
            if changed > 0 {
                for (name, image) in [("before", before), ("after", after)] {
                    if let png = image.representation(using: .png, properties: [:]) {
                        Attachment.record(png, named: "paging-reply-\(name).png")
                    }
                }
            }

            // Reading down pages later until the reply's end is shown again.
            for _ in 0..<40 where viewport.holdsEarlierSegments(of: reply.id) {
                let content = try #require(scroll.documentView)
                let end = content.bounds.height - scroll.contentView.bounds.height
                scroll.contentView.scroll(to: NSPoint(x: 0, y: end))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await settle(viewport, host: host)
            }
            #expect(!viewport.holdsEarlierSegments(of: reply.id), "\(viewport.diagnostics.suffix(16))")
            #expect(viewport.abandonedRequests == 0, "\(viewport.diagnostics.suffix(16))")
        }

        /// A reader who takes the viewport cancels a pending programmatic scroll before it runs.
        @Test @MainActor func readerInputCancelsAStaleTargetBeforeItScrolls() async throws {
            let session = distinctSession(count: 60)
            let viewport = TranscriptViewport()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 450), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(
                rootView: ChatTranscriptView(session: session, viewport: viewport)
                    .environment(AppModel.shared).frame(width: 700, height: 450))
            window.contentView = host
            window.orderFront(nil)
            defer {
                window.contentView = nil
                window.close()
            }
            try await settle(viewport, host: host)
            let range = viewport.messageRange(count: session.messages.count, cost: { _ in 0 })
            let commands = viewport.scrollCommands
            viewport.restore(Anchor(messageID: session.messages[range.lowerBound].id, offset: 0))
            viewport.readerMoved(currentRange: range)
            try await Task.sleep(for: .milliseconds(300))
            #expect(viewport.request == nil)
            #expect(viewport.scrollCommands == commands, "A cancelled target must never scroll")
        }

        /// A reader who interrupts an already-issued command owns the next direct move: the cancelled
        /// command claims no offset change, and the viewport stays where the reader put it.
        @Test @MainActor func aDirectMoveAfterAnInterruptedCommandIsTheReaders() async throws {
            let session = distinctSession(count: 60)
            let viewport = TranscriptViewport()
            let (window, host) = hostedWindow(session, viewport: viewport)
            defer {
                window.contentView = nil
                window.close()
            }
            try await settle(viewport, host: host)
            let scroll = try #require(findTranscriptScroll(host))
            let range = viewport.messageRange(count: session.messages.count, cost: { _ in 0 })
            let commands = viewport.scrollCommands
            viewport.restore(Anchor(messageID: session.messages[range.lowerBound].id, offset: 0))
            for _ in 0..<100 where viewport.scrollCommands == commands {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(viewport.scrollCommands > commands, "The command was issued")
            // The reader interrupts it and moves directly before the command's move lands.
            viewport.readerMoved(currentRange: range)
            let target = (scroll.documentView?.bounds.height ?? 0) / 2
            scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(viewport, host: host)
            try await settle(viewport, host: host)
            let trace = viewport.diagnostics.suffix(16)
            #expect(viewport.readerOwnsViewport && viewport.request == nil, "\(trace)")
            #expect(
                abs(scroll.contentView.bounds.minY - target) <= 1,
                "The viewport left the reader's position: \(scroll.contentView.bounds.minY) vs \(target); \(trace)")
        }

        /// A target without a row (missing, removed or never rendering) is abandoned within the bounded
        /// attempts instead of waiting for a layout that never comes; one that arrives in time is shown.
        @Test @MainActor func targetsWithoutARowHaveABoundedLifecycle() async throws {
            let session = distinctSession(count: 61)
            let tool = ChatMessage(role: .tool)
            tool.text = "Tool output"
            tool.complete = true
            session.messages.insert(tool, at: 50)
            let viewport = TranscriptViewport()
            let (window, host) = hostedWindow(session, viewport: viewport)
            defer {
                window.contentView = nil
                window.close()
            }
            try await settle(viewport, host: host)

            func awaitSettled() async throws -> Duration {
                let start = ContinuousClock.now
                for _ in 0..<200 where viewport.request != nil {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(10))
                }
                return ContinuousClock.now - start
            }
            let removed = try #require(session.messages.last)
            for name in ["missing", "non-rendering", "removed"] {
                let abandoned = viewport.abandonedRequests
                var id = UUID()
                if name == "non-rendering" { id = tool.id }
                if name == "removed" {
                    id = removed.id
                    session.messages.removeLast()
                }
                // A removed row's frame goes with its layout, before the target is requested.
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
                viewport.restore(Anchor(messageID: id, offset: 0))
                let elapsed = try await awaitSettled()
                let trace = viewport.diagnostics.suffix(8)
                #expect(viewport.request == nil, "A \(name) target must not wait forever; \(trace)")
                #expect(viewport.abandonedRequests == abandoned + 1, "A \(name) target is abandoned; \(trace)")
                #expect(elapsed < .seconds(1.5), "A \(name) target took \(elapsed); \(trace)")
            }

            // A row that lays out before the deadline is shown, not abandoned.
            let late = ChatMessage(role: .assistant)
            late.text = "A late reply"
            late.complete = true
            let abandoned = viewport.abandonedRequests
            viewport.restore(Anchor(messageID: late.id, offset: 0))
            try await Task.sleep(for: .milliseconds(100))
            session.messages.append(late)
            _ = try await awaitSettled()
            let trace = viewport.diagnostics.suffix(8)
            #expect(viewport.request == nil && viewport.abandonedRequests == abandoned, "\(trace)")
            #expect(viewport.anchor?.messageID == late.id, "\(trace)")
        }

        /// Restoration anchors to a row the held window renders: a non-rendering message gives way to
        /// its nearest row, and a missing one restores no anchor.
        @Test @MainActor func initialRestorationResolvesToARenderedRow() throws {
            let session = distinctSession(count: 60)
            let tool = ChatMessage(role: .tool)
            tool.complete = true
            session.messages.insert(tool, at: 20)
            let resolved = ChatTranscriptView(
                session: session, initiallyFollowing: false, initialVisibleMessageID: tool.id
            ).viewport
            #expect(resolved.anchor?.messageID == session.messages[21].id)
            #expect(resolved.request?.target == .anchor(Anchor(messageID: session.messages[21].id, offset: 0)))
            let missing = ChatTranscriptView(
                session: session, initiallyFollowing: false, initialVisibleMessageID: UUID()
            ).viewport
            #expect(missing.anchor == nil && missing.request == nil && missing.readerOwnsViewport)
        }

        /// Font and width reflow restore the reader's anchor through the executor: each correction is
        /// fulfilled only when the anchor's top is within 1 pt of its offset, and none is abandoned.
        @Test @MainActor func reflowRestoresTheReadersAnchor() async throws {
            let model = AppModel.shared
            let originalFont = model.chatFontSize
            defer { model.chatFontSize = originalFont }
            let session = distinctSession(count: 60)
            let anchorID = session.messages[20].id
            let viewport = TranscriptViewport(
                initiallyFollowing: false,
                initialHeldRange: TranscriptWindow.range(
                    count: session.messages.count, startingAt: 20,
                    cost: { TranscriptWindow.displayCost(session.messages[$0]) }),
                initialAnchor: Anchor(messageID: anchorID, offset: 0))
            let host = NSHostingView(
                rootView: ChatTranscriptView(
                    session: session, initiallyFollowing: false, initialVisibleMessageID: anchorID, viewport: viewport
                ).environment(model))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 450), styleMask: [.titled, .resizable],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer {
                window.contentView = nil
                window.close()
            }
            try await settle(viewport, host: host)
            #expect(viewport.anchor?.messageID == anchorID && viewport.request == nil)
            for (width, font) in [(500.0, 24.0), (900, 11), (700, 14)] {
                model.chatFontSize = font
                window.setContentSize(NSSize(width: width, height: 450))
                try await settle(viewport, host: host)
                #expect(viewport.readerOwnsViewport, "Reflow never hands the viewport to following")
                #expect(viewport.anchor?.messageID == anchorID, "Width \(width), font \(font)")
                #expect(viewport.request == nil && viewport.abandonedRequests == 0, "Width \(width), font \(font)")
            }
        }
    }
}

/// Fixed rows in a SwiftUI scroll view with the transcript's default anchors. Clearing
/// `initialOffsetAnchored` turns the initial-offset anchor off, as the transcript does after its first
/// placement.
@MainActor @Observable private final class ScrollLimitationModel {
    var rows = 200
    var initialOffsetAnchored = true
}

private struct ScrollLimitationProbe: View {
    let model: ScrollLimitationModel
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(0..<model.rows, id: \.self) { index in
                    Text("Row \(index)").frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
                }
            }
        }
        .defaultScrollAnchor(model.initialOffsetAnchored ? .bottom : nil, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .defaultScrollAnchor(.top, for: .sizeChanges)
    }
}

extension AppTests.Bleet {
    /// The SwiftUI limitation behind `TranscriptScrollExecutor` and the transcript's one-time initial
    /// offset (#54 section 2). When the known issue is no longer recorded, revisit both.
    @Suite(.serialized) struct ScrollPositionLimitationTests {
        /// Scrolls fixed rows at the bottom to 5000 without a gesture, as a keyboard, scroller or
        /// AppKit executor move does, then appends one row. Returns where the viewport ends up.
        @MainActor private func offsetAfterGrowth(initialOffsetAnchoredThroughout: Bool) async throws -> CGFloat {
            let model = ScrollLimitationModel()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: ScrollLimitationProbe(model: model).frame(width: 400, height: 400))
            window.contentView = host
            window.orderFront(nil)
            defer {
                window.contentView = nil
                window.close()
            }
            func settle() async throws {
                for _ in 0..<10 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            try await settle()
            let scroll = try #require(findTranscriptScroll(host))
            try #require(scroll.contentView.bounds.minY > 7_000, "The rows start at the bottom")
            if !initialOffsetAnchoredThroughout {
                model.initialOffsetAnchored = false
                try await settle()
            }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 5_000))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle()
            try #require(scroll.contentView.bounds.minY == 5_000)
            model.rows += 1
            try await settle()
            return scroll.contentView.bounds.minY
        }

        /// SwiftUI re-applies the initial bottom offset on a size change after a move without a
        /// gesture, taking a reader who moved by keyboard or scroller to the bottom.
        @Test @MainActor func initialOffsetReappliesAfterAMoveWithoutAGesture() async throws {
            let offset = try await offsetAfterGrowth(initialOffsetAnchoredThroughout: true)
            withKnownIssue("SwiftUI re-applies .defaultScrollAnchor(_:for: .initialOffset) after a non-gesture move") {
                #expect(offset == 5_000, "The viewport moved to \(offset) when one row was appended")
            }
        }

        /// Turning the initial offset off after the first placement keeps the viewport where it was
        /// moved, which is why the transcript does.
        @Test @MainActor func initialOffsetTurnedOffAfterPlacementKeepsTheViewport() async throws {
            let offset = try await offsetAfterGrowth(initialOffsetAnchoredThroughout: false)
            #expect(offset == 5_000, "The viewport moved to \(offset) when one row was appended")
        }
    }
}
