import AppKit
import Bleet
import Caprine
import Hoofprint
import SwiftUI

struct TranscriptInspectionAction: Sendable {
    var perform: @MainActor @Sendable () -> Void = {}
}

private struct TranscriptInspectionKey: EnvironmentKey {
    static let defaultValue = TranscriptInspectionAction()
}

extension EnvironmentValues {
    var transcriptInspection: TranscriptInspectionAction {
        get { self[TranscriptInspectionKey.self] }
        set { self[TranscriptInspectionKey.self] = newValue }
    }
}

/// The keys a message's items are measured under (ADR-0104). A message's first item and its answer
/// segments use its ID; its reasoning segments and its tail use keys derived from that ID.
enum TranscriptSegmentOwner {
    /// The key a message's reasoning segments are measured under. Applying it twice gives the ID back.
    static func reasoning(of messageID: UUID) -> UUID {
        var bytes = messageID.uuid
        bytes.15 ^= 0xA5
        return UUID(uuid: bytes)
    }

    /// The key a split message's tail is measured under. Applying it twice gives the ID back.
    static func tail(of messageID: UUID) -> UUID {
        var bytes = messageID.uuid
        bytes.15 ^= 0x5A
        return UUID(uuid: bytes)
    }

    /// Whether `key` is the message itself, its reasoning or its tail.
    static func key(_ key: UUID, belongsTo messageID: UUID) -> Bool {
        key == messageID || key == reasoning(of: messageID) || key == tail(of: messageID)
    }
}

/// Loading a database page of history at one end, while it runs.
private enum TranscriptPagingPhase: Equatable, Sendable {
    case idle
    case pagingEarlier
    case pagingLater
}

struct TranscriptRevealRequest: Equatable, Sendable {
    let token = UUID()
    let messageID: UUID
    let byteOffset: Int
    var match: TranscriptText.SearchMatch? = nil
}

/// The transcript's single navigation owner (#54 section 2, #60 A1, ADR-0104).
///
/// It holds who owns the viewport, the reader's anchor and at most one pending scroll request. Reader
/// gestures, history loads, restoration, compaction, jumps to the latest output and content changes
/// arrive as explicit events. `ChatTranscriptView` performs each request with one mechanism
/// (`TranscriptScrollExecutor`) and reports when the geometry shows it fulfilled. Raw scroll measurements
/// stay in the view's non-observable reader state. Nothing is windowed: every loaded message is an item
/// of the transcript's lazy stack.
@MainActor @Observable final class TranscriptViewport {
    /// A reading position: an item, and how far the viewport's top edge is below the item's top edge. A
    /// negative offset leaves space above it. The item is a message's first item (`segment` nil), or a
    /// segment of its answer or reasoning (`messageID` is then the message or its reasoning key), or a
    /// split message's tail (its tail key).
    struct Anchor: Equatable, Sendable {
        var messageID: UUID
        var offset: CGFloat
        var segment: Int? = nil
    }

    enum Target: Equatable, Sendable {
        case bottom
        case anchor(Anchor)
    }

    /// A scroll for the executor. A newer request replaces an older one, and a completion reported
    /// for a replaced request is ignored.
    struct Request: Equatable, Sendable {
        let target: Target
        let generation: UInt64
    }

    /// True while the viewport follows the latest output; false while the reader owns it.
    private(set) var autoFollow: Bool
    var readerOwnsViewport: Bool { !autoFollow }
    /// Presentation only: false shows the jump-to-latest button.
    var isScrolledToBottom: Bool
    @ObservationIgnored weak var historySession: ChatSession?
    /// The message an anchor's key belongs to: reasoning and tail keys map back to their message.
    @ObservationIgnored var messageForKey: (UUID) -> UUID? = { $0 }
    private(set) var anchor: Anchor? {
        didSet { historySession?.historyAnchorID = anchor.flatMap { messageForKey($0.messageID) } }
    }
    private(set) var request: Request?
    private var generation: UInt64 = 0
    /// Scroll commands issued and requests abandoned after the bounded attempts, for instrumentation.
    @ObservationIgnored private(set) var scrollCommands = 0
    /// Sheets and popovers that rows present. The relayout after a reflow replaces every row, which would
    /// dismiss them and discard what they hold (an unsaved edit), so it waits while any is open.
    private(set) var layoutHolds = 0
    func holdLayout() { layoutHolds += 1 }
    func releaseLayout() { layoutHolds = max(0, layoutHolds - 1) }
    /// How many times the lazy stack took a new identity after a reflow.
    @ObservationIgnored private(set) var relayouts = 0
    func recordRelayout() { relayouts += 1 }
    @ObservationIgnored private(set) var abandonedRequests = 0
    /// The executor's recent steps, for test failure messages and debugging. Bounded.
    @ObservationIgnored private(set) var diagnostics: [String] = []

    /// Prints every step when set, for debugging navigation beyond the bounded diagnostics.
    nonisolated static let traces = ProcessInfo.processInfo.environment["GOAT_TRANSCRIPT_TRACE"] == "1"

    func note(_ event: String) {
        if Self.traces { print("TRANSCRIPT_TRACE \(event)") }
        diagnostics.append(event)
        if diagnostics.count > 40 { diagnostics.removeFirst(diagnostics.count - 40) }
    }

    init(initiallyFollowing: Bool = true, initialAnchor: Anchor? = nil) {
        autoFollow = initiallyFollowing
        isScrolledToBottom = initiallyFollowing
        if !initiallyFollowing, let initialAnchor { restore(initialAnchor) }
    }

    /// How many times the reader took the viewport, so a deferred correction can tell it was overtaken.
    @ObservationIgnored private(set) var readerMoves = 0

    /// A reader gesture, keyboard or scroller movement, or an inspection took the viewport. The
    /// reader's input always wins, so any pending scroll is cancelled.
    func readerMoved(anchor: Anchor? = nil, replacingUnknown: Bool = false) {
        readerMoves &+= 1
        if Self.traces {
            note(
                "readerMoved anchor \(anchor.map { "\($0.messageID.uuidString.prefix(4))+\(Int($0.offset))" } ?? "nil")"
            )
        }
        autoFollow = false
        if let anchor {
            self.anchor = anchor
        } else if replacingUnknown {
            // A direct move to rows not laid out yet: the previous anchor no longer describes the
            // reader's position; the rows that lay out there supply the next one.
            self.anchor = nil
        }
        request = nil
    }

    /// The rows at a reader's position laid out after a move that had no measurable anchor.
    func adoptAnchor(_ anchor: Anchor) {
        guard readerOwnsViewport, self.anchor == nil, request == nil else { return }
        if Self.traces { note("adopt \(anchor.messageID.uuidString.prefix(4))+\(Int(anchor.offset))") }
        self.anchor = anchor
    }

    /// A reader gesture ended. Only a gesture ending at the conversation's true bottom hands the
    /// viewport back to following; geometry alone never does.
    func readerSettled(atTrueBottom: Bool, anchor: Anchor?) {
        // Where the gesture ended is the reader's place: a restore still pending from before it (a relayout
        // putting the anchor back) must not take the viewport away again.
        if let request, request.target != .bottom {
            if Self.traces { note("settled over \(request.generation)") }
            self.request = nil
        }
        if atTrueBottom {
            autoFollow = true
            self.anchor = nil
            // Settle on the items' real end, which a stale content estimate can leave below the viewport.
            if request == nil { issue(.bottom) }
        } else if let anchor {
            self.anchor = anchor
        }
    }

    /// The jump-to-latest action, or a new user turn: follow and scroll to the bottom.
    func jumpToLatest() {
        autoFollow = true
        isScrolledToBottom = true
        anchor = nil
        issue(.bottom)
    }

    /// Content grew, regrouped or reflowed. Following asks for the bottom. A reader's position needs no
    /// request: the lazy stack keeps its topmost visible row in place as rows above, below or within the
    /// viewport change size (WWDC26 "Dive into lazy stacks and scrolling with SwiftUI"), and the explicit
    /// restores (history loads, restoration, reveal, compaction) issue their own. An equal pending request
    /// is kept, so repeated changes coalesce.
    func contentChanged() {
        guard autoFollow, request?.target != .bottom else { return }
        issue(.bottom)
    }

    /// Following lost the items' end (a blank viewport was rescued): a fresh bottom request settles on it.
    func followAgain() {
        guard autoFollow else { return }
        issue(.bottom)
    }

    /// Makes `anchor` the reader's position and scrolls to it (history loads, restoration, compaction).
    func restore(_ anchor: Anchor) {
        if Self.traces {
            note(
                "restore \(anchor.messageID.uuidString.prefix(4))+\(Int(anchor.offset)) seg \(anchor.segment.map(String.init) ?? "-")"
            )
        }
        autoFollow = false
        self.anchor = anchor
        issue(.anchor(anchor))
    }

    /// Shows `anchor` (find, a link to a message).
    func reveal(_ anchor: Anchor) {
        isScrolledToBottom = false
        restore(anchor)
    }

    /// Records were added or evicted around the reader (a history page). Their items moved, not their
    /// identity: the reader's anchor is put back where it was. Following follows.
    func historyRebased() {
        guard readerOwnsViewport, let anchor else {
            contentChanged()
            return
        }
        restore(anchor)
    }

    /// Messages were removed (compaction, deletion). A reader whose anchor's message went continues at
    /// `fallback`, the first surviving message at their place.
    func messagesRemoved(anchorSurvives: Bool, fallback: UUID?) {
        guard readerOwnsViewport, !anchorSurvives, let fallback else { return }
        restore(Anchor(messageID: fallback, offset: 0))
    }

    /// The executor saw `request` fulfilled. A replaced request leaves the newer one pending.
    func fulfilled(_ request: Request) {
        if self.request == request { self.request = nil }
    }

    /// The executor gave up on `request` after its bounded attempts.
    func abandon(_ request: Request) {
        guard self.request == request else { return }
        abandonedRequests += 1
        self.request = nil
    }

    func recordScrollCommand() { scrollCommands += 1 }

    private func issue(_ target: Target) {
        generation &+= 1
        request = Request(target: target, generation: generation)
    }
}

/// Its owner keys this view by chat ID. A new chat gets fresh native scroll geometry,
/// measured row layout and follow tasks instead of inheriting another transcript's viewport.
struct ChatTranscriptView: View {
    @Bindable var session: ChatSession
    var revealRequest: TranscriptRevealRequest?
    var focusRequest: UUID?
    @FocusState private var focusedMessageID: UUID?
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State var viewport: TranscriptViewport
    @State private var reader = TranscriptReaderState()
    /// False until the first placement: at the latest output when following, else once the restored
    /// anchor's request ends. Until then SwiftUI's initial bottom offset applies, and a restoring
    /// transcript is not shown at a position it is about to leave.
    @State private var initiallyPlaced = false
    @State private var followThrottle = TranscriptFollowThrottle()
    @State private var pagingPhase: TranscriptPagingPhase = .idle
    @State private var isHoveringScrollButton = false
    /// Bumped once a reflow (font or reading width) settles; identifies the lazy stack's layout.
    @State private var layoutGeneration = 0
    /// A relayout waiting for the sheets and popovers rows present to close.
    @State private var relayoutDeferred = false
    @State private var reflowTask: Task<Void, Never>?

