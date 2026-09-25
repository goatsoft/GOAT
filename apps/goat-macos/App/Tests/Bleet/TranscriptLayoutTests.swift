import AppKit
import Bleet
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
            #expect(document.bounds.maxY - document.visibleRect.maxY > 500, "Should be scrolled away from bottom")
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

            #expect(
                reachedBottom,
                "A single click on the scroll-to-bottom button must bring the viewport to the end of the transcript")
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
            let host = NSHostingView(rootView: transcript(session))
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
            #expect(
                settled != nil,
                "An oversized completed reply must render a tall scrollable document and settle at the bottom")
        }
    }
}
