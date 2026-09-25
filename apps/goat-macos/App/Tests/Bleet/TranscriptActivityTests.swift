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
        message.complete = true
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertGreaterThanOrEqual(host.fittingSize.height, initial, "Tool arrival must not collapse visible prose")
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
