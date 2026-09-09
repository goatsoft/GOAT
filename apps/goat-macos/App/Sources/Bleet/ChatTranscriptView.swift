import Bleet
import Hoofprint
import SwiftUI

/// Its owner keys this view by chat ID. A new chat gets fresh native scroll geometry,
/// measured row layout and follow tasks instead of inheriting another transcript's viewport.
struct ChatTranscriptView: View {
    @Bindable var session: ChatSession
    @Environment(AppModel.self) private var model
    @State private var windowEnd: Int?
    @State private var autoFollow = true
    @State private var reader = TranscriptReaderState()
    @State private var visibleMessageID: UUID?
    @State private var followThrottle = TranscriptFollowThrottle()
    @State private var pendingFollowScroll: Task<Void, Never>?

    private static let bottomAnchor = UUID()

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
                    VStack(alignment: .leading, spacing: 20) {
                        if messageRange.lowerBound > 0 {
                            Button("Earlier messages", systemImage: "chevron.up") {
                                autoFollow = false
                                windowEnd = messageRange.lowerBound + TranscriptWindow.step
                            }
                            .buttonStyle(SecondaryChipButtonStyle())
                        }
                        ForEach(TranscriptActivity.rows(session.messages[messageRange])) { row in
                            // Group identity is the first message, stable as further tool rounds arrive.
                            // Keep projection inside the existing bounded, fully measured window.
                            VStack(alignment: .leading, spacing: 0) {
                                if row.isActivity {
                                    ToolActivityGroup(
                                        messages: row.messages,
                                        activeAssistantID: session.isStreaming
                                            ? session.messages.last(where: { $0.role == .assistant })?.id : nil,
                                        projectID: session.projectID
                                    )
                                } else if let message = row.messages.first {
                                    MessageView(
                                        message: message, isLast: message.id == session.messages.last?.id,
                                        projectID: session.projectID)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .id(row.id)
                        }
                        if messageRange.upperBound < session.messages.count {
                            HStack {
                                Button("Later messages", systemImage: "chevron.down") {
                                    let end = min(
                                        session.messages.count, messageRange.upperBound + TranscriptWindow.step)
                                    windowEnd = end == session.messages.count ? nil : end
                                }
                                Button("Latest", systemImage: "arrow.down.to.line") {
                                    windowEnd = nil
                                    autoFollow = true
                                    snapToBottom(using: proxy)
                                }
                            }
                            .buttonStyle(SecondaryChipButtonStyle())
                        }
                        // End sentinel the follower scrolls to as the transcript grows.
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchor)
                            .onScrollVisibilityChange(threshold: 0.1, updateBottomVisibility)

                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollPosition(id: $visibleMessageID)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .alignment)
                .defaultScrollAnchor(autoFollow ? .bottom : .top, for: .sizeChanges)
                // Reader gestures own the viewport until they return to the bottom sentinel.
                .onScrollPhaseChange { _, phase in
                    if phase == .tracking || phase == .interacting || phase == .decelerating {
                        reader.isScrolling = true
                        autoFollow = false
                        cancelPendingFollowScroll()
                    } else if phase == .idle {
                        reader.isScrolling = false
                        autoFollow = windowEnd == nil && reader.isAtBottom
                    }
                }
                // Native size-change anchoring handles font/width/Markdown reflow. Do not
                // feed estimated transcript heights back into programmatic scroll commands.
                // Chase streaming growth (text + thinking + new messages) while following.
                .onChange(of: streamRevision) {
                    guard autoFollow else { return }
                    requestFollowScroll(using: proxy)
                }
                // A newly sent turn always re-arms follow and snaps to the bottom.
                .onChange(of: session.messages.count) {
                    if session.messages.last?.role == .user {
                        windowEnd = nil
                        autoFollow = true
                        snapToBottom(using: proxy)
                    } else if autoFollow {
                        requestFollowScroll(using: proxy)
                    }
                }
                .onDisappear {
                    cancelPendingFollowScroll()
                    reader.resumeTask?.cancel()
                    reader.resumeTask = nil
                }
            }
        }
    }

    private var messageRange: Range<Int> {
        TranscriptWindow.range(count: session.messages.count, end: windowEnd)
    }

    private func updateBottomVisibility(_ visible: Bool) {
        // Visibility is input to the follower, not presentation state. Do not invalidate
        // SwiftUI layout synchronously from its own visibility callback.
        reader.isAtBottom = visible
        guard windowEnd == nil, visible, !reader.isScrolling, !autoFollow, reader.resumeTask == nil else { return }
        reader.resumeTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            reader.resumeTask = nil
            if windowEnd == nil && reader.isAtBottom && !reader.isScrolling { autoFollow = true }
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

    private func cancelPendingFollowScroll() {
        pendingFollowScroll?.cancel()
        pendingFollowScroll = nil
    }

}

/// Mutable scroll observations are deliberately not observable view state.
@MainActor private final class TranscriptReaderState {
    var isAtBottom = true
    var isScrolling = false
    var resumeTask: Task<Void, Never>?
}