    /// Distance from the bottom within which the latest content counts as shown, for both the
    /// jump button and a reader's return to following.
    static let bottomTolerance: CGFloat = 50
    /// Attempts per request while layout settles before it is abandoned (and instrumented).
    static let maximumScrollAttempts = 12
    /// How long an attempt waits for a target row that has not laid out, so a target that never renders
    /// is abandoned after `maximumScrollAttempts` of them.
    static let frameRetryInterval = Duration.milliseconds(50)
    /// Scheduler delays must not turn twelve nominal waits into an unbounded pending target.
    static let maximumFrameWait = frameRetryInterval * maximumScrollAttempts

    init(
        session: ChatSession,
        initiallyFollowing: Bool = true,
        initialVisibleMessageID: UUID? = nil,
        viewport: TranscriptViewport? = nil,
        revealRequest: TranscriptRevealRequest? = nil,
        focusRequest: UUID? = nil
    ) {
        self.session = session
        self.revealRequest = revealRequest
        self.focusRequest = focusRequest
        // Restoration anchors to a message that renders: a missing or removed message shows the latest
        // output, and a tool result or empty message gives way to its nearest rendered message.
        let start =
            initiallyFollowing
            ? nil : initialVisibleMessageID.flatMap { id in session.messages.firstIndex(where: { $0.id == id }) }
        let restoredAnchor = start.flatMap { Self.renderedMessageID(near: $0, of: session.messages) }
        _viewport = State(
            initialValue: viewport
                ?? TranscriptViewport(
                    initiallyFollowing: initiallyFollowing,
                    initialAnchor: restoredAnchor.map { TranscriptViewport.Anchor(messageID: $0, offset: 0) }
                ))
    }

    @State private var historyTask: Task<Void, Never>?
    /// The message whose edit sheet, or response details, the transcript presents.
    @State private var editing: ChatMessage?
    @State private var detailing: ChatMessage?

