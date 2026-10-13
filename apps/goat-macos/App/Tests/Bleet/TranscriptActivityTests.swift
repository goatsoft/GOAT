import AppKit
import Bleet
import Inference
import Persistence
import SwiftUI
import Testing
import XCTest

@testable import GOAT

@MainActor private func activityMessage(_ tool: String = "pen_read_file", result: String? = "Read successfully")
    -> ChatMessage
{
    let message = ChatMessage(role: .assistant)
    message.complete = true
    message.toolEvents = [
        ToolEventSnapshot(
            id: UUID().uuidString, server: "GOATed", tool: tool,
            arguments: #"{"path":"src/App.vue"}"#, result: result)
    ]
    return message
}

@MainActor final class ToolActivityDisclosureTests: XCTestCase {
    func testActionClickExpandsOnlyItsPayload() async throws {
        let messages = [
            activityMessage(), activityMessage("pen_edit_file"), activityMessage("pen_run_command", result: nil),
        ]
        var inspections = 0
        let host = NSHostingView(
            rootView: ToolActivityGroup(messages: messages, activeAssistantID: messages.last?.id, projectID: nil)
                .environment(AppModel.shared)
                .environment(\.transcriptInspection, TranscriptInspectionAction { inspections += 1 }))
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 660, height: 140),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(200))
        let collapsed = host.fittingSize.height
        window.setContentSize(NSSize(width: 660, height: collapsed))
        try await Task.sleep(for: .milliseconds(100))
        try attachSnapshot(host, name: "Tool activity collapsed")
        try clickHeader(host, in: window)
        try await Task.sleep(for: .milliseconds(200))
        let expanded = host.fittingSize.height
        XCTAssertGreaterThan(expanded, collapsed + 30, "Clicking an action must reveal its arguments and result")
        window.setContentSize(NSSize(width: 660, height: expanded))
        try await Task.sleep(for: .milliseconds(100))
        try attachSnapshot(host, name: "Tool activity expanded")
        try clickHeader(host, in: window)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(host.fittingSize.height, collapsed, accuracy: 2)
        XCTAssertEqual(inspections, 2, "Inspection must pause transcript following before layout changes")
    }

    func testConsecutiveToolMessagesHaveNoInvisibleFooterGap() async throws {
        let failed = activityMessage("pen_run_command")
        failed.toolEvents[0].isError = true
        failed.toolEvents[0].arguments = #"{"command":"npm","args":["install","--save-dev","@webgpu/types"]}"#
        let retry = activityMessage("pen_run_command")
        retry.text = "\n \n"
        retry.thinking = "\n"
        retry.toolEvents[0].arguments = failed.toolEvents[0].arguments
        let rows = TranscriptActivity.rows([failed, retry][...])
        let host = NSHostingView(
            rootView: VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    if let message = row.messages.first {
                        MessageView(
                            message: message, isLast: false, projectID: nil,
                            compactActivity: row.isContinuation,
                            joinsPreviousTools: row.joinsPreviousTools,
                            joinsNextTools: row.joinsNextTools)
                    }
                }
            }
            .frame(width: 720).environment(AppModel.shared))
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 720, height: 140),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertLessThan(host.fittingSize.height, 80, "Two tool-only rounds must not reserve hidden footers")
        window.setContentSize(NSSize(width: 720, height: host.fittingSize.height))
        try await Task.sleep(for: .milliseconds(100))
        try attachSnapshot(host, name: "Consecutive command tree without footer gaps")
    }

    func testReasoningRemainsVisibleWhenToolsArrive() async throws {
        let message = ChatMessage(role: .assistant)
        message.thinking =
            "The package already has a build script. I will check its entry point before changing the configuration.\n\nThe existing imports should tell me which framework conventions to follow."
        message.text = "I’ll inspect the entry point, then make the smallest change."
        let session = ChatSession(effort: .trot, modelID: nil)
        session.messages = [message]
        session.isStreaming = true
        let host = NSHostingView(
            rootView:
                VStack(alignment: .leading, spacing: 20) {
                    MessageView(message: message, isLast: true, projectID: nil)
                    AgentProgressView(session: session)
                }
                .padding(24).frame(width: 720).environment(AppModel.shared))
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 720, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(350))
        let initial = host.fittingSize.height
        XCTAssertGreaterThan(initial, 120, "Reasoning must be visible without expanding a disclosure")
        message.toolEvents = activityMessage().toolEvents
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertGreaterThanOrEqual(host.fittingSize.height, initial, "Tool arrival must not collapse visible prose")
        // Completion then folds only the reasoning to its "Thought" line (#60 B4); the answer stays.
        message.complete = true
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertGreaterThan(host.fittingSize.height, 80, "The answer and tool rows stay visible after completion")
        window.setContentSize(NSSize(width: 720, height: host.fittingSize.height))
        try await Task.sleep(for: .milliseconds(100))
        try attachSnapshot(host, name: "Visible reasoning with collapsed tool details")
    }

    func testMemoryBatchCollapsesToOneHeaderAndExpandsItsActions() async throws {
        let message = activityMessage("memory_read")
        message.toolEvents = (0..<3).map { index in
            ToolEventSnapshot(
                id: "memory-\(index)", server: "Memory", tool: "memory_read",
                arguments: "{\"id\":\"aurora-\(index)\"}", result: "Saved page")
        }
        message.toolEvents[1].isError = true
        let host = NSHostingView(
            rootView:
                ToolActivityGroup(messages: [message], activeAssistantID: nil, projectID: nil)
                .frame(width: 660).environment(AppModel.shared))
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 660, height: 140),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(200))
        let collapsed = host.fittingSize.height
        XCTAssertLessThan(collapsed, 50)
        window.setContentSize(NSSize(width: 660, height: collapsed))
        try await Task.sleep(for: .milliseconds(100))
        try attachSnapshot(host, name: "Memory batch with visible failure summary")
        try clickHeader(host, in: window)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(host.fittingSize.height, collapsed + 50)
        window.setContentSize(NSSize(width: 660, height: host.fittingSize.height))
        try await Task.sleep(for: .milliseconds(100))
        try attachSnapshot(host, name: "Expanded memory action tree")
        try clickHeader(host, in: window)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(host.fittingSize.height, collapsed, accuracy: 2)
    }

    func testCompactionRowPresentsCollapsedAndExpandedContent() async throws {
        let message = ChatMessage(role: .user)
        message.kind = .compaction
        message.text = """
            Goal: finish the editor model trial while preserving the verified work.

            Continue from the saved validation checkpoint and record any remaining failures.
            """
        message.compaction = CompactionInfo(
            coversUpToMessageID: UUID().uuidString,
            coveredExchangeCount: 12,
            filesRead: ["src/App.vue", "src/components/Editor.vue"],
            filesEdited: ["src/composables/useAurora.ts"])
        message.complete = true
        let collapsedHost = NSHostingView(
            rootView:
                CompactionRow(message: message, info: try XCTUnwrap(message.compaction), delete: {})
                .frame(width: 660).environment(AppModel.shared))
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 660, height: 140),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = collapsedHost
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(200))
        let collapsed = collapsedHost.fittingSize.height
        XCTAssertLessThan(collapsed, 60)
        window.setContentSize(NSSize(width: 660, height: collapsed))
        try await Task.sleep(for: .milliseconds(100))
        try attachSnapshot(collapsedHost, name: "Compaction row collapsed")

        let expandedHost = NSHostingView(
            rootView:
                CompactionRow(
                    message: message, info: try XCTUnwrap(message.compaction), delete: {}, initiallyExpanded: true
                )
                .frame(width: 660).environment(AppModel.shared))
        window.contentView = expandedHost
        try await Task.sleep(for: .milliseconds(250))
        let expanded = expandedHost.fittingSize.height
        XCTAssertGreaterThan(expanded, collapsed + 100)
        window.setContentSize(NSSize(width: 660, height: expanded))
        try await Task.sleep(for: .milliseconds(100))
        try attachSnapshot(expandedHost, name: "Compaction row expanded")
    }

    func testCompactionLongSummaryLayoutMatrix() async throws {
        let model = AppModel.shared
        let originalTheme = model.themeID
        defer { model.themeID = originalTheme }
        let message = ChatMessage(role: .user)
        message.kind = .compaction
        message.text = """
            ## Goal
            Finish the synthetic editor task while preserving unsaved work.

            ## Constraints
            Keep the selected engine and workspace unchanged. Do not install dependencies.

            ## Completed
            Read the source, edited the value and independently checked the resulting bytes.

            ## Next steps
            Continue from the recorded command result, then report any remaining failures accurately.
            """
        let info = CompactionInfo(
            coversUpToMessageID: UUID().uuidString, coveredExchangeCount: 24,
            filesRead: ["Sources/Editor/Components/Inspector/SelectionDetails.swift"],
            filesEdited: ["Tests/Editor/SelectionDetailsTests.swift"])
        message.compaction = info
        message.complete = true
        for theme in ["light", "leet"] {
            model.themeID = theme
            for width in [360.0, 700.0] {
                let host = NSHostingView(
                    rootView: CompactionRow(
                        message: message, info: info, delete: {}, initiallyExpanded: true
                    )
                    .frame(width: width).environment(model))
                let window = NSWindow(
                    contentRect: NSRect(x: 80, y: 80, width: width, height: 900),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: theme == "light" ? .aqua : .darkAqua)
                window.contentView = host
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(400))
                host.layoutSubtreeIfNeeded()
                let fitted = host.fittingSize
                XCTAssertEqual(fitted.width, width, accuracy: 1)
                XCTAssertGreaterThan(fitted.height, 200)
                XCTAssertLessThan(fitted.height, 1600)
                window.setContentSize(NSSize(width: width, height: fitted.height))
                try await Task.sleep(for: .milliseconds(100))
                try attachSnapshot(
                    host, name: "Compaction \(theme) \(Int(width))")
                window.contentView = nil
                window.close()
            }
        }
    }

    private func attachSnapshot(_ host: NSView, name: String) throws {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func clickHeader(_ host: NSView, in window: NSWindow) throws {
        let point = host.convert(NSPoint(x: 140, y: host.isFlipped ? 10 : host.bounds.height - 10), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
    }
}
extension AppTests.Bleet {
    @Suite struct TranscriptActivityTests {
        @Test func searchKeepsUTF8OffsetsAndBoundsExcerpts() throws {
            let id = UUID()
            let source = String(repeating: "🐐 ", count: 100) + "Café" + String(repeating: " tail", count: 100)
            let results = try TranscriptText.find("cafe", in: [.init(id: id, source: source)])
            let result = try #require(results.first)
            #expect(result.id == id)
            #expect(result.match == "Café")
            #expect(result.byteOffset == String(repeating: "🐐 ", count: 100).utf8.count)
            #expect(result.prefix.count <= 80 && result.suffix.count <= 120)
            #expect(try TranscriptText.find("", in: [.init(id: id, source: source)]).isEmpty)
            #expect(
                try TranscriptText.find(
                    "cafe", in: Array(repeating: .init(id: id, source: source), count: 10), limit: 2
                ).count == 2)
        }

        @Test @MainActor func searchNavigationUsesTheViewportOwnerAndCanReturnToLatest() {
            let viewport = TranscriptViewport()
            let id = UUID()
            viewport.reveal(
                .init(messageID: id, offset: 0, segment: 12), messageWindow: 40..<41, segment: 12, segmentCount: 90)
            #expect(viewport.readerOwnsViewport)
            #expect(viewport.heldRange == 40..<41)
            #expect(viewport.segmentWindow(for: id) == 12..<13)
            #expect(viewport.request?.target == .anchor(.init(messageID: id, offset: 0, segment: 12)))
            viewport.jumpToLatest()
            #expect(viewport.autoFollow)
            #expect(viewport.heldRange == nil)
            #expect(viewport.segmentWindow(for: id) == nil)
            #expect(viewport.request?.target == .bottom)
        }
        @Test @MainActor func dayBoundariesBreakAssistantContinuations() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
            let first = ChatMessage(role: .assistant, createdAt: Date(timeIntervalSince1970: 86_399))
            first.text = "Before midnight"
            let second = ChatMessage(role: .assistant, createdAt: Date(timeIntervalSince1970: 86_400))
            second.text = "After midnight"
            let third = ChatMessage(role: .assistant, createdAt: Date(timeIntervalSince1970: 86_401))
            third.text = "Same day"
            let rows = TranscriptActivity.rows([first, second, third][...], calendar: calendar)
            #expect(rows.map(\.startsDay) == [true, true, false])
            #expect(rows.map(\.isContinuation) == [false, false, true])
            // A page starting halfway through a day still identifies that day.
            #expect(TranscriptActivity.rows([third][...], calendar: calendar).first?.startsDay == true)
            #expect(
                TranscriptActivity.rows([third][...], precedingDate: second.createdAt, calendar: calendar)
                    .first?.startsDay == false)
        }

        @Test @MainActor func markdownExportPreservesSourceWhitespaceAndUnicode() {
            let message = ChatMessage(role: .assistant)
            message.text = "\n  🐐 café e\u{301}\n\n````markdown\n```swift\n  let x = 1\n```\n````\n  "
            message.thinking = "  Reasoning\n\n"
            let exported = TranscriptText.markdownExport(title: "A\nconversation", messages: [message])
            #expect(exported.hasPrefix("# A conversation\n\n## Assistant\n\n"))
            #expect(exported.contains(message.text + "\n\n### Reasoning\n\n" + message.thinking))
            #expect(String(data: Data(exported.utf8), encoding: .utf8) == exported)
        }

        @Test @MainActor func lastVisibleIDSkipsTrailingToolAndEmptyRows() {
            let user = ChatMessage(role: .user)
            user.text = "Summarise the file."
            let reply = ChatMessage(role: .assistant)
            reply.text = "Here is the summary."
            let tool = ChatMessage(role: .tool)
            tool.text = "raw result"
            let empty = ChatMessage(role: .assistant)
            #expect(TranscriptActivity.lastVisibleID(in: [user, reply, tool, empty]) == reply.id)
            #expect(TranscriptActivity.lastVisibleID(in: [user]) == user.id)
            #expect(TranscriptActivity.lastVisibleID(in: []) == nil)
        }

        @Test @MainActor func regenerationReplacesTheWholeTurnTheReaderSeesAsLast() {
            let user = ChatMessage(role: .user)
            user.text = "Summarise the file."
            let firstRound = ChatMessage(role: .assistant)
            firstRound.toolEvents = [
                ToolEventSnapshot(id: "t1", server: "Pens", tool: "pen_read_file", arguments: "{}", result: "ok")
            ]
            let toolRow = ChatMessage(role: .tool)
            toolRow.text = "raw result"
            let reply = ChatMessage(role: .assistant)
            reply.text = "Here is the summary."
            let empty = ChatMessage(role: .assistant)

            // The review's history: a trailing tool row and empty assistant follow the visible reply.
            let trailing = [user, reply, toolRow, empty]
            #expect(TranscriptActivity.lastVisibleID(in: trailing) == reply.id)
            #expect(AppModel.regenerationTurn(in: trailing)?.map(\.id) == [reply.id, toolRow.id, empty.id])

            // A final reply after other agent rounds regenerates every round of that turn.
            let agentic = [user, firstRound, toolRow, reply]
            #expect(AppModel.regenerationTurn(in: agentic)?.map(\.id) == [firstRound.id, toolRow.id, reply.id])

            // An unanswered user message regenerates with nothing to remove.
            #expect(AppModel.regenerationTurn(in: [user])?.isEmpty == true)

            // No user turn, or a turn holding anything but replies and tool rows, is not regenerated.
            #expect(AppModel.regenerationTurn(in: [reply]) == nil)
            let compaction = ChatMessage(role: .assistant)
            compaction.kind = .compaction
            #expect(AppModel.regenerationTurn(in: [user, reply, compaction]) == nil)
        }

        @Test @MainActor func footerShowsForEveryReplyWithTextOrErrorIncludingAgenticReplies() {
            let event = ToolEventSnapshot(
                id: "t1", server: "Pens", tool: "pen_read_file", arguments: "{}", result: "ok")
            let agentic = ChatMessage(role: .assistant)
            agentic.text = "Done."
            agentic.toolEvents = [event]
            #expect(MessageView.showsFooter(for: agentic))

            let toolsOnly = ChatMessage(role: .assistant)
            toolsOnly.toolEvents = [event]
            #expect(!MessageView.showsFooter(for: toolsOnly))

            let reasoningOnly = ChatMessage(role: .assistant)
            reasoningOnly.thinking = "Considering options."
            #expect(!MessageView.showsFooter(for: reasoningOnly))

            let failed = ChatMessage(role: .assistant)
            failed.error = "The model stopped."
            #expect(MessageView.showsFooter(for: failed))

            let user = ChatMessage(role: .user)
            user.text = "Hello"
            #expect(!MessageView.showsFooter(for: user))
        }

        @Test @MainActor func relativeTimeFollowsTheTimelineDate() {
            let sent = Date(timeIntervalSince1970: 1_000_000)
            #expect(MessageView.relativeTime(sent, now: sent.addingTimeInterval(10)) == "just now")
            let later = MessageView.relativeTime(sent, now: sent.addingTimeInterval(180))
            #expect(later != "just now")
            #expect(later.contains("3"), "Three minutes later reads as three minutes ago, got \(later)")
        }

        @Test @MainActor func activityRowsPreserveNarrationAndIdentityWhenToolCallsArrive() {
            let first = activityMessage()
            first.text = "I’ll inspect the current component."
            let second = activityMessage("pen_edit_file")
            let lead = ChatMessage(role: .user)
            lead.text = "Keep the existing colours."
            let third = activityMessage()
            let final = ChatMessage(role: .assistant)
            final.text = "The change is ready."
            final.complete = true
            let result = ChatMessage(role: .tool)
            let input = [first, result, second, lead, third, final]
            let rows = TranscriptActivity.rows(input[...])
            #expect(rows.map(\.id) == [first.id, second.id, lead.id, third.id, final.id])
            #expect(rows.map(\.isContinuation) == [false, true, false, false, true])
            #expect(rows[0].messages.map(\.id) == [first.id])
            #expect(rows[0].messages[0] === first)
            #expect(first.text == "I’ll inspect the current component.")
            #expect(first.toolEvents[0].result == "Read successfully")
            let growing = TranscriptActivity.rows([first, second, activityMessage()][...])
            #expect(growing[0].id == first.id)
            let emptyAssistant = ChatMessage(role: .assistant)
            let emptyRows = TranscriptActivity.rows([first, emptyAssistant][...])
            #expect(emptyRows.map(\.id) == [first.id], "Empty assistant messages are excluded from rows")

            let streaming = ChatMessage(role: .assistant)
            streaming.thinking = "Inspect the entry point first."
            let before = TranscriptActivity.rows([first, streaming][...])
            streaming.toolEvents = second.toolEvents
            let after = TranscriptActivity.rows([first, streaming][...])
            #expect(before.map(\.id) == after.map(\.id))
            #expect(before.map(\.isContinuation) == after.map(\.isContinuation))
            #expect(after[1].messages[0].thinking == "Inspect the entry point first.")
        }

        @Test @MainActor func activityPagingStaysBoundedWithoutLosingToolsAcrossWindows() {
            let messages = (0..<105).map { _ in activityMessage() }
            var visited = Set<UUID>()
            var end = messages.count
            repeat {
                let range = TranscriptWindow.range(count: messages.count, end: end)
                let rows = TranscriptActivity.rows(messages[range])
                let visible = rows.flatMap(\.messages)
                #expect(visible.count <= TranscriptWindow.capacity)
                #expect(visible.map(\.id) == messages[range].map(\.id))
                visited.formUnion(visible.map(\.id))
                if range.lowerBound == 0 { break }
                end = range.lowerBound + TranscriptWindow.step
            } while true
            #expect(visited == Set(messages.map(\.id)))
        }

        @Test @MainActor func toolTreeConnectsAdjacentActionsButNeverCrossesReasoningOrLead() {
            let first = activityMessage("pen_run_command")
            first.toolEvents[0].isError = true
            let retry = activityMessage("pen_run_command")
            let reasoning = activityMessage()
            reasoning.thinking = "The retry succeeded; inspect the result."
            let next = activityMessage()
            let lead = ChatMessage(role: .user)
            lead.text = "Use the existing config."
            let last = activityMessage()
            let rows = TranscriptActivity.rows([first, retry, reasoning, next, lead, last][...])
            #expect(rows.map(\.joinsPreviousTools) == [false, true, false, false, false, false])
            #expect(rows.map(\.joinsNextTools) == [true, false, false, false, false, false])
            #expect(rows.map(\.id) == [first.id, retry.id, reasoning.id, next.id, lead.id, last.id])
            #expect(TranscriptActivity.isToolOnly(first))
            #expect(!TranscriptActivity.isToolOnly(reasoning))
            #expect(TranscriptActivity.isEmpty(ChatMessage(role: .assistant)))
        }

        @Test @MainActor func whitespaceOnlyActivityDoesNotReserveResponseSpace() {
            let first = activityMessage()
            first.text = "\n  \n"
            first.thinking = "\n\t\n"
            #expect(TranscriptActivity.isToolOnly(first))
            let empty = ChatMessage(role: .assistant)
            empty.text = "\n \n"
            #expect(TranscriptActivity.isEmpty(empty))
            #expect(TranscriptText.removingBoundaryBlankLines("\n \n    indented code\n\n") == "    indented code")
            #expect(TranscriptText.removingBoundaryBlankLines("first\n\nsecond") == "first\n\nsecond")
        }

        @Test @MainActor func liveResponseDetailsRefreshAcrossPersistenceCheckpoints() throws {
            let model = AppModel.shared
            let session = ChatSession(effort: .trot, modelID: "fixture")
            let message = ChatMessage(role: .assistant)
            #expect(!ResponseDetailsView.hasUsefulDetails(message))
            let identity = ModelIdentity(engineProfileID: "fixture", modelID: "fixture")
            let compatibility = ModelCompatibilityResolver.resolve(identity: identity)
            message.generationContext = GenerationContext(
                engineProfileID: "fixture", engineName: "Fixture engine", engineConfigurationRevision: 1,
                identity: identity, compatibility: compatibility)
            message.generationParameters = EffectiveGenerationParameters(
                request: GenerationRequest(
                    model: "fixture", turns: [], effort: .trot, compatibility: compatibility))
            message.generationSelectedEffort = "trot"
            for state in [GenerationProvenanceRecord.Lifecycle.prepared, .started, .completed] {
                message.generationLifecycle = state.rawValue
                let stored = model.record(for: message, in: session, position: 0)
                let live = try #require(message.generationProvenance)
                #expect(live.lifecycle == state)
                let data = try #require(stored.generationProvenanceJson?.data(using: .utf8))
                #expect(try JSONDecoder().decode(GenerationProvenanceRecord.self, from: data) == live)
            }
            #expect(ResponseDetailsView.hasUsefulDetails(message))
            let sections = ResponseDetailSection.sections(try #require(message.generationProvenance))
            #expect(!sections.flatMap(\.rows).contains { $0.title == "Response model" })
            #expect(!sections.flatMap(\.rows).contains { $0.value == "Unknown" || $0.value == "None" })
            message.generationContext = nil
            #expect(model.record(for: message, in: session, position: 0).generationProvenanceJson != nil)
        }

        @Test @MainActor func activitySummaryKeepsFailuresDenialsAndPendingResultsHonest() {
            let first = activityMessage()
            first.toolEvents[0].isError = true
            let denied = activityMessage()
            denied.toolEvents[0].denied = true
            denied.toolEvents[0].isError = true
            let active = activityMessage("pen_run_command", result: nil)
            active.toolEvents.append(active.toolEvents[0])
            active.toolEvents[1].id = "queued"
            let messages = [first, denied, active]
            let summary = TranscriptActivity.summary(messages, activeAssistantID: active.id)
            #expect(summary.count == 4)
            #expect(summary.failed == 1)
            #expect(summary.denied == 1)
            #expect(summary.current?.id == active.toolEvents[0].id)
            #expect(summary.issues == "1 failed · 1 denied")
            active.toolEvents[0].result = "Done"
            #expect(TranscriptActivity.summary(messages, activeAssistantID: active.id).current?.id == "queued")
            let stopped = TranscriptActivity.summary(messages, activeAssistantID: nil)
            #expect(stopped.current == nil)
            #expect(stopped.issues.contains("1 without a result"))
        }

        @Test func activityLabelsDescribeNativeActionsWithoutExposingFileContents() {
            var event = ToolEventSnapshot(
                id: "one", server: "GOATed", tool: "pen_write_file",
                arguments: #"{"path":"src/App.vue","content":"SECRET FILE CONTENT"}"#)
            #expect(ToolActivityLabel.title(event) == "Create file · src/App.vue")
            event.tool = "pen_run_command"
            event.arguments = #"{"command":"npm","args":["run","my-custom-script"]}"#
            #expect(ToolActivityLabel.title(event) == "Run command · npm run my-custom-script")
            event.arguments = "malformed"
            #expect(ToolActivityLabel.title(event) == "Run command")
            event.tool = "pen_search"
            event.arguments = #"{"query":"button"}"#
            #expect(ToolActivityLabel.title(event) == "Search files · button")
            event.tool = "custom_external_tool"
            #expect(ToolActivityLabel.title(event) == "GOATed · custom_external_tool")
            event.server = "Memory"
            event.tool = "memory_write"
            event.arguments = #"{"name":"aurora_handover","body":"PRIVATE BODY"}"#
            #expect(ToolActivityLabel.title(event) == "Memory · Save memory · aurora_handover")
        }

        @Test @MainActor func progressUsesObservedOutputAndNeverGuessesPrefill() {
            let user = ChatMessage(role: .user, createdAt: Date(timeIntervalSince1970: 1))
            let assistant = ChatMessage(role: .assistant, createdAt: Date(timeIntervalSince1970: 2))
            let session = ChatSession(effort: .trot, modelID: nil)
            session.messages = [user, assistant]
            session.isStreaming = true
            #expect(AgentProgressState(session: session).title == "Waiting for response")
            #expect(AgentProgressState(session: session).lastOutputAt == nil)
            assistant.generationStatus = "Retrying response (attempt 2)"
            #expect(AgentProgressState(session: session).title == "Retrying response (attempt 2)")
            assistant.appendStream(text: "", thinking: "I will inspect the file.")
            #expect(AgentProgressState(session: session).title == "Thinking")
            #expect(assistant.generationStatus == nil)
            let lastOutput = assistant.liveMetrics.lastOutputAt
            assistant.appendStream(text: "", thinking: "")
            #expect(assistant.liveMetrics.lastOutputAt == lastOutput)
            assistant.appendStream(text: "Here is my approach.", thinking: "")
            #expect(AgentProgressState(session: session).title == "Writing response")
            assistant.appendStream(text: "", thinking: "Now check the import.")
            #expect(AgentProgressState(session: session).title == "Thinking")
            assistant.appendStream(text: "", thinking: "", toolInputBytes: 50)
            #expect(AgentProgressState(session: session).title == "Preparing tool call")
            #expect(
                AgentProgressState(session: session).displayTitle(at: Date.now.addingTimeInterval(6))
                    == "Waiting for more output")
            assistant.toolEvents = activityMessage(result: nil).toolEvents
            assistant.complete = true
            #expect(AgentProgressState(session: session).title == "Reading file · src/App.vue")
            #expect(AgentProgressState(session: session, awaitingApproval: true).title == "Waiting for your permission")

        }

        @MainActor @Test func reasoningPreviewKeepsRecentContentAndElapsedClockKeepsSeconds() {
            #expect(ReasoningPreview("Inspect the file.").text == "Inspect the file.")
            #expect(!ReasoningPreview("Inspect the file.").hasEarlierText)
            let long = String(repeating: "Earlier thoughts. ", count: 500) + "Latest decision."
            let preview = ReasoningPreview(long)
            #expect(preview.hasEarlierText)
            #expect(preview.text.count == ReasoningPreview.characterLimit)
            #expect(preview.text.hasSuffix("Latest decision."))
            #expect(AssistantStatusRow<EmptyView>.elapsedLabel(125) == "2m 5s")
            #expect(AssistantStatusRow<EmptyView>.elapsedLabel(3_665) == "1h 1m 5s")
        }
    }
}

