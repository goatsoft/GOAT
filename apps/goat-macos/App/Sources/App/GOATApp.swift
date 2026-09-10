import AppKit
import SwiftUI

struct GOATApp: App {
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model).judasLinks()
                .frame(minWidth: 880, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About GOAT") { showAbout() }
            }
            CommandGroup(replacing: .newItem) {
                Button("New chat") { Task { await AppModel.shared.beginNewChat() } }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!AppModel.shared.startupPhase.hasLocalState)
                Button("New Pen…") { AppModel.shared.showNewPenSheet = true }
                    .keyboardShortcut("n", modifiers: [.shift, .command])
                    .disabled(!AppModel.shared.startupPhase.hasLocalState)
            }
            CommandMenu("Chat") {
                Button("New chat", systemImage: "square.and.pencil") {
                    Task { await AppModel.shared.beginNewChat() }
                }
                .disabled(!AppModel.shared.startupPhase.hasLocalState)
                Divider()
                Menu("Model") { ModelMenuItems() }
                    .disabled(
                        AppModel.shared.currentSession == nil
                            || !AppModel.shared.startupPhase.hasLocalState)
                Menu("Effort") { EffortMenuItems() }
                    .disabled(
                        AppModel.shared.currentSession == nil
                            || !AppModel.shared.startupPhase.hasLocalState)
                Divider()
                Button("Stop Generating") { AppModel.shared.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                Button("Regenerate") { Task { await AppModel.shared.regenerate() } }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button(AppModel.shared.showActivityLog ? "Hide Log" : "Show Log") {
                    AppModel.shared.showActivityLog.toggle()
                }
                .keyboardShortcut("`", modifiers: .control)
            }
        }

        Settings {
            SettingsView()
                .environment(model).judasLinks()
        }
    }

    @MainActor private func showAbout() {
        // Reuse a single About window instead of stacking new ones.
        if let existing = Self.aboutWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: AboutView().environment(model).judasLinks())
        let window = NSWindow(contentViewController: hosting)
        window.title = "About GOAT"
        window.styleMask = [.titled, .closable, .fullSizeContentView]  // no resize/zoom, no minimize
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true  // drag from anywhere
        window.level = .floating  // always on top
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.setContentSize(NSSize(width: 500, height: 620))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Self.aboutWindow = window
    }

    @MainActor private static var aboutWindow: NSWindow?
}
