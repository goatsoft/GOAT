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

private enum TranscriptPagingPhase: Equatable, Sendable {
    case idle
    case pagingEarlier
    case pagingLater
}

/// The transcript's single navigation owner (#54 section 2, #60 A1).
///
/// It holds the admitted message window, who owns the viewport, the reader's anchor and at most one
/// pending scroll request. Reader gestures, paging, restoration, compaction, jumps to the latest
/// output and content changes arrive as explicit events. `ChatTranscriptView` performs each request
/// with one mechanism (SwiftUI `ScrollPosition`) and reports when the geometry shows it fulfilled.
/// Raw scroll measurements stay in the view's non-observable reader state.
@MainActor @Observable final class TranscriptViewport {
    /// A reading position: a message, and how far the viewport's top edge is below the message's top
    /// edge. A negative offset leaves space above the message.
    struct Anchor: Equatable, Sendable {
        var messageID: UUID
        var offset: CGFloat
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
    /// The only scroll mechanism: the executor below is its only writer.
    @State private var position: ScrollPosition
    @State private var reader = TranscriptReaderState()
    @State private var followThrottle = TranscriptFollowThrottle()
    @State private var pagingPhase: TranscriptPagingPhase = .idle
    @State private var isHoveringScrollButton = false

    /// Distance from the bottom within which the latest content counts as shown, for both the
    /// jump button and a reader's return to following.
    static let bottomTolerance: CGFloat = 50
    /// Attempts per request while layout settles before it is abandoned (and instrumented).
    static let maximumScrollAttempts = 12

