import AppKit
import Bleet
import MarkdownUI
import Observation
import Persistence
import SwiftUI
import Testing
import XCTest

@testable import GOAT

/// Extreme wheel deltas can bounce the viewport outside the document until AppKit settles.
@MainActor private func waitForScrollToSettle(_ scroll: NSScrollView) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    var previous: NSRect?
    var stableSamples = 0
    while clock.now < deadline {
        let bounds = scroll.contentView.bounds
        let constrained = scroll.contentView.constrainBoundsRect(bounds)
        if bounds == previous && abs(bounds.minY - constrained.minY) < 1 {
            stableSamples += 1
            if stableSamples == 3 { return }
        } else {
            stableSamples = 0
        }
        previous = bounds
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("Native scrolling did not settle within two seconds: \(scroll.contentView.bounds)")
}

/// Keep the window's size owner separate from SwiftUI's changing ideal content size.
/// In CI the direct hosting root contracted a requested 980 pt viewport to 65 pt on reflow,
/// despite sizingOptions being empty. Production receives its viewport from surrounding chrome.
@MainActor private func installReflowHost(_ host: NSView, in window: NSWindow) {
    let viewport = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
    host.frame = viewport.bounds
    host.autoresizingMask = [.width, .height]
    viewport.addSubview(host)
    window.contentView = viewport
}

@MainActor private func reflowScroll(_ view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    return view.subviews.lazy.compactMap(reflowScroll).first
}

@MainActor private func scrollWheel(_ scroll: NSScrollView, delta: Int) async throws {
    for (phase, amount) in [(NSEvent.Phase.began, delta), (.ended, 0)] {
        let cgEvent = try #require(
            CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(amount), wheel2: 0, wheel3: 0)
        )
        cgEvent.flags = []
        cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        scroll.scrollWheel(with: try #require(NSEvent(cgEvent: cgEvent)))
        try await Task.sleep(for: .milliseconds(20))
    }
}
extension AppTests.Bleet {
    @Suite struct TranscriptReflowTests {

