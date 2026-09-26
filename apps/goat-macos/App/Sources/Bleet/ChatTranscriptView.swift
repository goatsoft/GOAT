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

/// Segment paging and frame reports from long replies to the transcript's navigation owner. Equal
/// for the same owner, so a transcript update does not invalidate every reply: the actions read the
/// transcript's state when they run.
struct TranscriptSegmentNavigation: Equatable, Sendable {
    var viewport: TranscriptViewport?
    /// Shows `window` of a reply's segments, keeping segment `kept` where the reader sees it.
    /// `reachesEnd` says the window reaches the reply's end.
    var page: @MainActor @Sendable (_ messageID: UUID, _ window: Range<Int>, _ kept: Int, _ reachesEnd: Bool) -> Void =
        { _, _, _, _ in }
    /// A shown segment's frame in viewport coordinates, or nil when it is no longer laid out.
    var recordFrame: @MainActor @Sendable (_ messageID: UUID, _ segment: Int, _ frame: CGRect?) -> Void = {
        _, _, _ in
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.viewport === rhs.viewport }
}

extension EnvironmentValues {
    @Entry var transcriptSegments = TranscriptSegmentNavigation()
}

private enum TranscriptPagingPhase: Equatable, Sendable {
    case idle
    case pagingEarlier
    case pagingLater
    case pagingSegments
}

/// The transcript's single navigation owner (#54 section 2, #60 A1).
///
/// It holds the admitted message window, who owns the viewport, the reader's anchor and at most one
/// pending scroll request. Reader gestures, paging, restoration, compaction, jumps to the latest
/// output and content changes arrive as explicit events. `ChatTranscriptView` performs each request
/// with one mechanism (`TranscriptScrollExecutor`) and reports when the geometry shows it fulfilled.
/// Raw scroll measurements stay in the view's non-observable reader state.
@MainActor @Observable final class TranscriptViewport {
    /// A reading position: a message, and how far the viewport's top edge is below the message's top
    /// edge. A negative offset leaves space above the message. In a long reply shown as a window of
    /// segments the offset is measured from a segment's top edge instead, so it survives the window
    /// moving above it.
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

    private(set) var heldRange: Range<Int>?
    /// True while the viewport follows the latest output; false while the reader owns it.
    private(set) var autoFollow: Bool
    var readerOwnsViewport: Bool { !autoFollow }
    /// Presentation only: false shows the jump-to-latest button.
    var isScrolledToBottom: Bool
    private(set) var anchor: Anchor?
    private(set) var request: Request?
    /// A long reply's window the reader paged to, and whether it reached the reply's end then.
    struct SegmentHold: Equatable, Sendable {
        var window: Range<Int>
        var reachedEnd: Bool
    }

    /// Segment windows the reader paged long replies to, by message. Following clears them.
    private(set) var segmentWindows: [UUID: SegmentHold] = [:]
    static let maximumSegmentWindows = 16
    private var generation: UInt64 = 0
    /// Scroll commands issued and requests abandoned after the bounded attempts, for instrumentation.
    @ObservationIgnored private(set) var scrollCommands = 0
    @ObservationIgnored private(set) var abandonedRequests = 0
    /// The executor's recent steps, for test failure messages and debugging. Bounded.
    @ObservationIgnored private(set) var diagnostics: [String] = []

    func note(_ event: String) {
        diagnostics.append(event)
        if diagnostics.count > 40 { diagnostics.removeFirst(diagnostics.count - 40) }
    }

    init(initiallyFollowing: Bool = true, initialHeldRange: Range<Int>? = nil, initialAnchor: Anchor? = nil) {
        autoFollow = initiallyFollowing
        isScrolledToBottom = initiallyFollowing
        heldRange = initialHeldRange
        if !initiallyFollowing, let initialAnchor { restore(initialAnchor) }
    }

    func messageRange(count: Int, anchor: Int? = nil, cost: (Int) -> Int) -> Range<Int> {
        if let heldRange {
            return TranscriptWindow.clamped(heldRange, count: count, anchor: anchor, cost: cost)
        }
        return TranscriptWindow.range(count: count, end: nil, cost: cost)
    }

