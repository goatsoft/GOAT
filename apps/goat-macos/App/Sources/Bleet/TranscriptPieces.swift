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
    @Environment(AppModel.self) private var model
    @Environment(\.transcriptStreamingReplyID) private var streamingReplyID

    var body: some View {
        let text = TranscriptTexts.shared.answer(for: message)
        let showsCaret = Self.showsCaret(on: message, streamingReplyID: streamingReplyID)
        Group {
            if text.isPlain {
                if let parts = text.parts, parts.indices.contains(index) {
                    TranscriptPlainPart(
                        text: parts[index], fontSize: model.chatFontSize,
                        showsCaret: showsCaret && index == parts.count - 1)
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
                        isTail: showsCaret && index == document.segments.count - 1,
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
            } else if let thinking = reasoning.thinking, thinking.segments.indices.contains(index) {
                let segments = thinking.segments
                ThinkingSegmentView(
                    segment: segments[index],
                    joinsNext: index + 1 < segments.count && segments[index + 1].continuesPrevious
                )
                .padding(.top, index == 0 || segments[index].continuesPrevious ? 0 : 8)
            }
        }
        .foregroundStyle(model.theme.tokens.ink)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { reasoning.request() }
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
        let rect = rect.insetBy(dx: 0.5, dy: 0.5)
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
