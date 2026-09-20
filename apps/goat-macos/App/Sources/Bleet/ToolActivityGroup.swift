import Bleet
import Caprine
import Persistence
import SwiftUI

/// Tool payloads alone are disclosed. Assistant prose and reasoning remain in MessageView.
struct ToolActivityGroup: View {
    let messages: [ChatMessage]
    let activeAssistantID: UUID?
    let projectID: UUID?
    var connectsAbove = false
    var connectsBelow = false
    @Environment(AppModel.self) private var model
    @Environment(\.transcriptInspection) private var inspection
    @State private var memoryExpanded = false

    var body: some View {
        let summary = TranscriptActivity.summary(messages, activeAssistantID: activeAssistantID)
        let events = messages.flatMap(\.toolEvents)
        let groupsMemory = events.count > 1 && events.allSatisfy { $0.server == "Memory" }
        VStack(alignment: .leading, spacing: 0) {
            if groupsMemory {
                Button {
                    inspection.perform()
                    memoryExpanded.toggle()
                } label: {
                    HStack(spacing: Caprine.Activity.spacing) {
                        Image(systemName: memoryExpanded ? "chevron.down" : "chevron.right")
                        Label("Memory · \(events.count) actions", systemImage: "brain.head.profile")
                        if summary.current != nil { GoatLoadingIndicator().controlSize(.mini) }
                        if !summary.issues.isEmpty {
                            Text(summary.issues).foregroundStyle(model.theme.tokens.muted)
                        }
                    }
                    .font(Caprine.Activity.font)
                    .padding(.vertical, Caprine.Activity.rowPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(memoryExpanded ? "Expanded" : "Collapsed")
            }
            if !groupsMemory || memoryExpanded {
                actions(events: events, currentID: summary.current?.id, isolatedGroup: groupsMemory)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actions(events: [ToolEventSnapshot], currentID: String?, isolatedGroup: Bool) -> some View {
        let hasTree = events.count > 1 || (!isolatedGroup && (connectsAbove || connectsBelow))
        return
            VStack(alignment: .leading, spacing: 0) {
                ForEach(messages) { message in
                    ForEach(message.toolEvents) { event in
                        ToolCallCard(event: event, live: event.id == currentID)
                            .padding(.leading, hasTree ? Caprine.Activity.treeInset : 0)
                            .background(alignment: .leading) {
                                if hasTree {
                                    ToolTreeBranch(
                                        above: (!isolatedGroup && connectsAbove) || event.id != events.first?.id,
                                        below: (!isolatedGroup && connectsBelow) || event.id != events.last?.id
                                    )
                                    .frame(width: Caprine.Activity.treeInset)
                                }
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A decorative connector only; it does not imply that adjacent calls executed concurrently.
private struct ToolTreeBranch: View {
    @Environment(AppModel.self) private var model
    let above: Bool
    let below: Bool

    var body: some View {
        Canvas { context, size in
            let x = Caprine.Activity.ruleWidth
            let y = min(Caprine.Activity.branchHeight, size.height / 2)
            var path = Path()
            path.move(to: CGPoint(x: x, y: above ? 0 : y))
            path.addLine(to: CGPoint(x: x, y: below ? size.height : y))
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: size.width - Caprine.Activity.ruleWidth, y: y))
            context.stroke(path, with: .foreground, lineWidth: Caprine.Activity.ruleWidth / 2)
        }
        .foregroundStyle(model.theme.tokens.muted.opacity(Caprine.Activity.cardBorderOpacity))
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
