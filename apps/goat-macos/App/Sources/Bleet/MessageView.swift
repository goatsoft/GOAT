import AppKit
import Bleet
import CoreGraphics
import Herd
import Inference
import MarkdownUI
import Persistence
import SwiftUI

struct MessageView: View {
    let message: ChatMessage
    let isLast: Bool
    let projectID: UUID?
    var compactActivity = false
    var activeToolID: String? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var showingResponseDetails = false

    var body: some View {
        content
            .contentShape(Rectangle())  // whole row (incl. the area below the text) is hoverable
            .onHover { h in
                withAnimation(.easeOut(duration: 0.12)) { hovering = h }
            }
            .sheet(isPresented: $showingResponseDetails) {
                ResponseDetailsView(message: message)
            }
    }

    @ViewBuilder private var content: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistantBlock
        case .system, .tool: EmptyView()
        }
    }

    // MARK: User

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachmentPaths.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(message.attachmentPaths, id: \.self) { path in
                                StoredAttachmentThumbnail(path: path)
                            }
                        }
                    }
                    .frame(maxWidth: 420, alignment: .trailing)
                }
                PreparedMarkdownView(
                    id: message.id,
                    source: message.text,
                    fallbackFontSize: model.chatFontSize
                ) { content in
                    Markdown(content)
                        .markdownImageProvider(BlockedMarkdownImageProvider())
                        .markdownInlineImageProvider(BlockedMarkdownInlineImageProvider())
                        .goatMarkdownStyle(fontSize: model.chatFontSize)
                        .markdownBlockStyle(\.codeBlock) { configuration in
                            CodeBlockView(configuration: configuration)
                        }
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(model.theme.tokens.bubbleGradient, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(model.theme.tokens.accent.opacity(0.18))
                )
                if let error = message.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let notice = message.contextNotice {
                    Label(notice, systemImage: "text.badge.minus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                HStack(spacing: 8) {
                    CopyButton(text: message.text)
                        .labelStyle(.iconOnly)
                        .font(.caption2)
                    Text(relativeTime(message.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.trailing, 2)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
        }
    }

    // MARK: Assistant

    private var avatarPose: Goatie {
        Goatie.assistant(complete: message.complete, hasError: message.error != nil)
    }

    /// The speech bubble (wave dots inside) rides the avatar until visible words arrive -
    /// through the whole thinking phase. The avatar wears the thinking pose meanwhile.
    private var showThinkingBubble: Bool {
        model.presentation.isEnabled && !message.complete && message.text.isEmpty
    }

    private var assistantBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            if !compactActivity {
                Group {
                    if model.presentation.isEnabled {
                        GoatieView(pose: avatarPose, size: 60)
                    } else {
                        // Keep the smaller mark centred beside the label and duration without
                        // shrinking either line or retaining the previous wide avatar column.
                        FigureheadView(size: 28, fillsFrame: true)
                            .frame(height: 17)
                            .frame(height: message.complete ? 17 : 34)
                    }
                }
                .padding(.top, 1)
                .overlay(alignment: .top) {
                    if showThinkingBubble {
                        ThinkingBubble(
                            tint: model.theme.tokens.tint,
                            height: 30,
                            animates: liveAnimations
                        )
                        .fixedSize()
                        // Position the bubble above the avatar without covering the reasoning disclosure.
                        .offset(x: 44, y: -28)
                        .transition(.scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity))
                        .zIndex(1)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if !message.complete || !message.thinking.isEmpty {
                    Group {
                        if !message.thinking.isEmpty {
                            ThinkingDisclosure(message: message)
                        } else {
                            AssistantStatusRow(startedAt: message.complete ? nil : message.createdAt) {
                                if message.text.isEmpty {
                                    PrefillStatusLabel(startedAt: message.createdAt)
                                }
                            }
                        }
                    }
                    .padding(.top, model.presentation.isEnabled ? 12 : 0)
                }
                if message.complete && !message.text.isEmpty {
                    PreparedMarkdownView(
                        id: message.id,
                        source: message.text,
                        fallbackFontSize: model.chatFontSize,
                        onPrepared: { message.markRenderChanged() }
                    ) { content in
                        Markdown(content)
                            .markdownImageProvider(BlockedMarkdownImageProvider())
                            .markdownInlineImageProvider(BlockedMarkdownInlineImageProvider())
                            .goatMarkdownStyle(fontSize: model.chatFontSize)
                            .markdownBlockStyle(\.codeBlock) { configuration in
                                CodeBlockView(configuration: configuration)
                            }
                            .textSelection(.enabled)
                    }
                } else if !message.text.isEmpty {
                    StreamingMarkdownView(message: message)
                }
                ForEach(message.toolEvents) { event in
                    ToolCallCard(
                        event: event, live: event.id == activeToolID || (!message.complete && !isSettled(event)))
                }
                if let error = message.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if message.complete {
                    footer
                        .opacity(hovering || memorySaveState == .saving ? 1 : 0)
                        .allowsHitTesting(hovering)
                }
            }
            .alignmentGuide(.top) { _ in 0 }
            if !compactActivity { Spacer(minLength: 40) }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(relativeTime(message.createdAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let stats = message.stats {
                Text(statsLine(stats))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                if stats.toksPerSec > 100 {
                    SpeedBadge()
                }
            }
            Spacer().frame(width: 2)
            if isLast {
                Button("Regenerate", systemImage: "arrow.counterclockwise") {
                    Task { await model.regenerate() }
                }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Regenerate (⌘R)")
            }
            CopyButton(text: message.text.isEmpty ? (message.error ?? "") : message.text)
                .labelStyle(.iconOnly)
                .font(.caption)
            Button("Response Details…", systemImage: "info.circle") {
                showingResponseDetails = true
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Response Details")
            rememberButton
            FeedbackButtons(message: message)
        }
    }

    private var memorySaveState: MessageMemorySaveState? { model.messageMemorySaves[message.id] }

    private var rememberButton: some View {
        Button {
            model.remember(message)
        } label: {
            Image(systemName: "brain")
                .opacity(memorySaveState == .saving ? 0 : 1)
                .overlay {
                    if memorySaveState == .saving {
                        ProgressView().controlSize(.mini)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if memorySaveState?.isAccepted == true {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .offset(x: 4, y: 3)
                    } else if case .failed = memorySaveState {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .offset(x: 4, y: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(memorySaveState?.isAccepted == true ? model.theme.tokens.tint : Color.secondary)
        .disabled(!model.canRemember(message, projectID: projectID))
        .accessibilityLabel(memorySaveState?.help ?? "Remember This")
        .help(memorySaveState?.help ?? "Remember This")
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Date.now.timeIntervalSince(date)
        if seconds < 45 { return "just now" }
        return date.formatted(.relative(presentation: .named))
    }

    private func statsLine(_ stats: GenStats) -> String {
        let speedApprox = stats.speedIsServerReported ? "" : "~"
        let tokenApprox = stats.tokensAreExact ? "" : "~"
        var parts: [String] = []
        parts.append("\(speedApprox)\(Int(stats.toksPerSec)) tok/s")
        if let ttft = stats.ttft {
            parts.append(String(format: "%.1fs ttft", ttft))
        }
        parts.append("\(tokenApprox)\(stats.tokens) tok")
        return parts.joined(separator: " · ")
    }

    private var liveAnimations: Bool {
        model.animationsEnabled && !reduceMotion && scenePhase == .active
    }
}

private struct StoredAttachmentThumbnail: View {
    let path: String
    @State private var image: CGImage?
    @State private var document: TextAttachment?
    @State private var failed = false

    var body: some View {
        Group {
            if let document {
                VStack(spacing: 5) {
                    Image(systemName: "doc.text").font(.title2)
                    Text((document.name as NSString).pathExtension.uppercased())
                        .font(.caption2.weight(.semibold))
                    Text(document.name).font(.caption2).lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.25))
                .help(document.name)
                .accessibilityLabel(document.name)
            } else if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.secondary.opacity(0.08)
                    if failed {
                        Image(systemName: "photo.badge.exclamationmark")
                            .foregroundStyle(.secondary)
                    } else {
                        GoatLoadingIndicator().controlSize(.small)
                    }
                }
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: path) {
            image = nil
            document = nil
            failed = false
            if TextAttachment.isStoredDocument(path) {
                let loaded = await ChatAttachmentImporter.shared.storedDocument(path)
                guard !Task.isCancelled else { return }
                document = loaded
                failed = loaded == nil
                return
            }
            let loaded = await ImageFileWorker.shared.storedAttachment(named: path)
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
        }
    }
}

extension MessageView {
    fileprivate func isSettled(_ event: ToolEventSnapshot) -> Bool {
        event.result != nil || event.denied
    }
}

/// Thumbs up/down - toggles local rating and fires the goat easter eggs.
struct FeedbackButtons: View {
    let message: ChatMessage
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            button(1, "hand.thumbsup", .green)
            button(-1, "hand.thumbsdown", .orange)
        }
    }

    private func button(_ value: Int, _ symbol: String, _ onColor: Color) -> some View {
        Button {
            let wasSet = message.rating == value
            model.rateMessage(message, rating: wasSet ? 0 : value)
        } label: {
            Image(systemName: message.rating == value ? symbol + ".fill" : symbol)
                .foregroundStyle(message.rating == value ? onColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .font(.caption)
        .help(value > 0 ? "Good response" : "Bad response")
    }
}

struct ToolCallCard: View {
    let event: ToolEventSnapshot
    let live: Bool

    var body: some View {
        if event.server == "Memory" {
            MemoryToolCallCard(event: event, live: live)
        } else {
            ExternalToolCallCard(event: event, live: live)
        }
    }
}

/// MCP tools retain a compact technical transcript. Their disclosure keeps the raw request and
/// response reachable without turning every completed call into a large card in the conversation.
private struct ExternalToolCallCard: View {
    let event: ToolEventSnapshot
    let live: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    ToolCallStateIndicator(event: event, live: live)
                    Text(ToolActivityLabel.title(event))
                        .font(.caption.weight(.medium))
                        .strikethrough(event.denied)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .help("\(event.server) · \(event.tool)")
            if expanded {
                ToolCallDetails(event: event)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Memory is built into GOAT, so it reads as a lightweight in-conversation action rather than an
/// external tool card. Raw data remains available on demand without competing with the response.
private struct MemoryToolCallCard: View {
    let event: ToolEventSnapshot
    let live: Bool
    @Environment(AppModel.self) private var model
    @State private var detailsPresented = false

    private var action: String {
        switch event.tool {
        case "memory_list": "Browse saved memories"
        case "memory_read": "Read a saved memory"
        case "memory_write": "Save a memory"
        case "memory_capture_session": "Save this session"
        case "memory_handoff": event.result ?? "Save the handover"
        case "memory_delete": "Remove a memory"
        case "wiki_ingest_source": "Capture a source"
        case "wiki_list_sources": "Browse source captures"
        case "wiki_read_source": "Read a source capture"
        case "wiki_query": "Search the knowledge pages"
        case "wiki_lint": "Check the knowledge pages"
        default: event.tool.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private var hasDetails: Bool {
        ToolCallPayload.containsValue(event.arguments) || ToolCallPayload.containsValue(event.result)
    }

    var body: some View {
        if hasDetails {
            Button {
                detailsPresented.toggle()
            } label: {
                header
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            // The button fills the transcript width for easy clicking; pin the popover to its
            // leading edge so it opens under Memory instead of in the middle of the chat.
            .popover(
                isPresented: $detailsPresented,
                attachmentAnchor: .point(.bottomLeading),
                arrowEdge: .bottom
            ) {
                MemoryOperationDetails(event: event, action: action)
            }
        } else {
            header
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.theme.tokens.tint)
            Text("Memory")
                .font(.caption.weight(.semibold))
            Text(action)
                .font(.caption)
                .foregroundStyle(.secondary)
            if live {
                GoatLoadingIndicator().controlSize(.mini)
            } else if event.isError || event.denied {
                Image(systemName: event.denied ? "hand.raised.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(event.isError ? .orange : .secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Inspecting a memory operation should not resize the conversation. The popover keeps raw
/// protocol data available to curious users without making routine use feel like an MCP trace.
private struct MemoryOperationDetails: View {
    let event: ToolEventSnapshot
    let action: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(action, systemImage: "brain.head.profile")
                .font(.headline)
            ToolCallDetails(event: event)
        }
        .padding(16)
        .frame(width: 520, alignment: .leading)
    }
}

private struct ToolCallStateIndicator: View {
    let event: ToolEventSnapshot
    let live: Bool

    var body: some View {
        if live {
            GoatLoadingIndicator().controlSize(.mini)
        } else if event.result == nil && !event.denied && !event.isError {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Awaiting result")
        } else {
            Circle()
                .fill(event.denied ? .gray : (event.isError ? .red : .green))
                .frame(width: 8, height: 8)
        }
    }
}

private struct ToolCallDetails: View {
    let event: ToolEventSnapshot

    private var hasArguments: Bool { ToolCallPayload.containsValue(event.arguments) }
    private var hasResult: Bool { ToolCallPayload.containsValue(event.result) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasArguments {
                labeled("Arguments")
                JSONTreeView(raw: event.arguments)
            }
            if hasArguments && hasResult {
                Divider().padding(.vertical, 2)
            }
            if hasResult, let result = event.result {
                labeled(event.isError ? "Error" : "Result")
                ScrollView {
                    if event.isError {
                        Text(result)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.orange)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        JSONTreeView(raw: result)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    private func labeled(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}

private enum ToolCallPayload {
    /// A JSON `{}` or `[]` is a valid tool payload, but it does not convey anything worth
    /// rendering. `memory_list`, for example, intentionally needs no arguments.
    static func containsValue(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let data = trimmed.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data)
        else {
            return true
        }
        if let dictionary = value as? [String: Any] { return !dictionary.isEmpty }
        if let array = value as? [Any] { return !array.isEmpty }
        return !(value is NSNull)
    }
}

/// The rumination disclosure: while thinking streams it shows a live tail of the
/// latest thought (collapsed) with rippling dots; once words arrive it settles into
/// "Thought 12s ▸". Timing is session-local - reloaded chats show a plain "Thought".
struct ThinkingDisclosure: View {
    let message: ChatMessage
    @State private var expanded = false
    @Environment(AppModel.self) private var model

    private var live: Bool { !message.complete && message.text.isEmpty }

    private var title: String {
        if live { return "Thinking…" }
        if let s = message.thinkingSeconds { return "Thought \(s)s" }
        return "Thought"
    }

    /// The freshest slice of rumination, one line, newest end kept.
    private var tail: String {
        ThinkingFenceParser.isFenceLine(message.thinkingTail) ? "" : message.thinkingTail
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Model reasoning").font(.caption).foregroundStyle(model.theme.tokens.muted)
                    Spacer()
                    CopyButton(text: message.thinking)
                }
                ScrollView {
                    if expanded {
                        ThinkingContentView(source: message.thinking)
                    }
                }
                .frame(maxHeight: 280)
            }
            .padding(12)
            .background(model.theme.tokens.surface, in: RoundedRectangle(cornerRadius: 10))
        } label: {
            AssistantStatusRow(startedAt: message.complete ? nil : message.createdAt) {
                HStack(spacing: 7) {
                    ThinkingLabel(title: title, live: live)
                        .layoutPriority(1)
                    if live, !expanded, !tail.isEmpty {
                        Text(tail)
                            .font(.caption)
                            .italic()
                            .foregroundStyle(model.theme.tokens.muted)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: 440, alignment: .leading)
                    }
                }
            }
        }
    }
}

/// Prefill status shown before the first token. Reads "Thinking…" briefly, then switches to
/// "Waiting for the engine (prefill)" once prompt evaluation passes a short threshold, so a long
/// prefill does not read as a freeze (ADR-0089). The elapsed clock comes from AssistantStatusRow.
struct PrefillStatusLabel: View {
    let startedAt: Date
    static let prefillNoticeThreshold: TimeInterval = 10
    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let waiting = context.date.timeIntervalSince(startedAt) >= Self.prefillNoticeThreshold
            ThinkingLabel(title: waiting ? "Waiting for the engine (prefill)" : "Thinking…", live: true)
        }
    }
}
