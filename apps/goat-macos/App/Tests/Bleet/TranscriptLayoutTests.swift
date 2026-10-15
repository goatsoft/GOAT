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

            // Attribution and the visibility observer publish asynchronously. Click only
            // after the real button is available, without bypassing its action.
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                if !viewport.isScrolledToBottom { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(
                !viewport.isScrolledToBottom,
                "Scroll-to-bottom button must be visible; offset \(scroll.contentView.bounds.minY) of \(document.bounds.height), following \(viewport.autoFollow), request \(String(describing: viewport.request)), \(viewport.diagnostics.suffix(16))"
            )
            #expect(
                document.bounds.maxY - document.visibleRect.maxY > 500,
                "Should be scrolled away from bottom; \(viewport.diagnostics.suffix(16))")
            let clickPoint = NSPoint(x: host.bounds.midX, y: host.isFlipped ? (host.bounds.height - 28) : 28)
            click(at: clickPoint, in: host, window: window)

            #expect(viewport.autoFollow, "One click must invoke the bottom action")

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

        /// Regression for PR 66: text above the parts threshold re-splits as it grows, and each part is an
        /// item of its own (ADR-0104), so the parts are all reachable with no control to page between them.
        @Test @MainActor func plainPartsGrowWithTheirSource() async throws {
            let line = String(repeating: "x", count: 99) + "\n"  // 100 bytes
            func source(_ kib: Int) -> String { String(repeating: line, count: kib * 1_024 / 100) }
            let message = ChatMessage(role: .user)
            message.text = source(10)
            message.complete = true
            let texts = TranscriptTexts()
            let answer = texts.answer(for: message)
            #expect(answer.isPlain)
            for _ in 0..<100 where answer.parts?.count != 2 { try await Task.sleep(for: .milliseconds(20)) }
            #expect(answer.parts?.count == 2, "10 KiB is two 8 KiB parts")
            #expect(texts.layout(of: message) == .split(head: false, reasoning: 0, answer: 2, tail: true))

            message.text = source(20)
            answer.prepare()
            for _ in 0..<100 where answer.parts?.count != 3 { try await Task.sleep(for: .milliseconds(20)) }
            #expect(answer.parts?.count == 3, "The parts re-split as the source grows")
            #expect(answer.parts?.joined() == message.text, "The parts hold every byte")
            #expect(texts.layout(of: message) == .split(head: false, reasoning: 0, answer: 3, tail: true))
        }

        /// Issue #60 C0: a reply whose answer and reasoning both pass 8 KiB completes while streaming.
        /// The answer's latest segments and the reasoning's latest part must show, and the transcript
        /// must stay scrollable to its bottom without reselecting the chat.
        @Test @MainActor func oversizedAnswerAndReasoningCompleteIntoAReachableBottom() async throws {
            // Keep the reasoning open at completion, so its segments stay covered (#60 B4 folds it).
            let folds = AppModel.shared.foldsCompletedReasoning
            AppModel.shared.foldsCompletedReasoning = false
            defer { AppModel.shared.foldsCompletedReasoning = folds }
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
            // A reader who opened the reasoning reads all of it.
            ReasoningDisclosureStore.shared.set(.init(isOpen: true), for: assistant.id)
            let viewport = TranscriptViewport()
            let host = NSHostingView(
                rootView: ChatTranscriptView(session: session, viewport: viewport).id(session.id)
                    .environment(AppModel.shared).frame(width: 700, height: 450))
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

            // The answer and the open reasoning both reach their last segments (#60 A1, ADR-0104).
            func shownAnswer() -> String? {
                let text = TranscriptTexts.shared.answer(for: assistant)
                guard let document = text.document, document.isComplete,
                    let last = document.segments.indices.last, document.segments[last].isParsed
                else { return nil }
                return document.segments[last].text
            }
            func shownReasoning() -> String? {
                let reasoning = TranscriptTexts.shared.reasoning(for: assistant)
                guard let thinking = reasoning.thinking, thinking.revision == assistant.thinkingRevision,
                    let last = thinking.segments.indices.last
                else { return nil }
                return thinking.segments[last].text
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
                "Latest text renders and the bottom is reachable; answer \(shownAnswer()?.suffix(12) ?? "none"), reasoning \(shownReasoning()?.suffix(12) ?? "none"), document \(String(describing: findTranscriptScroll(host)?.documentView?.bounds)), visible \(String(describing: findTranscriptScroll(host)?.documentView?.visibleRect)), following \(viewport.autoFollow), request \(String(describing: viewport.request)), \(viewport.diagnostics.suffix(16))"
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

/// Whether the 4x4 device-pixel block at `x`, `y` differs as content that moved would. The lazy stack
/// lays a kept row out at another content offset while the reader sees it in the same place, within a
/// fraction of a point: gradient dithering follows a layer's position in the content, glyphs rasterize
/// at another sub-pixel phase, and edges round to the neighbouring device pixel. Block averages absorb
/// the first two and a one device pixel offset the third. Content moved by a point or more differs.
private func visiblyDiffers(_ before: NSBitmapImageRep, _ after: NSBitmapImageRep, x: Int, y: Int) -> Bool {
    func average(_ image: NSBitmapImageRep, _ top: Int) -> [Int] {
        var sum = [0, 0, 0]
        var pixel = [Int](repeating: 0, count: max(4, image.samplesPerPixel))
        for row in top..<(top + 4) {
            let clamped = min(max(0, row), image.pixelsHigh - 1)
            for column in x..<min(x + 4, image.pixelsWide) {
                image.getPixel(&pixel, atX: column, y: clamped)
                for channel in 0..<3 { sum[channel] += pixel[channel] }
            }
        }
        return sum.map { $0 / 16 }
    }
    let earlier = average(before, y)
    for dy in [0, -1, 1] {
        let shown = average(after, y + dy)
        if zip(earlier, shown).allSatisfy({ abs($0 - $1) <= 40 }) { return false }
    }
    return true
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

/// Waits until no scroll request has been pending for 300 ms, within 5 s. Rows whose Markdown finishes
/// preparing after the first placement change height and correctly issue a restore, so a single
/// moment without a request is not settled. A request that is never fulfilled still fails the caller.
@MainActor private func settle(_ viewport: TranscriptViewport, host: NSView) async throws {
    var quiet = 0
    for _ in 0..<250 where quiet < 15 {
        host.layoutSubtreeIfNeeded()
        quiet = viewport.request == nil ? quiet + 1 : 0
        try await Task.sleep(for: .milliseconds(20))
    }
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
            viewport.readerMoved(anchor: anchor)
            #expect(viewport.request == nil, "Reader input cancels a pending scroll")
            #expect(viewport.readerOwnsViewport && viewport.anchor == anchor)
            viewport.fulfilled(bottom)
            #expect(viewport.request == nil, "A stale completion changes nothing")

            viewport.contentChanged()
            // The lazy stack keeps the reader's rows in place, so content changes issue nothing (ADR-0099).
            #expect(viewport.request == nil, "Content changes never move a reader who owns the viewport")
            viewport.readerSettled(atTrueBottom: false, anchor: nil)
            #expect(viewport.readerOwnsViewport)
            viewport.readerSettled(atTrueBottom: true, anchor: nil)
            #expect(viewport.autoFollow && viewport.anchor == nil)
        }

        @Test @MainActor func aReplacedRequestIgnoresItsCompletion() throws {
            let viewport = TranscriptViewport(
                initiallyFollowing: false, initialAnchor: Anchor(messageID: UUID(), offset: 0))
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

        /// History loads put the reader's anchor back, and following keeps following. Removing the anchor's
        /// message (compaction) continues the reader at the given surviving message; a surviving anchor is
        /// kept as it was.
        @Test @MainActor func historyLoadsAndRemovalKeepTheReadersPlace() throws {
            let following = TranscriptViewport()
            following.historyRebased()
            #expect(following.autoFollow && following.request?.target == .bottom)

            let viewport = TranscriptViewport()
            let anchor = Anchor(messageID: UUID(), offset: 30, segment: 4)
            viewport.readerMoved(anchor: anchor)
            viewport.historyRebased()
            #expect(viewport.readerOwnsViewport && viewport.request?.target == .anchor(anchor))

            let fallback = UUID()
            viewport.messagesRemoved(anchorSurvives: true, fallback: fallback)
            #expect(viewport.anchor == anchor, "A surviving anchor is kept")
            viewport.messagesRemoved(anchorSurvives: false, fallback: fallback)
            #expect(viewport.anchor == Anchor(messageID: fallback, offset: 0))
            #expect(viewport.request?.target == .anchor(Anchor(messageID: fallback, offset: 0)))
        }

        /// ADR-0104: a message's items are measured under keys that all belong to it.
        @Test @MainActor func itemKeysBelongToTheirMessage() throws {
            let reply = UUID()
            let reasoning = TranscriptSegmentOwner.reasoning(of: reply)
            let tail = TranscriptSegmentOwner.tail(of: reply)
            #expect(reasoning != reply && tail != reply && reasoning != tail)
            #expect(TranscriptSegmentOwner.reasoning(of: reasoning) == reply)
            #expect(TranscriptSegmentOwner.tail(of: tail) == reply)
            for key in [reply, reasoning, tail] { #expect(TranscriptSegmentOwner.key(key, belongsTo: reply)) }
            #expect(!TranscriptSegmentOwner.key(UUID(), belongsTo: reply))
        }

        /// ADR-0104: short messages are one item; a long reply is a head, its open reasoning's segments, its
        /// answer's segments and a tail, so the lazy stack lays out only the segments near the viewport.
        /// Dense reasoning (a code block every few lines) is a thinking segment per block: its items pack
        /// consecutive segments to about one segment's target, tile them in order, and keep earlier groups
        /// as the reasoning grows.
        @Test func reasoningItemsPackSegmentsByBytes() {
            func segment(_ index: Int, _ bytes: Int) -> ThinkingSegment {
                ThinkingSegment(
                    index: index, text: String(repeating: "x", count: bytes), language: nil, continuesPrevious: false,
                    bytes: bytes)
            }
            let segments = ChunkedList((0..<1_000).map { segment($0, 100) })
            let groups = ReasoningText.groups(segments, targetBytes: 1_000)
            #expect(groups.count == 100)
            #expect(groups.first == 0..<10 && groups.last == 990..<1_000)
            #expect(zip(groups, groups.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
            let grown = ReasoningText.groups(
                ChunkedList((0..<1_005).map { segment($0, 100) }), targetBytes: 1_000)
            #expect(Array(grown.prefix(100)) == groups && grown.last == 1_000..<1_005)
            #expect(ReasoningText.groups(ChunkedList([ThinkingSegment]()), targetBytes: 1_000).isEmpty)
        }

        /// A stream is prepared every 120 ms, and every 400 ms only while it outpaces reading.
        @Test func veryFastStreamsAreSampledLessOften() {
            #expect(StreamSampling.interval(grewBy: 0) == .milliseconds(120))
            #expect(StreamSampling.interval(grewBy: StreamSampling.readableBytes) == .milliseconds(120))
            #expect(StreamSampling.interval(grewBy: StreamSampling.readableBytes + 1) == .milliseconds(400))
        }

        /// Only the reply still arriving carries the caret, and it goes once that reply completes or the
        /// session stops streaming: an earlier reply, the user's message and reasoning never carry it.
        @Test @MainActor func onlyTheArrivingReplyCarriesTheCaret() {
            let session = ChatSession(effort: .trot, modelID: nil)
            session.messagesLoaded = true
            let earlier = ChatMessage(role: .assistant)
            earlier.text = "Done."
            earlier.complete = true
            let question = ChatMessage(role: .user)
            question.text = "And now?"
            let reply = ChatMessage(role: .assistant)
            reply.thinking = "Working it out now."
            reply.text = "Here it comes"
            session.messages = [earlier, question, reply]
            #expect(ChatTranscriptView.streamingReplyID(in: session) == nil, "Nothing streams")
            #expect(!AnswerPiece.showsCaret(on: reply, streamingReplyID: nil))

            session.isStreaming = true
            let streaming = ChatTranscriptView.streamingReplyID(in: session)
            #expect(streaming == reply.id)
            #expect(AnswerPiece.showsCaret(on: reply, streamingReplyID: streaming))
            #expect(!AnswerPiece.showsCaret(on: earlier, streamingReplyID: streaming))
            #expect(!AnswerPiece.showsCaret(on: question, streamingReplyID: streaming))

            // The reply completes before the session's stream closes: the caret goes with it.
            reply.complete = true
            #expect(!AnswerPiece.showsCaret(on: reply, streamingReplyID: streaming))
            session.isStreaming = false
            #expect(ChatTranscriptView.streamingReplyID(in: session) == nil)
        }

        @Test @MainActor func longRepliesSplitIntoItemsAndShortOnesStayWhole() async throws {
            let folds = AppModel.shared.foldsCompletedReasoning
            AppModel.shared.foldsCompletedReasoning = true
            defer { AppModel.shared.foldsCompletedReasoning = folds }
            let user = ChatMessage(role: .user)
            user.text = "A question."
            user.complete = true
            let short = ChatMessage(role: .assistant)
            short.text = "A short answer."
            short.complete = true
            let long = ChatMessage(role: .assistant)
            long.appendStream(
                text: (0..<900).map { "Paragraph \($0) of a long reply, with words enough to wrap." }
                    .joined(separator: "\n\n"),
                thinking: (0..<900).map { "Reasoning step \($0), with words enough to wrap." }
                    .joined(separator: "\n\n"))
            long.complete = true
            let texts = TranscriptTexts()
            let rows = TranscriptActivity.rows([user, short, long][...])
            for _ in 0..<200 where (texts.answer(for: long).document?.segments.count ?? 0) < 2 {
                try await Task.sleep(for: .milliseconds(20))
            }
            let segments = try #require(texts.answer(for: long).document?.segments.count)
            #expect(segments > 5)
            // Folded reasoning: a head (its "Thought" line), the answer's segments and a tail.
            var parts = TranscriptItem.items(for: rows, texts: texts).filter { $0.message === long }.map(\.part)
            #expect(parts == [.head] + (0..<segments).map { TranscriptItem.Part.answer($0) } + [.tail])
            #expect(
                TranscriptItem.items(for: rows, texts: texts).filter { $0.message !== long }.map(\.part) == [
                    .whole, .whole,
                ])

            // Open reasoning adds its items: thinking segments packed to about one segment's target each.
            ReasoningDisclosureStore.shared.set(.init(isOpen: true), for: long.id)
            defer { ReasoningDisclosureStore.shared.set(.init(isOpen: false), for: long.id) }
            _ = texts.layout(of: long)
            for _ in 0..<200 where (texts.reasoning(for: long).thinking?.segments.count ?? 0) < 2 {
                try await Task.sleep(for: .milliseconds(20))
            }
            let thinking = try #require(texts.reasoning(for: long).thinking)
            let reasoning = texts.reasoning(for: long).groups.count
            #expect(reasoning > 1 && reasoning < thinking.segments.count, "Segments are packed into items")
            parts = TranscriptItem.items(for: rows, texts: texts).filter { $0.message === long }.map(\.part)
            #expect(
                parts == [.head] + (0..<reasoning).map { TranscriptItem.Part.reasoning($0) }
                    + (0..<segments).map { TranscriptItem.Part.answer($0) } + [.tail])
        }

        /// #78: a reader who scrolls up while a long reply streams stays where they are as output arrives
        /// below, and stays the owner (ADR-0104).
        @Test @MainActor func aReaderAboveAStreamingReplyStaysWhereTheyAre() async throws {
            let session = ChatSession(effort: .trot, modelID: nil)
            session.messagesLoaded = true
            let reply = ChatMessage(role: .assistant)
            reply.text = (0..<900).map { "Paragraph \($0) of a long reply, with words enough to wrap once or twice." }
                .joined(separator: "\n\n")
            reply.complete = false
            session.messages = [reply]
            session.isStreaming = true
            defer { session.isStreaming = false }
            let viewport = TranscriptViewport()
            let (window, host) = hostedWindow(session, viewport: viewport)
            defer {
                window.contentView = nil
                window.close()
            }
            for _ in 0..<150 where (TranscriptTexts.shared.answer(for: reply).document?.segments.count ?? 0) < 2 {
                try await Task.sleep(for: .milliseconds(20))
                host.layoutSubtreeIfNeeded()
            }
            try await settle(viewport, host: host)
            let scroll = try #require(findTranscriptScroll(host))

            // The reader moves up a few screens.
            let up = min(1_500, scroll.contentView.bounds.minY / 2)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - up))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(viewport, host: host)
            let trace = { viewport.diagnostics.suffix(16) }
            #expect(viewport.readerOwnsViewport, "\(trace())")
            let anchor = try #require(viewport.anchor, "\(trace())")
            let offset = scroll.contentView.bounds.minY

            // More output arrives below the reader.
            for batch in 0..<4 {
                reply.text += (0..<40).map { "\n\nParagraph \(900 + batch * 40 + $0), streamed below the reader." }
                    .joined()
                try await Task.sleep(for: .milliseconds(200))
                host.layoutSubtreeIfNeeded()
            }
            try await settle(viewport, host: host)
            #expect(viewport.readerOwnsViewport && viewport.anchor == anchor, "\(trace())")
            #expect(abs(scroll.contentView.bounds.minY - offset) <= 2, "The reader's view moved; \(trace())")
            #expect(viewport.abandonedRequests == 0, "\(trace())")
        }

        /// ADR-0104: every loaded message is in the one lazy stack. Scrolling to the top shows the first
        /// message, with nothing loading or paging, and the view stays put once there.
        @Test @MainActor func reachingTheTopShowsTheFirstMessageWithoutPaging() async throws {
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
            for _ in 0..<20 where scroll.contentView.bounds.minY > 1 {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await settle(viewport, host: host)
            }
            let trace = { viewport.diagnostics.suffix(16) }
            #expect(scroll.contentView.bounds.minY <= 1, "\(trace())")
            #expect(viewport.anchor?.messageID == session.messages[0].id, "The first message is shown; \(trace())")
            let before = try snapshot(host)
            try await Task.sleep(for: .milliseconds(500))
            try await settle(viewport, host: host)
            let after = try snapshot(host)
            var changed = 0
            for y in stride(from: 0, to: before.pixelsHigh - 4, by: 4) {
                for x in stride(from: 0, to: min(before.pixelsWide, after.pixelsWide) - 4, by: 8)
                where visiblyDiffers(before, after, x: x, y: y) {
                    changed += 1
                }
            }
            #expect(changed <= 4, "The view changed at the top: \(changed) blocks; \(trace())")
            #expect(viewport.abandonedRequests == 0, "\(trace())")
        }

        /// ADR-0104: a long reply scrolls virtually, segment by segment, from its first line to its last,
        /// with no window and no control to page. Its segments prepare as they come into view.
        @Test @MainActor func aLongReplyScrollsVirtuallyToBothEnds() async throws {
            let session = ChatSession(effort: .trot, modelID: nil)
            session.messagesLoaded = true
            let reply = ChatMessage(role: .assistant)
            reply.text = (0..<900).map { "Paragraph \($0) of a long reply, with words enough to wrap once or twice." }
                .joined(separator: "\n\n")
            reply.complete = true
            session.messages = [reply]
            try await scrollsToBothEnds(session, key: reply.id) {
                TranscriptTexts.shared.answer(for: reply).document?.segments.count ?? 0
            }
            #expect(TranscriptPartsCache.shared.parts(for: "\(reply.id.uuidString):text", source: reply.text) == nil)
        }

        /// ADR-0104: open reasoning scrolls virtually the same way, under its own key.
        @Test @MainActor func longReasoningScrollsVirtuallyToBothEnds() async throws {
            let session = ChatSession(effort: .trot, modelID: nil)
            session.messagesLoaded = true
            let reply = ChatMessage(role: .assistant)
            reply.appendStream(
                text: "The answer follows the reasoning.",
                thinking: (0..<900).map { "Reasoning step \($0), with words enough to wrap once or twice." }
                    .joined(separator: "\n\n"))
            reply.complete = true
            // A reader who opened the reasoning reads all of it.
            ReasoningDisclosureStore.shared.set(.init(isOpen: true), for: reply.id)
            session.messages = [reply]
            try await scrollsToBothEnds(session, key: TranscriptSegmentOwner.reasoning(of: reply.id)) {
                TranscriptTexts.shared.reasoning(for: reply).groups.count
            }
        }

        /// Scrolls `session`'s only reply from its end to its top and back, checking that the reader
        /// reaches its first and last segments (measured under `key`) and that nothing is abandoned.
        @MainActor private func scrollsToBothEnds(
            _ session: ChatSession, key: UUID, segments: @escaping @MainActor () -> Int
        ) async throws {
            let viewport = TranscriptViewport()
            let (window, host) = hostedWindow(session, viewport: viewport)
            defer {
                window.contentView = nil
                window.close()
            }
            for _ in 0..<200 where segments() < 2 {
                try await Task.sleep(for: .milliseconds(20))
                host.layoutSubtreeIfNeeded()
            }
            try #require(segments() > 5, "A long text is several segments")
            try await settle(viewport, host: host)
            let scroll = try #require(findTranscriptScroll(host))
            let trace = { viewport.diagnostics.suffix(16) }
            for _ in 0..<40 where scroll.contentView.bounds.minY > 1 {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, scroll.contentView.bounds.minY - 2_000)))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await settle(viewport, host: host)
            }
            #expect(scroll.contentView.bounds.minY <= 1, "The top is reachable; \(trace())")
            // The lazy stack lays the top out over its next updates; it must not stay blank. The reader stays
            // at the top, which records where they are once something is laid out there.
            for _ in 0..<50 where viewport.anchor == nil {
                try await Task.sleep(for: .milliseconds(20))
                for y: CGFloat in [4, 0] {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    try await settle(viewport, host: host)
                }
            }
            let top = try #require(viewport.anchor, "\(trace())")
            // The reply's first item: its head, its first reasoning segment (the head is a short row above it
            // whose frame the stack may still be resolving) or, with no reasoning, its first answer segment.
            #expect(
                TranscriptSegmentOwner.key(top.messageID, belongsTo: session.messages[0].id)
                    && top.messageID != TranscriptSegmentOwner.tail(of: session.messages[0].id)
                    && (top.segment ?? 0) == 0, "The reply's first item; \(trace())")

            for _ in 0..<60 {
                let content = try #require(scroll.documentView)
                let end = content.bounds.height - scroll.contentView.bounds.height
                if end - scroll.contentView.bounds.minY <= 1 { break }
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(end, scroll.contentView.bounds.minY + 2_000)))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await settle(viewport, host: host)
            }
            let content = try #require(scroll.documentView)
            #expect(
                content.bounds.height - scroll.contentView.bounds.maxY <= 1,
                "The end is reachable; \(trace())")
            #expect(viewport.abandonedRequests == 0, "\(trace())")
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
            let commands = viewport.scrollCommands
            viewport.restore(Anchor(messageID: session.messages[0].id, offset: 0))
            viewport.readerMoved()
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
            let commands = viewport.scrollCommands
            viewport.restore(Anchor(messageID: session.messages[0].id, offset: 0))
            for _ in 0..<100 where viewport.scrollCommands == commands {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(viewport.scrollCommands > commands, "The command was issued")
            // The reader interrupts it and moves directly before the command's move lands.
            viewport.readerMoved()
            let target = (scroll.documentView?.bounds.height ?? 0) / 2
            scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(viewport, host: host)
            try await settle(viewport, host: host)
            let trace = viewport.diagnostics.suffix(16)
            #expect(viewport.readerOwnsViewport && viewport.request == nil, "\(trace)")
            // The lazy stack keeps the reader's rows in place as estimates above them resolve, which moves
            // the offset by a few points; the failure this guards against moves it back to the command's
            // target, thousands of points away.
            #expect(
                abs(scroll.contentView.bounds.minY - target) <= 8,
                "The viewport left the reader's position: \(scroll.contentView.bounds.minY) vs \(target); \(trace)")
        }

        /// The executor's last-resort SwiftUI scroll lands as a move nothing recorded. Only that move is the
        /// executor's: it is claimed even when the content changes size with it, and a later keyboard or
        /// direct move is the reader's. Reader input, an ended request and expiry all retire it.
        @Test @MainActor func aProxyLandingClaimsOnlyItsOwnMove() {
            let landing = ProxyLanding(request: 7)
            // Lands in an update that also changes the content's height.
            var resolved = ProxyLanding.resolve(landing, moved: true, cause: .other, followedInput: false, pending: 7)
            #expect(resolved.landed && resolved.remaining == nil)
            // The next direct move, with no input event as in a test or an accessibility client, is not its.
            resolved = ProxyLanding.resolve(
                resolved.remaining, moved: true, cause: .other, followedInput: false, pending: 7)
            #expect(!resolved.landed)
            // The executor's own moves and unmoved reports leave it expected.
            resolved = ProxyLanding.resolve(landing, moved: true, cause: .executor, followedInput: false, pending: 7)
            #expect(!resolved.landed && resolved.remaining == landing)
            resolved = ProxyLanding.resolve(landing, moved: false, cause: nil, followedInput: false, pending: 7)
            #expect(!resolved.landed && resolved.remaining == landing)
            // Confirmed reader input always wins, and retires it.
            resolved = ProxyLanding.resolve(landing, moved: true, cause: .other, followedInput: true, pending: 7)
            #expect(!resolved.landed && resolved.remaining == nil)
            // Its request was fulfilled, abandoned or replaced.
            for pending in [nil, 8] as [UInt64?] {
                resolved = ProxyLanding.resolve(
                    landing, moved: true, cause: .other, followedInput: false, pending: pending)
                #expect(!resolved.landed && resolved.remaining == nil)
            }
            // A landing that never came does not claim a move a second later.
            resolved = ProxyLanding.resolve(
                landing, moved: true, cause: .other, followedInput: false, pending: 7, now: .now + .seconds(2))
            #expect(!resolved.landed && resolved.remaining == nil)
            // A rescue serves no request: its landing is the executor's whatever is pending.
            resolved = ProxyLanding.resolve(
                ProxyLanding(request: nil), moved: true, cause: .other, followedInput: false, pending: 3)
            #expect(resolved.landed)
        }

        /// The executor's two-step nudges (laying out the content, keeping the viewport inside content that
        /// shrank) make their second move on a later turn. A reader's move in between wins: the second move
        /// is dropped, and so is one whose purpose ended or whose scroll view was replaced. A move that is
        /// only the lazy stack shifting its offset (not attributed to the reader) leaves the return to run.
        @Test @MainActor func aMoveBetweenANudgesTwoStepsKeepsTheReadersPosition() async throws {
            final class Document: NSView { override var isFlipped: Bool { true } }
            func scrollView() -> NSScrollView {
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
                scroll.documentView = Document(frame: NSRect(x: 0, y: 0, width: 400, height: 5_000))
                return scroll
            }
            let scroll = scrollView()
            let executor = TranscriptScrollExecutor()
            executor.attach(scroll)
            defer { executor.detach() }
            var offset: CGFloat { scroll.contentView.bounds.minY }

            // Uninterrupted, the nudge returns to where it started.
            executor.scroll(toY: 1_000)
            executor.layoutContent { true }
            #expect(offset == 999)
            try await Task.sleep(for: .milliseconds(60))
            #expect(offset == 1_000)

            // The reader moves between the two steps: their position stands. The transcript attributes a
            // move without an input event before the second step; here the reader's move says so.
            final class Moved { var value = false }
            let readerMoved = Moved()
            executor.layoutContent { !readerMoved.value }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 1_600))
            scroll.reflectScrolledClipView(scroll.contentView)
            readerMoved.value = true
            try await Task.sleep(for: .milliseconds(60))
            #expect(offset == 1_600, "The nudge's return overrode the reader's move")

            // A move nothing attributes to the reader (the lazy stack's own shift) does not stop the return.
            executor.layoutContent { true }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 1_610))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(60))
            #expect(offset == 1_600, "The return runs after a layout shift")

            // The request it served ended: no second move, and its follow-up never runs.
            var followedUp = false
            executor.nudge(to: 2_000, thenTo: 2_001, while: { false }) { followedUp = true }
            try await Task.sleep(for: .milliseconds(60))
            #expect(offset == 2_000 && !followedUp)

            // Reattached to another scroll view: the old one is never moved again.
            executor.nudge(to: 2_500, thenTo: 2_501, while: { true })
            let replacement = scrollView()
            executor.attach(replacement)
            try await Task.sleep(for: .milliseconds(60))
            #expect(offset == 2_500)
            #expect(replacement.contentView.bounds.minY == 0)
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

        /// Restoration anchors to a message that renders: a non-rendering message gives way to
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
                initiallyFollowing: false, initialAnchor: Anchor(messageID: anchorID, offset: 0))
            let host = NSHostingView(
                rootView: ChatTranscriptView(
                    session: session, initiallyFollowing: false, initialVisibleMessageID: anchorID, viewport: viewport
                ).environment(model))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 450), styleMask: [.titled, .resizable],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            // Reflow receives a viewport from app chrome. A bare hosting root can instead
            // impose content-derived window constraints while the anchor is being placed.
            host.sizingOptions = []
            let container = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
            host.frame = container.bounds
            host.autoresizingMask = [.width, .height]
            container.addSubview(host)
            window.contentView = container
            window.orderFront(nil)
            defer {
                window.contentView = nil
                window.close()
            }
            try await settle(viewport, host: host)
            #expect(
                viewport.anchor?.messageID == anchorID && viewport.request == nil,
                "Initial reflow restoration: \(viewport.diagnostics.suffix(20))")
            #expect(abs(host.bounds.width - 700) <= 1 && abs(host.bounds.height - 450) <= 1)
            for (width, font) in [(500.0, 24.0), (900, 11), (700, 14)] {
                model.chatFontSize = font
                window.setContentSize(NSSize(width: width, height: 450))
                try await settle(viewport, host: host)
                #expect(
                    abs(host.bounds.width - width) <= 1 && abs(host.bounds.height - 450) <= 1,
                    "Requested viewport \(width) × 450, actual \(host.bounds)")
                #expect(viewport.readerOwnsViewport, "Reflow never hands the viewport to following")
                #expect(
                    viewport.anchor?.messageID == anchorID,
                    "Width \(width), font \(font): \(viewport.diagnostics.suffix(20))")
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