@MainActor final class TranscriptHistoryPagingTests: XCTestCase {
    func testTwoThousandMessagesRemainReachableWithoutLoadingThemAll() async throws {
        let model = AppModel.shared
        let previousDB = model.db
        let previousChats = model.chats
        let previousSelection = model.selectedChatID
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("goat-history-\(UUID()).sqlite")
        let db = try ChatDatabase(path: path.path)
        addTeardownBlock { [weak db] in
            // Never unlink a SQLite vnode while the actor still owns its connection pool.
            guard db == nil else { return }
            try? FileManager.default.removeItem(at: path)
        }
        let session = ChatSession(effort: .trot, modelID: nil)
        session.messagesLoaded = true
        model.db = db
        model.chats = [session]
        model.selectedChatID = session.id
        defer {
            model.db = previousDB
            model.chats = previousChats
            model.selectedChatID = previousSelection
        }
        try await db.save(model.record(for: session))
        var ids: [UUID] = []
        for index in 0..<2_000 {
            let id = UUID()
            ids.append(id)
            try await db.save(
                MessageRecord(
                    id: id.uuidString, chatId: session.id.uuidString,
                    role: index.isMultiple(of: 2) ? "user" : "assistant",
                    text: "Message \(index) 🐐", thinking: "", error: nil,
                    statsTtft: nil, statsTokens: nil, statsDuration: nil, complete: true,
                    position: index, createdAt: .now, generationProvenanceJson: "invalid saved details"))
        }
        session.messagesLoaded = false
        let started = ContinuousClock.now
        await model.loadMessages(for: session)
        print("HISTORY_OPEN rows=2000 admitted=\(session.messages.count) elapsed=\(started.duration(to: .now))")
        XCTAssertEqual(session.messages.map(\.id), Array(ids.suffix(40)))
        XCTAssertTrue(session.historyHasEarlier)
        XCTAssertNil(session.messages.first?.generationProvenance)
        XCTAssertFalse(session.messages.first?.generationProvenanceUnavailable ?? true)
        var visited = Set(session.messages.map(\.id))
        var pages = 0
        while session.historyHasEarlier && pages < 60 {
            let loaded = await model.pageHistory(for: session, earlier: true)
            XCTAssertTrue(loaded)
            XCTAssertLessThanOrEqual(session.messages.count, 120)
            visited.formUnion(session.messages.map(\.id))
            pages += 1
        }
        XCTAssertEqual(visited, Set(ids))
        XCTAssertFalse(session.historyHasEarlier)
        XCTAssertTrue(session.historyHasLater)
        pages = 0
        while session.historyHasLater && pages < 60 {
            let loaded = await model.pageHistory(for: session, earlier: false)
            XCTAssertTrue(loaded)
            XCTAssertLessThanOrEqual(session.messages.count, 120)
            pages += 1
        }
        XCTAssertEqual(session.messages.last?.id, ids.last)
        let held = try XCTUnwrap(session.messages.first)
        session.historyAnchorID = held.id
        let pending = ChatMessage(role: .user)
        pending.text = "New turn"
        session.messages.append(pending)
        let hydrated = await model.hydrateHistory(for: session)
        XCTAssertTrue(hydrated)
        XCTAssertEqual(session.messages.count, 2_001)
        XCTAssertTrue(session.messages.first(where: { $0.id == held.id }) === held)
        XCTAssertTrue(session.messages.last === pending)
        let receipt = model.controlSnapshot(
            turn: UUID(), record: .init(chatID: session.id, firstMessageID: pending.id), chat: session, running: false)
        XCTAssertEqual(receipt["text"], "", "Older assistant output must never become the new turn's receipt")
        XCTAssertTrue(session.hasCompleteHistory)
        session.messages.removeLast()
        model.trimHistory(for: session)
        XCTAssertLessThanOrEqual(session.messages.count, 120)
        XCTAssertTrue(session.messages.contains { $0.id == held.id })
        let around = await model.loadHistory(around: ids[500], for: session)
        XCTAssertTrue(around)
        XCTAssertLessThanOrEqual(session.messages.count, 41)
        XCTAssertTrue(session.messages.contains { $0.id == ids[500] })
        let matches = try await model.findInHistory("Message 5 🐐", for: session)
        XCTAssertEqual(matches.map(\.id), [ids[5]])
        XCTAssertLessThanOrEqual(session.messages.count, 41)
        let all = try await model.inspectHistory(for: session)
        XCTAssertEqual(all.map(\.id), ids)
        XCTAssertLessThanOrEqual(session.messages.count, 41, "Inspection must not replace the reader cache")
        let latest = await model.loadLatestHistory(for: session)
        XCTAssertTrue(latest)
        XCTAssertEqual(session.messages.map(\.id), Array(ids.suffix(40)))
        session.messages.first?.decodeStoredProvenance()
        XCTAssertTrue(session.messages.first?.generationProvenanceUnavailable ?? false)
        XCTAssertEqual(session.messages.first?.storedGenerationProvenance, "invalid saved details")
    }
}

