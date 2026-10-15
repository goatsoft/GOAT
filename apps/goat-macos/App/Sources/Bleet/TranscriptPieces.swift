import Bleet
import Caprine
import MarkdownUI
import SwiftUI

/// One segment of a message's answer (ADR-0104), or one plain part above the rich limit. It asks for its
/// segment's parse as it comes into view; until the parse is ready it reserves the segment's text height
/// without drawing raw Markdown. Only the reply whose output is still arriving shows the caret, on its
/// last segment.
struct AnswerPiece: View {
    let message: ChatMessage
    let index: Int

    /// Whether `message` carries the caret: it is the reply still arriving, until it completes. Reasoning
    /// never carries it.
    static func showsCaret(on message: ChatMessage, streamingReplyID: UUID?) -> Bool {
        message.role == .assistant && message.id == streamingReplyID && !message.complete
    }

    /// Whether the item at `index` of `count` carries the caret: only the last item of the reply still
    /// arriving.
    static func carriesCaret(on message: ChatMessage, index: Int, of count: Int, streamingReplyID: UUID?) -> Bool {
        showsCaret(on: message, streamingReplyID: streamingReplyID) && index == count - 1
    }
    @Environment(AppModel.self) private var model
    @Environment(\.transcriptStreamingReplyID) private var streamingReplyID

    var body: some View {
        let text = TranscriptTexts.shared.answer(for: message)
        Group {
            if text.isPlain {
                if let parts = text.parts, parts.indices.contains(index) {
                    TranscriptPlainPart(
                        text: parts[index], fontSize: model.chatFontSize,
                        showsCaret: Self.carriesCaret(
                            on: message, index: index, of: parts.count, streamingReplyID: streamingReplyID))
                } else {
                    // The last bytes, until the parts are prepared (a streaming reply's tail).
                    TranscriptPlainPart(
                        text: TranscriptTextParts.tail(message.text), fontSize: model.chatFontSize, showsCaret: false)
                }
            } else if let document = text.document, document.segments.indices.contains(index) {
                let segment = document.segments[index]
                if segment.isParsed {
                    MarkdownSegmentView(
                        // Incomplete text stays source-only (no live artifact previews) whether or not
                        // this transcript is the one streaming it.
                        segment: segment, fontSize: model.chatFontSize, isStreaming: !message.complete,
                        isTail: Self.carriesCaret(
                            on: message, index: index, of: document.segments.count, streamingReplyID: streamingReplyID),
                        codeSegment: MarkdownSegmentView.codeSegment(of: index, in: document.segments)
                    )
                    .equatable()
                    .environment(\.codeBlockMessageID, message.id)
                    // No margin on either block is SwiftUI's default padding, as in one Markdown document.
                    .padding(
                        .top,
                        index == 0
                            ? 0
                            : MarkdownSegmentSpacing.gap(
                                after: document.segments[index - 1], before: segment, fontSize: model.chatFontSize))
                } else {
                    PendingSegment(text: segment.body, fontSize: model.chatFontSize)
                }
            } else if index == 0 {
                // Never flash raw Markdown while a saved reply is being prepared off the main actor.
                Label("Formatting response…", systemImage: "text.badge.checkmark")
                    .font(Font(ReadingFonts.nsFont(model.effectiveChatFontID, size: model.chatFontSize, role: .chat)))
                    .foregroundStyle(.secondary)
            }
        }
        // Align the document boundary without searching nested lists and code scrollers.
        .alignmentGuide(.leading) { _ in 0 }
        .alignmentGuide(.trailing) { dimensions in dimensions.width }
        .onAppear { text.appeared(index) }
        .onDisappear { text.disappeared(index) }
    }
}

/// A segment whose parse is still being prepared: its text's height, without drawing it.
private struct PendingSegment: View {
    let text: String
    let fontSize: CGFloat
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(verbatim: text)
            .font(Font(ReadingFonts.nsFont(model.effectiveChatFontID, size: fontSize, role: .chat)))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .accessibilityHidden(true)
    }
}

/// One segment of a message's open reasoning, or one plain part above the rich limit.
struct ReasoningPiece: View {
    let message: ChatMessage
    let index: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        let reasoning = TranscriptTexts.shared.reasoning(for: message)
        Group {
            if reasoning.isPlain {
                if let parts = reasoning.parts, parts.indices.contains(index) {
                    TranscriptPlainPart(text: parts[index], fontSize: model.chatFontSize - 1, showsCaret: false)
                }
            } else if let thinking = reasoning.thinking, reasoning.groups.indices.contains(index) {
                let segments = thinking.segments
                let group = reasoning.groups[index].clamped(to: 0..<segments.count)
                ReasoningGroup(
                    segments: Array(segments[group]), startsReasoning: group.lowerBound == 0,
                    joinsNext: group.upperBound < segments.count && segments[group.upperBound].continuesPrevious
                )
                .equatable()
            }
        }
        .foregroundStyle(model.theme.tokens.ink)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { reasoning.request() }
    }
}

