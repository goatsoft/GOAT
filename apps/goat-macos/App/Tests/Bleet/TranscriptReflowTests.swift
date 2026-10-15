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
@MainActor @Observable private final class PresentedRow {
    var isPresented = false
    var shown = true
}

/// A row that presents something while `presented.isPresented`, and goes away when `shown` is false.
private struct PresentingRow: View {
    let presented: PresentedRow
    var body: some View {
        if presented.shown {
            Text("Row").holdsTranscriptLayout(while: presented.isPresented)
        }
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
                    #expect(ink > 100, "Viewport must contain visible text after \(context); \(state)")

                }
            }
        }

        /// The relayout after a reflow replaces every row. What the reader opened survives it: a tool
        /// disclosure stays expanded, and while a row presents a sheet or popover (an edit with an unsaved
        /// draft, response details) the relayout waits for it to close instead of dismissing it.
        @Test @MainActor func reflowKeepsWhatTheReaderOpened() async throws {
            let model = AppModel.shared
            let originalFont = model.chatFontSize
            defer { model.chatFontSize = originalFont }
            let session = ChatSession(effort: .trot, modelID: nil)
            session.messagesLoaded = true
            session.messages = (0..<12).map { index in
                let message = ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant)
                message.text = "Reflow row \(index). A short paragraph of transcript text."
                message.complete = true
                return message
            }
            let toolID = "reflow-disclosure-\(UUID().uuidString)"
            session.messages[11].toolEvents = [
                ToolEventSnapshot(
                    id: toolID, server: "GOATed", tool: "pen_read_file",
                    arguments: #"{"path":"App.swift"}"#, result: "Read successfully")
            ]
            let window = NSWindow(
                contentRect: NSRect(x: 80, y: 80, width: 760, height: 520), styleMask: [.titled, .resizable],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let navigation = TranscriptViewport()
            // SwiftUI builds its accessibility tree for an assistive client.
            let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let previousEnhancedUI = NSApp.accessibilityAttributeValue(enhancedUI)
            NSApp.accessibilitySetValue(true, forAttribute: enhancedUI)
            let host = NSHostingView(
                rootView: ChatTranscriptView(session: session, viewport: navigation).environment(model))
            host.sizingOptions = []
            installReflowHost(host, in: window)
            window.orderFront(nil)
            defer {
                window.contentView = nil
                window.close()
                NSApp.accessibilitySetValue(previousEnhancedUI ?? false, forAttribute: enhancedUI)
            }
            try await Task.sleep(for: .milliseconds(500))

            func value(_ object: NSObject, _ name: String) -> Any? {
                let selector = NSSelectorFromString(name)
                guard object.responds(to: selector) else { return nil }
                return object.perform(selector)?.takeUnretainedValue()
            }
            func disclosure() -> NSObject? {
                var visited = Set<ObjectIdentifier>()
                func find(_ object: Any) -> NSObject? {
                    guard let object = object as? NSObject, visited.insert(ObjectIdentifier(object)).inserted
                    else { return nil }
                    let identifier = object.accessibilityAttributeValue(.identifier) as? String
                    let label =
                        object.accessibilityAttributeValue(.title) as? String
                        ?? object.accessibilityAttributeValue(.description) as? String
                        ?? value(object, "accessibilityLabel") as? String ?? ""
                    let state = object.accessibilityAttributeValue(.value) as? String
                    if identifier == "tool-event-" + toolID
                        || (label.contains("App.swift") && (state == "Collapsed" || state == "Expanded"))
                    {
                        return object
                    }
                    let children = value(object, "accessibilityChildren") as? [Any] ?? []
                    return children.lazy.compactMap(find).first
                }
                return find(host)
            }
            func state() -> String? {
                disclosure().flatMap { $0.accessibilityAttributeValue(.value) as? String }
            }
            func relayout(toFont font: CGFloat) async throws {
                model.chatFontSize = font
                try await Task.sleep(for: .milliseconds(600))
                host.layoutSubtreeIfNeeded()
            }

            let control = try #require(disclosure(), "The tool disclosure must be an actionable control")
            #expect(state() == "Collapsed")
            let press = NSSelectorFromString("accessibilityPerformPress")
            let implementation = try #require(control.method(for: press))
            let perform = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
            #expect(perform(control, press))
            try await Task.sleep(for: .milliseconds(200))
            #expect(state() == "Expanded")

            let before = navigation.relayouts
            try await relayout(toFont: 22)
            #expect(navigation.relayouts > before, "The font change must replace the rows")
            #expect(state() == "Expanded", "The reader's open disclosure collapsed in the relayout")

            // A row presents a sheet: the relayout waits, then runs once it closes.
            navigation.holdLayout()
            let held = navigation.relayouts
            try await relayout(toFont: 15)
            #expect(navigation.relayouts == held, "Rows were replaced under an open presentation")
            navigation.releaseLayout()
            try await Task.sleep(for: .milliseconds(600))
            #expect(navigation.relayouts > held, "The deferred relayout must run once the presentation closes")
            #expect(state() == "Expanded")
        }

        /// A row's sheet or popover holds the relayout exactly while it is presented, and a row that goes
        /// away releases its hold.
        @Test @MainActor func presentationsHoldTheTranscriptLayoutWhileOpen() async throws {
            let presented = PresentedRow()
            let navigation = TranscriptViewport()
            let host = NSHostingView(
                rootView: PresentingRow(presented: presented).environment(\.transcriptViewport, navigation))
            host.frame = NSRect(x: 0, y: 0, width: 200, height: 60)
            func settle() async throws {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
                host.layoutSubtreeIfNeeded()
            }
            try await settle()
            #expect(navigation.layoutHolds == 0)
            presented.isPresented = true
            try await settle()
            #expect(navigation.layoutHolds == 1)
            presented.isPresented = false
            try await settle()
            #expect(navigation.layoutHolds == 0)
            presented.isPresented = true
            try await settle()
            presented.shown = false
            try await settle()
            #expect(navigation.layoutHolds == 0, "A row that went away must release its hold")
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

/// The Delivery 3 qualification fixture stops cleanly, so a cancelled run never completes a partial stream.
final class Delivery3QualificationFixtureTests: XCTestCase {
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
}