extension AppTests.Bleet {
    /// #60 B4: reasoning is visible while it streams and folds to one line after completion, unless
    /// the reader chose otherwise, turned folding off, or owns the viewport.
    @Suite(.serialized) struct ReasoningFoldTests {
        @MainActor private func reply() -> ChatMessage {
            let message = ChatMessage(role: .assistant)
            message.appendStream(
                text: "The answer paragraph.",
                thinking: (0..<8).map { "Reasoning line \($0) considers the question." }.joined(separator: "\n"))
            return message
        }

        @MainActor private func mounted(_ message: ChatMessage, viewport: TranscriptViewport? = nil) async throws
            -> (NSWindow, NSHostingView<AnyView>)
        {
            let host = NSHostingView(
                rootView: AnyView(
                    MessageView(message: message, isLast: true, projectID: nil)
                        .environment(\.transcriptViewport, viewport)
                        .frame(width: 600).environment(AppModel.shared)))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            return (window, host)
        }

        @MainActor private func completeAndMeasure(_ message: ChatMessage, _ host: NSView) async throws -> CGFloat {
            message.complete = true
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }

        @Test @MainActor func completedReasoningFoldsWhileTheTranscriptFollows() async throws {
            let message = reply()
            let (window, host) = try await mounted(message, viewport: TranscriptViewport())
            defer { window.close() }
            let streaming = host.fittingSize.height
            let completed = try await completeAndMeasure(message, host)
            #expect(completed < streaming - 60, "The reasoning folds to one line: \(streaming) -> \(completed) pt")
            #expect(ReasoningDisclosureStore.shared.choice(for: message.id) == nil, "Folding is not a user choice")
        }