    /// The window the reader paged a long reply to, if any. Without one a reply shows its latest
    /// segments, or keeps those shown while the reader owns the viewport.
    func segmentWindow(for messageID: UUID) -> Range<Int>? { segmentWindows[messageID]?.window }

    /// Whether the reader paged `messageID` to earlier segments, so the transcript's bottom is not
    /// the reply's end.
    func holdsEarlierSegments(of messageID: UUID) -> Bool {
        segmentWindows[messageID].map { !$0.reachedEnd } ?? false
    }

    /// The reader paged a long reply to `window`, which `reachesEnd` of the reply or not. The reader
    /// owns the viewport and keeps `anchor`, a segment inside both windows.
    func pageSegments(
        of messageID: UUID, to window: Range<Int>, reachesEnd: Bool, currentRange: Range<Int>, keeping anchor: Anchor
    ) {
        readerMoved(currentRange: currentRange)
        if segmentWindows[messageID] == nil, segmentWindows.count >= Self.maximumSegmentWindows {
            segmentWindows.removeAll()
        }
        segmentWindows[messageID] = SegmentHold(window: window, reachedEnd: reachesEnd)
        restore(anchor)
    }

    /// A reader gesture, keyboard or scroller movement, or an inspection took the viewport. The
    /// reader's input always wins, so any pending scroll is cancelled.
    func readerMoved(currentRange: Range<Int>, anchor: Anchor? = nil) {
        if heldRange == nil { heldRange = currentRange }
        autoFollow = false
        if let anchor { self.anchor = anchor }
        request = nil
    }

    func claimViewport(currentRange: Range<Int>) {
        readerMoved(currentRange: currentRange)
    }

    /// A reader gesture ended. Only a gesture ending at the conversation's true bottom hands the
    /// viewport back to following; geometry alone never does.
    func readerSettled(atTrueBottom: Bool, anchor: Anchor?) {
        if atTrueBottom {
            heldRange = nil
            autoFollow = true
            self.anchor = nil
            segmentWindows.removeAll()
        } else if let anchor {
            self.anchor = anchor
        }
    }

    /// The jump-to-latest action, or a new user turn: follow and scroll to the bottom.
    func jumpToLatest() {
        heldRange = nil
        autoFollow = true
        isScrolledToBottom = true
        anchor = nil
        segmentWindows.removeAll()
        issue(.bottom)
    }

    /// Content grew, regrouped or reflowed. Following asks for the bottom; a reader's anchor is
    /// restored. An equal pending request is kept, so repeated changes coalesce.
    func contentChanged() {
        guard let target = autoFollow ? Target.bottom : anchor.map(Target.anchor), request?.target != target
        else { return }
        issue(target)
    }

    /// Makes `anchor` the reader's position and scrolls to it (paging, restoration, compaction).
    func restore(_ anchor: Anchor) {
        autoFollow = false
        self.anchor = anchor
        issue(.anchor(anchor))
    }

    /// Messages were removed (compaction, deletion). The held window keeps the anchor's message
    /// when it survives; otherwise the reader continues at the first surviving message.
    func messagesRemoved(count: Int, anchorIndex: Int?, messageID: (Int) -> UUID, cost: (Int) -> Int) {
        guard let heldRange else { return }
        let surviving = TranscriptWindow.clamped(heldRange, count: count, anchor: anchorIndex, cost: cost)
        self.heldRange = surviving
        if anchorIndex == nil, let first = surviving.first, readerOwnsViewport {
            restore(Anchor(messageID: messageID(first), offset: 0))
        }
    }

    @discardableResult
    func pageEarlier(count: Int, cost: (Int) -> Int) -> (range: Range<Int>, anchor: Int)? {
        let current = messageRange(count: count, cost: cost)
        guard current.lowerBound > 0 else { return nil }
        let previous = TranscriptWindow.earlier(current, count: count, cost: cost)
        let anchor = previous.contains(current.lowerBound) ? current.lowerBound : max(0, previous.upperBound - 1)
        readerMoved(currentRange: previous)
        heldRange = previous
        return (previous, anchor)
    }