extension TranscriptHistoryPagingTests {
    func testStreamingPublicationDoesNotReevaluateFortySettledRows() async throws {
        let session = ChatSession(effort: .trot, modelID: nil)
        session.messagesLoaded = true
        session.isStreaming = true
        session.messages = (0..<40).map { index in
            let message = ChatMessage(role: .assistant)
            message.text = "Settled row \(index), with **styled text**."
            message.complete = index != 39
            return message
        }
        let active = try XCTUnwrap(session.messages.last)
        let settledIDs = Set(session.messages.dropLast().map(\.id))
        let host = NSHostingView(
            rootView: ChatTranscriptView(session: session).environment(AppModel.shared)
                .environment(\.scenePhase, .active).allowsHitTesting(false))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 760, height: 520),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // This measures publication invalidation, not hover changes as rows move under the mouse.
        window.ignoresMouseEvents = true
        TranscriptRenderMetrics.enabled = true
        TranscriptRenderMetrics.evaluations = [:]
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        window.contentView = container
        // No pointer can cross a row during this publication-only measurement. Keep native
        // layout and all 40 admitted rows, but isolate user focus and scene activation changes.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        defer {
            TranscriptRenderMetrics.enabled = false
            TranscriptRenderMetrics.evaluations = [:]
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(
            Set(TranscriptRenderMetrics.evaluations.keys).isSuperset(of: Set(session.messages.map(\.id))),
            "The instrumentation must include all 40 admitted rows")
        TranscriptRenderMetrics.evaluations = [:]
        for index in 0..<20 {
            active.appendStream(text: " Publication \(index).", thinking: "")
            try await Task.sleep(for: .milliseconds(50))
        }
        let settled = TranscriptRenderMetrics.evaluations.filter { settledIDs.contains($0.key) }.values.reduce(0, +)
        let live = TranscriptRenderMetrics.evaluations[active.id, default: 0]
        print("TRANSCRIPT_EVALUATIONS admitted=40 publications=20 settled=\(settled) live=\(live)")
        XCTAssertEqual(settled, 0, "Streaming a tail must not reevaluate settled MessageView bodies")
        XCTAssertGreaterThan(live, 0, "The live row must still observe publication changes")
        XCTAssertLessThanOrEqual(live, 40)
    }
}

