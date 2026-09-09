import Bleet
import Caprine
import SwiftUI

/// Collapsed by default, with one disclosure for the run and existing per-tool inspection inside.
struct ToolActivityGroup: View {
    let messages: [ChatMessage]
    let activeAssistantID: UUID?
    let projectID: UUID?
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        let summary = TranscriptActivity.summary(messages, activeAssistantID: activeAssistantID)
        VStack(alignment: .leading, spacing: Caprine.Activity.spacing) {
            Button {
                expanded.toggle()
            } label: {
                VStack(alignment: .leading, spacing: Caprine.Activity.spacing) {
                    HStack(spacing: Caprine.Activity.spacing) {
                        if summary.current != nil {
                            GoatLoadingIndicator().controlSize(.mini)
                        } else {
                            Image(systemName: "list.bullet")
                        }
                        Text(summary.title)
                        Spacer(minLength: 0)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    }
                    if let current = summary.current {
                        Text(ToolActivityLabel.title(current))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if !summary.issues.isEmpty {
                        Label(summary.issues, systemImage: "exclamationmark.circle")
                    }
                }
                .font(Caprine.Activity.font)
                .foregroundStyle(model.theme.tokens.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .help("Show or hide tool activity. Expand an action to inspect its arguments and result.")
            if expanded {
                ForEach(messages) { message in
                    Divider()
                    MessageView(
                        message: message, isLast: false, projectID: projectID, compactActivity: true,
                        activeToolID: message.id == activeAssistantID ? summary.current?.id : nil
                    )
                }
            } else {
                // Host failures (including interruption and unknown outcomes) must remain visible.
                ForEach(messages.filter { $0.error != nil }) { message in
                    if let error = message.error {
                        Text(error)
                            .font(Caprine.Activity.font)
                            .foregroundStyle(model.theme.tokens.ink)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(.vertical, Caprine.Activity.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