        @Test @MainActor func transcriptRetainsVisibleContentAcrossFontAndWidthReflow() async throws {
            let model = AppModel.shared
            let originalFont = model.chatFontSize
            defer { model.chatFontSize = originalFont }
            let session = ChatSession(effort: .trot, modelID: nil)
            session.messagesLoaded = true
            session.messages = (0..<80).map { index in
                let message = ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant)
                message.text =
                    "## Reflow marker \(index)\n\n"
                    + String(
                        repeating:
                            "A visible transcript paragraph with **bold words** and a [local link](http://localhost).\n\n",
                        count: 3 + index % 9)
                message.complete = true
                return message
            }
            let window = NSWindow(
                contentRect: NSRect(x: 80, y: 80, width: 760, height: 520), styleMask: [.titled, .resizable],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let navigation = TranscriptViewport()
            let host = NSHostingView(
                rootView: ChatTranscriptView(session: session, viewport: navigation).environment(model)
                    .environment(\.colorScheme, .light)
                    .background(
                        Color.white
                    ).foregroundStyle(
                        .black))
            host.appearance = NSAppearance(named: .aqua)
            // The fixture owns the viewport dimensions. A bare root NSHostingView otherwise
            // exports content-derived min/ideal/max sizes to the window while Markdown reflows.
            // In the app the transcript receives its width from the surrounding chat layout.
            host.sizingOptions = []
            installReflowHost(host, in: window)
            // Exercise a displayed window: native scroll settling and display-cycle layout
            // are suspended differently for a hidden hosting view.
            window.orderFront(nil)
            defer {
                window.contentView = nil
                window.close()
            }
            try await Task.sleep(for: .milliseconds(500))
            let scroll = try #require(reflowScroll(host))
            for (width, font) in [(760.0, 14.0), (440, 28), (980, 11), (500, 24), (760, 14)] {
                model.chatFontSize = font
                window.setContentSize(NSSize(width: width, height: 520))
                try await Task.sleep(for: .milliseconds(300))
                for delta in [1_000_000, -1_500, -1_000_000, 800, -600] {
                    // Exercise the native wheel path, including its bounds constraints and scroll
                    // phases. Direct clip-view offsets bypass these and can land past an estimated end.
                    try await scrollWheel(scroll, delta: delta)
                    try await waitForScrollToSettle(scroll)
                    host.layoutSubtreeIfNeeded()
                    #expect(
                        abs(host.bounds.width - width) <= 1,
                        "The test window must retain its requested width: requested \(width), host \(host.bounds)")
                    #expect(
                        abs(scroll.frame.width - host.bounds.width) <= 1,
                        "The transcript must fill its host: scroll \(scroll.frame), host \(host.bounds)")
                    let viewport = host
                    let bitmap = try #require(viewport.bitmapImageRepForCachingDisplay(in: viewport.bounds))
                    viewport.cacheDisplay(in: viewport.bounds, to: bitmap)
                    var ink = 0
                    for y in stride(from: 10, to: bitmap.pixelsHigh - 10, by: 3) {
                        for x in stride(from: 20, to: bitmap.pixelsWide - 20, by: 3) {
                            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                                color.alphaComponent > 0.9, color.redComponent < 0.6, color.greenComponent < 0.6,
                                color.blueComponent < 0.6
                            {
                                ink += 1
                            }
                        }
                    }
                    let document = String(describing: scroll.documentView?.frame)
                    let clip = "clip \(scroll.contentView.bounds), document \(document)"
                    let owner = "held \(String(describing: navigation.heldRange)), following \(navigation.autoFollow)"
                    let recent = Array(navigation.diagnostics.suffix(10))
                    let trace = "request \(String(describing: navigation.request)), \(recent)"
                    let hostGeometry =
                        "host \(host.frame), window \(window.frame), min \(window.contentMinSize), max \(window.contentMaxSize)"
                    let state = "\(clip), \(hostGeometry), \(owner), \(trace)"
                    let context = "width \(width), font \(font), wheel \(delta); ink=\(ink)"
                    if ink <= 100 {
                        // How long the lazy stack takes to show the rows there, for diagnosis.
                        let started = ContinuousClock.now
                        var recovered: Duration?
                        for _ in 0..<100 {
                            try await Task.sleep(for: .milliseconds(20))
                            host.layoutSubtreeIfNeeded()
                            if reflowInk(host) > 100 {
                                recovered = started.duration(to: .now)
                                break
                            }
                        }
                        print("REFLOW_RECOVERY \(context) after \(recovered.map { "\($0)" } ?? "none in 2 s")")
                        if recovered == nil, let directory = ProcessInfo.processInfo.environment["GOAT_TEST_SNAPSHOT_DIR"] {
                            try? bitmap.representation(using: .png, properties: [:])?.write(
                                to: URL(fileURLWithPath: directory).appendingPathComponent(
                                    "reflow-\(Int(width))-\(Int(font))-\(delta).png"))
                        }
                    }
                    #expect(ink > 100, "Viewport must contain visible text after \(context); \(state)")

                }
            }
        }

        @Test @MainActor func directHostingRootKeepsTheProductionMinimumDuringReflow() async throws {
            let model = AppModel.shared
            let originalFont = model.chatFontSize
            defer { model.chatFontSize = originalFont }
            let session = ChatSession(effort: .trot, modelID: nil)
            session.messagesLoaded = true
            session.messages = (0..<12).map { index in
                let message = ChatMessage(role: .assistant)
                message.text = "## Direct root \(index)\n\n" + String(repeating: "Reflow text. ", count: 80)
                message.complete = true
                return message
            }
            let window = NSWindow(
                contentRect: NSRect(x: 80, y: 80, width: 980, height: 600),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            // GOATApp's WindowGroup applies these exact minimum dimensions around ContentView.
            // Keep a direct hosting root covered separately from the isolated viewport fixtures.
            let host = NSHostingView(
                rootView: ChatTranscriptView(session: session).environment(model)
                    .frame(minWidth: 880, minHeight: 560))
            host.sizingOptions = [.minSize]
            window.contentView = host
            window.orderFront(nil)
            defer {
                window.contentView = nil
                window.close()
            }
            for (width, font) in [(980.0, 11.0), (1180, 28), (880, 14), (980, 24)] {
                model.chatFontSize = font
                window.setContentSize(NSSize(width: width, height: 600))
                for _ in 0..<10 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(30))
                }
                #expect(
                    abs(host.bounds.width - width) <= 1,
                    "Direct host must retain requested width \(width), got \(host.bounds)")
                #expect(window.contentMinSize.width >= 880 && window.contentMinSize.height >= 560)
                window.setContentSize(NSSize(width: 100, height: 100))
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                #expect(host.bounds.width >= 880 && host.bounds.height >= 560, "The exported minimum prevents collapse")
            }
        }

        @Test @MainActor func streamingAndReflowRespectAReaderWhoScrolledUp() async throws {
            let model = AppModel.shared
            let originalFont = model.chatFontSize
            defer { model.chatFontSize = originalFont }
            let session = ChatSession(effort: .trot, modelID: nil)
            session.messagesLoaded = true
            session.messages = (0..<30).map { index in
                let message = ChatMessage(role: .assistant)
                message.text =
                    "Message \(index)\n\n"
                    + String(repeating: "A paragraph to keep the transcript scrollable.\n\n", count: 5)
                message.complete = true
                return message
            }
            let active = try #require(session.messages.last)
            active.complete = false
            session.isStreaming = true
            let window = NSWindow(
                contentRect: NSRect(x: 80, y: 80, width: 700, height: 450), styleMask: [.titled, .resizable],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            // Seed the SwiftUI scroll-position binding as a real reader gesture would. Direct AppKit
            // clip-view movement alone does not update that binding consistently across macOS 26 and 27.
            let readerAnchor = session.messages[10].id
            let host = NSHostingView(
                rootView: ChatTranscriptView(
                    session: session, initiallyFollowing: false, initialVisibleMessageID: readerAnchor
                ).environment(model))
            // The fixture owns the viewport dimensions. A bare root NSHostingView otherwise
            // exports content-derived min/ideal/max sizes to the window while Markdown reflows.
            // In the app the transcript receives its width from the surrounding chat layout.
            host.sizingOptions = []
            installReflowHost(host, in: window)
            // Exercise a displayed window: native scroll settling and display-cycle layout
            // are suspended differently for a hidden hosting view.
            window.orderFront(nil)
            defer {
                window.contentView = nil
                window.close()
            }
            try await Task.sleep(for: .milliseconds(500))
            let scroll = try #require(reflowScroll(host))
            // Establish a reader who has scrolled up, then wait for native scroll to settle rather than a
            // fixed delay -- the began->ended wheel phase can land past an estimated end and bounce back
            // under load (matches transcriptRetainsVisibleContentAcrossFontAndWidthReflow).
            let document = try #require(scroll.documentView)
            // Synthetic wheel phases are not forwarded to SwiftUI on macOS 27. The fixture starts in
            // reader-owned mode, tries both native directions, then positions the clip view directly only
            // when AppKit ignored both events. The assertions below still exercise all later growth.
            for delta in [450, -450] where document.bounds.maxY - document.visibleRect.maxY <= 150 {
                try await scrollWheel(scroll, delta: delta)
                try await waitForScrollToSettle(scroll)
            }
            if document.bounds.maxY - document.visibleRect.maxY <= 150 {
                scroll.contentView.scroll(to: NSPoint(x: document.visibleRect.minX, y: document.bounds.minY))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded()
            }
            #expect(document.bounds.maxY - document.visibleRect.maxY > 150)
            active.text += String(repeating: "New streamed content.\n", count: 30)
            active.markRenderChanged()
            try await Task.sleep(for: .milliseconds(300))
            #expect(
                document.bounds.maxY - document.visibleRect.maxY > 150, "Streaming must not pull a reader to the bottom"
            )
            active.complete = true
            active.toolEvents = [
                ToolEventSnapshot(
                    id: "read", server: "GOATed", tool: "pen_read_file",
                    arguments: #"{"path":"App.swift"}"#, result: "Read successfully")
            ]
            let nextRound = ChatMessage(role: .assistant)
            nextRound.text = "Continuing the work."
            session.messages.append(nextRound)
            try await Task.sleep(for: .milliseconds(300))
            #expect(
                document.bounds.maxY - document.visibleRect.maxY > 150,
                "Grouping and adding the next tool round must not rearm following for a reader who scrolled up")
            model.chatFontSize = 24
            window.setContentSize(NSSize(width: 500, height: 450))
            try await Task.sleep(for: .milliseconds(300))
            try await waitForScrollToSettle(scroll)
            #expect(
                document.bounds.maxY - document.visibleRect.maxY > 150,
                "Font and width reflow must preserve reading away from the bottom")
        }
    }
}