extension TranscriptHistoryPagingTests {
    func testDatabasePageRestoresTheHeldReaderThroughTheExistingExecutor() async throws {
        let model = AppModel.shared
        let previousDB = model.db
        let previousChats = model.chats
        let previousSelection = model.selectedChatID
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("goat-anchor-\(UUID()).sqlite")
        let db = try ChatDatabase(path: path.path)
        addTeardownBlock { [weak db] in
            // Never unlink a SQLite vnode while the actor still owns its connection pool.
            guard db == nil else { return }
            try? FileManager.default.removeItem(at: path)
        }
        let session = ChatSession(effort: .trot, modelID: nil)
        session.messagesLoaded = true
        model.db = db
        model.chats = [session]
        model.selectedChatID = session.id
        defer {
            model.db = previousDB
            model.chats = previousChats
            model.selectedChatID = previousSelection
        }
        try await db.save(model.record(for: session))
        for index in 0..<200 {
            try await db.save(
                MessageRecord(
                    id: UUID().uuidString, chatId: session.id.uuidString, role: "assistant",
                    text: "Reader row \(index). A stable paragraph with **emphasis**.\n\nSecond paragraph.",
                    thinking: "",
                    error: nil, statsTtft: nil, statsTokens: nil, statsDuration: nil,
                    complete: true, position: index, createdAt: .now))
        }
        session.messagesLoaded = false
        await model.loadMessages(for: session)
        let anchor = TranscriptViewport.Anchor(messageID: session.messages[5].id, offset: 13)
        let navigation = TranscriptViewport(initiallyFollowing: false, initialHeldRange: 0..<40, initialAnchor: anchor)
        let host = NSHostingView(
            rootView: ChatTranscriptView(session: session, viewport: navigation).environment(model)
                .environment(\.scenePhase, .active).allowsHitTesting(false))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 760, height: 520),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        let viewport = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        host.frame = viewport.bounds
        host.autoresizingMask = [.width, .height]
        viewport.addSubview(host)
        window.contentView = viewport
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        // Readiness, not a fixed sleep: initial Markdown preparation can finish after the
        // first placement and correctly request another restore. The geometry assertion below
        // retains the executor's 1 pt tolerance and rejects every abandoned request.
        func awaitPlacement() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            var quietSince: ContinuousClock.Instant?
            while ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                if navigation.request == nil {
                    if let quietSince, ContinuousClock.now - quietSince >= .milliseconds(300) { return }
                    if quietSince == nil { quietSince = ContinuousClock.now }
                } else {
                    quietSince = nil
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await awaitPlacement()
        XCTAssertNil(navigation.request, "Initial placement must finish: \(navigation.diagnostics)")
        XCTAssertEqual(navigation.abandonedRequests, 0)
        let fulfilled = navigation.diagnostics.filter { $0.hasPrefix("fulfilled ") }.count
        let loaded = await model.pageHistory(for: session, earlier: true)
        XCTAssertTrue(loaded)
        try await awaitPlacement()
        XCTAssertEqual(navigation.anchor, anchor)
        XCTAssertTrue(navigation.readerOwnsViewport)
        // SwiftUI can already preserve the row during reconciliation. Require the executor
        // to verify the new request, not to issue a redundant scroll when it is within 1 pt.
        XCTAssertGreaterThan(navigation.diagnostics.filter { $0.hasPrefix("fulfilled ") }.count, fulfilled)
        XCTAssertNil(
            navigation.request, "Page restore must satisfy the executor's 1 pt tolerance: \(navigation.diagnostics)")
        XCTAssertEqual(navigation.abandonedRequests, 0, navigation.diagnostics.joined(separator: "\n"))
        XCTAssertLessThanOrEqual(session.messages.count, 120)
    }
}

