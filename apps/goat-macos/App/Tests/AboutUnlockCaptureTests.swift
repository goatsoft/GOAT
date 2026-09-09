import AppKit
import SwiftUI
import Testing

@testable import GOAT

// Opt-in native smoke test: requires an interactive desktop and owns keyboard focus.
// Keep normal verification independent of the foreground application.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["GOAT_UI_SMOKE"] == "1"))
func aboutKeyboardCaptureIsRestrictedToItsWindow() async throws {
    var unlocks = 0
    var progress = 0
    let about = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let other = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    about.isReleasedWhenClosed = false
    other.isReleasedWhenClosed = false
    let priorKeyWindow = NSApp.keyWindow
    defer {
        about.contentView = nil
        about.close()
        other.close()
        priorKeyWindow?.makeKeyAndOrderFront(nil)
    }
    about.contentView = NSHostingView(rootView: AboutKeyCapture(progress: { progress = $0 }, unlock: { unlocks += 1 }))
    about.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    for _ in 0..<20 {
        if NSApp.isActive && about.isKeyWindow { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(NSApp.isActive)
    try #require(about.isKeyWindow)

    func send(_ characters: String, to window: NSWindow) async throws {
        for character in characters {
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: String(character),
                    charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: 0))
            NSApp.postEvent(event, atStart: false)
            try await Task.sleep(for: .milliseconds(40))
        }
    }
    try await send("1", to: about)
    #expect(progress == 1)
    other.makeKeyAndOrderFront(nil)
    try await Task.sleep(for: .milliseconds(50))
    #expect(progress == 0)
    try await send("1337", to: other)
    #expect(unlocks == 0)
    about.makeKeyAndOrderFront(nil)
    try await Task.sleep(for: .milliseconds(50))
    try await send("1337", to: about)
    #expect(unlocks == 1)
    #expect(progress == 0)
}