    var body: some View {
        if session.isLoadingMessages || (!session.messagesLoaded && session.messageLoadError == nil) {
            VStack(spacing: 10) {
                GoatLoadingIndicator()
                Text("Loading transcript...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = session.messageLoadError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Caprine.Semantic.warning)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { model.retryMessageLoad(for: session) }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.messages.isEmpty {
            ContentUnavailableView(
                "Start a conversation", systemImage: "bubble.left.and.bubble.right",
                description: Text("Ask a question or attach a file below.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // The proxy is the last resort for a target the lazy stack will not lay out (`awaitLayout`).
            ScrollViewReader { proxy in
                ScrollView {
                    // One centred reading column shared with the composer (#60 D3).
                    BoundedWidthLayout(maximumWidth: readingColumn) {
                        // Lazy: only items near the viewport are laid out. A plain stack re-measured every
                        // row, including the scroll view's ideal-size pass, on each streamed update (#85,
                        // ADR-0099). Everything sits in the one lazy stack: a plain stack around it measured
                        // it in full again (Delivery 3 reasoning on macOS 26: 19 s became 78 s). Long replies
                        // are split into items, so the stack lays out only their segments near the
                        // viewport (ADR-0104).
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if pagingPhase == .pagingEarlier || session.isPagingHistory && session.historyHasEarlier {
                                ProgressView().controlSize(.small)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            if let error = session.historyPageError {
                                HStack {
                                    Text(error).font(.caption).foregroundStyle(Caprine.Semantic.warning)
                                    Button("Retry") { loadHistoryIfNear(force: true) }.font(.caption)
                                }
                            }
                            let context = itemContext
                            ForEach(transcriptItems) { item in
                                itemView(item, context: context)
                            }
                            if pagingPhase == .pagingLater || session.isPagingHistory && session.historyHasLater {
                                ProgressView().controlSize(.small)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            if session.isStreaming && !session.historyHasLater {
                                AgentProgressView(session: session)
                                    .padding(.top, Caprine.Activity.spacing)
                            }
                            // Space below the last row, so the latest line never sits on the window edge.
                            Color.clear
                                .frame(height: Caprine.Activity.doubleLineHeight + 1)
                        }
                        .scrollTargetLayout()
                        // A reflow leaves every row the lazy stack has not laid out since with its height
                        // from the old layout, so the content's size and every estimate are wrong until each
                        // row is seen again. A new identity once the reflow settles makes it estimate from
                        // rows laid out in the new layout.
                        .id(layoutGeneration)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity)
                    .coordinateSpace(.named(transcriptContentSpace))
                    .background { TranscriptScrollAttachment(executor: reader.executor) }
                }
                // A restoring transcript appears at the reader's anchor, not where it starts.
                .opacity(initiallyPlaced || viewport.autoFollow ? 1 : 0)
                .overlay(alignment: .bottom) {
                    ZStack {
                        if !viewport.isScrolledToBottom {
                            Button {
                                jumpToLatest()
                            } label: {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(tokens.ink)
                                    .frame(width: 32, height: 32)
                                    .background(
                                        tokens.surface.opacity(isHoveringScrollButton ? 1.0 : 0.92),
                                        in: Circle()
                                    )
                                    .overlay(
                                        Circle().strokeBorder(
                                            tokens.muted.opacity(isHoveringScrollButton ? 0.6 : 0.35),
                                            lineWidth: 1
                                        )
                                    )
                                    .shadow(color: Caprine.Semantic.shadow.opacity(0.25), radius: 4, y: 2)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help(session.isStreaming ? "New output, jump to latest" : "Jump to latest")
                            .accessibilityLabel(session.isStreaming ? "New output, jump to latest" : "Jump to latest")
                            .keyboardShortcut(.end, modifiers: [.command])
                            .accessibilityIdentifier("chat-transcript-scroll-bottom-button")
                            .padding(.bottom, Caprine.Activity.inset)
                            .onHover { isHoveringScrollButton = $0 }
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        }
                    }
                    // Only the button animates: a transaction animation would also fade the rows the lazy
                    // stack inserts and removes in the same update, drawing a row twice as it cross-fades.
                    .animation(
                        model.animationsEnabled && !reduceMotion ? .easeInOut(duration: 0.2) : nil,
                        value: viewport.isScrolledToBottom)
                }
                .environment(\.transcriptViewport, viewport)
                .environment(\.transcriptStreamingReplyID, streamingReplyID)
                .environment(
                    \.transcriptInspection,
                    TranscriptInspectionAction {
                        viewport.readerMoved(anchor: reader.measuredAnchor())
                    }
                )
                .environment(
                    \.transcriptPresenter,
                    TranscriptPresenter(edit: { editing = $0 }, showDetails: { detailing = $0 })
                )
                // Presented here, outside the lazy stack: recreating the item that asked never dismisses
                // them or discards an unsaved edit.
                .sheet(item: $editing) { message in
                    TranscriptMessageEditor(source: message.text) { text, original in
                        await model.editAndResend(message, text: text, previousText: original, in: session)
                    }
                }
                .sheet(item: $detailing) { message in
                    ResponseDetailsView(message: message)
                }
                // No initial bottom offset: SwiftUI re-applies it on later size changes, which a lazy stack
                // makes continuous as estimates resolve. Following places the transcript at its end through
                // the executor, before the first placement shows it.
                .defaultScrollAnchor(.bottom, for: .alignment)
                // Keep the reader's content in place as rows grow below it; the owner corrects any
                // remaining anchor movement explicitly.
                .defaultScrollAnchor(.top, for: .sizeChanges)
                .onScrollGeometryChange(for: TranscriptScrollMetrics.self) { geometry in
                    TranscriptScrollMetrics(geometry)
                } action: { previous, metrics in
                    handleGeometry(from: previous, to: metrics)
                }
                // Reader gestures own the viewport until they end at the true bottom.
                .onScrollPhaseChange { _, phase in
                    if phase == .tracking || phase == .interacting || phase == .decelerating {
                        if !reader.isScrolling { viewport.note("gesture \(phase)") }
                        reader.isScrolling = true
                        reader.proxyLanding = nil
                        viewport.readerMoved(anchor: reader.measuredAnchor())
                    } else if phase == .idle {
                        let readerFinishedScrolling = reader.isScrolling
                        reader.isScrolling = false
                        guard readerFinishedScrolling else { return }
                        viewport.note("gesture settled at \(Int(reader.metrics.offset))")
                        viewport.readerSettled(
                            atTrueBottom: !session.historyHasLater && reader.isAtBottom, anchor: reader.measuredAnchor()
                        )
                        loadHistoryIfNear()
                        // A scroll that ended where the lazy stack lays out nothing is rescued there, once the
                        // rows it does lay out have had a moment to report.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(60))
                            guard !reader.isScrolling else { return }
                            rescueBlankViewport(atReader: true)
                        }
                    }
                }
                // A move attributed to the reader after the rows report ends following with no further
                // geometry change, so the jump button is updated here as well as on geometry.
                .onChange(of: viewport.autoFollow) {
                    let showsLatest = viewport.autoFollow || reader.isAtBottom
                    if viewport.isScrolledToBottom != showsLatest { viewport.isScrolledToBottom = showsLatest }
                }
                .onChange(of: viewport.request) {
                    if viewport.request == nil {
                        placeInitiallyIfReady()
                        // History near an end loads once the reader is where the request put them.
                        Task { @MainActor in
                            await Task.yield()
                            loadHistoryIfNear()
                        }
                    }
                    // A replaced request does not wait out its predecessor's frame deadline.
                    cancelFrameWait()
                    executePendingRequest()
                }
                // Streaming growth (text, thinking, new messages): following chases it; a reader keeps
                // their anchor.
                .onChange(of: streamRevision) { viewport.contentChanged() }
                .onAppear {
                    viewport.historySession = session
                    viewport.messageForKey = { [session] key in
                        session.messages.first(where: { TranscriptSegmentOwner.key(key, belongsTo: $0.id) })?.id
                    }
                    session.historyAnchorID = viewport.anchor.flatMap { viewport.messageForKey($0.messageID) }
                }
                .onChange(of: session.historyRevision) { viewport.historyRebased() }
                .onChange(of: focusRequest) {
                    guard focusRequest != nil else { return }
                    let anchor = reader.measuredAnchor()
                    guard
                        let id = anchor.flatMap({ viewport.messageForKey($0.messageID) })
                            ?? Self.renderedMessageID(near: 0, of: session.messages)
                    else { return }
                    // Keyboard focus is reader input: cancel any pending automatic restore before native
                    // focus moves.
                    viewport.readerMoved(anchor: anchor)
                    focusedMessageID = id
                }
                .task(id: revealRequest) {
                    guard let revealRequest else { return }
                    guard await model.loadHistory(around: revealRequest.messageID, for: session), !Task.isCancelled,
                        let message = session.messages.first(where: { $0.id == revealRequest.messageID })
                    else { return }
                    let source = message.text
                    let complete = message.complete
                    let offset = revealRequest.byteOffset
                    let plain = TranscriptTexts.shared.answer(for: message).isPlain
                    let segmented = message.role == .assistant && message.kind == .regular && !plain
                    // The item that holds the match: a segment of a rich answer, or a plain part.
                    let worker = Task.detached(priority: .userInitiated) { () -> (index: Int?, count: Int) in
                        if segmented {
                            let segments = MarkdownSegmenter.segment(source, isComplete: complete).segments
                            return (segments.firstIndex { $0.sourceRange.contains(offset) }, segments.count)
                        }
                        guard plain, let parts = try? TranscriptTextParts.split(source) else { return (nil, 0) }
                        var end = 0
                        for (index, part) in parts.enumerated() {
                            end += part.utf8.count
                            if offset < end { return (index, parts.count) }
                        }
                        return (parts.count - 1, parts.count)
                    }
                    let (index, count) = await withTaskCancellationHandler {
                        await worker.value
                    } onCancel: {
                        worker.cancel()
                    }
                    guard !Task.isCancelled else { return }
                    reader.isScrolling = false
                    followThrottle.reset()
                    // A message laid out whole has no segment items: its first item holds the match.
                    let segment = (plain || count > 1) ? index : nil
                    viewport.reveal(.init(messageID: message.id, offset: 0, segment: segment))
                }
                .onChange(of: session.isStreaming) { viewport.contentChanged() }
                .onChange(of: ReflowKey(fontSize: model.chatFontSize, column: readingColumn)) { scheduleRelayout() }
                .onChange(of: viewport.layoutHolds) {
                    guard viewport.layoutHolds == 0, relayoutDeferred else { return }
                    relayoutDeferred = false
                    scheduleRelayout()
                }
                // Rows near the reader render formatted on their first frame when the lazy stack mounts them.
                .task(id: TranscriptPrewarm.Key(focus: anchorIndex, count: session.messages.count)) {
                    let focus = anchorIndex ?? session.messages.count - 1
                    let range =
                        max(
                            0, focus - TranscriptPrewarm.reach)..<min(
                            session.messages.count, focus + TranscriptPrewarm.reach + 1)
                    await TranscriptPrewarm.prepare(Array(session.messages[range]), around: focus - range.lowerBound)
                }
                // A newly sent turn always re-arms following and jumps to the bottom.
                .onChange(of: session.messages.count) { previousCount, count in
                    if count < previousCount, session.hasCompleteHistory {
                        viewport.messagesRemoved(
                            anchorSurvives: anchorIndex != nil,
                            fallback: Self.renderedMessageID(near: 0, of: session.messages))
                    }
                    if session.isStreaming && session.messages.last?.role == .user {
                        jumpToLatest()
                    } else {
                        viewport.contentChanged()
                    }
                }
                .onDisappear {
                    historyTask?.cancel()
                    historyTask = nil
                    reader.executorTask?.cancel()
                    reader.executorTask = nil
                    reader.attributionTask?.cancel()
                    reader.attributionTask = nil
                    reader.keepInsideTask?.cancel()
                    reader.keepInsideTask = nil
                    reader.executor.cancelDeferredMove()
                    reader.verificationTask?.cancel()
                    reader.verificationTask = nil
                    reflowTask?.cancel()
                    reflowTask = nil
                    reader.attributingMove = false
                    pagingPhase = .idle
                }
                .onAppear { reader.proxy = proxy }
            }
        }
    }

    private var tokens: Caprine { model.theme.tokens }

    private var readingColumn: CGFloat {
        ReadingMeasure.column(
            fontID: model.effectiveChatFontID, size: model.chatFontSize, presentation: model.presentation.isEnabled)
    }

    /// What every item needs to know about the transcript, computed once per update.
    private struct ItemContext {
        let lastMessageID: UUID?
        let activeAssistantID: UUID?
        let activeToolID: String?
    }

    private var itemContext: ItemContext {
        let activeAssistant: ChatMessage? =
            session.isStreaming ? session.messages.last(where: { $0.role == .assistant }) : nil
        let activeToolID = activeAssistant.flatMap { assistant in
            TranscriptActivity.summary([assistant], activeAssistantID: assistant.id).current?.id
        }
        return ItemContext(
            lastMessageID: TranscriptActivity.lastVisibleID(in: session.messages),
            activeAssistantID: activeAssistant?.id, activeToolID: activeToolID)
    }

    /// A message's date heads its first item when it starts a day.
    private func showsDate(_ item: TranscriptItem) -> Bool {
        item.row.startsDay && topPadding(of: item, ignoringJoins: true) > 0
    }

    private func itemView(_ item: TranscriptItem, context: ItemContext) -> some View {
        let message = item.message
        return VStack(alignment: .leading, spacing: 0) {
            if showsDate(item) {
                Text(message.createdAt, format: .dateTime.year().month(.wide).day())
                    .font(Caprine.Activity.font)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Caprine.Activity.inset)
                    .accessibilityAddTraits(.isHeader)
            }
            if let segment = segmentItem(item) {
                segment.equatable()
            } else {
                messageRow(item, context: context)
            }
        }
        // Align the item boundary without traversing completed Markdown.
        .alignmentGuide(.leading) { _ in 0 }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, topPadding(of: item))
        // Item frames in content coordinates locate anchors; they are raw measurements, kept out of
        // observable state.
        .modifier(
            TranscriptFrameReport(label: "item \(message.id.uuidString.prefix(4)) \(item.part)") { instance, frame in
                let key = item.frameKey
                recordFrame(frame, of: key.key, segment: key.segment, instance: instance)
            }
        )
        .id(item.id)
    }

    /// A reply's reasoning or answer segment that does not carry its avatar, built from values so a
    /// streamed update leaves settled segments alone; nil for every other item.
    private func segmentItem(_ item: TranscriptItem) -> ReplySegmentItem? {
        let message = item.message
        guard message.role == .assistant else { return nil }
        let hasReasoning = TranscriptText.hasContent(message.thinking)
        switch item.part {
        case .reasoning(let index):
            let last = index == TranscriptTexts.shared.reasoning(for: message).pieceCount - 1
            return ReplySegmentItem(
                message: message, part: item.part, topPadding: index == 0 ? Caprine.Activity.spacing : 0,
                bottomPadding: last && TranscriptText.hasContent(message.text) ? Caprine.Activity.reasoningGap : 0)
        case .answer(let index) where index > 0 || hasReasoning:
            return ReplySegmentItem(
                message: message, part: item.part,
                topPadding: index == 0 && hasReasoning ? Caprine.Activity.spacing : 0, bottomPadding: 0)
        default:
            return nil
        }
    }

    private func messageRow(_ item: TranscriptItem, context: ItemContext) -> some View {
        let message = item.message
        return TranscriptMessageRow(
            message: message, session: session, part: item.part,
            isLast: message.id == context.lastMessageID,
            compactActivity: item.row.isContinuation,
            joinsPreviousTools: item.row.joinsPreviousTools,
            joinsNextTools: item.row.joinsNextTools,
            activeToolID: message.id == context.activeAssistantID ? context.activeToolID : nil,
            canDeleteCompaction: CompactionDeletion.canRestore(message, in: session.messages),
            canEdit: message.role == .user && !session.isStreaming,
            keyboardFocus: $focusedMessageID,
            isKeyboardFocused: focusedMessageID == message.id
        )
        .equatable()
    }

    /// Every loaded message, as the items of the lazy stack (ADR-0104).
    private var transcriptItems: [TranscriptItem] {
        let rows = TranscriptActivity.rows(session.messages[...], precedingDate: session.historyPrecedingDate)
        return TranscriptItem.items(for: rows, texts: .shared)
    }

    /// Space above an item: a message's first item is spaced from the message before it; its other items
    /// continue it.
    private func topPadding(of item: TranscriptItem, ignoringJoins: Bool = false) -> CGFloat {
        let message = item.message
        let leads: Bool =
            switch item.part {
            case .whole, .head: true
            case .answer(0):
                message.role == .user
                    ? message.attachmentPaths.isEmpty : !TranscriptText.hasContent(message.thinking)
            case .reasoning, .answer, .tail: false
            }
        guard leads else { return 0 }
        if ignoringJoins { return 1 }
        return item.row.joinsPreviousTools || item.row.messages.allSatisfy(TranscriptActivity.isEmpty)
            ? 0 : Caprine.Activity.messageSpacing
    }

    /// The reply whose output is still arriving, which alone shows the streaming caret.
    private var streamingReplyID: UUID? { Self.streamingReplyID(in: session) }

    static func streamingReplyID(in session: ChatSession) -> UUID? {
        guard session.isStreaming else { return nil }
        return session.messages.last(where: { $0.role == .assistant })?.id
    }

    private var anchorIndex: Int? {
        viewport.anchor.flatMap { anchor in
            session.messages.firstIndex(where: { TranscriptSegmentOwner.key(anchor.messageID, belongsTo: $0.id) })
        }
    }

    /// Bumps once per visible publication without scanning the accumulated response.
    private var streamRevision: UInt64 {
        session.messages.last?.renderRevision ?? 0
    }

    private func jumpToLatest() {
        if session.historyHasLater {
            historyTask?.cancel()
            historyTask = Task { @MainActor in
                guard await model.loadLatestHistory(for: session), !Task.isCancelled else { return }
                session.historyAnchorID = nil
                viewport.jumpToLatest()
            }
            return
        }
        session.historyAnchorID = nil
        pagingPhase = .idle
        followThrottle.reset()
        reader.isScrolling = false
        // Not in an animation transaction: the change would cross-fade every row it replaces.
        viewport.jumpToLatest()
    }

    /// Loads the adjacent page of stored history when the viewport is within a viewport of an end of the
    /// loaded records (ADR-0102, ADR-0104). There is no control to press: the reader scrolls on, and their
    /// place is kept as records are added and evicted. Not while a move is pending or being attributed, a
    /// gesture is under way, or before the first placement: loading then could pull the reader.
    private func loadHistoryIfNear(force: Bool = false) {
        guard initiallyPlaced, pagingPhase == .idle, !session.isPagingHistory, !session.isStreaming,
            viewport.request == nil, !reader.attributingMove, !reader.isScrolling,
            force || session.historyPageError == nil
        else { return }
        reader.syncGeometry()
        let reach = reader.metrics.layout.container.height
        guard reach > 0 else { return }
        if session.historyHasEarlier, reader.metrics.topGap <= reach {
            fetchHistory(earlier: true)
        } else if session.historyHasLater, reader.metrics.bottomGap <= reach {
            fetchHistory(earlier: false)
        }
    }

    private func fetchHistory(earlier: Bool) {
        guard !session.isPagingHistory, !session.isStreaming else { return }
        // The reader's place is kept across the load; following keeps following.
        if viewport.readerOwnsViewport, let anchor = reader.measuredAnchor() ?? viewport.anchor {
            viewport.readerMoved(anchor: anchor)
        }
        viewport.note("load \(earlier ? "earlier" : "later") history")
        pagingPhase = earlier ? .pagingEarlier : .pagingLater
        historyTask = Task { @MainActor in
            let loaded = await model.pageHistory(for: session, earlier: earlier)
            guard !Task.isCancelled else { return }
            pagingPhase = .idle
            guard loaded else { return }
            viewport.historyRebased()
        }
    }

    /// The nearest message at or after `index` (else before it) that renders. Tool results and empty
    /// assistant messages have nothing to anchor to.
    static func renderedMessageID(near index: Int, of messages: [ChatMessage]) -> UUID? {
        let rendered = { (index: Int) in
            messages[index].role != .tool && !TranscriptActivity.isEmpty(messages[index])
        }
        let start = min(max(index, 0), messages.count)
        let found = (start..<messages.count).first(where: rendered) ?? (0..<start).last(where: rendered)
        return found.map { messages[$0].id }
    }

    /// An item's frame in content coordinates, or nil when it is no longer laid out. A message's first
    /// item and a split message's tail are measured by key alone; segments by key and index.
    private func recordFrame(_ frame: CGRect?, of key: UUID, segment: Int?, instance: UUID) {
        guard let segment else {
            recordRowFrame(frame, of: key, instance: instance)
            return
        }
        if frame == nil, reader.segmentInstances[key]?[segment] != instance { return }
        reader.segmentInstances[key, default: [:]][segment] = frame == nil ? nil : instance
        if reader.segmentInstances[key]?.isEmpty == true { reader.segmentInstances[key] = nil }
        let previous = reader.segmentFrames[key]?[segment]
        reader.segmentFrames[key, default: [:]][segment] = frame
        if reader.segmentFrames[key]?.isEmpty == true { reader.segmentFrames[key] = nil }
        if let previous, let frame, previous.minY != frame.minY, viewport.anchor?.messageID == key,
            viewport.anchor?.segment == segment
        {
            keepAnchorInPlace(previousTop: previous.minY)
        }
        arrived(frame, key: key)
    }

    private func recordRowFrame(_ frame: CGRect?, of id: UUID, instance: UUID) {
        guard let frame else {
            // Only the instance whose frame is held clears it: a lazy stack can mount a row's
            // replacement, which reports its frame, before the replaced instance disappears.
            if reader.rowInstances[id] == instance {
                reader.rowFrames[id] = nil
                reader.rowInstances[id] = nil
            }
            return
        }
        reader.rowInstances[id] = instance
        let previous = reader.rowFrames[id]
        reader.rowFrames[id] = frame
        if let previous, previous.minY != frame.minY, viewport.anchor?.messageID == id,
            viewport.anchor?.segment == nil
        {
            keepAnchorInPlace(previousTop: previous.minY)
        }
        arrived(frame, key: id)
    }

    /// A reported frame may locate a reader who has no anchor yet, or be the awaited target.
    private func arrived(_ frame: CGRect?, key: UUID) {
        guard frame != nil else { return }
        if viewport.anchor == nil, viewport.readerOwnsViewport, !reader.isScrolling,
            let anchor = reader.measuredAnchor()
        {
            viewport.adoptAnchor(anchor)
        }
        if case .anchor(let anchor) = viewport.request?.target,
            let message = viewport.messageForKey(anchor.messageID), TranscriptSegmentOwner.key(key, belongsTo: message)
        {
            // The awaited item arrived: run now rather than at the retry.
            cancelFrameWait()
            executePendingRequest()
        }
    }

    private func handleGeometry(from previous: TranscriptScrollMetrics, to metrics: TranscriptScrollMetrics) {
        // Where the reader was before this snapshot, for attributing a move it reports. Rows can report
        // their new places before the offset that moved with them, so the anchor measured at the previous
        // report is kept as well: either one matching where the rows are now means the content stayed put.
        let anchorBefore = reader.measuredAnchor()
        let reportedAnchor = reader.reportedAnchor
        reader.metrics = metrics
        defer { reader.reportedAnchor = reader.measuredAnchor() }
        // Rows reflow only when the reading column's width changes: it is capped, so a wide window's
        // resize changes nothing. Re-identifying the lazy stack rebuilds the rows it shows, so only a
        // reflow large enough to leave its estimates wrong does it (not a scroller appearing).
        let column = min(readingColumn, max(0, metrics.width - 48))
        if column > 0 {
            if reader.relayoutColumn == 0 {
                // The first width the transcript is laid out at.
                reader.relayoutColumn = column
            } else if abs(column - reader.relayoutColumn) >= 32 {
                reader.relayoutColumn = column
                // Never invalidate layout from inside its own geometry callback.
                Task { @MainActor in scheduleRelayout() }
            }
        }
        if TranscriptViewport.traces, metrics != previous {
            let anchorTop = viewport.anchor.flatMap { reader.rowFrames[$0.messageID] }.map { "\(Int($0.minY))" } ?? "-"
            viewport.note(
                "geometry \(Int(previous.offset))->\(Int(metrics.offset)) content \(Int(metrics.contentHeight)) "
                    + "cause \(reader.executor.cause(ofOffset: metrics.offset).map { "\($0)" } ?? "nil") anchor row \(anchorTop)"
            )
        }
        let atBottom = !session.historyHasLater && metrics.distanceFromBottom <= Self.bottomTolerance
        reader.isAtBottom = atBottom
        // Near an end of the loaded records, the next page loads (never inside the geometry callback).
        if !reader.isScrolling, pagingPhase == .idle,
            session.historyHasEarlier && metrics.topGap <= metrics.layout.container.height
                || session.historyHasLater && metrics.bottomGap <= metrics.layout.container.height
        {
            Task { @MainActor in
                await Task.yield()
                loadHistoryIfNear()
            }
        }
        if !reader.isScrolling, metrics.contentHeight > metrics.layout.container.height,
            metrics.offset > metrics.contentHeight - metrics.layout.container.height + 1
        {
            // The content shrank above a viewport past its new end. The scroll view keeps its bounds
            // valid, but the lazy stack lays out the rows there only after a move it is told about, so
            // the executor makes that move. Never inside the geometry callback.
            reader.keepInsideTask?.cancel()
            reader.keepInsideTask = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled, !reader.isScrolling else { return }
                reader.syncGeometry()
                guard reader.metrics.bottomGap <= 0.5 else { return }
                let end = max(0, reader.metrics.contentHeight - reader.metrics.layout.container.height)
                viewport.note("keep inside the content at \(Int(end))")
                let moves = viewport.readerMoves
                let readerStayed: @MainActor @Sendable () -> Bool = { [reader, viewport] in
                    !reader.isScrolling && viewport.readerMoves == moves
                }
                reader.executor.nudge(to: end - 1, thenTo: end, while: readerStayed) {
                    reader.syncGeometry()
                    reader.keepInsideTask = Task { @MainActor in
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        // Only if the reader did not take the viewport since: their move is never undone.
                        guard readerStayed() else { return }
                        rescueBlankViewport()
                    }
                }
            }
        }
        // The proxy's landing is the first move after it that the executor did not make, whether or not
        // the content changed size with it, while the request it served is pending. Confirmed reader input
        // always wins over it.
        let landing = ProxyLanding.resolve(
            reader.proxyLanding, moved: abs(metrics.offset - previous.offset) >= 1,
            cause: reader.executor.cause(ofOffset: metrics.offset),
            followedInput: reader.executor.lastMoveFollowedInput, pending: viewport.request?.generation)
        reader.proxyLanding = landing.remaining
        let proxyLanded = landing.landed
        if proxyLanded { viewport.note("proxy landed at \(Int(metrics.offset))") }
        if !reader.isScrolling {
            if metrics.layout != previous.layout {
                // Content grew or reflowed, or the viewport resized, moving the offset with it if at all:
                // follow it, or put the reader's anchor back.
                viewport.contentChanged()
            } else if abs(metrics.offset - previous.offset) >= 1 {
                // Less than a point is the scroll view aligning to device pixels as content changes,
                // never a reader.
                // Who moved the viewport is recorded where the move happens, never inferred from geometry.
                // A rescue while following lands through SwiftUI and the lazy stack then moves the offset
                // as rows resolve; until the bottom request it left settles, those moves are not a reader's.
                let rescuingBottom =
                    reader.followRescue.map { ContinuousClock.now - $0 < .seconds(1) } == true
                    && viewport.request?.target == .bottom
                let restoringAnchor = (viewport.request.map { $0.target != .bottom } ?? false) || rescuingBottom
                switch reader.executor.cause(ofOffset: metrics.offset) {
                case .executor, .layout:
                    // The executor's own command, checked for fulfilment below, or AppKit keeping the
                    // bounds valid as the document resized.
                    break
                case .other where proxyLanded:
                    // The executor's last-resort SwiftUI scroll landing; the pending request continues.
                    break
                case .other where restoringAnchor && !reader.executor.lastMoveFollowedInput:
                    // No reader input came with this move: the lazy stack moving the offset as rows above
                    // resolve while the executor restores the reader's anchor. The restore continues and is
                    // checked against where the rows now are. Following yields to any move.
                    viewport.note("unprompted offset \(Int(previous.offset))->\(Int(metrics.offset))")
                case .other:
                    // The keyboard, a scroller or another direct move without a gesture phase, or the lazy
                    // stack moving the offset with its content as row estimates resolve. Only the first
                    // moves what the reader sees, so decide once the rows report where they now are, and
                    // hold any pending scroll until then.
                    attributeMove(
                        from: previous.offset, to: metrics.offset, anchorsBefore: [anchorBefore, reportedAnchor])
                case nil:
                    // No recorded move lands here, so it changes no ownership.
                    viewport.note(
                        "unattributed offset \(Int(previous.offset))->\(Int(metrics.offset)), last move "
                            + (reader.executor.lastMove.map { "\($0.cause) at \($0.offset)" } ?? "none"))
                }
            }
        }
        if !initiallyPlaced, metrics.contentHeight > 0 {
            // Never invalidate layout from inside its own geometry callback.
            Task { @MainActor in placeInitiallyIfReady() }
        }
        // Following shows the latest output even while a growth step is still being chased.
        let showsLatest = viewport.autoFollow || atBottom
        if viewport.isScrolledToBottom != showsLatest {
            // Presentation only; never invalidate layout from inside its own geometry callback.
            Task { @MainActor in
                viewport.isScrolledToBottom = showsLatest
            }
        }
        executePendingRequest()
    }

    /// Performs the owner's pending request, the transcript's only scroll path. A request runs on a
    /// later turn of the main actor (never inside a geometry callback), once its target is laid out;
    /// it is fulfilled when the geometry shows it and re-issued as layout settles, at most
    /// `maximumScrollAttempts` times. A target that has no row yet is retried on the same bound, so one
    /// that never renders is abandoned. Reader input cancels it through the owner.
    private func executePendingRequest() {
        guard let request = viewport.request, reader.executorTask == nil, !reader.isScrolling, !reader.attributingMove
        else { return }
        if reader.attemptGeneration != request.generation {
            reader.attemptGeneration = request.generation
            reader.attempts = 0
            reader.frameWaitStarted = nil
            reader.revealsTried.removeAll()
        }
        let delay =
            request.target == .bottom && session.isStreaming
            ? followThrottle.delay(at: ProcessInfo.processInfo.systemUptime) : 0
        reader.executorTask = Task { @MainActor in
            if delay > 0 {
                do { try await Task.sleep(for: .milliseconds(Int((delay * 1_000).rounded(.up)))) } catch { return }
            } else {
                await Task.yield()
            }
            reader.executorTask = nil
            // A request issued while this attempt waited runs next; it must not wait for geometry.
            defer {
                if !Task.isCancelled, let pending = viewport.request, pending != request { executePendingRequest() }
            }
            guard !Task.isCancelled, viewport.request == request, !reader.isScrolling, !reader.attributingMove
            else { return }
            reader.syncGeometry()
            if reader.shows(request.target) {
                viewport.note("fulfilled \(request.generation) at \(Int(reader.metrics.offset))")
                if reader.proxyLanding?.request == request.generation { reader.proxyLanding = nil }
                viewport.fulfilled(request)
                if pagingPhase != .idle { pagingPhase = .idle }
                return
            }
            guard reader.attempts < Self.maximumScrollAttempts else {
                abandonRequest(request)
                return
            }
            // Not attached to its scroll view yet: its layout runs this again, else a retry does.
            guard reader.executor.isAttached else { return awaitLayout(request, for: "scroll view") }
            let metrics = reader.metrics
            var target: CGFloat
            switch request.target {
            case .bottom:
                // Each move to the estimated end lays out the rows there at their real heights, which moves
                // the end again. When following has chased it this often without holding it, SwiftUI's own
                // scroll to the last item lays that item out exactly, and the chase ends from there. While a
                // reply streams the end moves anyway, so this waits for it to settle.
                let now = ContinuousClock.now
                reader.bottomChase.removeAll { now - $0 > .milliseconds(1_500) }
                if reader.attempts == 0 { reader.bottomChase.append(now) }
                if !session.isStreaming, reader.bottomChase.count >= 4, let last = transcriptItems.last,
                    let proxy = reader.proxy
                {
                    viewport.note("bottom chase settles on the last item")
                    reader.bottomChase.removeAll()
                    reader.followRescue = now
                    reader.proxyLanding = .init(request: request.generation)
                    proxy.scrollTo(last.id, anchor: .bottom)
                    reader.attempts += 1
                    viewport.recordScrollCommand()
                    verifyAfterScroll()
                    return
                }
                RenderSignposts.event("TranscriptFollow")
                followThrottle.recordFire(at: ProcessInfo.processInfo.systemUptime)
                target = metrics.offset + metrics.bottomGap
                // While the last row is not laid out, the document's end is SwiftUI's estimate, which can
                // lie far past the rows (a reflow made it 15,000 pt too long): a move there shows nothing.
                // Step to the end estimated from the rows laid out instead; the last rows then lay out and
                // the next attempt moves to the document's real end.
                if let end = estimatedContentEnd(), end < target + metrics.layout.container.height - 1 {
                    let step = max(metrics.offset, end - metrics.layout.container.height)
                    viewport.note("bottom estimate \(Int(step)) short of the document's \(Int(target))")
                    target = step
                }
            case .anchor(let anchor):
                // Not laid out yet: the row's or segment's first geometry report runs this again, else a
                // retry does, within the same bound.
                guard let frame = reader.frame(of: anchor) else {
                    revealIfUnmounted(anchor)
                    return awaitLayout(request, for: anchor.segment == nil ? "row" : "segment")
                }
                target = frame.minY + anchor.offset
            }
            target = min(max(target, metrics.offset - metrics.topGap), metrics.offset + metrics.bottomGap)
            viewport.note(
                "scroll \(request.generation) \(request.target == .bottom ? "bottom" : "anchor") "
                    + "\(Int(metrics.offset))->\(Int(target)) gap \(Int(metrics.topGap))/\(Int(metrics.bottomGap))")
            reader.executor.scroll(toY: target)
            reader.syncGeometry()
            reader.attempts += 1
            viewport.recordScrollCommand()
            verifyAfterScroll()
        }
    }

    /// Checks the pending request again shortly after a scroll command. A command's geometry report
    /// normally runs the check, but the scroll view does not always report a move it was told to make
    /// (an off-screen or idle window), and the request must not wait on it.
    /// Following also checks that the end is still shown: the lazy stack lays out the last rows at their
    /// real heights once the command reveals them, which moves the end below the viewport.
    private func verifyAfterScroll() {
        reader.verificationTask?.cancel()
        reader.verificationTask = Task { @MainActor in
            do { try await Task.sleep(for: Self.frameRetryInterval) } catch { return }
            reader.verificationTask = nil
            // Only while the executor made the last move: a reader's direct move is attributed first.
            if viewport.request == nil, viewport.autoFollow, !reader.isScrolling, !reader.attributingMove,
                reader.executor.lastMove?.cause != .other
            {
                reader.syncGeometry()
                if reader.metrics.bottomGap > 1 { viewport.contentChanged() }
            }
            executePendingRequest()
        }
    }

    /// A move nothing recorded explains is the reader's only if the content on screen moved with it. The
    /// lazy stack shifts the offset and its rows together when estimates above the viewport resolve; the
    /// reader's anchor then stays where it was, and ownership does not change.
    private func attributeMove(
        from previousOffset: CGFloat, to offset: CGFloat, anchorsBefore: [TranscriptViewport.Anchor?]
    ) {
        reader.attributionTask?.cancel()
        reader.attributingMove = true
        reader.attributionTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            reader.attributingMove = false
            reader.attributionTask = nil
            let anchorAfter = reader.measuredAnchor()
            reader.reportedAnchor = anchorAfter
            if let anchorAfter,
                anchorsBefore.contains(where: { anchorBefore in
                    guard let anchorBefore else { return false }
                    return anchorBefore.messageID == anchorAfter.messageID
                        && anchorBefore.segment == anchorAfter.segment
                        && abs(anchorBefore.offset - anchorAfter.offset) <= 1
                })
            {
                viewport.note("layout offset \(Int(previousOffset))->\(Int(offset))")
            } else {
                viewport.note("reader offset \(Int(previousOffset))->\(Int(offset))")
                // A move up by more than the bottom tolerance is the reader's even when rows resolving
                // above leave the viewport near the new bottom.
                if viewport.readerOwnsViewport || !reader.isAtBottom || previousOffset - offset > Self.bottomTolerance {
                    viewport.readerMoved(anchor: anchorAfter, replacingUnknown: true)
                }
            }
            executePendingRequest()
        }
    }

    /// The lazy stack lays out only rows near the viewport, so an anchor's row may have no frame. Moves
    /// the viewport, with the executor's own native command, to where the row is estimated to be from the
    /// rows that are laid out; the row's layout there then gives the exact offset on a later attempt. A
    /// SwiftUI scroll is not used: it lands after the request returns and can override a reader's move.
    private func revealIfUnmounted(_ anchor: TranscriptViewport.Anchor) {
        let items = transcriptItems
        guard reader.frame(of: anchor) == nil,
            let target = items.firstIndex(where: {
                $0.frameKey.key == anchor.messageID && $0.frameKey.segment == anchor.segment
            })
        else { return }
        reader.syncGeometry()
        // Only frames near the viewport are current: the lazy stack laid them out for where it is.
        let reach = 4 * reader.metrics.layout.container.height
        let near = (reader.metrics.offset - reach)...(reader.metrics.offset + reach)
        let laidOut = Self.ordered(
            items.enumerated().compactMap { index, item in
                frame(of: item).flatMap { near.overlaps($0.minY...$0.maxY) ? (index, $0) : nil }
            })
        guard let nearest = laidOut.min(by: { abs($0.0 - target) < abs($1.0 - target) }) else { return }
        let averageHeight = laidOut.map(\.1.height).reduce(0, +) / CGFloat(max(laidOut.count, 1))
        let estimate =
            target < nearest.0
            ? nearest.1.minY - CGFloat(nearest.0 - target) * averageHeight
            : nearest.1.maxY + CGFloat(target - nearest.0 - 1) * averageHeight
        let metrics = reader.metrics
        var y = min(max(estimate + anchor.offset, metrics.offset - metrics.topGap), metrics.offset + metrics.bottomGap)
        // An estimate from few items can be far off, and one past the items shows nothing: move at most a
        // few viewports per attempt, so the items on the way lay out and the next estimate starts from them.
        let maximumMove = 3 * metrics.layout.container.height
        y = min(max(y, metrics.offset - maximumMove), metrics.offset + maximumMove)
        // An estimate that keeps the viewport where it is would wait forever: step a viewport toward the
        // item, so the items there lay out and the next estimate starts from them.
        if abs(y - metrics.offset) < 1 {
            let step = metrics.layout.container.height
            y =
                target < nearest.0
                ? max(metrics.offset - metrics.topGap, metrics.offset - step)
                : min(metrics.offset + metrics.bottomGap, metrics.offset + step)
        }
        // Estimates that return to a place already tried are not converging. SwiftUI knows where the item
        // is in what it renders; its scroll lands on a later update, and the executor then places the
        // target exactly.
        if reader.revealsTried.contains(where: { abs($0 - y) < 1 }), let proxy = reader.proxy {
            viewport.note("reveal item \(target) through SwiftUI after \(reader.revealsTried.count) estimates")
            reader.proxyLanding = .init(request: viewport.request?.generation)
            proxy.scrollTo(items[target].id, anchor: .top)
            viewport.recordScrollCommand()
            verifyAfterScroll()
            return
        }
        reader.revealsTried.append(y)
        viewport.note(
            "reveal item \(target) near \(nearest.0) at \(Int(y)) from \(Int(metrics.offset)) gap "
                + "\(Int(metrics.topGap))/\(Int(metrics.bottomGap)) laid out "
                + laidOut.map { "\($0.0)@\(Int($0.1.minY))" }.joined(separator: ","))
        reader.executor.scroll(toY: y)
        reader.syncGeometry()
        viewport.recordScrollCommand()
        verifyAfterScroll()
    }

    /// An item's frame, when laid out.
    private func frame(of item: TranscriptItem) -> CGRect? {
        let key = item.frameKey
        return key.segment.map { reader.segmentFrames[key.key]?[$0] } ?? reader.rowFrames[key.key]
    }

    /// The reader's anchor moved with layout. The lazy stack keeps its topmost visible row in place,
    /// which is the anchor's row unless the anchor starts below the viewport's top edge (space above it,
    /// as under a loader) or names a segment: then a size change above it moves what the reader sees,
    /// and the owner puts it back. Only while the reader owns the viewport, nothing else moves it, and
    /// the anchor was where the reader sees it before this layout (`previousTop` is its earlier top
    /// edge): an anchor a cancelled restore left behind describes nothing on screen.
    private func keepAnchorInPlace(previousTop: CGFloat) {
        guard viewport.readerOwnsViewport, viewport.request == nil, !reader.isScrolling, !reader.attributingMove,
            pagingPhase == .idle, let anchor = viewport.anchor,
            abs(previousTop + anchor.offset - reader.metrics.offset) <= 1,
            let frame = reader.frame(of: anchor),
            abs(frame.minY + anchor.offset - reader.metrics.offset) > 1
        else { return }
        viewport.note("anchor drifted \(Int(frame.minY + anchor.offset - reader.metrics.offset))")
        viewport.restore(anchor)
    }

    /// After a drastic size change while unmounted, the lazy stack can keep a row's old place and lay
    /// out nothing where the viewport is, whatever the scroll view does; even a wheel then does not move
    /// it. Only a SwiftUI scroll to a row makes it lay out again. When no laid-out row meets the
    /// viewport, scrolls to the anchor's row while the reader owns the viewport. The reader sees nothing
    /// then, so there is no reader position to override; the executor then places the target exactly.
    /// `atReader` rescues where a reader's own scroll ended instead of at their anchor: the row at the
    /// same place in the window (the last row's end near the bottom, the first row near the top).
    private func rescueBlankViewport(atReader: Bool = false) {
        reader.syncGeometry()
        let metrics = reader.metrics
        let top = metrics.offset
        let bottom = top + metrics.layout.container.height
        guard !reader.itemFrames.contains(where: { $0.frame.maxY > top && $0.frame.minY < bottom }) else { return }
        let items = transcriptItems
        /// The item as far through the items as the viewport is through the content.
        func itemAtReader() -> (id: TranscriptItem.ID, edge: UnitPoint)? {
            guard metrics.contentHeight > 0 else { return items.first.map { ($0.id, .top) } }
            let fraction = min(1, max(0, top / metrics.contentHeight))
            let index = min(items.count - 1, Int(fraction * CGFloat(items.count)))
            return items.indices.contains(index) ? (items[index].id, .top) : nil
        }
        let target: (id: TranscriptItem.ID, edge: UnitPoint)?
        let following = !viewport.readerOwnsViewport
        // While a reply streams, its next update moves the end anyway: a gap there is momentary.
        if following, session.isStreaming { return }
        if following {
            // Following, at the end of a content estimate the items no longer reach: SwiftUI lays out the
            // last item it scrolls to, and following then settles on the items' real end.
            target = items.last.map { ($0.id, .bottom) }
        } else if atReader {
            let reach = metrics.layout.container.height
            // At either end the items' own estimate, or the top itself, is where the items are: SwiftUI
            // places an item by its estimate of the content, which is what left the viewport blank.
            if metrics.bottomGap <= reach, let end = estimatedContentEnd(), end < top + reach {
                let y = max(0, end - reach)
                viewport.note("rescue blank viewport at \(Int(top)) to the items' end \(Int(y))")
                reader.executor.scroll(toY: y)
                reader.syncGeometry()
                return
            }
            if metrics.topGap <= reach {
                viewport.note("rescue blank viewport at \(Int(top)) to the top")
                reader.executor.scroll(toY: 0)
                reader.syncGeometry()
                return
            }
            if metrics.bottomGap <= reach {
                target = items.last.map { ($0.id, .bottom) }
            } else {
                target = itemAtReader()
            }
        } else if let anchor = viewport.anchor,
            let item = items.first(where: {
                $0.frameKey.key == anchor.messageID && $0.frameKey.segment == anchor.segment
            })
        {
            target = (item.id, .top)
        } else {
            // No anchor to return to: the item about where the reader is, never the top.
            target = itemAtReader()
        }
        // At most once per interval: right after it the lazy stack re-estimates the content, and a
        // second rescue before that settles would chase the estimate.
        let now = ContinuousClock.now
        if let last = reader.lastRescue, now - last < .milliseconds(500) { return }
        guard let target, let proxy = reader.proxy else { return }
        reader.lastRescue = now
        viewport.note("rescue blank viewport at \(Int(top)) to \(target.id.message.uuidString.prefix(4))")
        // It lands on a later update, as a move the scroll view did not record: the next one is this
        // scroll's, not the reader's. Its landing at the last item's end is the bottom while following:
        // a further bottom request would chase the content's estimate past the items.
        if following {
            reader.followRescue = now
            viewport.followAgain()
        }
        reader.proxyLanding = .init(request: viewport.request?.generation)
        proxy.scrollTo(target.id, anchor: target.edge)
    }

    /// Where the content ends, estimated from the items laid out, while the last item is not laid out;
    /// nil when it is, or when nothing is laid out to estimate from.
    private func estimatedContentEnd() -> CGFloat? {
        let items = transcriptItems
        guard let last = items.last, frame(of: last) == nil else { return nil }
        let laidOut = Self.ordered(items.enumerated().compactMap { index, item in frame(of: item).map { (index, $0) } })
        guard let nearest = laidOut.last else { return nil }
        let averageHeight = laidOut.map(\.1.height).reduce(0, +) / CGFloat(laidOut.count)
        // Items after the nearest one, then the trailing space and anything below it.
        return nearest.1.maxY + CGFloat(items.count - 1 - nearest.0) * averageHeight
            + Caprine.Activity.doubleLineHeight + 1 + 64
    }

    private struct ReflowKey: Equatable {
        let fontSize: CGFloat
        let column: CGFloat
    }

    /// Gives the lazy stack a new identity once a reflow settles, then puts the reader's anchor back
    /// or follows to the end. A window resize settles after its last change.
    private func scheduleRelayout() {
        reflowTask?.cancel()
        reflowTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard !reader.isScrolling else { return }
            guard viewport.layoutHolds == 0 else {
                relayoutDeferred = true
                viewport.note("relayout waits for \(viewport.layoutHolds) presentation(s)")
                return
            }
            layoutGeneration &+= 1
            viewport.recordRelayout()
            reader.rowFrames.removeAll()
            reader.reportedAnchor = nil
            reader.rowInstances.removeAll()
            reader.segmentFrames.removeAll()
            reader.segmentInstances.removeAll()
            viewport.note("relayout \(layoutGeneration)")
            if viewport.readerOwnsViewport, let anchor = viewport.anchor {
                viewport.restore(anchor)
            } else {
                viewport.contentChanged()
            }
        }
    }