    init(
        session: ChatSession,
        initiallyFollowing: Bool = true,
        initialVisibleMessageID: UUID? = nil,
        viewport: TranscriptViewport? = nil
    ) {
        self.session = session
        let initialHeld: Range<Int>?
        if !initiallyFollowing {
            let start = initialVisibleMessageID.flatMap { id in
                session.messages.firstIndex(where: { $0.id == id })
            }
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
        let restoredAnchor = initiallyFollowing ? nil : initialVisibleMessageID
        _viewport = State(
            initialValue: viewport
                ?? TranscriptViewport(
                    initiallyFollowing: initiallyFollowing,
                    initialHeldRange: initialHeld,
                    initialAnchor: restoredAnchor.map { TranscriptViewport.Anchor(messageID: $0, offset: 0) }
                ))
        _position = State(
            initialValue: restoredAnchor.map { ScrollPosition(id: $0, anchor: .top) } ?? ScrollPosition(edge: .bottom))
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
            }
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
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
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
                    reader.isScrolling = true
                    viewport.readerMoved(currentRange: messageRange, anchor: reader.measuredAnchor())
                } else if phase == .idle {
                    let readerFinishedScrolling = reader.isScrolling
                    reader.isScrolling = false
                    guard readerFinishedScrolling else { return }
                    viewport.readerSettled(
                        atTrueBottom: messageRange.upperBound == session.messages.count && reader.isAtBottom,
                        anchor: reader.measuredAnchor())
                }
            }
            .onChange(of: viewport.request) {
                // A reader gesture that cancels a paging scroll also ends that page load.
                if viewport.request == nil, pagingPhase != .idle { pagingPhase = .idle }
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
    private func loadEarlierMessages() {
        guard pagingPhase == .idle, messageRange.lowerBound > 0 else { return }
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

    /// The nearest message at or after `index` in the window (else before it) that renders a row.
    /// Tool results and empty assistant messages have no row to anchor to.
    private func renderedMessageID(near index: Int) -> UUID? {
        let range = messageRange
        let rendered = { (index: Int) in
            session.messages[index].role != .tool && !TranscriptActivity.isEmpty(session.messages[index])
        }
        let start = min(max(index, range.lowerBound), range.upperBound)
        let found =
            (start..<range.upperBound).first(where: rendered)
            ?? (range.lowerBound..<start).last(where: rendered)
        return found.map { session.messages[$0].id }
    }

    nonisolated private static func contentFrame(_ proxy: GeometryProxy) -> CGRect {
        proxy.frame(in: .named(transcriptContentSpace))
    }

    private func recordFrame(_ frame: CGRect, of id: UUID) {
        reader.rowFrames[id] = frame
        if case .anchor(let anchor) = viewport.request?.target, anchor.messageID == id {
            executePendingRequest()
        }
    }

    private func handleGeometry(from previous: TranscriptScrollMetrics, to metrics: TranscriptScrollMetrics) {
        reader.metrics = metrics
        let atBottom =
            metrics.distanceFromBottom <= Self.bottomTolerance && messageRange.upperBound == session.messages.count
        reader.isAtBottom = atBottom
        if !reader.isScrolling {
            if metrics.contentHeight != previous.contentHeight || metrics.width != previous.width {
                // Content grew or reflowed: follow it, or put the reader's anchor back.
                viewport.contentChanged()
            } else if metrics.offset != previous.offset, !reader.executorReached(metrics.offset) {
                // The keyboard, a scroller or another direct move changed the offset without a gesture
                // phase and without a content change; it cancels any pending scroll.
                viewport.note("reader offset \(Int(previous.offset))->\(Int(metrics.offset))")
                // The binding still holds the executor's last target, which SwiftUI would re-apply on
                // the next update and scroll the reader back. A direct move leaves it with no target.
                if position.point != nil || position.edge != nil { position = ScrollPosition(idType: UUID.self) }
                if viewport.readerOwnsViewport || !atBottom {
                    viewport.readerMoved(currentRange: messageRange, anchor: reader.measuredAnchor())
                }
            }
            if metrics.offset != previous.offset { reader.executorTarget = nil }
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
    /// `maximumScrollAttempts` times. Reader input cancels it through the owner.
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
            let metrics = reader.metrics
            var target: CGFloat
            switch request.target {
            case .bottom:
                RenderSignposts.event("TranscriptFollow")
                followThrottle.recordFire(at: ProcessInfo.processInfo.systemUptime)
                target = metrics.offset + metrics.bottomGap
            case .anchor(let anchor):
                // Not laid out yet: the row's geometry report runs this again, within the same bound.
                guard let frame = reader.rowFrames[anchor.messageID] else {
                    reader.attempts += 1
                    return
                }
                target = frame.minY + anchor.offset
            }
            target = min(max(target, metrics.offset - metrics.topGap), metrics.offset + metrics.bottomGap)
            // SwiftUI ignores a position equal to the one it holds, which it still holds after
            // scrolling that was not a gesture. A hair's difference makes it scroll again.
            if position.point?.y == target { target += 0.001 }
            viewport.note(
                "scroll \(request.generation) \(request.target == .bottom ? "bottom" : "anchor") "
                    + "\(Int(metrics.offset))->\(Int(target)) gap \(Int(metrics.topGap))/\(Int(metrics.bottomGap))")
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { position.scrollTo(y: target) }
            reader.attempts += 1
            reader.executorTarget = target
            viewport.recordScrollCommand()
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

    init() {}

    init(_ geometry: ScrollGeometry) {
        offset = geometry.contentOffset.y
        topGap = max(0, geometry.contentOffset.y + geometry.contentInsets.top)
        bottomGap = max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
        contentHeight = geometry.contentSize.height
        width = geometry.containerSize.width
    }

    var distanceFromBottom: CGFloat { bottomGap }
}

/// The scroll content's coordinate space. Frames measured in it change only with layout, never with
/// scrolling, so an anchor measured as the reader scrolls is never read from a stale frame.
private let transcriptContentSpace = "transcript-content"

/// Raw scroll measurements and executor bookkeeping. Deliberately not observable view state.
@MainActor private final class TranscriptReaderState {
    var isAtBottom = true
    var isScrolling = false
    var metrics = TranscriptScrollMetrics()
    /// Row frames in content coordinates, keyed by message identity.
    var rowFrames: [UUID: CGRect] = [:]
    var executorTask: Task<Void, Never>?
    /// The offset the executor's last command scrolled to. An offset change is the executor's only when
    /// it lands there; any other direct move is the reader's, even when a command produced no change.
    var executorTarget: CGFloat?
    var attemptGeneration: UInt64 = 0
    var attempts = 0

    func executorReached(_ offset: CGFloat) -> Bool {
        executorTarget.map { abs(offset - $0) <= 1 } ?? false
    }

    /// The distance from `id`'s top edge to the viewport's top edge, when laid out.
    func offset(of id: UUID) -> CGFloat? {
        rowFrames[id].map { metrics.offset - $0.minY }
    }

    /// The reader's position: the topmost row still visible, and how far into it the viewport starts.
    func measuredAnchor() -> TranscriptViewport.Anchor? {
        let top = metrics.offset
        return rowFrames.filter { $0.value.maxY > top }.min { $0.value.minY < $1.value.minY }
            .map { TranscriptViewport.Anchor(messageID: $0.key, offset: top - $0.value.minY) }
    }

    /// Whether the viewport already shows `target`: the anchor's top within 1 pt of its offset, or
    /// scrolled as far as the content allows toward it.
    func shows(_ target: TranscriptViewport.Target) -> Bool {
        switch target {
        case .bottom:
            return metrics.distanceFromBottom <= 1
        case .anchor(let anchor):
            guard let frame = rowFrames[anchor.messageID] else { return false }
            let error = frame.minY - metrics.offset + anchor.offset
            if abs(error) <= 1 { return true }
            // The target lies past an end of the scrollable range: the nearest end is fulfilment.
            return (error > 0 && metrics.bottomGap <= 1) || (error < 0 && metrics.topGap <= 1)
        }
    }
}
