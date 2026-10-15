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
    /// Shows `window` of a reply's segments, keeping segment `kept` where the reader sees it. The
    /// reply has `segmentCount` segments now.
    var page: @MainActor @Sendable (_ messageID: UUID, _ window: Range<Int>, _ kept: Int, _ segmentCount: Int) -> Void =
        { _, _, _, _ in }
    /// Short windows use explicit buttons; mounting the opposite boundary must not reverse a page.
    var canAutomaticallyPage: @MainActor @Sendable () -> Bool = { true }
    /// Whether a loader seen now can page, keeping `segment` of `messageID` in place: the reader owns
    /// the viewport, no move is pending or being attributed, and that segment has reported where it is.
    /// A loader seen while one of these is still settling waits for it, within a bound.
    var readyToPage: @MainActor @Sendable (_ messageID: UUID, _ segment: Int) -> Bool = { _, _ in true }
    /// A reply's segment count changed as it streamed.
    var recordSegmentCount: @MainActor @Sendable (_ messageID: UUID, _ segmentCount: Int) -> Void = { _, _ in }
    /// The reader took the viewport while a reply showed `window` of its `segmentCount` segments,
    /// which it keeps.
    var hold: @MainActor @Sendable (_ messageID: UUID, _ window: Range<Int>, _ segmentCount: Int) -> Void = {
        _, _, _ in
    }
    /// A shown segment's frame in content coordinates, or nil when it is no longer laid out, and the
    /// window of segments that layout shows.
    /// `instance` identifies the mounted view that measured it.
    var recordFrame:
        @MainActor @Sendable (
            _ messageID: UUID, _ segment: Int, _ frame: CGRect?, _ window: Range<Int>, _ instance: UUID
        ) -> Void = { _, _, _, _, _ in }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.viewport === rhs.viewport }
}

extension EnvironmentValues {
    @Entry var transcriptSegments = TranscriptSegmentNavigation()
}

/// The keys long text pages under with the navigation owner (#60 A1). A reply's answer uses its
/// message ID; its expanded reasoning pages independently under a key derived from that ID.
enum TranscriptSegmentOwner {
    /// The key a message's expanded reasoning pages under. Applying it twice gives the message ID back.
    static func reasoning(of messageID: UUID) -> UUID {
        var bytes = messageID.uuid
        bytes.15 ^= 0xA5
        return UUID(uuid: bytes)
    }

    /// Whether `key` is the message itself or its reasoning.
    static func key(_ key: UUID, belongsTo messageID: UUID) -> Bool {
        key == messageID || key == reasoning(of: messageID)
    }
}

private enum TranscriptPagingPhase: Equatable, Sendable {
    case idle
    case pagingEarlier
    case pagingLater
    case pagingSegments
}

struct TranscriptRevealRequest: Equatable, Sendable {
    let token = UUID()
    let messageID: UUID
    let byteOffset: Int
    var match: TranscriptText.SearchMatch? = nil
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
    @ObservationIgnored weak var historySession: ChatSession?
    private(set) var anchor: Anchor? {
        didSet { historySession?.historyAnchorID = anchor?.messageID }
    }
    private(set) var request: Request?
    /// Segment windows the reader paged long replies to, by message. Following clears them.
    private(set) var segmentWindows: [UUID: Range<Int>] = [:] {
        didSet { segmentCounts = segmentCounts.filter { segmentWindows[$0.key] != nil } }
    }
    /// The current segment count of each held reply, which grows while it streams. Read only when a
    /// gesture settles, so a streaming refresh does not invalidate every reply.
    @ObservationIgnored private var segmentCounts: [UUID: Int] = [:]
    static let maximumSegmentWindows = 16
    private var generation: UInt64 = 0
    /// Scroll commands issued and requests abandoned after the bounded attempts, for instrumentation.
    @ObservationIgnored private(set) var scrollCommands = 0
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
    func segmentWindow(for messageID: UUID) -> Range<Int>? { segmentWindows[messageID] }

    /// Whether the reader holds `messageID` short of its current end, so the transcript's bottom is
    /// not the reply's end. A window that reached the end stops reaching it as the reply grows.
    func holdsEarlierSegments(of messageID: UUID) -> Bool {
        guard let window = segmentWindows[messageID] else { return false }
        // Without a known count, never treat the held window as the end.
        guard let count = segmentCounts[messageID] else { return true }
        return window.upperBound < count
    }

    /// The reader paged a long reply of `segmentCount` segments to `window`. The reader owns the
    /// viewport and keeps `anchor`, a segment inside both windows.
    func pageSegments(
        of messageID: UUID, to window: Range<Int>, segmentCount: Int, currentRange: Range<Int>, keeping anchor: Anchor
    ) {
        readerMoved(currentRange: currentRange)
        if segmentWindows[messageID] == nil, segmentWindows.count >= Self.maximumSegmentWindows {
            segmentWindows.removeAll()
        }
        segmentWindows[messageID] = window
        segmentCounts[messageID] = segmentCount
        restore(anchor)
    }