    /// The longest run of frames whose positions agree with their order, so a frame left from an earlier
    /// layout never steers an estimate. `frames` is sorted by row index.
    static func ordered(_ frames: [(Int, CGRect)]) -> [(Int, CGRect)] {
        guard frames.count > 1 else { return frames }
        var length = Array(repeating: 1, count: frames.count)
        var previous = Array(repeating: -1, count: frames.count)
        for i in frames.indices {
            for j in 0..<i where frames[j].1.minY < frames[i].1.minY && length[j] + 1 > length[i] {
                length[i] = length[j] + 1
                previous[i] = j
            }
        }
        var index = length.indices.max(by: { length[$0] < length[$1] }) ?? 0
        var run: [(Int, CGRect)] = []
        while index >= 0 {
            run.append(frames[index])
            index = previous[index]
        }
        return run.reversed()
    }

    /// Ends the initial placement once the transcript has content and no restoration is pending.
    private func placeInitiallyIfReady() {
        guard !initiallyPlaced, reader.metrics.contentHeight > 0 else { return }
        guard viewport.autoFollow || viewport.request == nil else { return }
        initiallyPlaced = true
    }

    /// Counts an attempt that found its target not laid out, and retries it after a bounded wait, so a
    /// target that never lays out is abandoned. The awaited row's first layout runs it at once.
    private func awaitLayout(_ request: TranscriptViewport.Request, for missing: String) {
        let now = ContinuousClock.now
        if let started = reader.frameWaitStarted, now - started >= Self.maximumFrameWait {
            abandonRequest(request)
            return
        }
        if reader.frameWaitStarted == nil { reader.frameWaitStarted = now }
        // No row is laid out at all: the content was not laid out for where the viewport is. After a
        // drastic size change while unmounted, the lazy stack can keep a row's old place and lay out
        // nothing where the viewport is; only a SwiftUI scroll to the row makes it lay that row out.
        // The reader sees nothing then, so there is no reader position for it to override.
        if reader.rowFrames.isEmpty && reader.segmentFrames.isEmpty {
            if reader.attempts >= 2 {
                rescueBlankViewport()
            } else {
                reader.executor.layoutContent { [viewport] in viewport.request == request }
            }
        }
        reader.attempts += 1
        viewport.note(
            "awaiting \(missing) \(request.generation)"
                + (TranscriptViewport.traces
                    ? " items \(reader.rowFrames.count + reader.segmentFrames.count) at \(Int(reader.metrics.offset)) of \(Int(reader.metrics.contentHeight))"
                    : ""))
        reader.awaitingFrame = true
        reader.executorTask = Task { @MainActor in
            do { try await Task.sleep(for: Self.frameRetryInterval) } catch { return }
            reader.executorTask = nil
            reader.awaitingFrame = false
            executePendingRequest()
        }
    }

