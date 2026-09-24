import Bleet
import Caprine
import Inference
import SwiftUI

struct InspectorView: View {
    @Bindable var session: ChatSession
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ChatMetricsReveal(hasStarted: !session.messages.isEmpty) {
                    NerdStatsView(session: session)
                }
                inspectorSection("Model") {
                    LabeledContent("Model") {
                        VStack(alignment: .leading, spacing: Caprine.ModelMenu.rowDetailSpacing) {
                            Text(modelName)
                            if let worker = model.selectedSubagentModelID {
                                SubagentModelLabel(modelID: worker)
                            }
                        }
                    }
                    LabeledContent("Effort") {
                        HStack(spacing: 6) {
                            if model.presentation.isEnabled { GoatieView(pose: session.effort.goatie, size: 18) }
                            Text(session.effort.label).foregroundStyle(
                                session.effort.presentationColor(in: model.theme))
                        }
                    }
                    Divider()
                    SubagentModelMenu(model: model, parentModelID: model.resolvedModelID(for: session))
                    if model.selectedSubagentModelID != nil {
                        DisclosureGroup("Subagent budget") {
                            SubagentBudgetControls(model: model)
                        }
                    }
                    LabeledContent("Messages", value: "\(session.messages.count)")

                }
                inspectorSection("Engine") {
                    EngineStatusSummary()
                }
                inspectorSection("MCP") {
                    if connectedMCPServers.isEmpty {
                        Text("No servers connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(connectedMCPServers, id: \.name) { server in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(model.theme.tokens.tint)
                                    .frame(width: 6, height: 6)
                                Text(server.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(server.name)
                                Spacer(minLength: 8)
                                Text("\(server.toolCount) \(server.toolCount == 1 ? "tool" : "tools")")
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .contentMargins(.top, 0, for: .scrollContent)
    }

    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(model.theme.tokens.muted)
            VStack(alignment: .leading, spacing: 10, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(model.theme.tokens.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var connectedMCPServers: [(name: String, toolCount: Int)] {
        model.mcp.states.keys.sorted().compactMap { name in
            guard let state = model.mcp.states[name], state.status == .connected else { return nil }
            let count = state.tools.filter { !MCPModel.isOwnerAdministrationTool($0.name) }.count
            return (name: name, toolCount: count)
        }
    }

    private var modelName: String {
        model.resolvedModelID(for: session).map { ModelRef(id: $0).displayName } ?? "-"
    }

}
