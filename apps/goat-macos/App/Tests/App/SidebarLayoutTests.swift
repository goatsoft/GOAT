import AppKit
import Bleet
import Caprine
import Inference
import Pens
import SwiftUI
import Testing

@testable import GOAT

@MainActor private func findSidebarSplit(_ view: NSView) -> NSSplitView? {
    if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count >= 2 { return split }
    return view.subviews.lazy.compactMap(findSidebarSplit).first
}

extension AppTests.App {
    @Suite struct SidebarLayoutTests {

        @Test @MainActor func sidebarDividerStaysWithinItsWidthLimits() async throws {
            let model = AppModel.shared
            let previousPhase = model.startupPhase
            let previousShowInspector = model.showInspector
            let previousArtifact = model.paddockArtifact
            let previousChatID = model.selectedChatID
            let previousPenID = model.selectedPenID
            let previousShowingPensHome = model.showingPensHome
            model.startupPhase = .ready
            model.showInspector = false
            model.paddockArtifact = nil
            model.selectedChatID = nil
            model.selectedPenID = nil
            model.showingPensHome = false
            defer {
                model.startupPhase = previousPhase
                model.showInspector = previousShowInspector
                model.paddockArtifact = previousArtifact
                model.selectedChatID = previousChatID
                model.selectedPenID = previousPenID
                model.showingPensHome = previousShowingPensHome
            }
            let controller = NSHostingController(
                rootView: ContentView().environment(model).frame(minWidth: 880, minHeight: 560))
            let window = NSWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 1180, height: 780))
            window.orderFront(nil)
            defer {
                window.contentViewController = nil
                window.close()
            }
            try await Task.sleep(for: .milliseconds(300))
            let split = try #require(findSidebarSplit(controller.view))
            let sidebar = try #require(split.arrangedSubviews.first)
            let nativeController = try #require(split.delegate as? NSSplitViewController)
            let item = try #require(nativeController.splitViewItems.first)
            #expect(item.minimumThickness == 200)
            #expect(item.maximumThickness == 600)
            for windowWidth in [1180.0, 880, 1500, 1180] {
                window.setContentSize(NSSize(width: windowWidth, height: 780))
                for width in [200.0, 300, 400, 500, 600, 1400, 200, 600, 300] {
                    split.setPosition(width, ofDividerAt: 0)
                    try await Task.sleep(for: .milliseconds(30))
                    controller.view.layoutSubtreeIfNeeded()
                    #expect(sidebar.frame.width >= 200)
                    // The native column includes an eight-point Liquid Glass inset at its drag limit.
                    #expect(sidebar.frame.width <= 608)
                    // An oversized split view used to center itself outside the window, hiding labels.
                    #expect(sidebar.convert(sidebar.bounds, to: nil).minX >= 0)
                }
            }
            item.isCollapsed = true
            try await Task.sleep(for: .milliseconds(100))
            #expect(item.isCollapsed)
            item.isCollapsed = false
            try await Task.sleep(for: .milliseconds(100))
            split.setPosition(1400, ofDividerAt: 0)
            try await Task.sleep(for: .milliseconds(30))
            #expect(!item.isCollapsed)
            #expect(sidebar.frame.width <= 608)
            #expect(sidebar.convert(sidebar.bounds, to: nil).minX >= 0)
        }

        @Test @MainActor func sidebarDividerResizingWithActiveChatDoesNotTriggerLayoutRecursion() async throws {
            let model = AppModel.shared
            let previousPhase = model.startupPhase
            let previousChatID = model.selectedChatID
            let previousChats = model.chats
            let previousShowInspector = model.showInspector
            let previousArtifact = model.paddockArtifact
            let previousPenID = model.selectedPenID
            let previousShowingPensHome = model.showingPensHome

            model.startupPhase = .ready
            model.showInspector = false
            model.paddockArtifact = nil
            model.selectedPenID = nil
            model.showingPensHome = false

            let session = ChatSession(effort: .trot, modelID: nil)
            session.title = "Layout Test Chat"
            session.messagesLoaded = true
            model.chats = [session]
            model.selectedChatID = session.id

            defer {
                model.startupPhase = previousPhase
                model.chats = previousChats
                model.selectedChatID = previousChatID
                model.showInspector = previousShowInspector
                model.paddockArtifact = previousArtifact
                model.selectedPenID = previousPenID
                model.showingPensHome = previousShowingPensHome
            }

            let controller = NSHostingController(
                rootView: ContentView().environment(model).frame(minWidth: 880, minHeight: 560))
            let window = NSWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 1180, height: 780))
            window.orderFront(nil)
            defer {
                window.contentViewController = nil
                window.close()
            }
            try await Task.sleep(for: .milliseconds(300))
            let split = try #require(findSidebarSplit(controller.view))
            for width in [200.0, 250, 300, 350, 400, 450, 500, 550, 600, 200, 600, 300] {
                split.setPosition(width, ofDividerAt: 0)
                try await Task.sleep(for: .milliseconds(16))
                controller.view.layoutSubtreeIfNeeded()
            }
            #expect(model.currentSession?.id == session.id)
        }
    }
}