    private func abandonRequest(_ request: TranscriptViewport.Request) {
        if reader.proxyLanding?.request == request.generation { reader.proxyLanding = nil }
        viewport.note("abandoned \(request.generation)")
        RenderSignposts.event("TranscriptScrollAbandoned")
        viewport.abandon(request)
        pagingPhase = .idle
    }

    private func cancelFrameWait() {
        guard reader.awaitingFrame else { return }
        reader.executorTask?.cancel()
        reader.executorTask = nil
        reader.awaitingFrame = false
    }
}

/// Prepares the formatted text of the settled messages near the reader off the main actor, nearest first.
/// The lazy stack mounts an item only as it nears the viewport, so without this an item coming back into
/// view would show its placeholder for a frame and then change height (ADR-0099).
@MainActor enum TranscriptPrewarm {
    struct Key: Equatable {
        let focus: Int?
        let count: Int
    }

    /// Messages prepared on each side of the reader's.
    static let reach = 20

    static func prepare(_ messages: [ChatMessage], around focus: Int) async {
        let order = messages.indices.sorted { abs($0 - focus) < abs($1 - focus) }
        for index in order {
            guard !Task.isCancelled else { return }
            let message = messages[index]
            guard message.complete, TranscriptText.hasContent(message.text) else { continue }
            let source = message.text
            switch message.role {
            case .user:
                guard source.utf8.count <= TranscriptTextParts.maximumBytes,
                    MarkdownContentCache.shared.peek(id: message.id, source: source) == nil
                else { continue }
                if case .parsed(let content) = await MarkdownRenderCache.shared.prepare(id: message.id, source: source)
                {
                    MarkdownContentCache.shared.set(id: message.id, source: source, content: content)
                }
            case .assistant where message.kind == .regular:
                let revision = message.textRevision
                guard revision.utf8Count <= ReplyWindow.richLimit,
                    PreparedMarkdownDocumentCache.shared.document(for: message.id, revision: revision) == nil,
                    let document = await MarkdownSegmentCache.shared.prepare(
                        id: message.id, source: source, revision: revision, isComplete: true,
                        window: AnswerText.window(forUnshown: revision.utf8Count))
                else { continue }
                PreparedMarkdownDocumentCache.shared.store(document, for: message.id)
            default:
                continue
            }
        }
    }
}