final class TranscriptComparisonPreparationTests: XCTestCase {
    @MainActor func testQualificationCancellationDuringStartupKeepsTheOriginalFixture() async {
        let fixture = Delivery3Qualification()
        let original = fixture.session.messages.map(\.id)
        let task = Task { await fixture.stream(reasoning: false) }
        for _ in 0..<100 where !fixture.running { await Task.yield() }
        XCTAssertTrue(fixture.running)
        task.cancel()
        await task.value
        XCTAssertEqual(fixture.session.messages.map(\.id), original)
        XCTAssertFalse(fixture.running)
        XCTAssertFalse(fixture.session.isStreaming)
        XCTAssertEqual(fixture.status, "Cancelled")
    }

    @MainActor func testQualificationTeardownDoesNotCompleteAPartialStream() async throws {
        for reasoning in [false, true] {
            let fixture = Delivery3Qualification(startDelay: .zero)
            let task = Task { await fixture.stream(reasoning: reasoning) }
            defer { task.cancel() }
            for _ in 0..<100 where !fixture.session.isStreaming {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(fixture.session.isStreaming)
            let reply = try XCTUnwrap(fixture.session.messages.first)
            let text = reasoning ? reply.thinking : reply.text
            XCTAssertFalse(text.isEmpty)
            XCTAssertLessThan(text.utf8.count, 2 * 1_024 * 1_024)
            fixture.stop()
            // Even without view-task cancellation, the teardown guard stops publication.
            await task.value
            XCTAssertEqual(reasoning ? reply.thinking : reply.text, text)
            XCTAssertFalse(reply.complete)
            XCTAssertFalse(fixture.running)
            XCTAssertFalse(fixture.session.isStreaming)
            XCTAssertEqual(fixture.status, "Cancelled")
            await fixture.stream(reasoning: reasoning)
            XCTAssertEqual(reasoning ? reply.thinking : reply.text, text)
        }
    }

    @MainActor func testSwiftUIOverscanPreparesColdNeighboursBeforeTheyAppear() async throws {
        let fixture = TranscriptComparisonFixture()
        defer { fixture.stopPreparation() }
        try await fixture.seed(rounds: 3)
        fixture.documents.removeAll()
        await fixture.markdown.removeAll()
        let index = try XCTUnwrap(fixture.rows.firstIndex { $0.id == "header-1" })
        let visible = fixture.rows[index]
        fixture.updateSwiftUIVisibility([visible.id], viewportHeight: 780)
        await fixture.prepareRequestedRows()
        let neighbour = try XCTUnwrap(
            fixture.rows[(index + 1)...].first {
                if case .markdown = $0.content { return true }
                return false
            })
        XCTAssertFalse(fixture.visible.contains(neighbour.id), "The neighbour has not appeared")
        let userRow = try XCTUnwrap(
            fixture.rows[(index + 1)...].first {
                if case .message = $0.content { return true }
                return false
            })
        guard case .message(let user) = userRow.content else { return XCTFail("Expected user row") }
        XCTAssertFalse(fixture.visible.contains(userRow.id))
        XCTAssertNotNil(MarkdownContentCache.shared.peek(id: user.id, source: user.text))
        XCTAssertNotNil(fixture.preparedSegment(for: neighbour), "Cold upcoming content is prepared in advance")
        let identity = fixture.preparedSegment(for: neighbour)?.preparationID
        fixture.updateSwiftUIVisibility([neighbour.id], viewportHeight: 780)
        await fixture.prepareRequestedRows()
        XCTAssertEqual(fixture.preparedSegment(for: neighbour)?.preparationID, identity)
        fixture.updateSwiftUIVisibility([], viewportHeight: 780)
        await fixture.prepareRequestedRows()
        if case .markdown(let message, _, _) = neighbour.content {
            XCTAssertNil(fixture.preparation(for: message.id).document)
        }
    }
    @MainActor func testComparisonPreparesNeighbouringRowsTogetherAndReusesScrollBack() async throws {
        let fixture = TranscriptComparisonFixture()
        defer { fixture.stopPreparation() }
        try await fixture.seed(rounds: 1)
        let neighbours = fixture.rows.filter {
            if case .markdown = $0.content { return true }
            return false
        }
        XCTAssertGreaterThanOrEqual(neighbours.count, 2)
        let first = try XCTUnwrap(neighbours.first)
        let second = neighbours[1]
        fixture.documents.removeAll()
        await fixture.markdown.removeAll()
        fixture.visible = [first.id, second.id]
        await fixture.prepareRequestedRows()
        let firstID = try XCTUnwrap(fixture.preparedSegment(for: first)?.preparationID)
        let secondID = try XCTUnwrap(fixture.preparedSegment(for: second)?.preparationID)
        let count = await fixture.markdown.snapshot().parseCount
        // Recreating either row does not issue a narrower request or discard its neighbour.
        fixture.visible = [second.id]
        await fixture.prepareRequestedRows()
        fixture.visible = []
        await fixture.prepareRequestedRows()
        fixture.visible = [first.id, second.id]
        XCTAssertEqual(fixture.preparedSegment(for: first)?.preparationID, firstID)
        XCTAssertEqual(fixture.preparedSegment(for: second)?.preparationID, secondID)
        await fixture.prepareRequestedRows()
        let after = await fixture.markdown.snapshot().parseCount
        XCTAssertEqual(after, count)
    }

    @MainActor func testUserPreparationDiscardsAReplacedMessageAfterAwaiting() async throws {
        let fixture = TranscriptComparisonFixture()
        defer { fixture.stopPreparation() }
        try await fixture.seed(rounds: 1)
        let row = try XCTUnwrap(
            fixture.rows.first {
                if case .message = $0.content { return true }
                return false
            })
        guard case .message(let message) = row.content else { return XCTFail("Expected user row") }
        fixture.visible = [row.id]
        let originalSource = message.text
        XCTAssertNil(MarkdownContentCache.shared.peek(id: message.id, source: originalSource))
        await fixture.prepareRequestedRows { _, source in
            await Task.yield()
            let replacement = ChatMessage(role: message.role, id: message.id)
            replacement.text = "Replaced while preparation awaited"
            row.content = .message(replacement)
            return .parsed(PreparedMarkdownContent(value: MarkdownContent(source)))
        }
        XCTAssertNil(MarkdownContentCache.shared.peek(id: message.id, source: originalSource))
    }

    @MainActor func testUserPreparationCancellationStopsBeforeTheNextRow() async throws {
        let fixture = TranscriptComparisonFixture()
        defer { fixture.stopPreparation() }
        try await fixture.seed(rounds: 3)
        let users = fixture.rows.filter {
            if case .message = $0.content { return true }
            return false
        }
        XCTAssertEqual(users.count, 3)
        fixture.visible = Set(users.map(\.id))
        var calls = 0
        let task = Task { @MainActor in
            await fixture.prepareRequestedRows { _, source in
                calls += 1
                await Task.yield()
                withUnsafeCurrentTask { $0?.cancel() }
                return .parsed(PreparedMarkdownContent(value: MarkdownContent(source)))
            }
        }
        await task.value
        XCTAssertEqual(calls, 1, "Cancelled preparation must not await more rows")
        for row in users {
            guard case .message(let message) = row.content else { continue }
            XCTAssertNil(MarkdownContentCache.shared.peek(id: message.id, source: message.text))
        }
    }

    @MainActor func testFrameSamplingUsesTheCurrentClipOrigin() throws {
        let fixture = TranscriptComparisonFixture()
        defer { fixture.stopPreparation() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let document = ComparisonFrameSamplingDocument(frame: NSRect(x: 0, y: 0, width: 800, height: 2_000))
        let row = NSView(frame: NSRect(x: 0, y: 600, width: 800, height: 200))
        document.addSubview(row)
        scroll.documentView = document
        window.contentView = scroll
        defer {
            window.contentView = nil
            window.close()
        }
        fixture.registerFrameView(row, id: "row")
        fixture.following = false
        fixture.recordReaderGeometry(width: scroll.contentView.bounds.width, font: AppModel.shared.chatFontSize)
        fixture.observeSwiftUIReader()
        fixture.sampleFrames()
        let before = try XCTUnwrap(fixture.frames["row"])
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 60))
        fixture.sampleFrames()
        let after = try XCTUnwrap(fixture.frames["row"])
        XCTAssertEqual(after.minY - before.minY, -60, accuracy: 0.01)
        XCTAssertEqual(fixture.capturedReader?.id, "row")
        XCTAssertEqual(try XCTUnwrap(fixture.capturedReader?.offset), after.minY, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(fixture.readerRestoreOffset(id: "row", offset: before.minY)), 0, accuracy: 0.01)
        row.frame.origin.y += 100
        XCTAssertEqual(try XCTUnwrap(fixture.readerRestoreOffset(id: "row", offset: after.minY)), 160, accuracy: 0.01)
        let font = AppModel.shared.chatFontSize
        defer { AppModel.shared.chatFontSize = font }
        AppModel.shared.chatFontSize = font + 1
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        XCTAssertEqual(
            try XCTUnwrap(fixture.capturedReader?.offset), after.minY, accuracy: 0.01,
            "A reflow notification must not replace the pre-reflow reader anchor")
        fixture.unregisterFrameView(row, id: "row")
        fixture.sampleFrames()
        XCTAssertNil(fixture.frames["row"])
    }

