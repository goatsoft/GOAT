import Bleet
import Inference
import SwiftUI

/// Where the pasture stands: context used by a session vs the model's window (when the
/// server reports one). `~` marks estimates; exact numbers come from `usage` (ADR-0016).
@MainActor
struct ContextStatus {
    let used: Int
    let usageKnown: Bool
    let window: Int?
    let pressureLimit: Int?
    let exact: Bool
    let windowExact: Bool
    let trimmed: Bool

    init?(session: ChatSession, models: [ModelRef], defaultModelID: String?) {
        let active = session.isStreaming ? session.messages.last(where: { $0.role == .assistant && !$0.complete }) : nil
        let generated = active?.liveMetrics.estimatedTokens ?? 0
        let savedStats = session.messages.last(where: { $0.role == .assistant })?.stats
        let savedUsage: Int? = savedStats.flatMap { stats in
            guard let prompt = stats.promptTokens, prompt >= 0, stats.tokens >= 0 else { return nil }
            let sum = prompt.addingReportingOverflow(stats.tokens)
            return sum.overflow ? nil : sum.partialValue
        }
        let baseUsage = session.lastContextTokens ?? savedUsage
        self.usageKnown = baseUsage != nil || session.messages.isEmpty
        let total = max(0, baseUsage ?? 0).addingReportingOverflow(max(0, generated))
        self.used = total.overflow ? Int.max : total.partialValue
        let id = session.modelID ?? defaultModelID
        self.window =
            session.lastContextWindow
            ?? id.flatMap { mid in models.first(where: { $0.id == mid })?.contextLength }
        self.pressureLimit = session.lastContextPressureLimit ?? window
        self.exact =
            (session.lastContextTokens != nil ? session.contextIsExact : savedStats?.tokensAreExact == true)
            && generated == 0
        self.windowExact = session.lastContextWindow == nil || session.contextWindowIsExact
        self.trimmed = session.lastPromptWasTrimmed
    }

    var ratio: Double? {
        guard usageKnown, let pressureLimit, pressureLimit > 0 else { return nil }
        return min(1, max(0, Double(used) / Double(pressureLimit)))
    }

    /// Show the meter once there's something worth watching: 60% of a known window,
    /// or 8k tokens of an unknown one.
    var worthShowing: Bool {
        if trimmed { return true }
        if let ratio { return ratio >= 0.6 }
        return used >= 8192
    }

    var label: String {
        let usedApprox = exact ? "" : "~"
        let usage = usageKnown ? "\(usedApprox)\(Self.compact(used))" : "?"
        if let limit = pressureLimit ?? window {
            let limitApprox = windowExact ? "" : "~"
            let qualifier = pressureLimit != nil && pressureLimit != window ? " input" : ""
            return "\(usage) / \(limitApprox)\(Self.compact(limit))\(qualifier)"
        }
        return "\(usage) ctx"
    }

    var color: Color {
        guard let ratio else { return .secondary }
        if ratio > 0.9 { return .red }
        if ratio > 0.75 { return .orange }
        return .secondary
    }

    static func compact(_ n: Int) -> String {
        n < 1000 ? "\(n)" : String(format: "%.1fk", Double(n) / 1000)
    }
}

/// A thin themed capsule showing how much of the pasture is grazed. Pass `width: nil`
/// to fill the available space (the fill tracks the measured width).
struct ContextBar: View {
    let ratio: Double
    let color: Color
    var width: CGFloat? = 56

    @Environment(AppModel.self) private var model
    private var fillColor: Color { color == .secondary ? model.theme.tokens.tint : color }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(model.theme.tokens.muted.opacity(0.18))
                Capsule().fill(
                    LinearGradient(
                        colors: [fillColor, model.theme.tokens.accent], startPoint: .leading, endPoint: .trailing)
                )
                .frame(width: geo.size.width * min(1, max(0, ratio)))
            }
        }
        .frame(width: width, height: 5)
    }
}

/// The in-chat indicator: a grazing goatie + gauge that appears as context grows.
struct PastureMeterChip: View {
    @Bindable var session: ChatSession
    @Environment(AppModel.self) private var model

    var body: some View {
        if let status = ContextStatus(
            session: session, models: model.models,
            defaultModelID: model.defaultModelID),
            status.worthShowing
        {
            HStack(spacing: 6) {
                if model.presentation.isEnabled { GoatieView(pose: .graze, size: 18) }
                if let ratio = status.ratio {
                    ContextBar(ratio: ratio, color: status.color)
                }
                Text(status.label)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(status.color)
            }
            .help(
                "Context this chat is using\(status.exact && status.windowExact ? "" : " (estimated)"). \(status.trimmed ? "Some prompt context was trimmed to fit. " : "")A fuller bar means older turns are close to falling off."
            )
            .transition(.opacity)
        }
    }
}