/// The scroll geometry the navigation owner needs, compared on every scroll frame. Distances to the
/// ends come from the visible rectangle, so they hold whatever insets the window applies.
struct TranscriptScrollMetrics: Equatable {
    var offset: CGFloat = 0
    /// How far the viewport can still move up, and down.
    var topGap: CGFloat = 0
    var bottomGap: CGFloat = 0
    var contentHeight: CGFloat = 0
    var width: CGFloat = 0
    /// Everything but the offset: a change here is layout, not a move.
    var layout = Layout()

    struct Layout: Equatable {
        var contentHeight: CGFloat = 0
        var container = CGSize.zero
        var insets = EdgeInsets()
    }

    init() {}

    init(_ geometry: ScrollGeometry) {
        offset = geometry.contentOffset.y
        topGap = max(0, geometry.contentOffset.y + geometry.contentInsets.top)
        bottomGap = max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
        contentHeight = geometry.contentSize.height
        width = geometry.containerSize.width
        layout = Layout(
            contentHeight: geometry.contentSize.height, container: geometry.containerSize,
            insets: geometry.contentInsets)
    }

    var distanceFromBottom: CGFloat { bottomGap }
}

/// The transcript's only scroll writer (#54 section 2), a narrowly scoped AppKit adapter.
///
/// SwiftUI positioning is not used because SwiftUI keeps a programmatic target and re-applies it after
/// a move without a gesture (keyboard, scroller, direct), which does not clear it:
/// - A `ScrollPosition` command: with it, the owner recording a reader's direct move led SwiftUI
///   (`HostingScrollView.updateAnimationTarget`) to scroll the reader back to the command's target;
///   `aDirectMoveAfterAnInterruptedCommandIsTheReaders` fails with a `ScrollPosition` writer, with or
///   without the initial offset. Rewriting the binding from the geometry callback to hide it was
///   applied out of order and oscillated on CI (#71).
/// - The initial bottom offset, re-applied on any size change; `ScrollPositionLimitationTests`
///   reproduce it with fixed rows, so the transcript turns it off after its first placement.
///
/// Commands move the clip view at once. Every bounds change is recorded where it happens: inside a
/// command it is the executor's; when it only constrains the previous origin to a resized document it
/// is AppKit's layout; any other is another's, the reader's unless the scroll geometry snapshot that
/// reports it shows layout (a content, container or inset change). An offset no recorded move explains
/// changes no ownership.
@MainActor final class TranscriptScrollExecutor {
    enum Cause: Equatable, Sendable {
        /// Inside one of the executor's commands.
        case executor
        /// AppKit keeping the bounds valid as the document resizes.
        case layout
        /// Anything else: the reader's, unless the same geometry snapshot shows layout.
        case other
    }

