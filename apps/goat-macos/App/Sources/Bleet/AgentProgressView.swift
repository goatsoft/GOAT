import Bleet
import Caprine
import SwiftUI

/// Observed client activity only. Silence cannot distinguish queueing, loading and prefill.
@MainActor struct AgentProgressState {
    let title: String
    let startedAt: Date
    let lastOutputAt: Date?
    let awaitingApproval: Bool
    private let canPause: Bool

    init(session: ChatSession, awaitingApproval: Bool = false) {
        self.awaitingApproval = awaitingApproval
        let user = session.messages.last(where: { $0.role == .user })
        let assistant = session.messages.last(where: { $0.role == .assistant })
        let current = assistant.flatMap { row in
            user.map { row.createdAt >= $0.createdAt } ?? true ? row : nil
        }
        startedAt = current?.createdAt ?? user?.createdAt ?? session.createdAt
        lastOutputAt = current?.liveMetrics.lastOutputAt
        canPause =
            !awaitingApproval && session.activeCompactionID == nil
            && current?.complete == false && current?.generationStatus == nil
            && current?.toolEvents.contains(where: { $0.result == nil && !$0.isError && !$0.denied }) != true
        if awaitingApproval {
            title = "Waiting for your permission"
        } else if session.activeCompactionID != nil {
            title = "Compacting context"
        } else if let current,
            let tool = current.toolEvents.first(where: { $0.result == nil && !$0.isError && !$0.denied })
        {
            title = ToolActivityLabel.progressTitle(tool)
        } else if let current, !current.complete {
            if let status = current.generationStatus {
                title = status
                return
            }
            switch current.lastStreamActivity {
            case .reasoning: title = "Thinking"
            case .answer: title = "Writing response"
            case .toolArguments: title = "Preparing tool call"
            case nil: title = "Waiting for response"
            }
        } else {
            title = "Preparing next step"
        }
    }

    func displayTitle(at date: Date) -> String {
        if canPause, let lastOutputAt, date.timeIntervalSince(lastOutputAt) >= 5 {
            return "Waiting for more output"
        }
        return title
    }
}

struct AgentProgressView: View {
    let session: ChatSession
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = AgentProgressState(session: session, awaitingApproval: model.mcp.pendingPermission != nil)
        TimelineView(.periodic(from: state.startedAt, by: 1)) { context in
            HStack(spacing: Caprine.Activity.spacing) {
                if state.awaitingApproval {
                    Image(systemName: "hand.raised")
                } else {
                    GoatLoadingIndicator().controlSize(.mini)
                }
                Text(state.displayTitle(at: context.date)).lineLimit(2)
                Text(AssistantStatusRow<EmptyView>.elapsedLabel(context.date.timeIntervalSince(state.startedAt)))
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            .font(Caprine.Activity.font)
            .foregroundStyle(model.theme.tokens.muted)
            .accessibilityElement(children: .combine)
        }
        .padding(.leading, (model.presentation.isEnabled ? 60 : 28) + 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
