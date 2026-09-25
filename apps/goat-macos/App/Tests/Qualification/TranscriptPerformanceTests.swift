import AppKit
import Bleet
import Darwin
import Hoofprint
import Persistence
import SwiftUI
import XCTest

@testable import GOAT

/// A synthetic, engine-free Release workload for issue #29. Metrics are observations,
/// not portable pass/fail thresholds. Run this class alone when collecting a profile.
final class TranscriptPerformanceTests: XCTestCase {
    @MainActor func testLongCodingTranscript() async throws {
        for follows in [false, true] {
            let session = ChatSession(effort: .trot, modelID: nil)
            session.messagesLoaded = true
            session.messages = (0..<24).map { index in
                let message = ChatMessage(role: index.isMultiple(of: 6) ? .user : .assistant)
                message.restoreContent(
                    text: "## Synthetic response \(index)\n\n" + String(repeating: Self.block, count: 20),
                    thinking: String(repeating: "Inspect the source and verify the result.\n", count: 80))
                message.complete = true
                if message.role == .assistant {
                    message.toolEvents = [
                        ToolEventSnapshot(
                            id: "synthetic-\(index)", server: "GOATed", tool: "pen_read_file",
                            arguments: #"{"path":"fixture.swift"}"#,
                            result: String(repeating: "Synthetic tool output\n", count: 100))
                    ]
                }
                return message
            }
            let active = try XCTUnwrap(session.messages.last)
            active.complete = false
            let window = NSWindow(
                contentRect: NSRect(x: 80, y: 80, width: 760, height: 520),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(
                rootView: ChatTranscriptView(
                    session: session, initiallyFollowing: follows,
                    initialVisibleMessageID: follows ? nil : session.messages[10].id
                ).environment(AppModel.shared))
            window.contentView = host
            window.orderFront(nil)
            defer {
                window.contentView = nil
                window.close()
            }
            try await Task.sleep(for: .seconds(3))
            for phase in ["idle", "waiting", "streaming"] {
                session.isStreaming = phase != "idle"
                RenderSignposts.event("TranscriptWorkloadPhase")
                let before = Self.usage()
                let start = ProcessInfo.processInfo.systemUptime
                var latencies: [Double] = []
                for tick in 0..<40 {
                    let scheduled = ProcessInfo.processInfo.systemUptime
                    try await Task.sleep(for: .milliseconds(50))
                    latencies.append(max(0, ProcessInfo.processInfo.systemUptime - scheduled - 0.05))
                    if phase == "streaming" {
                        active.appendStream(text: "\nPublication \(tick): **synthetic output**.\n", thinking: "")
                    }
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let after = Self.usage()
                latencies.sort()
                print(
                    "TRANSCRIPT_PROFILE follow=\(follows) phase=\(phase) messages=24 "
                        + "wall_s=\(elapsed) cpu_s=\(after.cpu - before.cpu) "
                        + "main_actor_delay_p95_ms=\(latencies[37] * 1_000) "
                        + "peak_rss_bytes=\(after.peakRSS)")
            }
            XCTAssertEqual(session.messages.count, 24)
            XCTAssertTrue(active.text.contains("Publication 39"))
        }
    }

    private static let block = """
        A reproducible paragraph with **emphasis**, `inline code`, and a short explanation.

        ```swift
        struct SyntheticValue {
            let count: Int
            func doubled() -> Int { count * 2 }
        }
        ```

        - Inspect the input
        - Verify the output


        """

    @MainActor func testOversizedCompletedReplyRendersScrollableDocument() async throws {
        let session = ChatSession(effort: .trot, modelID: nil)
        session.messagesLoaded = true
        let user = ChatMessage(role: .user)
        user.text = "Write a comprehensive report on transcript performance."
        user.complete = true

        let assistant = ChatMessage(role: .assistant)
        assistant.text = String(
            repeating: "Here is paragraph detailing architecture and layout metrics.\n\n", count: 180)
        assistant.thinking = String(
            repeating: "Reasoning step evaluating trade-offs and performance implications.\n\n", count: 80)
        assistant.complete = true
        session.messages = [user, assistant]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(
            rootView: ChatTranscriptView(session: session, initiallyFollowing: true)
                .environment(AppModel.shared))
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }

        func findScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(findScroll).first
        }

        var settled: NSScrollView?
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if let scroll = findScroll(host), let document = scroll.documentView,
                document.bounds.height > 600,
                document.visibleRect.height > 0,
                document.bounds.height > scroll.contentView.bounds.height
            {
                settled = scroll
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(settled, "Oversized completed reply must render a tall scrollable document")
    }

    private static func usage() -> (cpu: Double, peakRSS: Int) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu =
            Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        return (cpu, Int(usage.ru_maxrss))
    }
}