    private weak var scrollView: NSScrollView?
    private var observer: NSObjectProtocol?
    private var commanding = false
    private var previousOrigin: NSPoint?
    /// The last recorded bounds change: where the clip view's top edge moved, and why.
    private(set) var lastMove: (offset: CGFloat, cause: Cause)?
    /// Whether the reader's input was being handled when `lastMove` happened: a key, wheel or mouse
    /// event the app took moments before, or any move while VoiceOver runs (its scrolling sends none).
    private(set) var lastMoveFollowedInput = false

    var isAttached: Bool { scrollView != nil }

    func attach(_ scrollView: NSScrollView) {
        guard scrollView !== self.scrollView else { return }
        detach()
        self.scrollView = scrollView
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        // Delivered synchronously, inside the call that moved the clip view.
        observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: nil
        ) { [weak self] _ in MainActor.assumeIsolated { self?.boundsChanged() } }
    }

    func detach() {
        cancelDeferredMove()
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
        scrollView = nil
        lastMove = nil
        lastMoveFollowedInput = false
        previousOrigin = nil
    }

    /// Moves the viewport's top edge to `y` in content coordinates, without animation.
    func scroll(toY y: CGFloat) {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        commanding = true
        defer { commanding = false }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Lays out the scroll view's content now. After the clip view is clamped into a document that
    /// shrank, nothing else asks the lazy stack for the rows the viewport now shows.
    func layoutContent(while stillWanted: @escaping @MainActor () -> Bool) {
        guard let scrollView else { return }
        let y = scrollView.contentView.bounds.minY
        // A move, which the lazy stack answers by laying out what the viewport shows, and back.
        nudge(to: y - 1, thenTo: y, while: stillWanted)
    }

    /// Moves to `first` now and to `second` on a later turn: SwiftUI coalesces a move and its return
    /// within one. The second move is owned here: a move with confirmed reader input cancels it at once,
    /// and it is made only if the same scroll view is still attached and `stillWanted` holds. The caller's
    /// `stillWanted` says whether the reader took the viewport since: the transcript attributes a move
    /// without input (the lazy stack shifting its offset as rows resolve is not the reader's) before the
    /// second move. `then` runs after the second move.
    func nudge(
        to first: CGFloat, thenTo second: CGFloat, while stillWanted: @escaping @MainActor () -> Bool,
        then: (@MainActor () -> Void)? = nil
    ) {
        cancelDeferredMove()
        guard let scrollView else { return }
        scroll(toY: first)
        deferredMove = Task { @MainActor [weak self, weak scrollView] in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard let self, let scrollView, self.scrollView === scrollView, stillWanted() else { return }
            self.deferredMove = nil
            // A move the executor did not make that carried the viewport a screen or more from the first
            // step is the reader's, even before it is attributed: the lazy stack shifts it far less.
            let clip = scrollView.contentView
            if self.lastMove?.cause == .other, abs(clip.bounds.minY - first) >= clip.bounds.height { return }
            self.scroll(toY: second)
            then?()
        }
    }

    private var deferredMove: Task<Void, Never>?

    func cancelDeferredMove() {
        deferredMove?.cancel()
        deferredMove = nil
    }

    /// Where the viewport is now, read from the scroll view itself: the top edge's offset, how far it
    /// can still move up and down, and the content's height. SwiftUI reports geometry with its next
    /// update, which an idle or off-screen window may defer, and a lazy stack changes the content's
    /// height as estimates resolve, so a command is planned and verified against this.
    func geometry() -> (offset: CGFloat, topGap: CGFloat, bottomGap: CGFloat, contentHeight: CGFloat)? {
        guard let scrollView, let document = scrollView.documentView else { return nil }
        let clip = scrollView.contentView
        let bounds = clip.bounds
        let insets = clip.contentInsets
        return (
            bounds.minY, max(0, bounds.minY + insets.top), max(0, document.frame.maxY + insets.bottom - bounds.maxY),
            document.frame.height
        )
    }

    /// Why the viewport's top edge is at `offset`, if a recorded move put it there.
    func cause(ofOffset offset: CGFloat) -> Cause? {
        guard let lastMove, abs(lastMove.offset - offset) <= 0.5 else { return nil }
        return lastMove.cause
    }

    private func boundsChanged() {
        guard let clip = scrollView?.contentView else { return }
        let origin = clip.bounds.origin
        defer { previousOrigin = origin }
        let cause: Cause
        if commanding {
            cause = .executor
        } else if let previousOrigin, abs(previousOrigin.y - origin.y) > 0.5,
            abs(clip.constrainBoundsRect(NSRect(origin: previousOrigin, size: clip.bounds.size)).minY - origin.y) <= 0.5
        {
            // The clip view reflecting a document frame change: the previous origin, made valid again.
            cause = .layout
        } else {
            cause = .other
        }
        lastMove = (origin.y, cause)
        lastMoveFollowedInput = cause == .other && Self.readerInputIsCurrent()
        if lastMoveFollowedInput { cancelDeferredMove() }
    }

    private static let readerInput: Set<NSEvent.EventType> = [
        .keyDown, .scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .otherMouseDown,
        .otherMouseDragged, .swipe, .magnify, .smartMagnify, .gesture, .pressure,
    ]

    private static func readerInputIsCurrent() -> Bool {
        if NSWorkspace.shared.isVoiceOverEnabled { return true }
        guard let event = NSApp.currentEvent, readerInput.contains(event.type) else { return false }
        return ProcessInfo.processInfo.systemUptime - event.timestamp < 0.5
    }
}