extension TranscriptHistoryPagingTests {
    func testShortReasoningCanBePagedWithoutScrollingFirst() async throws {
        let session = ChatSession(effort: .trot, modelID: nil)
        session.messagesLoaded = true
        let message = ChatMessage(role: .assistant)
        message.thinking = "First paragraph.\n\n```swift\nlet choice = 42\n```\n\nLast paragraph."
        message.complete = true
        session.messages = [message]
        ReasoningDisclosureStore.shared.set(.init(isOpen: true, showsAll: true), for: message.id)
        let owner = TranscriptViewport()
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousEnhancedUI = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(true, forAttribute: enhancedUI)
        let host = NSHostingView(
            rootView: ChatTranscriptView(session: session, viewport: owner).environment(AppModel.shared))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 760, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 900))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
            NSApp.accessibilitySetValue(previousEnhancedUI ?? false, forAttribute: enhancedUI)
        }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(owner.autoFollow, "The fixture must not require a preceding scroll gesture")
        var visited: Set<ObjectIdentifier> = []
        func value(_ object: NSObject, _ selectorName: String) -> Any? {
            let selector = NSSelectorFromString(selectorName)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        func find(_ object: Any) -> NSObject? {
            guard let object = object as? NSObject,
                visited.insert(ObjectIdentifier(object)).inserted
            else { return nil }
            let name =
                value(object, "accessibilityLabel") as? String
                ?? object.accessibilityAttributeValue(.description) as? String
            let role =
                value(object, "accessibilityRole") as? String
                ?? object.accessibilityAttributeValue(.role) as? String
            if name == "Earlier reasoning", role == NSAccessibility.Role.button.rawValue { return object }
            let children =
                value(object, "accessibilityChildren") as? [Any]
                ?? object.accessibilityAttributeValue(.children) as? [Any] ?? []
            for child in children {
                if let found = find(child) { return found }
            }
            return nil
        }
        let earlier = try XCTUnwrap(find(host), "Earlier reasoning must be an actionable control")
        // SwiftUI's AX node exposes the modern Objective-C action without declaring the
        // NSAccessibilityButton protocol. Call that BOOL-returning method with its correct ABI;
        // NSObject's deprecated accessibilityPerformAction implementation is a no-op here.
        let press = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(earlier.responds(to: press))
        let implementation = try XCTUnwrap(earlier.method(for: press))
        let performPress = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
        XCTAssertTrue(performPress(earlier, press))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(owner.readerOwnsViewport)
        let key = TranscriptSegmentOwner.reasoning(of: message.id)
        XCTAssertEqual(owner.segmentWindow(for: key)?.lowerBound, 0, "The first paragraph must remain reachable")
    }
}