    @discardableResult
    func pageLater(count: Int, cost: (Int) -> Int) -> (range: Range<Int>, anchor: Int)? {
        let current = messageRange(count: count, cost: cost)
        guard current.upperBound < count else { return nil }
        let next = TranscriptWindow.later(current, count: count, cost: cost)
        let oldAnchor = max(0, current.upperBound - 1)
        let anchor = next.contains(oldAnchor) ? oldAnchor : next.lowerBound
        readerMoved(currentRange: next)
        heldRange = next
        return (next, anchor)
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
    @Environment(AppModel.self) private var model
    @State var viewport: TranscriptViewport
    @State private var reader = TranscriptReaderState()
    /// False until the first placement: at the latest output when following, else once the restored
    /// anchor's request ends. Until then SwiftUI's initial bottom offset applies, and a restoring
    /// transcript is not shown at a position it is about to leave.
    @State private var initiallyPlaced = false
    @State private var followThrottle = TranscriptFollowThrottle()
    @State private var pagingPhase: TranscriptPagingPhase = .idle
    @State private var isHoveringScrollButton = false

    /// Distance from the bottom within which the latest content counts as shown, for both the
    /// jump button and a reader's return to following.
    static let bottomTolerance: CGFloat = 50
    /// Attempts per request while layout settles before it is abandoned (and instrumented).
    static let maximumScrollAttempts = 12
    /// How long an attempt waits for a target row that has not laid out, so a target that never renders
    /// is abandoned after `maximumScrollAttempts` of them.
    static let frameRetryInterval = Duration.milliseconds(50)

    init(
        session: ChatSession,
        initiallyFollowing: Bool = true,
        initialVisibleMessageID: UUID? = nil,
        viewport: TranscriptViewport? = nil
    ) {
        self.session = session
        let initialHeld: Range<Int>?
        let start =
            initiallyFollowing
            ? nil : initialVisibleMessageID.flatMap { id in session.messages.firstIndex(where: { $0.id == id }) }
        if !initiallyFollowing {
            initialHeld =
                start.map { start in
                    TranscriptWindow.range(
                        count: session.messages.count,
                        startingAt: start,
                        cost: { TranscriptWindow.displayCost(session.messages[$0]) })
                }
                ?? TranscriptWindow.range(
                    count: session.messages.count,
                    end: nil,
                    cost: { TranscriptWindow.displayCost(session.messages[$0]) })
        } else {
            initialHeld = nil
        }
        // Restoration anchors to a row that renders in the held window: a missing or removed message
        // shows the latest page, and a tool result or empty message gives way to its nearest row.
        let restoredAnchor = start.flatMap { start in
            initialHeld.flatMap { Self.renderedMessageID(near: start, in: $0, of: session.messages) }
        }
        _viewport = State(
            initialValue: viewport
                ?? TranscriptViewport(
                    initiallyFollowing: initiallyFollowing,
                    initialHeldRange: initialHeld,
                    initialAnchor: restoredAnchor.map { TranscriptViewport.Anchor(messageID: $0, offset: 0) }
                ))
    }

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
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if messageRange.lowerBound > 0 {
                        HStack {
                            GoatLoadingIndicator().controlSize(.mini)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .id("earlier-messages-loader")
                        .onScrollVisibilityChange(threshold: 0.01) { visible in
                            // Never inside the layout pass that revealed the loader: the scroll that
                            // revealed it is attributed first.
                            guard visible else { return }
                            Task { @MainActor in
                                await Task.yield()
                                loadEarlierMessages()
                            }
                        }
                    }
                    let rows = TranscriptActivity.rows(session.messages[messageRange])
                    let lastMessageID = TranscriptActivity.lastVisibleID(in: session.messages)
                    let activeAssistant =
                        session.isStreaming
                        ? session.messages.last(where: { $0.role == .assistant }) : nil
                    let activeAssistantID = activeAssistant?.id
                    let activeToolID: String? = {
                        guard let activeAssistant else { return nil }
                        return TranscriptActivity.summary([activeAssistant], activeAssistantID: activeAssistant.id)
                            .current?.id
                    }()
                    ForEach(rows) { row in
                        // Each message retains its identity and ancestry as tool events arrive.
                        // Keep projection inside the existing bounded, fully measured window.
                        VStack(alignment: .leading, spacing: 0) {
                            if let message = row.messages.first {
                                MessageView(
                                    message: message, isLast: message.id == lastMessageID,
                                    projectID: session.projectID, compactActivity: row.isContinuation,
                                    joinsPreviousTools: row.joinsPreviousTools,
                                    joinsNextTools: row.joinsNextTools,
                                    activeToolID: message.id == activeAssistantID ? activeToolID : nil,
                                    deleteCompaction: CompactionDeletion.canRestore(
                                        message, in: session.messages)
                                        ? { Task { await model.deleteCompaction(message, in: session) } }
                                        : nil)
                            }
                        }
                        // Align the row boundary without traversing completed Markdown.
                        .alignmentGuide(.leading) { _ in 0 }
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(
                            .top,
                            row.joinsPreviousTools || row.messages.allSatisfy(TranscriptActivity.isEmpty)
                                ? 0 : Caprine.Activity.messageSpacing
                        )
                        // Row frames in content coordinates locate anchors; they are raw measurements,
                        // kept out of observable state.
                        .onGeometryChange(for: CGRect.self, of: Self.contentFrame) { recordFrame($0, of: row.id) }
                        .onDisappear { reader.rowFrames[row.id] = nil }
                        .id(row.id)
                    }
                    if messageRange.upperBound < session.messages.count {
                        HStack {
                            GoatLoadingIndicator().controlSize(.mini)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .id("later-messages-loader")
                        .onScrollVisibilityChange(threshold: 0.01) { visible in
                            // Never inside the layout pass that revealed the loader: the scroll that
                            // revealed it is attributed first.
                            guard visible else { return }
                            Task { @MainActor in
                                await Task.yield()
                                loadLaterMessages()
                            }
                        }
                    }
                    if session.isStreaming && messageRange.upperBound == session.messages.count {
                        AgentProgressView(session: session)
                            .padding(.top, Caprine.Activity.spacing)
                    }
                    // Space below the last row, so the latest line never sits on the window edge.
                    Color.clear
                        .frame(height: Caprine.Activity.doubleLineHeight + 1)
                }
                .scrollTargetLayout()
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .coordinateSpace(.named(transcriptContentSpace))
                .background { TranscriptScrollAttachment(executor: reader.executor) }
            }
            // A restoring transcript appears at the reader's anchor, not where it starts.
            .opacity(initiallyPlaced || viewport.autoFollow ? 1 : 0)
            .overlay(alignment: .bottom) {
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
                    .help("Scroll to bottom")
                    .accessibilityLabel("Scroll to bottom")
                    .accessibilityIdentifier("chat-transcript-scroll-bottom-button")
                    .padding(.bottom, Caprine.Activity.inset)
                    .onHover { isHoveringScrollButton = $0 }
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .environment(
                \.transcriptInspection,
                TranscriptInspectionAction {
                    viewport.readerMoved(currentRange: messageRange, anchor: reader.measuredAnchor())
                }
            )
            .environment(
                \.transcriptSegments,
                TranscriptSegmentNavigation(
                    viewport: viewport,
                    page: { id, window, kept, reachesEnd in
                        pageSegments(of: id, to: window, keeping: kept, reachesEnd: reachesEnd)
                    },
                    recordFrame: { id, segment, frame in recordFrame(frame, of: id, segment: segment) })
            )
            // SwiftUI re-applies its initial bottom offset on later size changes until a gesture positions
            // the view, even after the executor or a direct reader move did; it holds only until the first
            // placement.
            .defaultScrollAnchor(initiallyPlaced ? nil : .bottom, for: .initialOffset)
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
                    viewport.readerMoved(currentRange: messageRange, anchor: reader.measuredAnchor())
                } else if phase == .idle {
                    let readerFinishedScrolling = reader.isScrolling
                    reader.isScrolling = false
                    guard readerFinishedScrolling else { return }
                    viewport.note("gesture settled at \(Int(reader.metrics.offset))")
                    // A last reply held on earlier segments is not the conversation's end.
                    let holdsLastReply =
                        session.messages.last.map { viewport.holdsEarlierSegments(of: $0.id) } ?? false
                    viewport.readerSettled(
                        atTrueBottom: messageRange.upperBound == session.messages.count && reader.isAtBottom
                            && !holdsLastReply,
                        anchor: reader.measuredAnchor())
                }
            }
            .onChange(of: viewport.request) {
                if viewport.request == nil {
                    // A reader gesture that cancels a paging scroll also ends that page load.
                    if pagingPhase != .idle { pagingPhase = .idle }
                    placeInitiallyIfReady()
                }
                // A replaced request does not wait out its predecessor's frame deadline.
                cancelFrameWait()
                executePendingRequest()
            }
            // Streaming growth (text, thinking, new messages): following chases it; a reader keeps
            // their anchor.
            .onChange(of: streamRevision) { viewport.contentChanged() }
            .onChange(of: session.isStreaming) { viewport.contentChanged() }
            // A newly sent turn always re-arms following and jumps to the bottom.
            .onChange(of: session.messages.count) { previousCount, count in
                if count < previousCount, viewport.heldRange != nil {
                    viewport.messagesRemoved(
                        count: count, anchorIndex: anchorIndex,
                        messageID: { renderedMessageID(near: $0) ?? session.messages[$0].id }, cost: displayCost)
                }
                if session.messages.last?.role == .user {
                    jumpToLatest()
                } else {
                    viewport.contentChanged()
                }
            }
            .onDisappear {
                reader.executorTask?.cancel()
                reader.executorTask = nil
                pagingPhase = .idle
            }
        }
    }

    private var tokens: Caprine { model.theme.tokens }

    var visibleMessageRange: Range<Int> { messageRange }

    private var anchorIndex: Int? {
        viewport.anchor.flatMap { anchor in
            session.messages.firstIndex(where: { $0.id == anchor.messageID })
        }
    }

    private var messageRange: Range<Int> {
        viewport.messageRange(count: session.messages.count, anchor: anchorIndex, cost: displayCost)
    }

    private func displayCost(_ index: Int) -> Int {
        TranscriptWindow.displayCost(session.messages[index])
    }

    /// Bumps once per visible publication without scanning the accumulated response.
    private var streamRevision: UInt64 {
        session.messages.last?.renderRevision ?? 0
    }

    private func jumpToLatest() {
        pagingPhase = .idle
        followThrottle.reset()
        reader.isScrolling = false
        withAnimation(.easeInOut(duration: 0.2)) {
            viewport.jumpToLatest()
        }
    }

    /// Pages earlier while keeping the message at the top of the window where the reader sees it.
    /// Only a reader pages earlier: while the transcript follows, the earlier loader can be seen for a
    /// moment during layout (a reply still preparing is short), and paging then would leave the latest
    /// output.
    private func loadEarlierMessages() {
        guard pagingPhase == .idle, messageRange.lowerBound > 0, viewport.readerOwnsViewport else { return }
        let kept = session.messages[messageRange.lowerBound].id
        let keptOffset = reader.offset(of: kept)
        guard let result = viewport.pageEarlier(count: session.messages.count, cost: displayCost) else { return }
        pagingPhase = .pagingEarlier
        restorePagingAnchor(result.anchor, kept: kept, keptOffset: keptOffset)
    }

    /// Pages later while keeping the message at the end of the window where the reader sees it.
    private func loadLaterMessages() {
        guard pagingPhase == .idle, messageRange.upperBound < session.messages.count else { return }
        let kept = session.messages[messageRange.upperBound - 1].id
        let keptOffset = reader.offset(of: kept)
        guard let result = viewport.pageLater(count: session.messages.count, cost: displayCost) else { return }
        pagingPhase = .pagingLater
        restorePagingAnchor(result.anchor, kept: kept, keptOffset: keptOffset)
    }

    /// Resolves the page's anchor index to a stable message identity before scrolling. When pages
    /// overlap it is the kept message at its measured offset; otherwise the top of the new page.
    private func restorePagingAnchor(_ index: Int, kept: UUID, keptOffset: CGFloat?) {
        guard session.messages.indices.contains(index) else {
            pagingPhase = .idle
            return
        }
        guard let id = renderedMessageID(near: index) else {
            pagingPhase = .idle
            return
        }
        viewport.restore(TranscriptViewport.Anchor(messageID: id, offset: id == kept ? keptOffset ?? 0 : 0))
    }

    /// Moves a long reply's segment window, keeping segment `kept` where the reader sees it.
    /// Only a reader pages a reply: while following, a loader seen during layout is transient.
    private func pageSegments(of id: UUID, to window: Range<Int>, keeping kept: Int, reachesEnd: Bool) {
        guard pagingPhase == .idle, viewport.readerOwnsViewport else { return }
        let offset = reader.offset(of: id, segment: kept) ?? 0
        pagingPhase = .pagingSegments
        viewport.pageSegments(
            of: id, to: window, reachesEnd: reachesEnd, currentRange: messageRange,
            keeping: TranscriptViewport.Anchor(messageID: id, offset: offset, segment: kept))
    }

    /// The nearest message at or after `index` in the window (else before it) that renders a row.
    /// Tool results and empty assistant messages have no row to anchor to.
    private func renderedMessageID(near index: Int) -> UUID? {
        Self.renderedMessageID(near: index, in: messageRange, of: session.messages)
    }

    private static func renderedMessageID(near index: Int, in range: Range<Int>, of messages: [ChatMessage]) -> UUID? {
        let rendered = { (index: Int) in
            messages[index].role != .tool && !TranscriptActivity.isEmpty(messages[index])
        }
        let start = min(max(index, range.lowerBound), range.upperBound)
        let found =
            (start..<range.upperBound).first(where: rendered)
            ?? (range.lowerBound..<start).last(where: rendered)
        return found.map { messages[$0].id }
    }

    nonisolated private static func contentFrame(_ proxy: GeometryProxy) -> CGRect {
        proxy.frame(in: .named(transcriptContentSpace))
    }

    private func recordFrame(_ frame: CGRect, of id: UUID) {
        reader.rowFrames[id] = frame
        if case .anchor(let anchor) = viewport.request?.target, anchor.messageID == id {
            // The awaited row arrived: run now rather than at the retry.
            cancelFrameWait()
            executePendingRequest()
        }
    }

    private func recordFrame(_ frame: CGRect?, of id: UUID, segment: Int) {
        reader.segmentFrames[id, default: [:]][segment] = frame
        if reader.segmentFrames[id]?.isEmpty == true { reader.segmentFrames[id] = nil }
        if frame != nil, case .anchor(let anchor) = viewport.request?.target, anchor.messageID == id {
            // The awaited segment arrived: run now rather than at the retry.
            cancelFrameWait()
            executePendingRequest()
        }
    }

    private func handleGeometry(from previous: TranscriptScrollMetrics, to metrics: TranscriptScrollMetrics) {
        reader.metrics = metrics
        let atBottom =
            metrics.distanceFromBottom <= Self.bottomTolerance && messageRange.upperBound == session.messages.count
        reader.isAtBottom = atBottom
        if !reader.isScrolling {
            if metrics.layout != previous.layout {
                // Content grew or reflowed, or the viewport resized, moving the offset with it if at all:
                // follow it, or put the reader's anchor back.
                viewport.contentChanged()
            } else if metrics.offset != previous.offset {
                // Who moved the viewport is recorded where the move happens, never inferred from geometry.
                switch reader.executor.cause(ofOffset: metrics.offset) {
                case .executor, .layout:
                    // The executor's own command, checked for fulfilment below, or AppKit keeping the
                    // bounds valid as the document resized.
                    break
                case .other:
                    // The keyboard, a scroller or another direct move, without a gesture phase; it
                    // cancels any pending scroll.
                    viewport.note("reader offset \(Int(previous.offset))->\(Int(metrics.offset))")
                    if viewport.readerOwnsViewport || !atBottom {
                        viewport.readerMoved(currentRange: messageRange, anchor: reader.measuredAnchor())
                    }
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
                withAnimation(.easeInOut(duration: 0.2)) { viewport.isScrolledToBottom = showsLatest }
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
        guard let request = viewport.request, reader.executorTask == nil, !reader.isScrolling else { return }
        if reader.attemptGeneration != request.generation {
            reader.attemptGeneration = request.generation
            reader.attempts = 0
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
            guard !Task.isCancelled, viewport.request == request, !reader.isScrolling else { return }
            if reader.shows(request.target) {
                viewport.note("fulfilled \(request.generation) at \(Int(reader.metrics.offset))")
                viewport.fulfilled(request)
                if pagingPhase != .idle { pagingPhase = .idle }
                return
            }
            guard reader.attempts < Self.maximumScrollAttempts else {
                viewport.note("abandoned \(request.generation)")
                RenderSignposts.event("TranscriptScrollAbandoned")
                viewport.abandon(request)
                pagingPhase = .idle
                return
            }
            // Not attached to its scroll view yet: its layout runs this again, else a retry does.
            guard reader.executor.isAttached else { return awaitLayout(request, for: "scroll view") }
            let metrics = reader.metrics
            var target: CGFloat
            switch request.target {
            case .bottom:
                RenderSignposts.event("TranscriptFollow")
                followThrottle.recordFire(at: ProcessInfo.processInfo.systemUptime)
                target = metrics.offset + metrics.bottomGap
            case .anchor(let anchor):
                // Not laid out yet: the row's or segment's first geometry report runs this again, else a
                // retry does, within the same bound.
                guard let frame = reader.frame(of: anchor) else { return awaitLayout(request, for: "row") }
                target = frame.minY + anchor.offset
            }
            target = min(max(target, metrics.offset - metrics.topGap), metrics.offset + metrics.bottomGap)
            viewport.note(
                "scroll \(request.generation) \(request.target == .bottom ? "bottom" : "anchor") "
                    + "\(Int(metrics.offset))->\(Int(target)) gap \(Int(metrics.topGap))/\(Int(metrics.bottomGap))")
            reader.executor.scroll(toY: target)
            reader.attempts += 1
            viewport.recordScrollCommand()
        }
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
        reader.attempts += 1
        viewport.note("awaiting \(missing) \(request.generation)")
        reader.awaitingFrame = true
        reader.executorTask = Task { @MainActor in
            do { try await Task.sleep(for: Self.frameRetryInterval) } catch { return }
            reader.executorTask = nil
            reader.awaitingFrame = false
            executePendingRequest()
        }
    }

    private func cancelFrameWait() {
        guard reader.awaitingFrame else { return }
        reader.executorTask?.cancel()
        reader.executorTask = nil
        reader.awaitingFrame = false
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
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
        scrollView = nil
        lastMove = nil
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

/// Raw scroll measurements and executor bookkeeping. Deliberately not observable view state.
@MainActor private final class TranscriptReaderState {
    var isAtBottom = true
    var isScrolling = false
    var metrics = TranscriptScrollMetrics()
    /// Row frames in content coordinates, keyed by message identity.
    var rowFrames: [UUID: CGRect] = [:]
    /// Frames of the shown segments of windowed long replies in content coordinates, by message and
    /// segment index.
    var segmentFrames: [UUID: [Int: CGRect]] = [:]
    /// The transcript's only scroll writer.
    let executor = TranscriptScrollExecutor()
    var executorTask: Task<Void, Never>?
    /// The pending attempt waits, with a deadline, for its target row's first layout.
    var awaitingFrame = false
    var attemptGeneration: UInt64 = 0
    var attempts = 0

    /// The distance from `id`'s top edge to the viewport's top edge, when laid out.
    func offset(of id: UUID) -> CGFloat? {
        rowFrames[id].map { metrics.offset - $0.minY }
    }

    /// The distance from a shown segment's top edge to the viewport's top edge, when laid out.
    func offset(of id: UUID, segment: Int) -> CGFloat? {
        segmentFrames[id]?[segment].map { metrics.offset - $0.minY }
    }

    /// The frame an anchor is measured from: its segment's when it names one, else its row's.
    func frame(of anchor: TranscriptViewport.Anchor) -> CGRect? {
        guard let segment = anchor.segment else { return rowFrames[anchor.messageID] }
        return segmentFrames[anchor.messageID]?[segment]
    }

    /// The reader's position: the topmost row still visible, and how far into it the viewport starts.
    /// In a windowed long reply, the topmost segment still visible.
    func measuredAnchor() -> TranscriptViewport.Anchor? {
        let top = metrics.offset
        guard
            let row = rowFrames.filter({ $0.value.maxY > top }).min(by: { $0.value.minY < $1.value.minY })
        else { return nil }
        if let segment = segmentFrames[row.key]?.filter({ $0.value.maxY > top }).min(by: { $0.key < $1.key }) {
            return TranscriptViewport.Anchor(messageID: row.key, offset: top - segment.value.minY, segment: segment.key)
        }
        return TranscriptViewport.Anchor(messageID: row.key, offset: top - row.value.minY)
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