/// The thinking segments of one reasoning item, compared by value: the reasoning is prepared again on
/// every streamed update, and a group whose segments did not change is neither evaluated nor measured
/// again.
private struct ReasoningGroup: View, Equatable {
    let segments: [ThinkingSegment]
    let startsReasoning: Bool
    /// The segment after the group continues its last one.
    let joinsNext: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(segments.indices, id: \.self) { index in
                let segment = segments[index]
                ThinkingSegmentView(
                    segment: segment,
                    joinsNext: index + 1 < segments.count ? segments[index + 1].continuesPrevious : joinsNext
                )
                .padding(
                    .top, (index == 0 && startsReasoning) || segment.continuesPrevious ? 0 : Caprine.Activity.spacing)
            }
        }
    }
}

/// A segment item of a split reply (ADR-0104): a piece of its open reasoning, or an answer segment that
/// does not carry the avatar, in the reply's column. It is built from values only and reads nothing of
/// the streaming message, which changes on every update, so the lazy stack keeps a settled segment's
/// measurement instead of laying every segment of the reply out again.
struct ReplySegmentItem: View, Equatable {
    let message: ChatMessage
    let part: TranscriptItem.Part
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    @Environment(AppModel.self) private var model
    @Environment(\.transcriptPresenter) private var presenter
    @State private var hovering = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message === rhs.message && lhs.part == rhs.part && lhs.topPadding == rhs.topPadding
            && lhs.bottomPadding == rhs.bottomPadding
    }

    var body: some View {
        AssistantRowLayout {
            Color.clear.frame(
                width: model.presentation.isEnabled
                    ? Caprine.Activity.presentationAvatarWidth : Caprine.Activity.standardAvatarWidth,
                height: Caprine.Activity.ruleWidth / 2)
            content
        }
        .accessibilityElement(children: .contain)
        .contentShape(Rectangle())
        // Hovering any piece of the reply shows its actions in its tail.
        .onHover { isHovering in
            guard isHovering != hovering else { return }
            hovering = isHovering
            TranscriptTexts.shared.answer(for: message).hover(isHovering)
        }
        .onDisappear {
            if hovering { TranscriptTexts.shared.answer(for: message).hover(false) }
            hovering = false
        }
        .contextMenu {
            Button("Copy Markdown", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            }
            Button("Copy plain text", systemImage: "text.alignleft") {
                let source = message.text
                let pasteboardVersion = NSPasteboard.general.changeCount
                Task { @MainActor in
                    let text = await Task.detached(priority: .userInitiated) {
                        MarkdownContent(source).renderPlainText()
                    }.value
                    guard NSPasteboard.general.changeCount == pasteboardVersion else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            if let showDetails = presenter.showDetails, ResponseDetailsView.hasUsefulDetails(message) {
                Button("Response Details…", systemImage: "info.circle") { showDetails(message) }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch part {
        case .reasoning(let index):
            ReasoningPiece(message: message, index: index)
                .reasoningRule(model.theme.tokens.muted)
                .padding(.top, topPadding)
                .padding(.bottom, bottomPadding)
                // Its own group, named: an assistive reader tells reasoning from the answer that follows.
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Reasoning")
        case .answer(let index):
            AnswerPiece(message: message, index: index)
                .padding(.top, topPadding)
                .padding(.bottom, bottomPadding)
        case .whole, .head, .tail:
            EmptyView()
        }
    }
}

/// Plain selectable text: a part of text above the rich limit.
struct TranscriptPlainPart: View {
    let text: String
    let fontSize: CGFloat
    var showsCaret = false
    @Environment(AppModel.self) private var model

    var body: some View {
        let view = Text(verbatim: text)
            .font(Font(ReadingFonts.nsFont(model.effectiveChatFontID, size: fontSize, role: .chat)))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        if showsCaret { view.modifier(StreamingCaret()) } else { view }
    }
}

/// The outline of one piece of a user bubble split into items: its sides, and the top or bottom edge
/// with rounded corners when it is the first or last piece, so the pieces read as one bubble.
struct BubblePieceOutline: Shape {
    let first: Bool
    let last: Bool
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(radius, rect.width / 2, rect.height / 2)
        // Half a point in from the edges the stroke must not overrun; a seam with the next piece is
        // not an edge, so the sides run through it and the pieces' outlines meet.
        let rect = CGRect(
            x: rect.minX + 0.5, y: first ? rect.minY + 0.5 : rect.minY, width: rect.width - 1,
            height: rect.height - (first ? 0.5 : 0) - (last ? 0.5 : 0))
        // Left side, from bottom to top.
        path.move(to: CGPoint(x: rect.minX, y: last ? rect.maxY - r : rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: first ? rect.minY + r : rect.minY))
        if first {
            path.addArc(
                center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180),
                endAngle: .degrees(270), clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addArc(
                center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(270),
                endAngle: .degrees(0), clockwise: false)
        } else {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: last ? rect.maxY - r : rect.maxY))
        if last {
            path.addArc(
                center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(0),
                endAngle: .degrees(90), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            path.addArc(
                center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(90),
                endAngle: .degrees(180), clockwise: false)
        }
        return path
    }
}
