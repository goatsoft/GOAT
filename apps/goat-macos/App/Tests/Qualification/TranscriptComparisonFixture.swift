import AppKit
import Bleet
import Caprine
import Foundation
import Persistence
import SwiftUI

@testable import GOAT

/// Test-only row inputs shared by both container candidates. No service or command is executed.
@MainActor @Observable final class ComparisonRow: Identifiable {
    enum Content {
        case message(ChatMessage)
        case markdown(ChatMessage, PreparedMarkdownSegment, Int)
        case reasoning(ThinkingSegment)
        case tools(ChatMessage)
        case label(String)
    }
    let id: String
    var content: Content
    var revision = 0
    init(_ id: String, _ content: Content) {
        self.id = id
        self.content = content
    }
}

@MainActor @Observable final class TranscriptComparisonFixture {
    var rows: [ComparisonRow] = []
    var generation = 0
    var viewportWidth: CGFloat = 0
    var following = true
    var latestRequest = 0
    var visible: Set<String> = []
    var frames: [String: CGRect] = [:]
    var peakVisible = 0
    var heightUpdates = 0
    var status = "Ready"
    var composer = ""
    var finished = false
    let markdown = MarkdownSegmentCache()
    let thinking = ThinkingPreparation()
    let active = ChatMessage(role: .assistant)
    let liveTools = ChatMessage(role: .assistant)
    var answerStart = 0
    var reasoningStart = 0
    var lastChanged: Range<Int> = 0..<0

    func appeared(_ id: String) {
        visible.insert(id)
        peakVisible = max(peakVisible, visible.count)
    }
    func disappeared(_ id: String) {
        visible.remove(id)
        frames[id] = nil
    }

    func seed(rounds: Int = 48) async throws {
        for round in 0..<rounds {
            let user = ChatMessage(role: .user)
            user.text =
                "Review change \(round): consult project memory, delegate a source audit, run the tests and show the code and previews."
            user.complete = true
            rows.append(ComparisonRow("user-\(round)", .message(user)))
            rows.append(ComparisonRow("header-\(round)", .label("GOAT · response \(round)")))
            let reasoning = try await thinking.segments(Self.reasoningBlock(round))
            for segment in reasoning {
                rows.append(ComparisonRow("reason-\(round)-\(segment.index)", .reasoning(segment)))
            }
            let toolMessage = ChatMessage(role: .assistant)
            toolMessage.complete = true
            toolMessage.toolEvents = Self.tools(round)
            rows.append(ComparisonRow("tools-\(round)", .tools(toolMessage)))
            let answer = ChatMessage(role: .assistant)
            answer.text = Self.answerBlock(round)
            answer.complete = true
            if let doc = await markdown.prepare(
                id: answer.id, source: answer.text, revision: answer.textRevision, isComplete: true)
            {
                for segment in doc.segments {
                    rows.append(
                        ComparisonRow(
                            "answer-\(round)-\(segment.index)", .markdown(answer, segment.unparsed(), segment.index)))
                }
            }
            rows.append(ComparisonRow("footer-\(round)", .label("Completed · synthetic replay · response \(round)")))
        }
        rows.append(ComparisonRow("live-header", .label("GOAT · live replay")))
        rows.append(ComparisonRow("live-tools", .tools(liveTools)))
        reasoningStart = rows.count
        answerStart = rows.count
        generation += 1
    }

    func replayTools() async throws {
        for completed in Self.tools(999) {
            var pending = completed
            pending.result = nil
            liveTools.toolEvents.append(pending)
            liveTools.complete = false
            generation += 1
            try await Task.sleep(for: .milliseconds(120))
            liveTools.toolEvents[liveTools.toolEvents.count - 1] = completed
            generation += 1
        }
        liveTools.complete = true
    }

