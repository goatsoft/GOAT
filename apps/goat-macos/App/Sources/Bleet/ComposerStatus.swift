import Bleet
import Foundation
import SwiftUI

/// Empty chats do not mount telemetry. Fade it in once a first message exists,
/// including when the Pen composer hands off to a newly created chat view.
struct ChatMetricsReveal<Content: View>: View {
    let hasStarted: Bool
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    var body: some View {
        if hasStarted {
            content()
                .opacity(visible ? 1 : 0)
                .onAppear {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                        visible = true
                    }
                }
                .onDisappear { visible = false }
        }
    }
}

struct ComposerStatus: View {
    @Bindable var session: ChatSession
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ChatMetricsReveal(hasStarted: !session.messages.isEmpty) {
            metrics
        }
    }

    private var metrics: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !session.isStreaming || scenePhase != .active)) {
            timeline in
            HStack(spacing: 10) {
                Text(throughput(at: timeline.date))
                    .foregroundStyle(model.theme.tokens.muted)
                    .help(
                        "Live speed is estimated from streamed text, reasoning and tool arguments. Final speed uses engine statistics when available."
                    )
                if let status = ContextStatus(
                    session: session, models: model.models, defaultModelID: model.defaultModelID)
                {
                    Text(status.label)
                        .foregroundStyle(status.color == .secondary ? model.theme.tokens.muted : status.color)
                    ContextBar(ratio: status.ratio ?? 0, color: status.color, width: 128)
                        .help(
                            !status.usageKnown
                                ? "Context usage is unavailable for this saved chat until its next response."
                                : status.window == nil
                                    ? "The engine has not reported a context window."
                                    : "Context usage. ~ indicates an estimate.")
                }
            }
            .font(.caption)
            .monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func throughput(at date: Date) -> String {
        GenerationDisplayState(session: session).throughput(at: date)
    }
}
