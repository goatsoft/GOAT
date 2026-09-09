import Caprine
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        ZStack {
            // Fill the whole window, including under the (transparent) toolbar/titlebar strip, so
            // the top edge is themed rather than a black band in fullscreen.
            CaprineBackground(model.theme.tokens, transparency: model.windowTransparency)
                .ignoresSafeArea()
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView()
                    // Custom sidebar toggle: plain (no macOS glass square on hover/press) and a fixed
                    // frame so it matches the inspector toggle exactly. Replaces the system toggle.
                    .toolbar(removing: .sidebarToggle)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                                }
                            } label: {
                                ChromeToggleIcon(systemImage: "sidebar.leading")
                            }
                            .buttonStyle(.plain)
                            .help("Toggle sidebar")
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
            } detail: {
                if !model.startupPhase.hasLocalState {
                    StartupPastureView()
                } else if model.showingPensHome {
                    PensHomeView()
                } else if let pen = model.selectedPen {
                    PenLandingView(pen: pen)
                } else if let session = model.currentSession {
                    ChatView(session: session)
                } else {
                    EmptyPastureView()
                }
            }
        }
        .tint(model.theme.tokens.tint)
        .goatPresentation()
        .fontDesign(model.theme.isMono ? .monospaced : nil)
        // Transparent toolbar: the themed CaprineBackground (in the ZStack) shows straight through,
        // no bar anywhere.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .background(WindowConfigurator(fullscreenBackdrop: model.theme.tokens.bg))
        .sheet(isPresented: $model.showNewPenSheet) {
            PenSheet(pen: nil)
        }
        .sheet(item: $model.editingPen) { pen in
            PenSheet(pen: pen)
        }
        .task {
            await model.start()
        }
        .task(id: model.engineRecoveryTrigger) {
            model.updateEngineRecovery(isActive: scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            model.updateEngineRecovery(isActive: phase == .active)
        }
    }
}

struct StartupPastureView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            switch model.startupPhase {
            case .failed:
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 42))
                    .foregroundStyle(.orange)
                Text("GOAT could not restore local state")
                    .font(.title3.weight(.semibold))
                Text(model.startupPhase.statusText)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                Button("Retry") { Task { await model.retryStartup() } }
                    .buttonStyle(.borderedProminent)
            default:
                GoatLoadingIndicator()
                    .controlSize(.large)
                Text(model.startupPhase.statusText)
                    .font(.headline)
                Text("Your local data stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Fixed circular chrome, independent of macOS toolbar group backgrounds.
struct ChromeToggleIcon: View {
    let systemImage: String
    @Environment(AppModel.self) private var model
    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: InterfaceMetrics.controlIcon))
            .frame(width: InterfaceMetrics.controlHitArea, height: InterfaceMetrics.controlHitArea)
            .foregroundStyle(model.theme.tokens.muted)
            .background(model.theme.tokens.surface.opacity(0.65), in: Circle())
            .overlay(Circle().strokeBorder(model.theme.tokens.muted.opacity(0.18), lineWidth: 0.5))
            .contentShape(Circle())
            .fixedSize()
    }
}

struct EmptyPastureView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            GoatieView(pose: .shrug, size: 140)
            VStack(spacing: 6) {
                Text(model.presentation.isEnabled ? "The pasture is empty" : "Start a conversation")
                    .font(.title3.weight(.semibold))
                Text(
                    model.presentation.isEnabled
                        ? "⌘N to raise your first goat." : "Create a chat to work with your local AI models."
                )
                .foregroundStyle(.secondary)
            }
            Button("New Chat") { Task { await model.newChat() } }
                .buttonStyle(.borderedProminent)
                .disabled(!model.startupPhase.hasLocalState)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