    /// Only changed tail rows are replaced; settled row objects keep their identity and revision.
    func append(_ delta: String, reasoning: Bool, complete: Bool = false) async throws {
        active.appendStream(text: reasoning ? "" : delta, thinking: reasoning ? delta : "")
        active.complete = complete
        let start = reasoning ? reasoningStart : answerStart
        if reasoning {
            let prepared = try await thinking.prepare(
                id: active.id, source: active.thinking, revision: active.thinkingRevision)
            let oldCount = rows.count - start
            let first = min(prepared.segments.count, max(0, oldCount - 2))
            if rows.count > start + prepared.segments.count {
                rows.removeLast(rows.count - start - prepared.segments.count)
            }
            for index in first..<prepared.segments.count {
                let content = ComparisonRow.Content.reasoning(prepared.segments[index])
                if start + index < rows.count {
                    rows[start + index].content = content
                    rows[start + index].revision += 1
                } else {
                    rows.append(ComparisonRow("live-reason-\(index)", content))
                }
            }
            lastChanged = (start + first)..<rows.count
            answerStart = rows.count
        } else if let doc = await markdown.prepare(
            id: active.id, source: active.text, revision: active.textRevision, isComplete: complete, window: .latest)
        {
            let oldCount = rows.count - start
            let first = min(doc.segments.count, max(0, oldCount - 2))
            if rows.count > start + doc.segments.count { rows.removeLast(rows.count - start - doc.segments.count) }
            for index in first..<doc.segments.count {
                let content = ComparisonRow.Content.markdown(
                    active, doc.segments[index].unparsed(),
                    SegmentedMarkdownView.codeSegment(of: index, in: doc.segments))
                if start + index < rows.count {
                    rows[start + index].content = content
                    rows[start + index].revision += 1
                } else {
                    rows.append(ComparisonRow("live-answer-\(index)", content))
                }
            }
            lastChanged = (start + first)..<rows.count
        }
        generation += 1
    }

    static func answerBlock(_ index: Int) -> String {
        let longCode =
            index.isMultiple(of: 3)
            ? "\n```swift title=Expanded\(index).swift\n"
                + (0..<96).map { "let item\($0) = \($0) // line \($0), scroll and expand this block\n" }.joined()
                + "```\n" : ""
        return """
            ## Change \(index): bounded rendering

            The investigation found a stable-prefix cache and a layout invalidation at the visible tail. Preserve **reader ownership**, account for `renderedBytes`, and keep cold preparation off the main actor.

            - Check memory findings before editing.
            - Verify the delegated source audit against the implementation.
            - Keep user-visible output and diagnostics separate.

            ```swift title=Cache\(index).swift
            struct CacheEntry {
                let revision: UInt64
                let sourceBytes: Int
                func accepts(_ next: UInt64) -> Bool {
                    next >= revision
                }
            }
            ```

            | Check | Result |
            | --- | --- |
            | Unit tests | Passed |
            | Reader anchor | Requires measurement |

            ```html title=report\(index).html
            <html><body><h2>Review \(index)</h2><p>Local synthetic preview.</p></body></html>
            ```

            ```svg title=status\(index).svg
            <svg xmlns="http://www.w3.org/2000/svg" width="240" height="80"><rect width="240" height="80" fill="#285A46"/><text x="12" y="44" fill="white">Review \(index) complete</text></svg>
            ```

            \(longCode)

            > Next: test a narrow inspector layout while the answer continues to grow.

            This is a deterministic fixture, including Unicode: café, 日本語, 🐐. No network resources are loaded.


            """
    }

    static func reasoningBlock(_ index: Int) -> String {
        """
        Investigation \(index): reconcile the memory note with source evidence. The tool result may be incomplete; inspect its status before drawing a conclusion.

        ```swift
        let oldRevision = 42
        let changed = incomingRevision != oldRevision
        ```

        Compare the completed answer and the still-growing tail. Check horizontal code overflow, the preview boundary, and reader position after folding. Retain uncertainty until the measurements agree.


        """
    }