/// Attaches the executor to the scroll view that encloses the transcript's content.
private struct TranscriptScrollAttachment: NSViewRepresentable {
    let executor: TranscriptScrollExecutor

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.executor = executor
        return view
    }

    func updateNSView(_ view: AttachmentView, context: Context) {
        view.executor = executor
        view.attach()
    }

    static func dismantleNSView(_ view: AttachmentView, coordinator: ()) {
        view.executor?.detach()
    }

    final class AttachmentView: NSView {
        weak var executor: TranscriptScrollExecutor?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        func attach() {
            guard let scrollView = enclosingScrollView else { return }
            executor?.attach(scrollView)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The scroll content's coordinate space. Frames measured in it change only with layout, never with
/// scrolling, so an anchor measured as the reader scrolls is never read from a stale frame.
let transcriptContentSpace = "transcript-content"

/// Reports a view's frame in the transcript's content coordinates, and nil when it disappears, as one
/// mounted instance: each instance reports under its own identity, so the disappearance of an instance
/// a lazy stack replaced never clears the frame its replacement reported.
///
/// An instance the lazy stack brings back reports its last frame again: SwiftUI reports a geometry
/// change only when the value changes, so an instance that returns where it was reports nothing.
struct TranscriptFrameReport: ViewModifier {
    var isEnabled = true
    /// Names the view in traces.
    var label = ""
    let report: @MainActor (_ instance: UUID, _ frame: CGRect?) -> Void
    /// A reference, so recording a measurement never invalidates the view.
    @State private var measurement = Measurement()

    private final class Measurement {
        let instance = UUID()
        var frame: CGRect?
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect?.self, of: { isEnabled ? transcriptContentFrame($0) : nil }) { frame in
                guard let frame else {
                    if isEnabled, TranscriptViewport.traces { print("TRANSCRIPT_TRACE \(label) measured outside") }
                    return
                }
                measurement.frame = frame
                report(measurement.instance, frame)
            }
            .onAppear {
                if isEnabled, TranscriptViewport.traces {
                    print(
                        "TRANSCRIPT_TRACE \(label) appeared with \(measurement.frame.map { "\(Int($0.minY))" } ?? "-")")
                }
                if isEnabled, let frame = measurement.frame { report(measurement.instance, frame) }
            }
            .onDisappear {
                if isEnabled, TranscriptViewport.traces { print("TRANSCRIPT_TRACE \(label) disappeared") }
                if isEnabled { report(measurement.instance, nil) }
            }
    }
}

/// A view's frame in the transcript's content coordinates, or nil when the layout measuring it does not
/// place it in the transcript's content: a lazy stack also sizes rows in passes detached from the
/// scroll content, where a named space falls back to other coordinates and the frame is meaningless
/// (a long reply's segment reported 855 pt below where it was).
nonisolated func transcriptContentFrame(_ proxy: GeometryProxy) -> CGRect? {
    guard proxy.bounds(of: .named(transcriptContentSpace)) != nil else { return nil }
    return proxy.frame(in: .named(transcriptContentSpace))
}

/// Raw scroll measurements and executor bookkeeping. Deliberately not observable view state.
/// A SwiftUI scroll the executor issued as a last resort. It lands on a later update, as a move the
/// scroll view did not record; that move is the executor's only for the request it served (none for a
/// rescue), and only briefly: a landing that never came must not claim a later move.
struct ProxyLanding: Equatable {
    let request: UInt64?
    let issued = ContinuousClock.now

    init(request: UInt64?) { self.request = request }

    func isCurrent(request pending: UInt64?, now: ContinuousClock.Instant = .now) -> Bool {
        now - issued < .seconds(1) && (request == nil || request == pending)
    }

    /// Whether a reported move is `landing`'s, and what is still expected. Any move the executor did not
    /// make retires the landing, whether or not the content changed size with it; it is the landing's
    /// only without reader input and while the landing is current.
    static func resolve(
        _ landing: ProxyLanding?, moved: Bool, cause: TranscriptScrollExecutor.Cause?, followedInput: Bool,
        pending: UInt64?, now: ContinuousClock.Instant = .now
    ) -> (landed: Bool, remaining: ProxyLanding?) {
        guard let landing else { return (false, nil) }
        guard landing.isCurrent(request: pending, now: now) else { return (false, nil) }
        guard moved, cause != .executor else { return (false, landing) }
        return (!followedInput, nil)
    }
}

@MainActor private final class TranscriptReaderState {
    var isAtBottom = true
    var isScrolling = false
    var metrics = TranscriptScrollMetrics()
    /// Frames of a message's first item, or a split message's tail, in content coordinates, by key.
    var rowFrames: [UUID: CGRect] = [:]
    /// The mounted instance that reported each row's and segment's frame.
    var rowInstances: [UUID: UUID] = [:]
    var segmentInstances: [UUID: [Int: UUID]] = [:]
    /// Frames of segment items in content coordinates, by key (a message or its reasoning) and segment.
    var segmentFrames: [UUID: [Int: CGRect]] = [:]
    /// The transcript's only scroll writer.
    let executor = TranscriptScrollExecutor()
    var executorTask: Task<Void, Never>?
    /// A move awaiting attribution holds the executor until the rows report their positions.
    var attributingMove = false
    var attributionTask: Task<Void, Never>?
    /// The correction that keeps the viewport inside content that shrank under it.
    var keepInsideTask: Task<Void, Never>?
    /// Where the reader was as of the last geometry report or attributed move.
    var reportedAnchor: TranscriptViewport.Anchor?
    /// Re-checks the pending request after a scroll command whether or not its geometry is reported.
    var verificationTask: Task<Void, Never>?
    /// SwiftUI's own scroll, used only for a target the lazy stack does not lay out, and whether its
    /// landing is still to come.
    var proxy: ScrollViewProxy?
    /// The executor's last-resort SwiftUI scroll, whose landing is still to come.
    var proxyLanding: ProxyLanding?
    var lastRescue: ContinuousClock.Instant?
    /// When a blank viewport was last rescued while following, or a bottom chase settled on the last item.
    var followRescue: ContinuousClock.Instant?
    /// When recent bottom requests began, to tell a chase of a moving end from following.
    var bottomChase: [ContinuousClock.Instant] = []
    /// The offsets the current request's reveals moved to.
    var revealsTried: [CGFloat] = []
    /// The reading column's width the lazy stack was last identified for.
    var relayoutColumn: CGFloat = 0
    /// The pending attempt waits, with a deadline, for its target row's first layout.
    var awaitingFrame = false
    var attemptGeneration: UInt64 = 0
    var attempts = 0
    var frameWaitStarted: ContinuousClock.Instant?

    /// Takes the viewport's position from the scroll view, so a command is never planned or verified
    /// against geometry SwiftUI has not reported yet. Only the executor reads it; SwiftUI's next report
    /// replaces it as usual.
    func syncGeometry() {
        guard let geometry = executor.geometry() else { return }
        metrics.offset = geometry.offset
        metrics.topGap = geometry.topGap
        metrics.bottomGap = geometry.bottomGap
        metrics.contentHeight = geometry.contentHeight
    }

    /// The distance from `id`'s top edge to the viewport's top edge, when laid out.
    func offset(of id: UUID) -> CGFloat? {
        rowFrames[id].map { metrics.offset - $0.minY }
    }

    /// The distance from a shown segment's top edge to the viewport's top edge, when laid out.
    func offset(of id: UUID, segment: Int) -> CGFloat? {
        segmentFrames[id]?[segment].map { metrics.offset - $0.minY }
    }

    /// The frame an anchor is measured from: its segment's when it names one, else its item's.
    func frame(of anchor: TranscriptViewport.Anchor) -> CGRect? {
        guard let segment = anchor.segment else { return rowFrames[anchor.messageID] }
        return segmentFrames[anchor.messageID]?[segment]
    }

    static let anchorSlack: CGFloat = 2

    /// The reader's position: the topmost item still visible, and how far into it the viewport starts.
    func measuredAnchor() -> TranscriptViewport.Anchor? {
        let top = metrics.offset
        // A lazy stack keeps items it laid out elsewhere until they disappear: only an item on screen
        // locates the reader.
        let bottom = top + metrics.layout.container.height
        var topmost: (key: UUID, segment: Int?, frame: CGRect)?
        func consider(_ key: UUID, _ segment: Int?, _ frame: CGRect) {
            // An item showing only its last point or two is above the reader: the lazy stack shifts the
            // offset by about that much as rows resolve, which must not move the anchor to it.
            guard frame.maxY > top + Self.anchorSlack, frame.minY < bottom, frame.height > 0 else { return }
            if topmost.map({ frame.minY < $0.frame.minY }) ?? true { topmost = (key, segment, frame) }
        }
        for (key, frame) in rowFrames { consider(key, nil, frame) }
        for (key, frames) in segmentFrames {
            for (segment, frame) in frames { consider(key, segment, frame) }
        }
        guard let topmost else { return nil }
        return TranscriptViewport.Anchor(
            messageID: topmost.key, offset: top - topmost.frame.minY, segment: topmost.segment)
    }

    /// Every laid-out item's frame, by key and segment.
    var itemFrames: [(key: UUID, segment: Int?, frame: CGRect)] {
        rowFrames.map { ($0.key, nil, $0.value) }
            + segmentFrames.flatMap { key, frames in frames.map { (key, Optional($0.key), $0.value) } }
    }

    /// Whether the viewport already shows `target`: the anchor's top within 1 pt of its offset, or
    /// scrolled as far as the content allows toward it.
    func shows(_ target: TranscriptViewport.Target) -> Bool {
        switch target {
        case .bottom:
            return metrics.distanceFromBottom <= 1
        case .anchor(let anchor):
            guard let frame = frame(of: anchor) else { return false }
            let error = frame.minY - metrics.offset + anchor.offset
            if abs(error) <= 1 { return true }
            // The target lies past an end of the scrollable range: the nearest end is fulfilment.
            return (error > 0 && metrics.bottomGap <= 1) || (error < 0 && metrics.topGap <= 1)
        }
    }
}

/// Parent publication invalidates layout metadata, but settled messages keep their view inputs.
/// MessageView still observes its own message, theme, focus and tool state directly.
private struct TranscriptMessageRow: View, Equatable {
    let message: ChatMessage
    let session: ChatSession
    let part: TranscriptItem.Part
    let isLast: Bool
    let compactActivity: Bool
    let joinsPreviousTools: Bool
    let joinsNextTools: Bool
    let activeToolID: String?
    let canDeleteCompaction: Bool
    let canEdit: Bool
    let keyboardFocus: FocusState<UUID?>.Binding
    let isKeyboardFocused: Bool
    @Environment(AppModel.self) private var model

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message === rhs.message && lhs.session === rhs.session && lhs.part == rhs.part && lhs.isLast == rhs.isLast
            && lhs.compactActivity == rhs.compactActivity && lhs.joinsPreviousTools == rhs.joinsPreviousTools
            && lhs.joinsNextTools == rhs.joinsNextTools && lhs.activeToolID == rhs.activeToolID
            && lhs.canDeleteCompaction == rhs.canDeleteCompaction && lhs.canEdit == rhs.canEdit
            && lhs.isKeyboardFocused == rhs.isKeyboardFocused
    }

    var body: some View {
        MessageView(
            message: message, isLast: isLast, projectID: session.projectID,
            transcriptKeyboardFocus: keyboardFocus, isFocusedInTranscript: isKeyboardFocused,
            compactActivity: compactActivity, joinsPreviousTools: joinsPreviousTools, joinsNextTools: joinsNextTools,
            activeToolID: activeToolID,
            deleteCompaction: canDeleteCompaction
                ? { Task { await model.deleteCompaction(message, in: session) } } : nil,
            editMessage: canEdit
                ? { text, original in
                    await model.editAndResend(message, text: text, previousText: original, in: session)
                } : nil,
            part: part)
    }
}
