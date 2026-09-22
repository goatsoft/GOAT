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

/// Its owner keys this view by chat ID. A new chat gets fresh native scroll geometry,
/// measured row layout and follow tasks instead of inheriting another transcript's viewport.
struct ChatTranscriptView: View {
    @Bindable var session: ChatSession
    @Environment(AppModel.self) private var model
    @State private var heldRange: Range<Int>?
    @State private var autoFollow = true
    @State private var readerOwnsViewport = false
    @State private var reader = TranscriptReaderState()
    @State private var visibleMessageID: UUID?
    @State private var readerAnchorID: UUID?
    @State private var followThrottle = TranscriptFollowThrottle()
    @State private var pendingFollowScroll: Task<Void, Never>?
    @State private var pendingPreserveScroll: Task<Void, Never>?
    @State private var pagingPhase: TranscriptPagingPhase = .idle
    @State private var pagingTask: Task<Void, Never>?
    @State private var isScrolledToBottom: Bool
    @State private var isHoveringScrollButton = false

    private static let bottomAnchor = UUID()

    init(
        session: ChatSession,
        initiallyFollowing: Bool = true,
        initialVisibleMessageID: UUID? = nil
    ) {
        self.session = session
        _autoFollow = State(initialValue: initiallyFollowing)
        _readerOwnsViewport = State(initialValue: !initiallyFollowing)
        _visibleMessageID = State(initialValue: initialVisibleMessageID)
        _readerAnchorID = State(initialValue: initialVisibleMessageID)
        _isScrolledToBottom = State(initialValue: initiallyFollowing)
        if !initiallyFollowing {
            if session.messages.count <= TranscriptWindow.capacity {
                _heldRange = State(initialValue: nil)
            } else {
                let start = initialVisibleMessageID.flatMap { id in
                    session.messages.firstIndex(where: { $0.id == id })
                }
                _heldRange = State(
                    initialValue: start.map { start in
                        let lower = min(session.messages.count, max(0, start))
                        let upper = min(session.messages.count, lower + TranscriptWindow.capacity)
                        return lower..<upper
                    } ?? max(0, session.messages.count - TranscriptWindow.capacity)..<session.messages.count)
            }
        }
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
                    .foregroundStyle(.orange)
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
                        ForEach(TranscriptActivity.rows(session.messages[messageRange])) { row in
                            // Each message retains its identity and ancestry as tool events arrive.
                            // Keep projection inside the existing bounded, fully measured window.
                            VStack(alignment: .leading, spacing: 0) {
                                if let message = row.messages.first {
                                    MessageView(
                                        message: message, isLast: message.id == session.messages.last?.id,
                                        projectID: session.projectID, compactActivity: row.isContinuation,
                                        joinsPreviousTools: row.joinsPreviousTools,
                                        joinsNextTools: row.joinsNextTools,
                                        activeToolID: session.isStreaming
                                            && message.id == session.messages.last(where: { $0.role == .assistant })?.id
                                            ? TranscriptActivity.summary([message], activeAssistantID: message.id)
                                                .current?.id : nil,
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
                            .frame(height: 1)
                            .id(Self.bottomAnchor)
                            .onScrollVisibilityChange(threshold: 0.1) { visible in
                                updateBottomVisibility(visible, using: proxy)
                            }

                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, Caprine.Activity.doubleLineHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .overlay(alignment: .bottom) {
                    if !isScrolledToBottom {
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
                                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                        .help("Scroll to bottom")
                        .padding(.bottom, Caprine.Activity.inset)
                        .onHover { isHoveringScrollButton = $0 }
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                }
                .environment(
                    \.transcriptInspection,
                    TranscriptInspectionAction {
                        claimViewport()
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
                        claimViewport()
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
                            readerOwnsViewport = false
                            heldRange = nil
                            autoFollow = true
                        } else if readerOwnsViewport {
                            autoFollow = false
                        }
                    }
                }
                // Native size-change anchoring handles font/width/Markdown reflow. Do not
                // feed estimated transcript heights back into programmatic scroll commands.
                // Chase streaming growth (text + thinking + new messages) while following.
                .onChange(of: streamRevision) {
                    if autoFollow {
                        requestFollowScroll(using: proxy)
                    } else if readerOwnsViewport {
                        preserveReaderPosition(using: proxy)
                    }
                }
                // A newly sent turn always re-arms follow and snaps to the bottom.
                .onChange(of: session.messages.count) { previousCount, count in
                    if let heldRange, count < previousCount {
                        let anchor = readerAnchorID.flatMap { id in
                            session.messages.firstIndex(where: { $0.id == id })
                        }
                        let surviving = TranscriptWindow.clamped(
                            heldRange, count: count, anchor: anchor, cost: displayCost)
                        self.heldRange = surviving
                        if anchor == nil {
                            self.readerAnchorID = surviving.first.map { session.messages[$0].id }
                            visibleMessageID = self.readerAnchorID
                        }
                    }
                    if session.messages.last?.role == .user {
                        resetPaging()
                        heldRange = nil
                        autoFollow = true
                        readerOwnsViewport = false
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isScrolledToBottom = true
                        }
                        snapToBottom(using: proxy)
                    } else if autoFollow {
                        requestFollowScroll(using: proxy)
                    } else if readerOwnsViewport {
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

    private var messageRange: Range<Int> {
        let count = session.messages.count
        guard count > TranscriptWindow.capacity else {
            return 0..<count
        }
        if let heldRange {
            let upper = min(count, heldRange.upperBound)
            let lower = min(heldRange.lowerBound, upper)
            if lower == upper, upper > 0 {
                return max(0, upper - TranscriptWindow.capacity)..<upper
            }
            return lower..<upper
        }
        return max(0, count - TranscriptWindow.capacity)..<count
    }

    private func displayCost(_ index: Int) -> Int {
        TranscriptWindow.displayCost(session.messages[index])
    }

    private func page(to range: Range<Int>, anchor: Int, scrollTarget: Int? = nil, using proxy: ScrollViewProxy? = nil)
    {
        claimViewport()
        heldRange = range
        guard session.messages.indices.contains(anchor) else { return }
        let targetID =
            scrollTarget.flatMap { session.messages.indices.contains($0) ? session.messages[$0].id : nil }
            ?? session.messages[anchor].id
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
            let previousLower = max(0, messageRange.lowerBound - TranscriptWindow.step)
            let anchor = messageRange.lowerBound
            let newUpper = min(session.messages.count, max(messageRange.upperBound, previousLower + 100))
            let previous = previousLower..<newUpper
            page(to: previous, anchor: anchor, scrollTarget: anchor, using: proxy)
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
            let nextUpper = min(session.messages.count, messageRange.upperBound + TranscriptWindow.step)
            if nextUpper == session.messages.count {
                heldRange = nil
                autoFollow = true
                readerOwnsViewport = false
                snapToBottom(using: proxy)
            } else {
                let anchor = messageRange.upperBound - 1
                let newLower = max(0, min(messageRange.lowerBound, nextUpper - 100))
                let next = newLower..<nextUpper
                page(to: next, anchor: anchor, scrollTarget: anchor, using: proxy)
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

    private func claimViewport() {
        if heldRange == nil { heldRange = messageRange }
        autoFollow = false
        readerOwnsViewport = true
    }

    private func updateBottomVisibility(_ visible: Bool, using proxy: ScrollViewProxy) {
        // Visibility is input to the follower, not presentation state. Do not invalidate
        // SwiftUI layout synchronously from its own visibility callback.
        let isAtTrueBottom = visible && messageRange.upperBound == session.messages.count
        reader.isAtBottom = isAtTrueBottom
        if isScrolledToBottom != isAtTrueBottom {
            withAnimation(.easeInOut(duration: 0.2)) {
                isScrolledToBottom = isAtTrueBottom
            }
        }
        if isAtTrueBottom, readerOwnsViewport, !reader.isScrolling {
            Task { @MainActor in
                await Task.yield()
                if readerOwnsViewport, !reader.isScrolling {
                    preserveReaderPosition(using: proxy)
                }
            }
            return
        }
        guard heldRange == nil, isAtTrueBottom, !reader.isScrolling, !readerOwnsViewport, !autoFollow,
            reader.resumeTask == nil
        else { return }
        reader.resumeTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            reader.resumeTask = nil
            if heldRange == nil && reader.isAtBottom && !reader.isScrolling { autoFollow = true }
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
            guard autoFollow, !reader.isScrolling, !Task.isCancelled else {
                pendingFollowScroll = nil
                return
            }
            let firedAt = ProcessInfo.processInfo.systemUptime
            followThrottle.recordFire(at: firedAt)
            scrollToBottom(using: proxy)
            pendingFollowScroll = nil
        }
    }

    private func snapToBottom(using proxy: ScrollViewProxy) {
        cancelPendingPreserveScroll()
        cancelPendingFollowScroll()
        resetPaging()
        followThrottle.reset()
        reader.isScrolling = false
        readerOwnsViewport = false
        readerAnchorID = nil
        visibleMessageID = nil
        let wasWindowed = heldRange != nil || messageRange.upperBound < session.messages.count
        heldRange = nil
        autoFollow = true
        reader.isAtBottom = false
        isScrolledToBottom = false
        if !wasWindowed {
            scrollToBottom(using: proxy)
        }
        pendingFollowScroll = Task { @MainActor in
            if wasWindowed {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(30))
            }
            scrollToBottom(using: proxy)
            for delay in [50, 100, 200] {
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                guard autoFollow, !Task.isCancelled else { break }
                scrollToBottom(using: proxy)
                if reader.isAtBottom && messageRange.upperBound == session.messages.count { break }
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
            guard readerOwnsViewport, !autoFollow, !reader.isScrolling, !Task.isCancelled else {
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
}
