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

/// Tracks the visible window and reader viewport ownership for a chat transcript.
@MainActor @Observable final class TranscriptViewport {
    var heldRange: Range<Int>?
    var autoFollow: Bool
    var readerOwnsViewport: Bool
    var isScrolledToBottom: Bool

    init(initiallyFollowing: Bool = true, initialHeldRange: Range<Int>? = nil) {
        self.autoFollow = initiallyFollowing
        self.readerOwnsViewport = !initiallyFollowing
        self.isScrolledToBottom = initiallyFollowing
        self.heldRange = initialHeldRange
    }

    func messageRange(count: Int, anchor: Int? = nil, cost: (Int) -> Int) -> Range<Int> {
        if let heldRange {
            return TranscriptWindow.clamped(heldRange, count: count, anchor: anchor, cost: cost)
        }
        return TranscriptWindow.range(count: count, end: nil, cost: cost)
    }

    func claimViewport(currentRange: Range<Int>) {
        if heldRange == nil { heldRange = currentRange }
        autoFollow = false
        readerOwnsViewport = true
    }

    @discardableResult
    func pageEarlier(count: Int, cost: (Int) -> Int) -> (range: Range<Int>, anchor: Int)? {
        let current = messageRange(count: count, cost: cost)
        guard current.lowerBound > 0 else { return nil }
        let previous = TranscriptWindow.earlier(current, count: count, cost: cost)
        let anchor = previous.contains(current.lowerBound) ? current.lowerBound : max(0, previous.upperBound - 1)
        claimViewport(currentRange: previous)
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
        claimViewport(currentRange: next)
        heldRange = next
        return (next, anchor)
    }

    func snapToBottom() {
        heldRange = nil
        readerOwnsViewport = false
        autoFollow = true
        isScrolledToBottom = true
    }
}

/// Its owner keys this view by chat ID. A new chat gets fresh native scroll geometry,
/// measured row layout and follow tasks instead of inheriting another transcript's viewport.
struct ChatTranscriptView: View {
    @Bindable var session: ChatSession
    @Environment(AppModel.self) private var model
    @State var viewport: TranscriptViewport
    @State private var reader = TranscriptReaderState()
    @State private var visibleMessageID: UUID?
    @State private var readerAnchorID: UUID?
    @State private var followThrottle = TranscriptFollowThrottle()
    @State private var pendingFollowScroll: Task<Void, Never>?
    @State private var pendingPreserveScroll: Task<Void, Never>?
    @State private var pagingPhase: TranscriptPagingPhase = .idle
    @State private var pagingTask: Task<Void, Never>?
    @State private var isHoveringScrollButton = false

