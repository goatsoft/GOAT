import AppKit
import Testing

@testable import GOAT

@MainActor private final class ScrollReceiver: NSResponder {
    var count = 0
    override func scrollWheel(with event: NSEvent) { count += 1 }
}

@Test @MainActor func nativeMapClicksActivateScrollAndLeavingReturnsScrollToThePage() throws {
    let view = GraphInteractionSurface.Surface(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let page = ScrollReceiver()
    view.nextResponder = page
    var cameraEvents = 0
    var changes: [Bool] = []
    view.onScroll = { _, _, _ in cameraEvents += 1 }
    view.onActiveChange = { changes.append($0) }
    let cg = try #require(
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 20, wheel2: 0, wheel3: 0))
    let scroll = try #require(NSEvent(cgEvent: cg))
    view.scrollWheel(with: scroll)
    #expect(page.count == 1)
    #expect(cameraEvents == 0)
    let click = try #require(
        NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 100, y: 100), modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    view.mouseDown(with: click)
    #expect(view.isActive)
    view.scrollWheel(with: scroll)
    #expect(cameraEvents == 1)
    #expect(page.count == 1)
    view.mouseExited(with: click)
    #expect(!view.isActive)
    view.scrollWheel(with: scroll)
    #expect(page.count == 2)
    #expect(cameraEvents == 1)
    #expect(changes == [true, false])
}

@Test @MainActor func nativeMapReleasesKeyboardFocusAndCanActivateAgain() throws {
    let view = GraphInteractionSurface.Surface()
    let click = try #require(
        NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
    view.mouseDown(with: click)
    #expect(view.isActive)
    _ = view.resignFirstResponder()
    #expect(!view.isActive)
    view.mouseDown(with: click)
    #expect(view.isActive)
    var selected = false
    view.onSelect = { _ in selected = true }
    view.mouseUp(with: click)
    #expect(selected)
}

@Test @MainActor func legendHoverAndClickHelpNeverClaimKeyboardFocus() throws {
    let view = MapLegendHoverSurface.Surface(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
    var changes: [Bool] = []
    view.onHover = { changes.append($0) }
    let event = try #require(
        NSEvent.mouseEvent(
            with: .mouseMoved, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
    view.mouseEntered(with: event)
    view.mouseExited(with: event)
    #expect(changes == [true, false])
    #expect(view.hitTest(NSPoint(x: 10, y: 10)) === view)
    view.mouseDown(with: event)
    #expect(changes == [true, false, true])
    #expect(!view.acceptsFirstResponder)
}
