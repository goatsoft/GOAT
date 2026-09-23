import AppKit
import Bleet
import SwiftUI
import Testing

@testable import GOAT

@MainActor private func transcript(_ session: ChatSession) -> some View {
    ChatTranscriptView(session: session).id(session.id)
        .environment(AppModel.shared).frame(width: 700, height: 450)
}

@MainActor private func findView(matching predicate: (NSView) -> Bool, in view: NSView) -> NSView? {
    if predicate(view) { return view }
    for sub in view.subviews {
        if let found = findView(matching: predicate, in: sub) { return found }
    }
    return nil
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
            let host = NSHostingView(rootView: transcript(session))
            window.contentView = host
            window.orderFront(nil)
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

            try await Task.sleep(for: .milliseconds(60))
            #expect(document.bounds.maxY - document.visibleRect.maxY > 500, "Should be scrolled away from bottom")

            // Perform ONE single click on the scroll-to-bottom button at the bottom of host
            let clickPoint = NSPoint(x: host.bounds.midX, y: host.isFlipped ? (host.bounds.height - 24) : 24)
            click(at: clickPoint, in: host, window: window)

            // Wait for scroll to settle at the bottom
            var reachedBottom = false
            for _ in 0..<50 {
                host.layoutSubtreeIfNeeded()
                let distFromBottom = document.bounds.maxY - document.visibleRect.maxY
                if distFromBottom < 80 {
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
                #expect(viewport.autoFollow == false, "Loading final page does NOT re-enable auto-follow or snap to bottom")
            }
            #expect(current.upperBound == session.messages.count, "Reached the latest message")
        }
    }
}
