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
                inspectorSection("Engine") {
                    EngineStatusSummary()
                    if model.enginePreset.metadataDialect == .omlx {
                        InspectorEngineRuntimeDetails(session: session)
                    }
                }
                inspectorSection("Model") {
                    Text(modelName)
                    LabeledContent("Effort") {
                        HStack(spacing: 6) {
                            if model.presentation.isEnabled { GoatieView(pose: session.effort.goatie, size: 18) }
                            Text(session.effort.label).foregroundStyle(
                                session.effort.presentationColor(in: model.theme))
                        }
                    }
                    if let ref = model.models.first(where: { $0.id == model.resolvedModelID(for: session) }) {
                        VStack(alignment: .leading, spacing: Caprine.Activity.compactSpacing) {
                            capabilityRow("Tools", claim: ref.capabilities.tools)
                            capabilityRow("Vision", claim: ref.capabilities.vision)
                            capabilityRow("Reasoning", claim: ref.capabilities.reasoning)
                        }
                        .font(Caprine.Activity.font)
                    }
                }
                inspectorSection("Subagent") {
                    SubagentModelMenu(
                        model: model, parentModelID: model.resolvedModelID(for: session), showsSelection: true
                    )
                    .caprineSecondaryMenu(color: model.theme.tokens.muted)
                    if model.selectedSubagentModelID != nil {
                        DisclosureGroup("Options") {
                            SubagentBudgetControls(model: model)
                                .padding(.top, Caprine.Activity.spacing)
                        }
                    }
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

    private func capabilityRow(_ title: String, claim: CapabilityClaim) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(
                claim.isConflict
                    ? "Conflicting reports"
                    : claim.support == .supported
                        ? "Supported" : claim.support == .unsupported ? "Unsupported" : "Unknown")
        }
        .foregroundStyle(model.theme.tokens.muted)
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
