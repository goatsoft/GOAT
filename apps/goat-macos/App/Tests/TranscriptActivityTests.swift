import AppKit
import Bleet
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

@Test @MainActor func activityGroupingPreservesOrderAndStopsAtLeadAndFinalReplies() {
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
    #expect(rows.map(\.id) == [first.id, lead.id, third.id, final.id])
    #expect(rows.map(\.isActivity) == [true, false, true, false])
    #expect(rows[0].messages.map(\.id) == [first.id, second.id])
    #expect(rows[0].messages[0] === first)
    #expect(first.text == "I’ll inspect the current component.")
    #expect(first.toolEvents[0].result == "Read successfully")
    let growing = TranscriptActivity.rows([first, second, activityMessage()][...])
    #expect(growing[0].id == first.id)
    let streaming = ChatMessage(role: .assistant)
    #expect(TranscriptActivity.rows([first, streaming][...]).count == 2)
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
}

@MainActor final class ToolActivityDisclosureTests: XCTestCase {
    func testHeaderClickExpandsAndCollapsesToolRounds() async throws {
        let messages = [
            activityMessage(), activityMessage("pen_edit_file"), activityMessage("pen_run_command", result: nil),
        ]
        let host = NSHostingView(
            rootView: ToolActivityGroup(messages: messages, activeAssistantID: messages.last?.id, projectID: nil)
                .environment(AppModel.shared))
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
        XCTAssertGreaterThan(expanded, collapsed + 60, "Clicking the header title must reveal tool rounds")
        window.setContentSize(NSSize(width: 660, height: expanded))
        try await Task.sleep(for: .milliseconds(100))
        try attachSnapshot(host, name: "Tool activity expanded")
        try clickHeader(host, in: window)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(host.fittingSize.height, collapsed, accuracy: 2)
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
        let point = host.convert(NSPoint(x: 140, y: host.isFlipped ? 20 : host.bounds.height - 20), to: nil)
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
