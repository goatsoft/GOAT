import AppKit
import Bleet
import SwiftUI
import Testing

@testable import GOAT

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

@MainActor private func transcript(_ session: ChatSession) -> some View {
    ChatTranscriptView(session: session).id(session.id)
        .environment(AppModel.shared).frame(width: 700, height: 450)
}

@MainActor private func findTranscriptScroll(_ view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    return view.subviews.lazy.compactMap(findTranscriptScroll).first
}