        @Test @MainActor func aReaderWhoOwnsTheViewportKeepsReasoningOpen() async throws {
            let message = reply()
            let (window, host) = try await mounted(message, viewport: TranscriptViewport(initiallyFollowing: false))
            defer { window.close() }
            let streaming = host.fittingSize.height
            let completed = try await completeAndMeasure(message, host)
            #expect(completed == streaming, "Completion must not move a reader's content: \(streaming) -> \(completed)")
        }

        @Test @MainActor func turningFoldingOffKeepsReasoningOpen() async throws {
            let folds = AppModel.shared.foldsCompletedReasoning
            AppModel.shared.foldsCompletedReasoning = false
            defer { AppModel.shared.foldsCompletedReasoning = folds }
            let message = reply()
            let (window, host) = try await mounted(message, viewport: TranscriptViewport())
            defer { window.close() }
            let streaming = host.fittingSize.height
            #expect(try await completeAndMeasure(message, host) == streaming)
        }

        @Test @MainActor func aRememberedChoiceSurvivesRemounting() async throws {
            let message = reply()
            message.complete = true
            let (foldedWindow, folded) = try await mounted(message)
            let foldedHeight = folded.fittingSize.height
            foldedWindow.close()

            ReasoningDisclosureStore.shared.set(.init(isOpen: true), for: message.id)
            let (openWindow, open) = try await mounted(message)
            defer { openWindow.close() }
            #expect(open.fittingSize.height > foldedHeight + 60, "The reopened reasoning stays open when remounted")
        }

        @Test @MainActor func choicesAreBounded() {
            let store = ReasoningDisclosureStore(limit: 2)
            let ids = (0..<3).map { _ in UUID() }
            for id in ids { store.set(.init(isOpen: true), for: id) }
            #expect(store.choice(for: ids[0]) == nil)
            #expect(store.choice(for: ids[2])?.isOpen == true)
        }
    }
}
