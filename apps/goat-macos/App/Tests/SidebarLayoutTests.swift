import AppKit
import SwiftUI
import Testing

@testable import GOAT

@Test @MainActor func sidebarDividerStaysWithinItsWidthLimits() async throws {
    let model = AppModel.shared
    let previousPhase = model.startupPhase
    model.startupPhase = .ready
    defer { model.startupPhase = previousPhase }
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

@MainActor private func findSidebarSplit(_ view: NSView) -> NSSplitView? {
    if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count >= 2 { return split }
    return view.subviews.lazy.compactMap(findSidebarSplit).first
}
