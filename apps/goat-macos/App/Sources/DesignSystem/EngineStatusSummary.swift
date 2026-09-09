import SwiftUI

/// Shared engine identity and connection details for the sidebar and inspector.
struct EngineStatusSummary: View {
    var showSettings = false
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                        .help(connectionLabel)
                        .accessibilityLabel(connectionLabel)
                    Text(model.activeEngineProfile?.name ?? "No engine configured")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.theme.tokens.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.activeEngineProfile?.name ?? "No engine configured")
                    if !model.engineTransitioning, case .ok(let models) = model.health {
                        Text("\(models.count) model\(models.count == 1 ? "" : "s")")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(model.theme.tokens.tint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(model.theme.tokens.tint.opacity(0.10), in: Capsule())
                            .fixedSize()
                    }
                    Spacer(minLength: 0)

                }
                Text(model.activeEngineProfile == nil ? "Add your first connection" : model.endpoint)
                    .font(.system(size: 10))
                    .foregroundStyle(model.theme.tokens.muted.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.leading, 15)
                    .help(model.endpoint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.activeEngineProfile != nil, case .offline = model.health {
                Button {
                    Task { await model.refreshHealth() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(model.engineTransitioning || model.activeTurnSessionID != nil)
                .help("Reconnect to the configured engine")
                .accessibilityLabel("Reconnect engine")
            }
            if showSettings {
                Button {
                    model.settingsTab = .engine
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
                .accessibilityLabel("Open settings")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var connectionLabel: String {
        if model.activeEngineProfile == nil { return "Not configured" }
        if model.engineTransitioning { return "Connecting…" }
        return switch model.health {
        case .ok: "Connected"
        case .authRequired: "API key required"
        case .offline: "Offline"
        }
    }

    private var statusColor: Color {
        if model.engineTransitioning { return model.theme.tokens.tint }
        return switch model.health {
        case .ok: .green
        case .authRequired: .orange
        case .offline: model.theme.tokens.muted
        }
    }
}
