import AppKit
import Bleet
import Caprine
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
    var joinsPreviousTools = false
    var joinsNextTools = false
    var activeToolID: String? = nil
    var deleteCompaction: (() -> Void)? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var showingResponseDetails = false

    var body: some View {
        content
            .contentShape(Rectangle())  // whole row (incl. the area below the text) is hoverable
            .onHover { h in
                // Reduce Motion, the animations setting and inactive scenes all skip the fade (#60 D9).
                withAnimation(liveAnimations ? .easeOut(duration: 0.12) : nil) { hovering = h }
            }
            .sheet(isPresented: $showingResponseDetails) {
                ResponseDetailsView(message: message)
            }
            .contextMenu {
                if message.role == .assistant && ResponseDetailsView.hasUsefulDetails(message) {
                    Button("Response Details…", systemImage: "info.circle") {
                        showingResponseDetails = true
                    }
                }
            }
    }

    @ViewBuilder private var content: some View {
        if message.kind == .compaction, let info = message.compaction {
            CompactionRow(
                message: message,
                info: info,
                delete: deleteCompaction)
        } else {
            switch message.role {
            case .user: userBubble
            case .assistant:
                if TranscriptActivity.isEmpty(message) {
                    EmptyView()
                } else {
                    assistantBlock
                }
            case .system, .tool: EmptyView()
            }
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
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Self.relativeTime(message.createdAt, now: context.date))
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help(message.createdAt.formatted(date: .abbreviated, time: .standard))
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
        model.presentation.isEnabled && !message.complete && message.lastStreamActivity == .reasoning
    }

    private var assistantBlock: some View {
        AssistantRowLayout {
            if !compactActivity {
                Group {
                    if model.presentation.isEnabled && !TranscriptActivity.isToolOnly(message) {
                        GoatieView(pose: avatarPose, size: 60)
                    } else {
                        // Keep the smaller mark centred beside the label and duration without
                        // shrinking either line or retaining the previous wide avatar column.
                        FigureheadView(size: Caprine.Activity.standardAvatarWidth, fillsFrame: true)
                            .frame(
                                width: model.presentation.isEnabled
                                    ? Caprine.Activity.presentationAvatarWidth : Caprine.Activity.standardAvatarWidth
                            )
                            .frame(height: Caprine.Activity.singleLineHeight)
                            .frame(
                                height: message.complete || TranscriptActivity.isToolOnly(message)
                                    ? Caprine.Activity.singleLineHeight : Caprine.Activity.doubleLineHeight
                            )
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
            if compactActivity {
                Color.clear.frame(
                    width: model.presentation.isEnabled
                        ? Caprine.Activity.presentationAvatarWidth : Caprine.Activity.standardAvatarWidth,
                    height: Caprine.Activity.ruleWidth / 2
                )
            }
            VStack(alignment: .leading, spacing: Caprine.Activity.spacing) {
                if TranscriptText.hasContent(message.thinking) {
                    ThinkingDisclosure(message: message)
                }
                if TranscriptText.hasContent(message.text) {
                    StreamingMarkdownView(message: message)
                }
                if !message.toolEvents.isEmpty {
                    ToolActivityGroup(
                        messages: [message], activeAssistantID: activeToolID == nil ? nil : message.id,
                        projectID: projectID,
                        connectsAbove: joinsPreviousTools, connectsBelow: joinsNextTools)
                }
                if let error = message.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(Caprine.Semantic.warning)
                }
                if Self.showsFooter(for: message) {
                    // The footer row is reserved from the first answer text, so completion only reveals
                    // actions and never changes the row height (#60 A2, measurement 2). Continue sits in
                    // the same row and stays visible without hover when a reply stopped at its limit.
                    HStack(spacing: 10) {
                        if canContinue { continueButton }
                        footer
                            .opacity(message.complete && (hovering || memorySaveState == .saving) ? 1 : 0)
                            .allowsHitTesting(message.complete && hovering)
                            .accessibilityHidden(!message.complete)
                    }
                } else if canContinue {
                    // A reply truncated before any answer text has no footer row to share.
                    continueButton
                }
            }
        }
    }

    /// Every reply with answer text or an error has actions, including replies that also called tools
    /// (#60 D1). Replies with only reasoning or tool calls have nothing to copy or rate.
    static func showsFooter(for message: ChatMessage) -> Bool {
        message.role == .assistant && !TranscriptActivity.isEmpty(message)
            && (TranscriptText.hasContent(message.text) || message.error != nil)
    }

    private var canContinue: Bool {
        isLast && message.complete && message.stats?.finishReason == "length"
    }

    private var continueButton: some View {
        Button("Continue response", systemImage: "arrow.right.circle") {
            guard
                let session = model.chats.first(where: { chat in
                    chat.messages.contains { $0.id == message.id }
                })
            else { return }
            _ = model.send(
                "Continue from where the previous response stopped. Do not repeat completed content.",
                in: session)
        }
        .buttonStyle(.plain)
        .font(Caprine.Activity.font)
        .foregroundStyle(model.theme.tokens.tint)
        .disabled(model.shepherd.hasActiveTurn || model.engineTransitioning || !model.health.isOK)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // Scoped refresh: only this label re-renders as time passes (#60 B3).
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Self.relativeTime(message.createdAt, now: context.date))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .help(message.createdAt.formatted(date: .abbreviated, time: .standard))
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
                .font(Caprine.Activity.font)
                .foregroundStyle(model.theme.tokens.muted)
                .help("Regenerate (⌘R)")
            }
            CopyButton(text: message.text.isEmpty ? (message.error ?? "") : message.text)
                .labelStyle(.iconOnly)
                .font(.caption)
            if ResponseDetailsView.hasUsefulDetails(message) {
                Button("Response Details…", systemImage: "info.circle") {
                    showingResponseDetails = true
                }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .font(Caprine.Activity.font)
                .foregroundStyle(model.theme.tokens.muted)
                .help("Response Details")
            }
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

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter
    }()

    /// Relative to the timeline's date, so the label keeps moving without other invalidations.
    static func relativeTime(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 45 { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
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

struct CompactionRow: View {
    let message: ChatMessage
    let info: CompactionInfo
    let delete: (() -> Void)?
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    init(message: ChatMessage, info: CompactionInfo, delete: (() -> Void)?, initiallyExpanded: Bool = false) {
        self.message = message
        self.info = info
        self.delete = delete
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Caprine.Activity.spacing) {
            HStack(spacing: Caprine.Activity.spacing) {
                Button {
                    expanded.toggle()
                } label: {
                    Label {
                        Text("Compacted \(info.coveredExchangeCount) \(exchangeLabel)")
                            .font(Caprine.Activity.emphasizedFont)
                    } icon: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(Caprine.Activity.badgeFont)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")

                Spacer(minLength: Caprine.Activity.spacing)

                Menu {
                    Button("Delete compaction", systemImage: "arrow.uturn.backward", role: .destructive) {
                        delete?()
                    }
                    .disabled(delete == nil)
                    .help(
                        delete == nil
                            ? "Only the newest compaction can restore earlier prompt history."
                            : "Restore the earlier messages to prompt history."
                    )
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(model.theme.tokens.muted)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Compaction actions")
            }

            if expanded {
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

                fileList("Files edited", paths: info.filesEdited)
                fileList("Files read", paths: info.filesRead)
            }
        }
        .padding(Caprine.Activity.inset)
        .background(
            model.theme.tokens.surface.opacity(model.theme.tokens.bgOpacity),
            in: RoundedRectangle(cornerRadius: Caprine.Activity.radius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Caprine.Activity.radius)
                .strokeBorder(model.theme.tokens.muted.opacity(Caprine.Activity.cardBorderOpacity))
        }
        .accessibilityElement(children: .contain)
    }

    private var exchangeLabel: String {
        info.coveredExchangeCount == 1 ? "exchange" : "exchanges"
    }

    @ViewBuilder private func fileList(_ title: String, paths: [String]) -> some View {
        if !paths.isEmpty {
            VStack(alignment: .leading, spacing: Caprine.Activity.rowPadding) {
                Text(title)
                    .font(Caprine.Activity.badgeFont)
                    .foregroundStyle(model.theme.tokens.muted)
                ForEach(paths, id: \.self) { path in
                    Text(path)
                        .font(Caprine.Activity.monospaceFont)
                        .textSelection(.enabled)
                }
            }
        }
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
            button(1, "hand.thumbsup", Caprine.Semantic.success)
            button(-1, "hand.thumbsdown", Caprine.Semantic.warning)
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
    var penName: String? = nil

    var body: some View {
        if event.server == "Memory" {
            MemoryToolCallCard(event: event, live: live, penName: penName)
        } else {
            ExternalToolCallCard(event: event, live: live, penName: penName)
        }
    }
}

/// MCP tools retain a compact technical transcript. Their disclosure keeps the raw request and
/// response reachable without turning every completed call into a large card in the conversation.
private struct ExternalToolCallCard: View {
    @Environment(\.transcriptInspection) private var inspection
    @Environment(AppModel.self) private var model
    let event: ToolEventSnapshot
    let live: Bool
    var penName: String? = nil
    @State private var expanded = false

    private var presentation: ToolEventPresentation {
        ToolActivityLabel.presentation(for: event, rootName: penName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Caprine.Activity.compactSpacing) {
            Button {
                inspection.perform()
                expanded.toggle()
            } label: {
                HStack(spacing: Caprine.Activity.spacing) {
                    ToolCallStateIndicator(event: event, live: live)
                    Text(presentation.title)
                        .font(Caprine.Activity.emphasizedFont)
                        .strikethrough(event.denied)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(Caprine.Activity.badgeFont)
                        .foregroundStyle(.tertiary)
                    if event.denied {
                        Text("Denied").foregroundStyle(model.theme.tokens.muted)
                    } else if event.isError {
                        Text("Failed").foregroundStyle(model.theme.tokens.muted)
                    } else if !live && event.result == nil {
                        Text("No result").foregroundStyle(model.theme.tokens.muted)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("tool-event-" + event.id)
            .help("\(event.server) · \(event.tool)")
            if expanded {
                ToolCallDetails(event: event, penName: penName)
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
    var penName: String? = nil
    @Environment(AppModel.self) private var model
    @State private var detailsPresented = false

    @Environment(\.transcriptInspection) private var inspection

    private var presentation: ToolEventPresentation {
        ToolActivityLabel.presentation(for: event, rootName: penName)
    }

    private var action: String { presentation.action }
    private var hasDetails: Bool { presentation.hasDetails }

    var body: some View {
        HStack(spacing: Caprine.Activity.spacing) {
            Image(systemName: "brain.head.profile")
                .font(Caprine.Activity.font)
                .foregroundStyle(model.theme.tokens.tint)
            if hasDetails {
                Button {
                    inspection.perform()
                    detailsPresented.toggle()
                } label: {
                    label
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Memory · " + action)
                .help("Show memory operation details")
                .popover(
                    isPresented: $detailsPresented,
                    attachmentAnchor: .point(.bottomLeading), arrowEdge: .bottom
                ) {
                    MemoryOperationDetails(event: event, action: action, penName: penName)
                }
            } else {
                label
            }
            if live {
                GoatLoadingIndicator().controlSize(.mini)
            } else if event.isError || event.denied {
                Image(systemName: event.denied ? "hand.raised.fill" : "exclamationmark.triangle.fill")
                    .font(Caprine.Activity.font)
                    .foregroundStyle(
                        event.isError ? Caprine.Semantic.warning : model.theme.tokens.muted
                    )
                    .accessibilityLabel(event.denied ? "Denied" : "Failed")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Caprine.Activity.rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: some View {
        HStack(spacing: Caprine.Activity.spacing) {
            Text("Memory").font(Caprine.Activity.font.weight(.semibold))
            Text(action).font(Caprine.Activity.font).foregroundStyle(model.theme.tokens.muted)
                .lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle())
    }
}

/// Inspecting a memory operation should not resize the conversation. The popover keeps raw
/// protocol data available to curious users without making routine use feel like an MCP trace.
private struct MemoryOperationDetails: View {
    let event: ToolEventSnapshot
    let action: String
    var penName: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Caprine.Activity.inset) {
            HStack(spacing: Caprine.Activity.spacing) {
                Label(action, systemImage: "brain.head.profile").font(Caprine.Activity.headingFont)
                Spacer(minLength: 0)
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
            }
            ToolCallDetails(event: event, penName: penName)
        }
        .padding(Caprine.Activity.treeInset)
        .frame(width: Caprine.Activity.operationDetailsWidth, alignment: .leading)
    }
}

private struct ToolCallStateIndicator: View {
    @Environment(AppModel.self) private var model
    let event: ToolEventSnapshot
    let live: Bool

    var body: some View {
        if live {
            GoatLoadingIndicator().controlSize(.mini)
        } else if event.result == nil && !event.denied && !event.isError {
            Image(systemName: "clock")
                .foregroundStyle(model.theme.tokens.muted)
                .accessibilityLabel("Awaiting result")
        } else {
            Circle()
                .fill(
                    event.denied
                        ? Caprine.Semantic.denied
                        : (event.isError ? Caprine.Semantic.danger : Caprine.Semantic.success)
                )
                .frame(width: Caprine.Activity.statusDotSize, height: Caprine.Activity.statusDotSize)
        }
    }
}

private struct ToolCallDetails: View {
    @Environment(AppModel.self) private var model
    let event: ToolEventSnapshot
    var penName: String? = nil

    private var presentation: ToolEventPresentation {
        ToolActivityLabel.presentation(for: event, rootName: penName)
    }

    private var hasArguments: Bool { ToolCallPayload.containsValue(event.arguments) }
    private var hasResult: Bool { ToolCallPayload.containsValue(event.result) }

    private var investigationReceipt: SubagentReceipt? {
        // An MCP server may expose a tool with the same name; only GOAT's own extension owns receipts.
        guard event.server == "GOATed", event.tool == "subagent_delegate",
            let data = event.result?.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(SubagentReceipt.self, from: data)
    }

    var body: some View {
        if let receipt = investigationReceipt {
            SubagentInvestigationDetails(receipt: receipt, arguments: event.arguments)
        } else {
            VStack(alignment: .leading, spacing: Caprine.Activity.compactSpacing) {
                if hasArguments {
                    labeled("Arguments")
                    if model.showToolDiffs, let diff = presentation.diff {
                        ToolDiffView(diff: diff, rawJSON: event.arguments)
                    } else {
                        JSONTreeView(raw: event.arguments)
                    }
                }
                if hasArguments && hasResult {
                    Divider().padding(.vertical, Caprine.Activity.ruleWidth)
                }
                if hasResult, let result = event.result {
                    labeled(event.isError ? "Error" : "Result")
                    ScrollView {
                        if event.isError {
                            Text(result)
                                .font(Caprine.Activity.monospaceFont)
                                .foregroundStyle(Caprine.Semantic.warning)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            JSONTreeView(raw: result)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxHeight: Caprine.Activity.detailMaxHeight)
                }
            }
        }
    }

    private func labeled(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Caprine.Activity.badgeFont)
            .foregroundStyle(model.theme.tokens.muted)
    }
}

private struct SubagentInvestigationDetails: View {
    let receipt: SubagentReceipt
    let arguments: String
    @Environment(AppModel.self) private var model
    @State private var record: SubagentRunRecord?
    @State private var loadFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Caprine.Activity.spacing) {
            HStack {
                Label(statusLabel, systemImage: receipt.status == .completed ? "checkmark.circle" : "info.circle")
                    .font(Caprine.Activity.emphasizedFont)
                Spacer()
                if let record, let completed = record.completedAt {
                    Text("\(max(0, Int(completed.timeIntervalSince(record.createdAt))))s")
                        .font(Caprine.Activity.font)
                        .foregroundStyle(model.theme.tokens.muted)
                }
            }
            if !receipt.summary.isEmpty {
                Markdown(receipt.summary)
                    .markdownImageProvider(BlockedMarkdownImageProvider())
                    .markdownInlineImageProvider(BlockedMarkdownInlineImageProvider())
                    .goatMarkdownStyle(fontSize: model.chatFontSize)
                    .markdownBlockStyle(\.codeBlock) { configuration in
                        CodeBlockView(configuration: configuration)
                    }
                    .textSelection(.enabled)
            }
            if !receipt.citations.isEmpty {
                Text("Sources verified during this investigation")
                    .font(Caprine.Activity.badgeFont)
                    .foregroundStyle(model.theme.tokens.muted)
                ForEach(Array(receipt.citations.enumerated()), id: \.offset) { _, citation in
                    Button {
                        if let url = citationURL(citation) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    } label: {
                        Label("\(citation.path):\(citation.startLine)–\(citation.endLine)", systemImage: "doc.text")
                            .font(Caprine.Activity.monospaceFont)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.theme.tokens.tint)
                    .disabled(citationURL(citation) == nil)
                    .help("Reveal the source file in Finder. It may have changed since this investigation.")
                }
            }
            if !receipt.unresolved.isEmpty {
                Text("Unresolved")
                    .font(Caprine.Activity.badgeFont)
                ForEach(Array(receipt.unresolved.enumerated()), id: \.offset) { _, item in
                    Text([item.path, item.detail ?? item.reason].compactMap { $0 }.joined(separator: ": "))
                        .font(Caprine.Activity.font)
                        .foregroundStyle(model.theme.tokens.muted)
                        .textSelection(.enabled)
                }
            }
            if model.memory.builtInSettings.subagentDiagnosticsEnabled {
                DisclosureGroup("Diagnostics") {
                    VStack(alignment: .leading, spacing: Caprine.Activity.compactSpacing) {
                        Text("\(receipt.roundsExecuted) rounds · \(receipt.totalTokens) tokens")
                            .font(Caprine.Activity.font)
                        JSONTreeView(raw: arguments)
                        if let transcript = record?.transcriptJson {
                            ScrollView { JSONTreeView(raw: transcript) }
                                .frame(maxHeight: Caprine.Activity.detailMaxHeight)
                        } else if loadFailed {
                            Text("Saved transcript is unavailable. The result above is still available.")
                                .font(Caprine.Activity.font)
                        }
                    }
                }
                .font(Caprine.Activity.font)
            }
        }
        .task(id: receipt.runId) {
            record = nil
            loadFailed = false
            guard let db = model.db else {
                loadFailed = true
                return
            }
            do {
                let loaded = try await db.subagentRun(id: receipt.runId)
                guard !Task.isCancelled else { return }
                record = loaded
                loadFailed = loaded == nil
            } catch {
                guard !Task.isCancelled else { return }
                loadFailed = true
            }
        }
    }

    private var statusLabel: String {
        switch receipt.status {
        case .running: "Investigating"
        case .completed: "Investigation complete"
        case .timedOut: "Time limit reached"
        case .budgetExhausted: "Investigation limit reached"
        case .cancelled: "Investigation stopped"
        case .interrupted: "Investigation interrupted"
        case .failed: "Investigation could not finish"
        }
    }

    private func citationURL(_ citation: SubagentCitation) -> URL? {
        guard let record,
            let chat = model.chats.first(where: { $0.id.uuidString == record.chatId }),
            let penID = chat.projectID,
            let path = model.pens.first(where: { $0.id == penID })?.workspace?.path
        else { return nil }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let target = root.appendingPathComponent(citation.path).standardizedFileURL.resolvingSymlinksInPath()
        guard target.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: target.path) else {
            return nil
        }
        return target
    }
}

extension EnvironmentValues {
    /// Opens full reasoning instead of the recent excerpt when a disclosure first appears.
    @Entry var reasoningStartsExpanded = false
}

/// Reasoning stays visible when calls arrive. User choices survive stream updates.
struct ThinkingDisclosure: View {
    @Environment(\.transcriptInspection) private var inspection
    @Environment(\.reasoningStartsExpanded) private var startsExpanded
    let message: ChatMessage
    @State private var visible = true
    @State private var showAll = false
    @Environment(AppModel.self) private var model

    var body: some View {
        let preview = ReasoningPreview(message.thinking)
        VStack(alignment: .leading, spacing: Caprine.Activity.spacing) {
            HStack {
                Button {
                    inspection.perform()
                    visible.toggle()
                } label: {
                    HStack(spacing: Caprine.Activity.spacing) {
                        Image(systemName: visible ? "chevron.down" : "chevron.right")
                        Text("Reasoning")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(visible ? "Expanded" : "Collapsed")
                if let seconds = message.thinkingSeconds {
                    Text(AssistantStatusRow<EmptyView>.elapsedLabel(TimeInterval(seconds)))
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                CopyButton(text: message.thinking)
            }
            .font(Caprine.Activity.font)
            .foregroundStyle(model.theme.tokens.muted)
            if visible {
                ThinkingContentView(
                    source: TranscriptText.removingBoundaryBlankLines(
                        showAll ? message.thinking : preview.text),
                    cacheKey: "\(message.id.uuidString):thinking",
                    onPrepared: { message.markRenderChanged() }
                )
                .padding(.leading, Caprine.Activity.inset)
                .overlay(alignment: .leading) {
                    Rectangle().fill(model.theme.tokens.muted.opacity(Caprine.Activity.branchOpacity))
                        .frame(width: Caprine.Activity.ruleWidth)
                }
                if preview.hasEarlierText {
                    Button(showAll ? "Show recent reasoning" : "Show all reasoning") {
                        inspection.perform()
                        showAll.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(Caprine.Activity.font)
                    .foregroundStyle(model.theme.tokens.tint)
                }
            }
        }
        .onAppear { if startsExpanded { showAll = true } }
    }
}

/// A bounded live excerpt, with full content available without a nested scroll view.
struct ReasoningPreview {
    static let characterLimit = 1_400
    let text: String
    let hasEarlierText: Bool

    init(_ source: String) {
        let tail = source.suffix(Self.characterLimit + 1)
        hasEarlierText = tail.count > Self.characterLimit
        text = hasEarlierText ? String(tail.suffix(Self.characterLimit)) : source
    }
}
