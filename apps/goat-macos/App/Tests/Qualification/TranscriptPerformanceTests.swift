import AppKit
import Bleet
import Caprine
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

/// Opt-in, engine-free production-view surface for interactive and Instruments qualification.
@MainActor @Observable private final class Delivery3Qualification {
    let session = ChatSession(effort: .trot, modelID: nil)
    var finished = false
    var running = false
    var status = "Ready"

    init() { reset() }

    func reset() {
        guard !running else { return }
        session.messagesLoaded = true
        session.isStreaming = false
        let reply = ChatMessage(role: .assistant)
        reply.text =
            "# Delivery 3 synthetic fixture\n\nReadable **prose**, a link and `inline code`.\n\n```swift title=Fixture.swift\n"
            + (0..<90).map { "let value\($0) = \($0) // independent code actions\n" }.joined()
            + "```\n\nEnd of fixture."
        reply.thinking = "Consider the options.\n\n```swift\nlet choice = 42\n```\nVerify the result."
        reply.complete = true
        ReasoningDisclosureStore.shared.set(.init(isOpen: true, showsAll: true), for: reply.id)
        session.messages = [reply]
        status = "Ready"
    }

    func stream(reasoning: Bool) async {
        guard !running else { return }
        running = true
        status = "Starting in 5 seconds"
        try? await Task.sleep(for: .seconds(5))
        let reply = ChatMessage(role: .assistant)
        session.messages = [reply]
        session.isStreaming = true
        ReasoningDisclosureStore.shared.set(.init(isOpen: true, showsAll: true), for: reply.id)
        let block =
            "A synthetic paragraph to inspect **layout** and input responsiveness.\n\n```swift\nlet value = 42\n```\n\n"
        let source = String(String(repeating: block, count: 30_000).prefix(2 * 1_024 * 1_024))
        let clock = ContinuousClock()
        let start = clock.now
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpuBefore = Self.cpu(usage)
        var delays: [Double] = []
        var offset = source.startIndex
        let phase = reasoning ? "reasoning" : "answer"
        status = "Streaming \(phase)"
        print("DELIVERY3_PROFILE_START phase=\(phase) pid=\(getpid())")
        RenderSignposts.event("TranscriptWorkloadPhase")
        while offset < source.endIndex {
            let end = source.index(offset, offsetBy: 16_384, limitedBy: source.endIndex) ?? source.endIndex
            let text = String(source[offset..<end])
            reply.appendStream(text: reasoning ? "" : text, thinking: reasoning ? text : "")
            offset = end
            let scheduled = clock.now
            try? await Task.sleep(for: .milliseconds(120))
            let elapsed = scheduled.duration(to: clock.now).components
            delays.append(max(0, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18 - 0.120))
        }
        reply.complete = true
        session.isStreaming = false
        try? await Task.sleep(for: .seconds(3))
        getrusage(RUSAGE_SELF, &usage)
        let elapsed = start.duration(to: clock.now).components
        let wall = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        delays.sort()
        let p95 = delays[min(delays.count - 1, Int(Double(delays.count) * 0.95))] * 1_000
        print(
            "DELIVERY3_PROFILE phase=\(phase) bytes=\(source.utf8.count) wall_s=\(wall) cpu_s=\(Self.cpu(usage) - cpuBefore) delay_p95_ms=\(p95) peak_rss_bytes=\(usage.ru_maxrss)"
        )
        status = "Completed \(phase): 2 MiB"
        running = false
    }

    private static func cpu(_ usage: rusage) -> Double {
        Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}

private struct Delivery3QualificationView: View {
    @Bindable var fixture: Delivery3Qualification
    @Environment(AppModel.self) private var model
    @State private var inspector = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                Picker("Theme", selection: $model.themeID) {
                    ForEach(ThemeCatalog.builtins) { theme in Text(theme.name).tag(theme.id) }
                }.frame(width: 160)
                Toggle("Inspector", isOn: $inspector)
                Toggle("Animations", isOn: $model.animationsEnabled)
                Stepper("Font \(Int(model.chatFontSize))", value: $model.chatFontSize, in: 10...28)
                Button("Finish") { fixture.finished = true }.disabled(fixture.running)
            }.padding(8)
            HStack {
                Button("Short fixture") { fixture.reset() }.disabled(fixture.running)
                Button("Stream answer 2 MiB") { Task { await fixture.stream(reasoning: false) } }.disabled(
                    fixture.running)
                Button("Stream reasoning 2 MiB") { Task { await fixture.stream(reasoning: true) } }.disabled(
                    fixture.running)
                Text(fixture.status)
            }.padding(8)
            ChatView(session: fixture.session)
                .inspector(isPresented: $inspector) {
                    VStack {
                        Text("Synthetic inspector")
                        Text("Reserves inspector width for reflow qualification.")
                    }
                    .padding().inspectorColumnWidth(260)
                }
        }
        .background(model.theme.tokens.bg)
        .goatPresentation()
    }
}

extension TranscriptPerformanceTests {
    @MainActor func testInteractiveDelivery3Qualification() async throws {
        guard ProcessInfo.processInfo.environment["GOAT_DELIVERY3_QUALIFY"] == "1" else {
            throw XCTSkip("Opt in with TEST_RUNNER_GOAT_DELIVERY3_QUALIFY=1 for manual qualification")
        }
        let model = AppModel.shared
        let theme = model.themeID
        let font = model.chatFontSize
        let animations = model.animationsEnabled
        defer {
            model.themeID = theme
            model.chatFontSize = font
            model.animationsEnabled = animations
        }
        let fixture = Delivery3Qualification()
        let host = NSHostingView(rootView: Delivery3QualificationView(fixture: fixture).environment(model))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 60, y: 60, width: 1180, height: 780),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "GOAT Delivery 3 qualification"
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        print("DELIVERY3_READY pid=\(getpid())")
        if ProcessInfo.processInfo.environment["GOAT_DELIVERY3_AUTORUN"] == "1" {
            try await Task.sleep(for: .seconds(15))
            await fixture.stream(reasoning: false)
            await fixture.stream(reasoning: true)
            fixture.finished = true
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1_800))
        while !fixture.finished, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(fixture.finished, "Interactive qualification must be explicitly finished")
    }
}