    private static let bottomAnchor = UUID()

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
        _viewport = State(
            initialValue: viewport
                ?? TranscriptViewport(
                    initiallyFollowing: initiallyFollowing,
                    initialHeldRange: initialHeld
                ))
        _visibleMessageID = State(initialValue: initialVisibleMessageID)
        _readerAnchorID = State(initialValue: initialVisibleMessageID)
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
            ScrollViewReader { proxy in
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
                                if visible {
                                    loadEarlierMessages(using: proxy)
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
                                if visible {
                                    loadLaterMessages(using: proxy)
                                }
                            }
                        }
                        if session.isStreaming && messageRange.upperBound == session.messages.count {
                            AgentProgressView(session: session)
                                .padding(.top, Caprine.Activity.spacing)
                        }
                        // End sentinel the follower scrolls to as the transcript grows.
                        Color.clear
                            .frame(height: Caprine.Activity.doubleLineHeight + 1)
                            .id(Self.bottomAnchor)
                            .onScrollVisibilityChange(threshold: 0.1) { visible in
                                updateBottomVisibility(visible, using: proxy)
                            }

                    }
                    .scrollTargetLayout()
                    // One centred reading column shared with the composer (#60 D3).
                    .frame(maxWidth: readingColumn, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity)
                    .background(
                        TranscriptScrollViewObserver(
                            onScrollChanged: { scroll in
                                handleNativeScroll(scroll)
                            },
                            onResolve: { scroll in
                                reader.enclosingScrollView = scroll
                            }
                        )
                        .frame(width: 0, height: 0)
                    )
                }
                .overlay(alignment: .bottom) {
                    if !viewport.isScrolledToBottom {
                        Button {
                            snapToBottom(using: proxy)
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
                        viewport.claimViewport(currentRange: messageRange)
                        cancelPendingFollowScroll()
                        cancelPendingPreserveScroll()
                    }
                )
                .scrollPosition(id: $visibleMessageID, anchor: .top)
                .onChange(of: visibleMessageID) {
                    if reader.isScrolling, let visibleMessageID { readerAnchorID = visibleMessageID }
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .alignment)
                // Preserve the reader's current content when rows regroup or reflow. Active
                // following is driven explicitly by requestFollowScroll below.
                .defaultScrollAnchor(.top, for: .sizeChanges)
                // Reader gestures own the viewport until they return to the bottom sentinel.
                .onScrollPhaseChange { _, phase in
                    if phase == .tracking || phase == .interacting || phase == .decelerating {
                        reader.isScrolling = true
                        viewport.claimViewport(currentRange: messageRange)
                        cancelPendingFollowScroll()
                        cancelPendingPreserveScroll()
                    } else if phase == .idle {
                        let readerFinishedScrolling = reader.isScrolling
                        if readerFinishedScrolling, let visibleMessageID { readerAnchorID = visibleMessageID }
                        reader.isScrolling = false
                        // Only a reader gesture may hand the viewport back to bottom following.
                        // Regrouping can make the bottom sentinel transiently visible during
                        // native layout and must not change the ownership captured before it.
                        if readerFinishedScrolling && messageRange.upperBound == session.messages.count
                            && reader.isAtBottom
                        {
                            viewport.readerOwnsViewport = false
                            viewport.heldRange = nil
                            viewport.autoFollow = true
                        } else if viewport.readerOwnsViewport {
                            viewport.autoFollow = false
                        }
                    }
                }
                // Native size-change anchoring handles font/width/Markdown reflow. Do not
                // feed estimated transcript heights back into programmatic scroll commands.
                // Chase streaming growth (text + thinking + new messages) while following.
                .onChange(of: streamRevision) {
                    if viewport.autoFollow {
                        requestFollowScroll(using: proxy)
                    } else if viewport.readerOwnsViewport {
                        preserveReaderPosition(using: proxy)
                    }
                }
                .onChange(of: session.isStreaming) { wasStreaming, isStreaming in
                    if wasStreaming && !isStreaming, viewport.autoFollow {
                        requestFollowScroll(using: proxy)
                    }
                }
                // A newly sent turn always re-arms follow and snaps to the bottom.
                .onChange(of: session.messages.count) { previousCount, count in
                    if let heldRange = viewport.heldRange, count < previousCount {
                        let anchor = readerAnchorIndex
                        let surviving = TranscriptWindow.clamped(
                            heldRange, count: count, anchor: anchor, cost: displayCost)
                        viewport.heldRange = surviving
                        if anchor == nil {
                            self.readerAnchorID = surviving.first.map { session.messages[$0].id }
                            visibleMessageID = self.readerAnchorID
                        }
                    }
                    if session.messages.last?.role == .user {
                        resetPaging()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewport.snapToBottom()
                        }
                        snapToBottom(using: proxy)
                    } else if viewport.autoFollow {
                        requestFollowScroll(using: proxy)
                    } else if viewport.readerOwnsViewport {
                        preserveReaderPosition(using: proxy)
                    }
                }
                .onDisappear {
                    cancelPendingFollowScroll()
                    cancelPendingPreserveScroll()
                    resetPaging()
                    reader.resumeTask?.cancel()
                    reader.resumeTask = nil
                }
            }
        }
    }

    private var tokens: Caprine { model.theme.tokens }

    private var readingColumn: CGFloat {
        ReadingMeasure.column(
            fontID: model.effectiveChatFontID, size: model.chatFontSize, presentation: model.presentation.isEnabled)
    }

    var visibleMessageRange: Range<Int> { messageRange }

    private var readerAnchorIndex: Int? {
        readerAnchorID.flatMap { id in
            session.messages.firstIndex(where: { $0.id == id })
        }
    }

    private var messageRange: Range<Int> {
        viewport.messageRange(count: session.messages.count, anchor: readerAnchorIndex, cost: displayCost)
    }

    private func displayCost(_ index: Int) -> Int {
        TranscriptWindow.displayCost(session.messages[index])
    }

    private func scrollToPagingTarget(anchor: Int, using proxy: ScrollViewProxy?) {
        guard session.messages.indices.contains(anchor) else { return }
        let targetID = session.messages[anchor].id
        readerAnchorID = targetID
        visibleMessageID = targetID
        if let proxy {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(targetID, anchor: .top)
            }
        }
    }

    private func loadEarlierMessages(using proxy: ScrollViewProxy) {
        guard pagingPhase == .idle, pagingTask == nil, messageRange.lowerBound > 0 else { return }
        pagingPhase = .pagingEarlier
        pagingTask = Task { @MainActor in
            guard !Task.isCancelled, messageRange.lowerBound > 0 else {
                resetPaging()
                return
            }
            if let result = viewport.pageEarlier(count: session.messages.count, cost: displayCost) {
                scrollToPagingTarget(anchor: result.anchor, using: proxy)
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch {}
            resetPaging()
        }
    }

    private func loadLaterMessages(using proxy: ScrollViewProxy) {
        guard pagingPhase == .idle, pagingTask == nil, messageRange.upperBound < session.messages.count else { return }
        pagingPhase = .pagingLater
        pagingTask = Task { @MainActor in
            guard !Task.isCancelled, messageRange.upperBound < session.messages.count else {
                resetPaging()
                return
            }
            if let result = viewport.pageLater(count: session.messages.count, cost: displayCost) {
                scrollToPagingTarget(anchor: result.anchor, using: proxy)
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch {}
            resetPaging()
        }
    }

    private func resetPaging() {
        pagingTask?.cancel()
        pagingTask = nil
        pagingPhase = .idle
    }

    private func updateBottomVisibility(_ visible: Bool, using proxy: ScrollViewProxy) {
        // Visibility is input to the follower, not presentation state. Do not invalidate
        // SwiftUI layout synchronously from its own visibility callback.
        let isAtTrueBottom = visible && messageRange.upperBound == session.messages.count
        reader.isAtBottom = isAtTrueBottom
        if isAtTrueBottom, viewport.readerOwnsViewport, !reader.isScrolling {
            Task { @MainActor in
                await Task.yield()
                if viewport.readerOwnsViewport, !reader.isScrolling {
                    preserveReaderPosition(using: proxy)
                }
            }
            return
        }
        guard viewport.heldRange == nil,
            isAtTrueBottom,
            !reader.isScrolling,
            !viewport.readerOwnsViewport,
            !viewport.autoFollow,
            reader.resumeTask == nil
        else { return }
        reader.resumeTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            reader.resumeTask = nil
            if viewport.heldRange == nil && reader.isAtBottom && !reader.isScrolling {
                viewport.autoFollow = true
            }
        }
    }

    /// Bumps once per visible publication without scanning the accumulated response.
    private var streamRevision: UInt64 {
        session.messages.last?.renderRevision ?? 0
    }

    private func requestFollowScroll(using proxy: ScrollViewProxy) {
        guard pendingFollowScroll == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Never call scrollTo synchronously from a geometry callback: that changes the
        // geometry again in the same frame and can destabilize row placement.
        let delay = max(1.0 / 60, followThrottle.delay(at: now))
        pendingFollowScroll = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(Int((delay * 1_000).rounded(.up))))
            } catch {
                return
            }
            guard viewport.autoFollow, !reader.isScrolling, !Task.isCancelled else {
                pendingFollowScroll = nil
                return
            }
            let firedAt = ProcessInfo.processInfo.systemUptime
            followThrottle.recordFire(at: firedAt)
            scrollToBottom(using: proxy)
            pendingFollowScroll = nil
        }
    }

    private func handleNativeScroll(_ scroll: NSScrollView) {
        guard let document = scroll.documentView, document.bounds.height > 0 else { return }
        let distFromBottom = document.bounds.maxY - scroll.contentView.bounds.maxY
        let atBottom = distFromBottom <= 50 && messageRange.upperBound == session.messages.count
        reader.isAtBottom = atBottom
        if viewport.isScrolledToBottom != atBottom {
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewport.isScrolledToBottom = atBottom
                }
            }
        }
    }

    private func snapToBottom(using proxy: ScrollViewProxy) {
        cancelPendingPreserveScroll()
        cancelPendingFollowScroll()
        resetPaging()
        followThrottle.reset()
        reader.isScrolling = false
        readerAnchorID = nil
        visibleMessageID = nil
        reader.isAtBottom = true
        withAnimation(.easeInOut(duration: 0.2)) {
            viewport.snapToBottom()
        }

        func applyDirectBottomScroll() {
            if let scroll = reader.enclosingScrollView, let document = scroll.documentView {
                let targetY = max(0, document.bounds.maxY - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: targetY))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        applyDirectBottomScroll()
        scrollToBottom(using: proxy)

        pendingFollowScroll = Task { @MainActor in
            // Clearing the held page changes the document on the next layout pass.
            // Follow its measured bottom until the height settles; do not finish by
            // scrolling back to a sentinel measured before that layout.
            var previousHeight: CGFloat?
            var stableSamples = 0
            for _ in 0..<60 {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard viewport.autoFollow, !reader.isScrolling, !Task.isCancelled else { break }
                guard let scroll = reader.enclosingScrollView, let document = scroll.documentView else { continue }
                scroll.layoutSubtreeIfNeeded()
                applyDirectBottomScroll()
                let height = document.bounds.height
                let distance = abs(document.bounds.maxY - scroll.contentView.bounds.maxY)
                stableSamples = previousHeight == height && distance <= 1 ? stableSamples + 1 : 0
                previousHeight = height
                if stableSamples >= 6 { break }
            }
            pendingFollowScroll = nil
        }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        RenderSignposts.event("TranscriptFollow")
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    private func preserveReaderPosition(using proxy: ScrollViewProxy) {
        guard pendingPreserveScroll == nil, let readerAnchorID else { return }
        pendingPreserveScroll = Task { @MainActor in
            // The message mutation and its native scroll layout commit on different passes on
            // macOS 26. Restore after that pass instead of issuing a scroll against stale geometry.
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard viewport.readerOwnsViewport, !viewport.autoFollow, !reader.isScrolling, !Task.isCancelled else {
                pendingPreserveScroll = nil
                return
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(readerAnchorID, anchor: .top)
            }
            pendingPreserveScroll = nil
        }
    }

    private func cancelPendingFollowScroll() {
        pendingFollowScroll?.cancel()
        pendingFollowScroll = nil
    }

    private func cancelPendingPreserveScroll() {
        pendingPreserveScroll?.cancel()
        pendingPreserveScroll = nil
    }

}

/// Mutable scroll observations are deliberately not observable view state.
@MainActor private final class TranscriptReaderState {
    var isAtBottom = true
    var isScrolling = false
    var resumeTask: Task<Void, Never>?
    weak var enclosingScrollView: NSScrollView?
}

private struct TranscriptScrollViewObserver: NSViewRepresentable {
    let onScrollChanged: (NSScrollView) -> Void
    let onResolve: (NSScrollView) -> Void

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        .zero
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScrollChanged: onScrollChanged, onResolve: onResolve)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.targetView = view
        DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator, let scroll = view.enclosingScrollView else { return }
            coordinator.attach(to: scroll)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.targetView = nsView
        context.coordinator.onScrollChanged = onScrollChanged
        context.coordinator.onResolve = onResolve
        if context.coordinator.observedScrollView == nil {
            DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
                guard let nsView, let coordinator, let scroll = nsView.enclosingScrollView else { return }
                coordinator.attach(to: scroll)
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor final class Coordinator: NSObject {
        var onScrollChanged: (NSScrollView) -> Void
        var onResolve: (NSScrollView) -> Void
        weak var targetView: NSView?
        weak var observedScrollView: NSScrollView?
        private var observerToken: NSObjectProtocol?

        init(onScrollChanged: @escaping (NSScrollView) -> Void, onResolve: @escaping (NSScrollView) -> Void) {
            self.onScrollChanged = onScrollChanged
            self.onResolve = onResolve
        }

        func attach(to scroll: NSScrollView) {
            guard observedScrollView !== scroll else { return }
            detach()
            observedScrollView = scroll
            onResolve(scroll)
            scroll.contentView.postsBoundsChangedNotifications = true
            observerToken = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak self, weak scroll] _ in
                guard let self, let scroll else { return }
                self.onScrollChanged(scroll)
            }
        }

        func detach() {
            if let observerToken {
                NotificationCenter.default.removeObserver(observerToken)
                self.observerToken = nil
            }
            observedScrollView = nil
        }

    }
}
