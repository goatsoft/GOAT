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
        if !initiallyFollowing {
            let start = initialVisibleMessageID.flatMap { id in
                session.messages.firstIndex(where: { $0.id == id })
            }
            // The visible anchor starts the reader's window. Ending the window at that
            // message leaves no content below it, so native restoration clamps to the bottom.
            _heldRange = State(
                initialValue: start.map { start in
                    TranscriptWindow.range(count: session.messages.count, startingAt: start) {
                        TranscriptWindow.displayCost(session.messages[$0])
                    }
                }
                    ?? TranscriptWindow.range(count: session.messages.count, end: nil) {
                        TranscriptWindow.displayCost(session.messages[$0])
                    })
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
                            Button("Earlier messages", systemImage: "chevron.up") {
                                let previous = TranscriptWindow.earlier(
                                    messageRange, count: session.messages.count, cost: displayCost)
                                let anchor =
                                    previous.contains(messageRange.lowerBound)
                                    ? messageRange.lowerBound : previous.upperBound - 1
                                page(to: previous, anchor: anchor)
                            }
                            .buttonStyle(SecondaryChipButtonStyle())
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
                                Button("Later messages", systemImage: "chevron.down") {
                                    let next = TranscriptWindow.later(
                                        messageRange, count: session.messages.count, cost: displayCost)
                                    let anchor =
                                        next.contains(messageRange.upperBound - 1)
                                        ? messageRange.upperBound - 1 : next.lowerBound
                                    page(to: next, anchor: anchor)
                                }
                                Button("Latest", systemImage: "arrow.down.to.line") {
                                    heldRange = nil
                                    autoFollow = true
                                    readerOwnsViewport = false
                                    snapToBottom(using: proxy)
                                }
                            }
                            .buttonStyle(SecondaryChipButtonStyle())
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
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                        heldRange = nil
                        autoFollow = true
                        readerOwnsViewport = false
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
                    reader.resumeTask?.cancel()
                    reader.resumeTask = nil
                }
            }
        }
    }

    private var messageRange: Range<Int> {
        if let heldRange {
            return TranscriptWindow.clamped(heldRange, count: session.messages.count, cost: displayCost)
        }
        return TranscriptWindow.range(count: session.messages.count, end: nil, cost: displayCost)
    }

    private func displayCost(_ index: Int) -> Int {
        TranscriptWindow.displayCost(session.messages[index])
    }

    private func page(to range: Range<Int>, anchor: Int) {
        claimViewport()
        heldRange = range
        guard session.messages.indices.contains(anchor) else { return }
        readerAnchorID = session.messages[anchor].id
        visibleMessageID = readerAnchorID
    }

    private func claimViewport() {
        if heldRange == nil { heldRange = messageRange }
        autoFollow = false
        readerOwnsViewport = true
    }

    private func updateBottomVisibility(_ visible: Bool, using proxy: ScrollViewProxy) {
        // Visibility is input to the follower, not presentation state. Do not invalidate
        // SwiftUI layout synchronously from its own visibility callback.
        reader.isAtBottom = visible
        if visible, readerOwnsViewport, !reader.isScrolling {
            Task { @MainActor in
                await Task.yield()
                if readerOwnsViewport, !reader.isScrolling {
                    preserveReaderPosition(using: proxy)
                }
            }
            return
        }
        guard heldRange == nil, visible, !reader.isScrolling, !readerOwnsViewport, !autoFollow,
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
        followThrottle.reset()
        requestFollowScroll(using: proxy)
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