    static func tools(_ index: Int) -> [ToolEventSnapshot] {
        [
            ToolEventSnapshot(
                id: "memory-\(index)", server: "Memory", tool: "recall",
                arguments: #"{"query":"transcript architecture"}"#,
                result: #"{"items":[{"text":"Preserve reader position and bounded caches","source":"project notes"}]}"#),
            ToolEventSnapshot(
                id: "read-\(index)", server: "GOATed", tool: "pen_read_file",
                arguments: #"{"path":"Sources/Transcript.swift"}"#, result: "struct Transcript { let revision: UInt64 }"
            ),
            ToolEventSnapshot(
                id: "command-\(index)", server: "GOATed", tool: "pen_run_command",
                arguments: #"{"command":"swift test"}"#,
                result: #"{"exit_code":0,"stdout":"Executed 48 tests, 0 failures"}"#),
            ToolEventSnapshot(
                id: "delegate-\(index)", server: "GOATed", tool: "subagent_delegate",
                arguments: #"{"objective":"Audit cache invalidation","scope_hint":"Sources"}"#,
                result:
                    #"{"run_id":"fixture","status":"completed","summary":"Checked source and test coverage. Layout still needs live qualification.","citations":[],"unresolved":[],"rounds_executed":3,"total_tokens":1200}"#
            ),
            ToolEventSnapshot(
                id: "failure-\(index)", server: "GOATed", tool: "pen_read_file",
                arguments: #"{"path":"missing.swift"}"#, result: "File not found", isError: true),
        ]
    }

    static func source(bytes: Int, reasoning: Bool, dense: Bool) -> String {
        let block =
            dense
            ? "Paragraph **dense**.\n\n```swift\nlet value = 42\n```\n\n"
            : reasoning ? reasoningBlock(99) : answerBlock(99)
        let data = Array(String(repeating: block, count: bytes / block.utf8.count + 1).utf8)
        // End at a Unicode scalar boundary; ASCII padding keeps the requested byte total exact.
        var prefix = Array(data.prefix(bytes))
        while String(bytes: prefix, encoding: .utf8) == nil { prefix.removeLast() }
        return String(decoding: prefix, as: UTF8.self) + String(repeating: " ", count: bytes - prefix.count)
    }
}

struct ComparisonRowView: View {
    let row: ComparisonRow
    let fixture: TranscriptComparisonFixture
    var reportsSwiftUIFrame = true
    var measured: (CGFloat) -> Void = { _ in }
    @Environment(AppModel.self) private var model
    @State private var prepared: PreparedMarkdownSegment?

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { measured($0) }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) {
                if reportsSwiftUIFrame { fixture.frames[row.id] = $0 }
            }
            .onAppear { fixture.appeared(row.id) }
            .onDisappear { fixture.disappeared(row.id) }
            .task(id: row.revision) {
                guard case .markdown(let message, let segment, _) = row.content else { return }
                let revision = message.textRevision
                let doc = await fixture.markdown.prepare(
                    id: message.id, source: message.text, revision: revision, isComplete: message.complete,
                    window: .segments(segment.index..<(segment.index + 1)))
                guard !Task.isCancelled, let doc, doc.segments.indices.contains(segment.index) else { return }
                prepared = doc.segments[segment.index]
            }
    }

    @ViewBuilder private var content: some View {
        switch row.content {
        case .message(let message): MessageView(message: message, isLast: false, projectID: nil)
        case .tools(let message):
            ToolActivityGroup(
                messages: [message], activeAssistantID: message.complete ? nil : message.id, projectID: nil)
        case .reasoning(let segment): ThinkingSegmentView(segment: segment, joinsNext: false)
        case .label(let label): Text(label).font(.caption).foregroundStyle(model.theme.tokens.muted)
        case .markdown(let message, let segment, let codeSegment):
            if let prepared {
                MarkdownSegmentView(
                    segment: prepared, fontSize: model.chatFontSize, isStreaming: !message.complete,
                    isTail: !message.complete && !segment.isSettled, codeSegment: codeSegment
                )
                .environment(\.codeBlockMessageID, message.id)
            } else {
                Text(verbatim: segment.body).font(.system(size: model.chatFontSize))
            }
        }
    }
}