    /// The reader took the viewport while `messageID` showed `window` of its `segmentCount` segments.
    /// The reply keeps them, as the message window keeps its messages, so the owner holds them as if
    /// paged there, without a scroll: otherwise, once more output arrives, settling at the bottom of
    /// the kept segments would resume following with newer ones hidden.
    func holdSegments(of messageID: UUID, at window: Range<Int>, segmentCount: Int) {
        guard readerOwnsViewport, segmentWindows[messageID] == nil else { return }
        if segmentWindows.count >= Self.maximumSegmentWindows { segmentWindows.removeAll() }
        segmentWindows[messageID] = window
        segmentCounts[messageID] = segmentCount
    }

    /// A held reply now has `segmentCount` segments. Replies without a held window are not recorded.
    func recordSegmentCount(_ segmentCount: Int, of messageID: UUID) {
        guard segmentWindows[messageID] != nil else { return }
        segmentCounts[messageID] = segmentCount
    }

    /// A reader gesture, keyboard or scroller movement, or an inspection took the viewport. The
    /// reader's input always wins, so any pending scroll is cancelled.
    func readerMoved(currentRange: Range<Int>, anchor: Anchor? = nil, replacingUnknown: Bool = false) {
        if Self.traces {
            note(
                "readerMoved \(currentRange) anchor \(anchor.map { "\($0.messageID.uuidString.prefix(4))+\(Int($0.offset))" } ?? "nil")"
            )
        }
        if heldRange == nil { heldRange = currentRange }
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

    /// Content grew, regrouped or reflowed. Following asks for the bottom. A reader's position needs no
    /// request: the lazy stack keeps its topmost visible row in place as rows above, below or within the
    /// viewport change size (WWDC26 "Dive into lazy stacks and scrolling with SwiftUI"), and the explicit
    /// restores (paging, restoration, reveal, compaction) issue their own. An equal pending request is
    /// kept, so repeated changes coalesce.
    func contentChanged() {
        guard autoFollow, request?.target != .bottom else { return }
        issue(.bottom)
    }

    /// Makes `anchor` the reader's position and scrolls to it (paging, restoration, compaction).
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

    func reveal(_ anchor: Anchor, messageWindow: Range<Int>, segment: Int?, segmentCount: Int) {
        heldRange = messageWindow
        segmentWindows.removeAll()
        if let segment {
            segmentWindows[anchor.messageID] = segment..<min(segmentCount, segment + 1)
            segmentCounts[anchor.messageID] = segmentCount
        }
        isScrolledToBottom = false
        restore(anchor)
    }

    /// Database pages and complete-context hydration change array indices, not message identity.
    func historyRebased(count: Int, anchorIndex: Int?, cost: (Int) -> Int) {
        guard readerOwnsViewport, let anchorIndex else {
            contentChanged()
            return
        }
        heldRange = TranscriptWindow.range(count: count, startingAt: anchorIndex, cost: cost)
        // The window moved under the reader: verify their row is where it was.
        if let anchor { restore(anchor) }
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

    @State private var historyTask: Task<Void, Never>?
    @State private var earlierLoaderVisible = false
    @State private var laterLoaderVisible = false

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
                        // Lazy: only rows near the viewport are laid out. A plain stack re-measured every row,
                        // including the scroll view's ideal-size pass, on each streamed update (#85, ADR-0099).
                        // Everything sits in the one lazy stack: a plain stack around it measured it in full
                        // again (Delivery 3 reasoning on macOS 26: 19 s became 78 s). Paging restores the kept
                        // row explicitly, so a loader the stack anchors to never moves what the reader sees.
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if session.isPagingHistory { ProgressView().controlSize(.small) }
                            if let error = session.historyPageError {
                                Text(error).font(.caption).foregroundStyle(Caprine.Semantic.warning)
                            }
                            if messageRange.lowerBound > 0 || session.historyHasEarlier {
                                Button("Earlier messages", systemImage: "arrow.up") {
                                    viewport.claimViewport(currentRange: messageRange)
                                    loadEarlierMessages()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                                .id("earlier-messages-loader")
                                .onScrollVisibilityChange(threshold: 0.01) { visible in
                                    // Never inside the layout pass that revealed the loader: the scroll that
                                    // revealed it is attributed first.
                                    earlierLoaderVisible = visible
                                    guard visible else { return }
                                    Task { @MainActor in
                                        await Task.yield()
                                        pageThroughVisibleLoader()
                                    }
                                }
                            }
                            let precedingDate =
                                session.messages[..<messageRange.lowerBound].last {
                                    $0.role != .tool && !TranscriptActivity.isEmpty($0)
                                }?.createdAt ?? session.historyPrecedingDate
                            let rows = TranscriptActivity.rows(
                                session.messages[messageRange], precedingDate: precedingDate)
                            let lastMessageID = TranscriptActivity.lastVisibleID(in: session.messages)
                            let activeAssistant =
                                session.isStreaming
                                ? session.messages.last(where: { $0.role == .assistant }) : nil
                            let activeAssistantID = activeAssistant?.id
                            let activeToolID: String? = {
                                guard let activeAssistant else { return nil }
                                return TranscriptActivity.summary(
                                    [activeAssistant], activeAssistantID: activeAssistant.id
                                )
                                .current?.id
                            }()
                            ForEach(rows) { row in
                                // Each message retains its identity and ancestry as tool events arrive.
                                // Keep projection inside the existing bounded, fully measured window.
                                VStack(alignment: .leading, spacing: 0) {
                                    if let message = row.messages.first {
                                        if row.startsDay {
                                            Text(message.createdAt, format: .dateTime.year().month(.wide).day())
                                                .font(Caprine.Activity.font)
                                                .foregroundStyle(.secondary)
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, Caprine.Activity.inset)
                                                .accessibilityAddTraits(.isHeader)
                                        }
                                        TranscriptMessageRow(
                                            message: message, session: session, isLast: message.id == lastMessageID,
                                            compactActivity: row.isContinuation,
                                            joinsPreviousTools: row.joinsPreviousTools,
                                            joinsNextTools: row.joinsNextTools,
                                            activeToolID: message.id == activeAssistantID ? activeToolID : nil,
                                            canDeleteCompaction: CompactionDeletion.canRestore(
                                                message, in: session.messages),
                                            canEdit: message.role == .user && !session.isStreaming,
                                            keyboardFocus: $focusedMessageID,
                                            isKeyboardFocused: focusedMessageID == message.id
                                        )
                                        .equatable()
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
                                .modifier(
                                    TranscriptFrameReport(label: "row \(row.id.uuidString.prefix(4))") {
                                        instance, frame in
                                        recordFrame(frame, of: row.id, instance: instance)
                                    }
                                )
                                .id(row.id)
                            }
                            if messageRange.upperBound < session.messages.count || session.historyHasLater {
                                Button("Later messages", systemImage: "arrow.down") { loadLaterMessages() }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8)
                                    .id("later-messages-loader")
                                    .onScrollVisibilityChange(threshold: 0.01) { visible in
                                        // Never inside the layout pass that revealed the loader: the scroll that
                                        // revealed it is attributed first.
                                        laterLoaderVisible = visible
                                        guard visible else { return }
                                        Task { @MainActor in
                                            await Task.yield()
                                            pageThroughVisibleLoader()
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
                        page: { id, window, kept, segmentCount in
                            pageSegments(of: id, to: window, keeping: kept, segmentCount: segmentCount)
                        },
                        canAutomaticallyPage: {
                            reader.metrics.contentHeight > reader.metrics.layout.container.height + 1
                        },
                        readyToPage: { id, segment in
                            pagingPhase == .idle && viewport.readerOwnsViewport && viewport.request == nil
                                && !reader.attributingMove && reader.segmentFrames[id]?[segment] != nil
                        },
                        recordSegmentCount: { id, segmentCount in viewport.recordSegmentCount(segmentCount, of: id) },
                        hold: { id, window, segmentCount in
                            viewport.holdSegments(of: id, at: window, segmentCount: segmentCount)
                        },
                        recordFrame: { id, segment, frame, window, instance in
                            recordFrame(frame, of: id, segment: segment, laidOutIn: window, instance: instance)
                        })
                )
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
                        reader.expectsProxyLanding = false
                        viewport.readerMoved(currentRange: messageRange, anchor: reader.measuredAnchor())
                    } else if phase == .idle {
                        let readerFinishedScrolling = reader.isScrolling
                        reader.isScrolling = false
                        guard readerFinishedScrolling else { return }
                        viewport.note("gesture settled at \(Int(reader.metrics.offset))")
                        // A last reply held on earlier segments is not the conversation's end.
                        let holdsLastReply = session.messages.last.map { holdsEarlierSegments(of: $0) } ?? false
                        viewport.readerSettled(
                            atTrueBottom: !session.historyHasLater && messageRange.upperBound == session.messages.count
                                && reader.isAtBottom
                                && !holdsLastReply,
                            anchor: reader.measuredAnchor())
                        // A scroll that ended where the lazy stack lays out nothing is rescued there, once the
                        // rows it does lay out have had a moment to report.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(60))
                            guard !reader.isScrolling else { return }
                            rescueBlankViewport(atReader: true)
                        }
                    }
                }
                .onChange(of: viewport.request) {
                    if viewport.request == nil {
                        // A reader gesture that cancels a paging scroll also ends that page load.
                        if pagingPhase != .idle { pagingPhase = .idle }
                        placeInitiallyIfReady()
                        // A loader seen while the request ran pages once the reader is where it put them.
                        Task { @MainActor in
                            await Task.yield()
                            pageThroughVisibleLoader()
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
                    session.historyAnchorID = viewport.anchor?.messageID
                }
                .onChange(of: session.historyRevision) {
                    viewport.historyRebased(count: session.messages.count, anchorIndex: anchorIndex, cost: displayCost)
                }
                .onChange(of: pagingPhase) { _, phase in
                    guard phase == .idle, session.historyPageError == nil else { return }
                    Task { @MainActor in
                        await Task.yield()
                        pageThroughVisibleLoader()
                    }
                }
                .onChange(of: focusRequest) {
                    guard focusRequest != nil else { return }
                    let anchor = reader.measuredAnchor()
                    guard let id = anchor?.messageID ?? renderedMessageID(near: messageRange.lowerBound) else { return }
                    // Keyboard focus is reader input. Keep the current reading window and cancel
                    // any pending automatic restore before native focus moves within that window.
                    viewport.readerMoved(currentRange: messageRange, anchor: anchor)
                    focusedMessageID = id
                }
                .task(id: revealRequest) {
                    guard let revealRequest else { return }
                    guard await model.loadHistory(around: revealRequest.messageID, for: session), !Task.isCancelled,

                        let message = session.messages.first(where: { $0.id == revealRequest.messageID })
                    else { return }
                    let source = message.text
                    let complete = message.complete
                    let isAssistant = message.role == .assistant && message.kind == .regular
                    let richLimit = ReplyWindow.richLimit
                    let worker = Task.detached(priority: .userInitiated) { () -> (Int?, Int) in
                        guard isAssistant, source.utf8.count <= richLimit else { return (nil, 0) }
                        let segments = MarkdownSegmenter.segment(source, isComplete: complete).segments
                        let index = segments.firstIndex { $0.sourceRange.contains(revealRequest.byteOffset) }
                        return (index, segments.count)
                    }
                    let (segment, count) = await withTaskCancellationHandler {
                        await worker.value
                    } onCancel: {
                        worker.cancel()
                    }
                    guard !Task.isCancelled,
                        let index = session.messages.firstIndex(where: { $0.id == revealRequest.messageID })
                    else { return }
                    pagingPhase = .idle
                    reader.isScrolling = false
                    followThrottle.reset()
                    viewport.reveal(
                        .init(messageID: message.id, offset: 0, segment: segment),
                        messageWindow: TranscriptWindow.range(
                            count: session.messages.count, startingAt: index, cost: displayCost),
                        segment: segment, segmentCount: count)
                }
                .onChange(of: session.isStreaming) { viewport.contentChanged() }
                .onChange(of: ReflowKey(fontSize: model.chatFontSize, column: readingColumn)) { scheduleRelayout() }
                // Rows near the reader render formatted on their first frame when the lazy stack mounts them.
                .task(id: TranscriptPrewarm.Key(range: messageRange, count: session.messages.count)) {
                    let range = messageRange
                    let focus = (anchorIndex ?? range.upperBound - 1) - range.lowerBound
                    await TranscriptPrewarm.prepare(Array(session.messages[range]), around: focus)
                }
                // A newly sent turn always re-arms following and jumps to the bottom.
                .onChange(of: session.messages.count) { previousCount, count in
                    if count < previousCount, session.hasCompleteHistory, viewport.heldRange != nil {
                        viewport.messagesRemoved(
                            count: count, anchorIndex: anchorIndex,
                            messageID: { renderedMessageID(near: $0) ?? session.messages[$0].id }, cost: displayCost)
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

    var visibleMessageRange: Range<Int> { messageRange }

    private var anchorIndex: Int? {
        viewport.anchor.flatMap { anchor in
            session.messages.firstIndex(where: { TranscriptSegmentOwner.key(anchor.messageID, belongsTo: $0.id) })
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
        // Not in an animation transaction: the window change would cross-fade every row it replaces.
        viewport.jumpToLatest()
    }

    /// Pages through a loader the reader scrolled to. A loader is also seen for a moment while a
    /// restoration, page or jump is still moving the viewport, or before the first placement: paging
    /// then would cancel that move, so it waits until the move ends and the loader is still visible.
    /// The page also waits, within a bound, for the row it keeps in place to report where it is: the
    /// lazy stack lays that row out after the move that revealed the loader.
    private func pageThroughVisibleLoader(attempt: Int = 0) {
        guard initiallyPlaced, viewport.request == nil, pagingPhase == .idle,
            earlierLoaderVisible || laterLoaderVisible
        else { return }
        // SwiftUI reports a loader leaving the viewport with its next update: confirm from the scroll
        // view that the viewport is still at that end, so a reader who moved on is not paged.
        reader.syncGeometry()
        let reach = reader.metrics.layout.container.height
        guard earlierLoaderVisible ? reader.metrics.topGap <= reach : reader.metrics.bottomGap <= reach else { return }
        let range = messageRange
        let kept = renderedMessageID(near: earlierLoaderVisible ? range.lowerBound : range.upperBound - 1)
        let keptMeasured = kept.map { reader.rowFrames[$0] != nil } ?? true
        if !keptMeasured, attempt < Self.maximumScrollAttempts {
            Task { @MainActor in
                try? await Task.sleep(for: Self.frameRetryInterval)
                pageThroughVisibleLoader(attempt: attempt + 1)
            }
            return
        }
        if earlierLoaderVisible {
            loadEarlierMessages()
        } else {
            loadLaterMessages()
        }
    }

    /// Pages earlier while keeping the message at the top of the window where the reader sees it.
    /// Only a reader pages earlier: while the transcript follows, the earlier loader can be seen for a
    /// moment during layout (a reply still preparing is short), and paging then would leave the latest
    /// output.
    private func loadEarlierMessages() {
        guard pagingPhase == .idle, viewport.readerOwnsViewport else { return }
        if messageRange.lowerBound == 0, session.historyHasEarlier {
            fetchHistory(earlier: true)
            return
        }
        // The first row the reader sees in the window: a tool result or an empty message renders nothing.
        guard messageRange.lowerBound > 0, let kept = renderedMessageID(near: messageRange.lowerBound) else { return }
        let keptOffset = reader.offset(of: kept)
        let seen = reader.measuredAnchor()
        guard let result = viewport.pageEarlier(count: session.messages.count, cost: displayCost) else { return }
        pagingPhase = .pagingEarlier
        restorePagingAnchor(result.anchor, kept: kept, keptOffset: keptOffset, seen: seen)
    }

    /// Pages later while keeping the message at the end of the window where the reader sees it.
    private func loadLaterMessages() {
        guard pagingPhase == .idle else { return }
        if messageRange.upperBound == session.messages.count, session.historyHasLater {
            fetchHistory(earlier: false)
            return
        }
        guard messageRange.upperBound < session.messages.count,
            let kept = renderedMessageID(near: messageRange.upperBound - 1)
        else { return }
        let keptOffset = reader.offset(of: kept)
        let seen = reader.measuredAnchor()
        guard let result = viewport.pageLater(count: session.messages.count, cost: displayCost) else { return }
        pagingPhase = .pagingLater
        restorePagingAnchor(result.anchor, kept: kept, keptOffset: keptOffset, seen: seen)
    }

    private func fetchHistory(earlier: Bool) {
        guard !session.isPagingHistory, !session.isStreaming else { return }
        let anchor = reader.measuredAnchor() ?? viewport.anchor
        if let anchor { viewport.readerMoved(currentRange: messageRange, anchor: anchor) }
        pagingPhase = earlier ? .pagingEarlier : .pagingLater
        historyTask = Task { @MainActor in
            let loaded = await model.pageHistory(for: session, earlier: earlier)
            guard !Task.isCancelled else { return }
            pagingPhase = .idle
            guard loaded else { return }
            viewport.historyRebased(count: session.messages.count, anchorIndex: anchorIndex, cost: displayCost)
            if earlier { loadEarlierMessages() } else { loadLaterMessages() }
        }
    }

    /// Resolves the page's anchor index to a stable message identity before scrolling. When pages
    /// overlap it is the kept message at its measured offset; otherwise the top of the new page.
    /// `seen` is what the reader saw at the viewport's top before paging: it stays exactly there whenever
    /// the new window still holds it. Otherwise the window's edge row `kept` stays where it was.
    private func restorePagingAnchor(_ index: Int, kept: UUID, keptOffset: CGFloat?, seen: TranscriptViewport.Anchor?) {
        if let seen,
            let seenIndex = session.messages.firstIndex(where: {
                TranscriptSegmentOwner.key(seen.messageID, belongsTo: $0.id)
            }),
            messageRange.contains(seenIndex)
        {
            viewport.restore(seen)
            return
        }
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

    /// Whether the reader holds `message` short of its end: its answer, or its reasoning while no
    /// answer follows it.
    private func holdsEarlierSegments(of message: ChatMessage) -> Bool {
        if viewport.holdsEarlierSegments(of: message.id) { return true }
        guard message.textRevision.utf8Count == 0 else { return false }
        return viewport.holdsEarlierSegments(of: TranscriptSegmentOwner.reasoning(of: message.id))
    }

    /// Moves a long reply's segment window, keeping segment `kept` where the reader sees it.
    /// Only a reader pages a reply: while following, a loader seen during layout is transient.
    private func pageSegments(of id: UUID, to window: Range<Int>, keeping kept: Int, segmentCount: Int) {
        guard pagingPhase == .idle, viewport.readerOwnsViewport else { return }
        let offset = reader.offset(of: id, segment: kept) ?? 0
        pagingPhase = .pagingSegments
        viewport.pageSegments(
            of: id, to: window, segmentCount: segmentCount, currentRange: messageRange,
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

    private func recordFrame(_ frame: CGRect?, of id: UUID, instance: UUID) {
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
        if viewport.anchor == nil, viewport.readerOwnsViewport, !reader.isScrolling,
            let anchor = reader.measuredAnchor()
        {
            viewport.adoptAnchor(anchor)
        }
        if case .anchor(let anchor) = viewport.request?.target, anchor.messageID == id {
            // The awaited row arrived: run now rather than at the retry.
            cancelFrameWait()
            executePendingRequest()
        }
    }

    private func recordFrame(
        _ frame: CGRect?, of id: UUID, segment: Int, laidOutIn window: Range<Int>, instance: UUID
    ) {
        if frame == nil, reader.segmentInstances[id]?[segment] != instance { return }
        reader.segmentInstances[id, default: [:]][segment] = frame == nil ? nil : instance
        if reader.segmentInstances[id]?.isEmpty == true { reader.segmentInstances[id] = nil }
        let previous = reader.segmentFrames[id]?[segment]
        if TranscriptViewport.traces {
            viewport.note(
                "segment \(id.uuidString.prefix(4)) \(segment) in \(window) at \(frame.map { "\(Int($0.minY))" } ?? "gone")"
            )
        }
        reader.segmentFrames[id, default: [:]][segment] = frame
        if let previous, let frame, previous.minY != frame.minY, viewport.anchor?.messageID == id,
            viewport.anchor?.segment == segment
        {
            keepAnchorInPlace(previousTop: previous.minY)
        }
        if frame != nil { reader.segmentFrameWindows[id] = window }
        if reader.segmentFrames[id]?.isEmpty == true {
            reader.segmentFrames[id] = nil
            reader.segmentFrameWindows[id] = nil
        }
        if frame != nil, case .anchor(let anchor) = viewport.request?.target, anchor.messageID == id {
            // The awaited segment arrived: run now rather than at the retry.
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
        let atBottom =
            !session.historyHasLater && metrics.distanceFromBottom <= Self.bottomTolerance
            && messageRange.upperBound == session.messages.count
        reader.isAtBottom = atBottom
        if !reader.isScrolling, metrics.contentHeight > metrics.layout.container.height,
            metrics.offset > metrics.contentHeight - metrics.layout.container.height + 1
        {
            // The content shrank above a viewport past its new end. The scroll view keeps its bounds
            // valid, but the lazy stack lays out the rows there only after a move it is told about, so
            // the executor makes that move. Never inside the geometry callback.
            Task { @MainActor in
                reader.syncGeometry()
                guard reader.metrics.bottomGap <= 0.5 else { return }
                let end = max(0, reader.metrics.contentHeight - reader.metrics.layout.container.height)
                viewport.note("keep inside the content at \(Int(end))")
                // Two moves on separate turns: SwiftUI coalesces a move and its return within one.
                reader.executor.scroll(toY: end - 1)
                try? await Task.sleep(for: .milliseconds(16))
                reader.executor.scroll(toY: end)
                reader.syncGeometry()
                try? await Task.sleep(for: .milliseconds(100))
                rescueBlankViewport()
            }
        }
        if !reader.isScrolling {
            if metrics.layout != previous.layout {
                // Content grew or reflowed, or the viewport resized, moving the offset with it if at all:
                // follow it, or put the reader's anchor back.
                viewport.contentChanged()
            } else if abs(metrics.offset - previous.offset) >= 1 {
                // Less than a point is the scroll view aligning to device pixels as content changes,
                // never a reader.
                // Who moved the viewport is recorded where the move happens, never inferred from geometry.
                switch reader.executor.cause(ofOffset: metrics.offset) {
                case .executor, .layout:
                    // The executor's own command, checked for fulfilment below, or AppKit keeping the
                    // bounds valid as the document resized.
                    break
                case .other where reader.expectsProxyLanding:
                    // The executor's last-resort SwiftUI scroll landing; the pending request continues.
                    reader.expectsProxyLanding = false
                    viewport.note("proxy landed at \(Int(metrics.offset))")
                case .other where viewport.request != nil && !reader.executor.lastMoveFollowedInput:
                    // No reader input came with this move: the lazy stack moving the offset as rows above
                    // resolve while the executor chases a request. The request continues and is checked
                    // against where the rows now are.
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
            if reader.shows(request.target, heldWindow: viewport.segmentWindow(for:)) {
                viewport.note("fulfilled \(request.generation) at \(Int(reader.metrics.offset))")
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
                // A segment's frame counts only once the reply lays out the window the owner holds: right
                // after paging it is still the previous window's, which the anchor was measured from.
                guard let frame = reader.frame(of: anchor, heldWindow: viewport.segmentWindow(for: anchor.messageID))
                else {
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
                if viewport.readerOwnsViewport || !reader.isAtBottom {
                    viewport.readerMoved(currentRange: messageRange, anchor: anchorAfter, replacingUnknown: true)
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
        guard
            let message = session.messages.first(where: {
                TranscriptSegmentOwner.key(anchor.messageID, belongsTo: $0.id)
            }), reader.rowFrames[message.id] == nil
        else { return }
        let order = TranscriptActivity.rows(session.messages[messageRange]).map(\.id)
        guard let target = order.firstIndex(of: message.id) else { return }
        reader.syncGeometry()
        // Only frames near the viewport are current: the lazy stack laid them out for where it is.
        let reach = 4 * reader.metrics.layout.container.height
        let near = (reader.metrics.offset - reach)...(reader.metrics.offset + reach)
        let laidOut = Self.ordered(
            order.enumerated().compactMap { index, id in
                reader.rowFrames[id].flatMap { near.overlaps($0.minY...$0.maxY) ? (index, $0) : nil }
            })
        guard let nearest = laidOut.min(by: { abs($0.0 - target) < abs($1.0 - target) }) else { return }
        let averageHeight = laidOut.map(\.1.height).reduce(0, +) / CGFloat(max(laidOut.count, 1))
        let estimate =
            target < nearest.0
            ? nearest.1.minY - CGFloat(nearest.0 - target) * averageHeight
            : nearest.1.maxY + CGFloat(target - nearest.0 - 1) * averageHeight
        let metrics = reader.metrics
        var y = min(max(estimate + anchor.offset, metrics.offset - metrics.topGap), metrics.offset + metrics.bottomGap)
        // An estimate from few rows can be far off, and one past the rows shows nothing: move at most a few
        // viewports per attempt, so the rows on the way lay out and the next estimate starts from them.
        let maximumMove = 3 * metrics.layout.container.height
        y = min(max(y, metrics.offset - maximumMove), metrics.offset + maximumMove)
        // An estimate that keeps the viewport where it is would wait forever: step a viewport toward the
        // row, so the rows there lay out and the next estimate starts from them.
        if abs(y - metrics.offset) < 1 {
            let step = metrics.layout.container.height
            y =
                target < nearest.0
                ? max(metrics.offset - metrics.topGap, metrics.offset - step)
                : min(metrics.offset + metrics.bottomGap, metrics.offset + step)
        }
        // Estimates that return to a place already tried are not converging: the rows laid out do not
        // place the target (a window rebased under the reveal renumbers them). SwiftUI knows where the
        // row is in what it renders; its scroll lands on a later update, and the executor then places
        // the target exactly.
        if reader.revealsTried.contains(where: { abs($0 - y) < 1 }), let proxy = reader.proxy {
            viewport.note("reveal row \(target) through SwiftUI after \(reader.revealsTried.count) estimates")
            reader.expectsProxyLanding = true
            proxy.scrollTo(rowID(containing: message.id) ?? message.id, anchor: .top)
            viewport.recordScrollCommand()
            verifyAfterScroll()
            return
        }
        reader.revealsTried.append(y)
        viewport.note(
            "reveal row \(target) near \(nearest.0) at \(Int(y)) from \(Int(metrics.offset)) gap "
                + "\(Int(metrics.topGap))/\(Int(metrics.bottomGap)) laid out "
                + laidOut.map { "\($0.0)@\(Int($0.1.minY))" }.joined(separator: ","))
        reader.executor.scroll(toY: y)
        reader.syncGeometry()
        viewport.recordScrollCommand()
        verifyAfterScroll()
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
            let frame = reader.frame(of: anchor, heldWindow: viewport.segmentWindow(for: anchor.messageID)),
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
        guard !reader.rowFrames.values.contains(where: { $0.maxY > top && $0.minY < bottom }) else { return }
        // Following reaches the end through the rows' own estimate instead (`estimatedContentEnd`).
        guard viewport.readerOwnsViewport else { return }
        let rows = TranscriptActivity.rows(session.messages[messageRange])
        let target: (id: UUID, edge: UnitPoint)?
        if atReader {
            let reach = metrics.layout.container.height
            // At either end the rows' own estimate, or the top itself, is where the rows are: SwiftUI
            // places a row by its estimate of the content, which is what left the viewport blank.
            if metrics.bottomGap <= reach, let end = estimatedContentEnd(), end < top + reach {
                let y = max(0, end - reach)
                viewport.note("rescue blank viewport at \(Int(top)) to the rows' end \(Int(y))")
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
                target = rows.last.map { ($0.id, .bottom) }
            } else if metrics.contentHeight <= 0 {
                target = rows.first.map { ($0.id, .top) }
            } else {
                let fraction = min(1, max(0, top / metrics.contentHeight))
                let index = min(rows.count - 1, Int(fraction * CGFloat(rows.count)))
                target = rows.indices.contains(index) ? (rows[index].id, .top) : nil
            }
        } else if let anchor = viewport.anchor, let row = rowID(containing: anchor.messageID) {
            target = (row, .top)
        } else {
            target = rows.first.map { ($0.id, .top) }
        }
        // At most once per interval: right after it the lazy stack re-estimates the content, and a
        // second rescue before that settles would chase the estimate.
        let now = ContinuousClock.now
        if let last = reader.lastRescue, now - last < .milliseconds(500) { return }
        guard let target, let proxy = reader.proxy else { return }
        reader.lastRescue = now
        viewport.note("rescue blank viewport at \(Int(top)) to \(target.id.uuidString.prefix(4))")
        // It lands on a later update, as a move the scroll view did not record: the next one is this
        // scroll's, not the reader's. Its landing at the last row's end is the bottom while following:
        // a further bottom request would chase the content's estimate past the rows.
        reader.expectsProxyLanding = true
        proxy.scrollTo(target.id, anchor: target.edge)
    }

    /// Where the content ends, estimated from the rows laid out, while the last row is not laid out;
    /// nil when it is, or when nothing is laid out to estimate from.
    private func estimatedContentEnd() -> CGFloat? {
        let order = TranscriptActivity.rows(session.messages[messageRange]).map(\.id)
        guard let last = order.last, reader.rowFrames[last] == nil else { return nil }
        let laidOut = Self.ordered(
            order.enumerated().compactMap { index, id in reader.rowFrames[id].map { (index, $0) } })
        guard let nearest = laidOut.last else { return nil }
        let averageHeight = laidOut.map(\.1.height).reduce(0, +) / CGFloat(laidOut.count)
        // Rows after the nearest one, then the trailing space and anything below it.
        return nearest.1.maxY + CGFloat(order.count - 1 - nearest.0) * averageHeight
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
            layoutGeneration &+= 1
            reader.rowFrames.removeAll()
            reader.reportedAnchor = nil
            reader.rowInstances.removeAll()
            reader.segmentFrames.removeAll()
            reader.segmentInstances.removeAll()
            reader.segmentFrameWindows.removeAll()
            viewport.note("relayout \(layoutGeneration)")
            if viewport.readerOwnsViewport, let anchor = viewport.anchor {
                viewport.restore(anchor)
            } else {
                viewport.contentChanged()
            }
        }
    }

    /// The identity of the row that shows `key`, a message or its reasoning.
    private func rowID(containing key: UUID) -> UUID? {
        TranscriptActivity.rows(session.messages[messageRange]).first { row in
            row.messages.contains { TranscriptSegmentOwner.key(key, belongsTo: $0.id) }
        }?.id
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
        if reader.rowFrames.isEmpty {
            if reader.attempts >= 2 { rescueBlankViewport() } else { reader.executor.layoutContent() }
        }
        reader.attempts += 1
        viewport.note(
            "awaiting \(missing) \(request.generation)"
                + (TranscriptViewport.traces
                    ? " rows \(reader.rowFrames.count) at \(Int(reader.metrics.offset)) of \(Int(reader.metrics.contentHeight))"
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

/// Prepares the formatted text of the admitted window's settled messages off the main actor, nearest
/// the reader first. The lazy stack mounts a row only as it nears the viewport, and a row's own
/// preparation is cancelled if it leaves first, so without this a row coming back into view would show
/// its placeholder for a frame and then change height (ADR-0099).
@MainActor enum TranscriptPrewarm {
    struct Key: Equatable {
        let range: Range<Int>
        let count: Int
    }

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
                        id: message.id, source: source, revision: revision, isComplete: true, window: .latest)
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
    func layoutContent() {
        guard let scrollView else { return }
        let origin = scrollView.contentView.bounds.origin
        // A move, which the lazy stack answers by laying out what the viewport shows, and back on a
        // later turn: SwiftUI coalesces a move and its return within one.
        scroll(toY: origin.y - 1)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            self?.scroll(toY: origin.y)
        }
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
@MainActor private final class TranscriptReaderState {
    var isAtBottom = true
    var isScrolling = false
    var metrics = TranscriptScrollMetrics()
    /// Row frames in content coordinates, keyed by message identity, for rows laid out now.
    var rowFrames: [UUID: CGRect] = [:]
    /// The mounted instance that reported each row's and segment's frame.
    var rowInstances: [UUID: UUID] = [:]
    var segmentInstances: [UUID: [Int: UUID]] = [:]
    /// Frames of the shown segments of windowed long replies in content coordinates, by message and
    /// segment index.
    var segmentFrames: [UUID: [Int: CGRect]] = [:]
    /// The window of segments each reply's reported frames were laid out in.
    var segmentFrameWindows: [UUID: Range<Int>] = [:]
    /// The transcript's only scroll writer.
    let executor = TranscriptScrollExecutor()
    var executorTask: Task<Void, Never>?
    /// A move awaiting attribution holds the executor until the rows report their positions.
    var attributingMove = false
    var attributionTask: Task<Void, Never>?
    /// Where the reader was as of the last geometry report or attributed move.
    var reportedAnchor: TranscriptViewport.Anchor?
    /// Re-checks the pending request after a scroll command whether or not its geometry is reported.
    var verificationTask: Task<Void, Never>?
    /// SwiftUI's own scroll, used only for a target the lazy stack does not lay out, and whether its
    /// landing is still to come.
    var proxy: ScrollViewProxy?
    var expectsProxyLanding = false
    var lastRescue: ContinuousClock.Instant?
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

    /// The frame an anchor is measured from: its segment's when it names one, else its row's. A
    /// segment's frame is used only when laid out in `heldWindow`, the window the owner holds for the
    /// reply, if any.
    func frame(of anchor: TranscriptViewport.Anchor, heldWindow: Range<Int>?) -> CGRect? {
        guard let segment = anchor.segment else { return rowFrames[anchor.messageID] }
        if let heldWindow, segmentFrameWindows[anchor.messageID] != heldWindow { return nil }
        return segmentFrames[anchor.messageID]?[segment]
    }

    /// The reader's position: the topmost row still visible, and how far into it the viewport starts.
    /// In a windowed long reply or expanded reasoning, the topmost segment still visible.
    func measuredAnchor() -> TranscriptViewport.Anchor? {
        let top = metrics.offset
        // A lazy stack keeps rows it laid out elsewhere until they disappear: only a row on screen
        // locates the reader.
        let bottom = top + metrics.layout.container.height
        guard
            let row = rowFrames.filter({ $0.value.maxY > top && $0.value.minY < bottom })
                .min(by: { $0.value.minY < $1.value.minY })
        else { return nil }
        var topmost: (key: UUID, segment: Int, frame: CGRect)?
        for key in [row.key, TranscriptSegmentOwner.reasoning(of: row.key)] {
            for (segment, frame) in segmentFrames[key] ?? [:] where frame.maxY > top {
                if topmost.map({ frame.minY < $0.frame.minY }) ?? true {
                    topmost = (key: key, segment: segment, frame: frame)
                }
            }
        }
        if let topmost {
            return TranscriptViewport.Anchor(
                messageID: topmost.key, offset: top - topmost.frame.minY, segment: topmost.segment)
        }
        return TranscriptViewport.Anchor(messageID: row.key, offset: top - row.value.minY)
    }

    /// Whether the viewport already shows `target`: the anchor's top within 1 pt of its offset, or
    /// scrolled as far as the content allows toward it.
    /// A segment anchor is never acknowledged against a window other than the one the owner holds.
    func shows(_ target: TranscriptViewport.Target, heldWindow: (UUID) -> Range<Int>?) -> Bool {
        switch target {
        case .bottom:
            return metrics.distanceFromBottom <= 1
        case .anchor(let anchor):
            guard let frame = frame(of: anchor, heldWindow: heldWindow(anchor.messageID)) else { return false }
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
        lhs.message === rhs.message && lhs.session === rhs.session && lhs.isLast == rhs.isLast
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
                } : nil)
    }
}