    @MainActor func testHistoricalPreparationDoesNotObserveLivePublications() async throws {
        let fixture = TranscriptComparisonFixture()
        defer { fixture.stopPreparation() }
        try await fixture.seed(rounds: 1)
        let row = try XCTUnwrap(
            fixture.rows.first {
                if case .markdown = $0.content { return true }
                return false
            })
        let invalidated = XCTestExpectation(description: "Historical document must not be invalidated")
        invalidated.isInverted = true
        withObservationTracking {
            _ = fixture.preparedSegment(for: row)
        } onChange: {
            invalidated.fulfill()
        }
        try await fixture.append("A live **answer**.", reasoning: false)
        XCTAssertNotNil(fixture.preparation(for: fixture.active.id).document)
        await fulfillment(of: [invalidated], timeout: 0.05)
        fixture.following = false
        try await fixture.append(" Offscreen growth.", reasoning: false)
        XCTAssertNil(
            fixture.preparation(for: fixture.active.id).document,
            "An offscreen unfollowed message must release its working document")
    }

}

@MainActor private final class ComparisonFrameSamplingDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private func reflowInk(_ view: NSView) -> Int {
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    var ink = 0
    for y in stride(from: 10, to: bitmap.pixelsHigh - 10, by: 3) {
        for x in stride(from: 20, to: bitmap.pixelsWide - 20, by: 3) {
            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9,
                color.redComponent < 0.6, color.greenComponent < 0.6, color.blueComponent < 0.6
            {
                ink += 1
            }
        }
    }
    return ink
}
