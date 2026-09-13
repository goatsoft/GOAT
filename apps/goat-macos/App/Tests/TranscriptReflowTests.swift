import AppKit
import Bleet
import Persistence
import SwiftUI
import Testing

@testable import GOAT

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
    let host = NSHostingView(
        rootView: ChatTranscriptView(session: session).environment(model).environment(\.colorScheme, .light).background(
            Color.white
        ).foregroundStyle(
            .black))
    host.appearance = NSAppearance(named: .aqua)
    window.contentView = host
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
            #expect(
                ink > 100,
                "Viewport must contain visible text after width \(width), font \(font), wheel \(delta); ink=\(ink)")

        }
    }
}

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

@MainActor private func reflowScroll(_ view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    return view.subviews.lazy.compactMap(reflowScroll).first
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
            "Message \(index)\n\n" + String(repeating: "A paragraph to keep the transcript scrollable.\n\n", count: 5)
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
    let host = NSHostingView(rootView: ChatTranscriptView(session: session).environment(model))
    window.contentView = host
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
    try await scrollWheel(scroll, delta: 450)
    try await waitForScrollToSettle(scroll)
    let document = try #require(scroll.documentView)
    #expect(document.bounds.maxY - document.visibleRect.maxY > 150)
    active.text += String(repeating: "New streamed content.\n", count: 30)
    active.markRenderChanged()
    try await Task.sleep(for: .milliseconds(300))
    #expect(document.bounds.maxY - document.visibleRect.maxY > 150, "Streaming must not pull a reader to the bottom")
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
